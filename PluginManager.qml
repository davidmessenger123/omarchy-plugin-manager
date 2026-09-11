import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PluginManager.js" as PM

// Plugin Manager — a bar widget that manages installed Omarchy shell plugins.
//
// Data comes from two read-only commands run as processes:
//   - omarchy plugin list --json   -> enabled/canDisable/firstParty state
//   - omarchy-plugin-catalog       -> metadata, manifest path, schema
// Actions shell out to the same CLI the user would type, so everything here
// stays in sync with `omarchy plugin ...`.
Panel {
  id: root
  moduleName: "davidjm.plugin-manager"

  // No ipcTarget: keep the IpcHandler off so multiple monitor copies of this
  // widget never fight over one target.

  // ---- State -------------------------------------------------------------
  property var allPlugins: []
  property var rows: []
  property var listRaw: null
  property var catalogRaw: null
  property string query: ""
  property bool loading: false
  property string notice: ""
  property var busy: ({})
  property int cursorIndex: -1

  // Per-plugin git status: id -> "checking" | "current" | "stale" | "unknown".
  // "stale" means the installed checkout is behind its origin, i.e. an update
  // is available for that plugin.
  property var gitInfo: ({})
  property var gitChecks: []
  property string gitCurrentId: ""

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string iconText: "\uf1b3"

  readonly property real listRowHeight: Style.space(48)
  readonly property real maxListHeight: Style.space(340)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function listHeight() {
    if (root.rows.length === 0) return Style.space(72)
    return Math.min(root.rows.length * root.listRowHeight, root.maxListHeight)
  }

  // ---- Data loading ------------------------------------------------------
  function reconcile() {
    if (root.listRaw === null || root.catalogRaw === null) return
    root.allPlugins = PM.merge(PM.parseList(root.listRaw), PM.parseCatalog(root.catalogRaw))
    root.rows = PM.applyFilter(root.allPlugins, root.query)
    root.loading = false
    if (root.cursorIndex >= root.rows.length) root.cursorIndex = root.rows.length - 1
    root.scheduleGitChecks()
  }

  function refresh() {
    root.listRaw = null
    root.catalogRaw = null
    root.loading = true
    root.notice = ""
    root.gitInfo = {}
    root.gitChecks = []
    root.gitCurrentId = ""
    listProc.running = false
    catalogProc.running = false
    Qt.callLater(fetchAll)
  }

function fetchAll() {
    if (!listProc.running) listProc.running = true
    if (!catalogProc.running) catalogProc.running = true
  }

  function rowById(id) {
    for (var i = 0; i < root.allPlugins.length; i++) {
      if (root.allPlugins[i].id === id) return root.allPlugins[i]
    }
    return null
  }

  Process {
    id: listProc
    command: PM.listCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.listRaw = text
        root.reconcile()
      }
    }
  }

  Process {
    id: catalogProc
    command: PM.catalogCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.catalogRaw = text
        root.reconcile()
      }
    }
  }

  // ---- Git update checks -------------------------------------------------

  // Compares the installed checkout's HEAD against its origin's HEAD. Prints
  // two lines: "<short-sha>" then STALE (a newer commit exists) or
  // UP-TO-DATE. Non-git folders or missing origins exit non-zero and map to
  // "unknown" — no update UI, no SHA shown.
  readonly property string gitCheckScript:
    "dir=$1;"
    + "full=$(git -C \"$dir\" rev-parse HEAD 2>/dev/null) || exit 3;"
    + "short=$(git -C \"$dir\" rev-parse --short=7 HEAD 2>/dev/null) || exit 3;"
    + "remote=$(git -C \"$dir\" ls-remote origin HEAD 2>/dev/null | cut -f1) || exit 4;"
    + "[ -n \"$remote\" ] || exit 4;"
    + "echo \"$short\";"
    + "[ \"$remote\" = \"$full\" ] && echo UP-TO-DATE || echo STALE"

  function scheduleGitChecks() {
    for (var i = 0; i < root.allPlugins.length; i++) {
      var p = root.allPlugins[i]
      if (p.firstParty || !p.sourceDir) continue
      root.enqueueGitCheck(p.id, String(p.sourceDir))
    }
  }

  function enqueueGitCheck(id, dir) {
    if (root.gitInfo[id] !== undefined) return
    root.gitInfo[id] = { "status": "checking", "sha": "" }
    root.gitChecks.push({ "id": id, "dir": dir })
    root.gitCheckNext()
  }

  function gitCheckNext() {
    if (root.gitCurrentId !== "" || root.gitChecks.length === 0) return
    var job = root.gitChecks.shift()
    root.gitCurrentId = job.id
    gitCheckProc.command = ["bash", "-c", root.gitCheckScript, "check", job.dir]
    gitCheckProc.running = true
  }

  function updateCount() {
    var n = 0
    for (var i = 0; i < root.allPlugins.length; i++) {
      var g = root.gitInfo[root.allPlugins[i].id]
      if (g && g.status === "stale") n++
    }
    return n
  }

  Process {
    id: gitCheckProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = root.gitCurrentId
        root.gitCurrentId = ""
        var lines = String(text || "").trim().split("\n")
        var sha = lines.length > 0 ? lines[0].trim() : ""
        var status = lines.length > 1 ? lines[1].trim() : ""
        if (status === "STALE") status = "stale"
        else if (status === "UP-TO-DATE") status = "current"
        else { status = "unknown"; sha = "" }
        root.gitInfo[id] = { "status": status, "sha": sha }
        root.gitCheckNext()
      }
    }
  }

  // ---- Actions -----------------------------------------------------------
  function rowBusy(id) {
    return root.busy[id] === true
  }

  function runPluginsCommand(command, successMsg, failMsg, idOverride) {
    var id = idOverride !== undefined ? idOverride : command[command.length - 1]
    if (!id || root.rowBusy(id)) return
    if (root.allPlugins.length > 0 && root.rowById(id)) {
      var entry = root.rowById(id)
      if (entry.isBar) return
      root.busy[id] = true
    }
    actionProc.command = command
    actionProc._successMsg = successMsg
    actionProc._failMsg = failMsg
    actionProc.running = true
  }

  function toggleRow(row) {
    if (!row || row.isBar || root.rowBusy(row.id)) return
    if (row.enabled) root.runPluginsCommand(PM.disableCommand(row.id), "Disabled " + row.name, "Failed to disable " + row.name)
    else root.runPluginsCommand(PM.enableCommand(row.id), "Enabled " + row.name, "Failed to enable " + row.name)
  }

  function removeRow(row) {
    if (!row || !row.canRemove || root.rowBusy(row.id)) return
    root.runPluginsCommand(PM.removeCommand(row.id), "Removed " + row.name, "Failed to remove " + row.name, row.id)
  }

  function updateRow(row) {
    if (!row || row.firstParty || root.rowBusy(row.id) || root.busy["*"]) return
    delete root.gitInfo[row.id]
    root.runPluginsCommand(PM.updateCommand(row.id), "Updated " + row.name, "Failed to update " + row.name, row.id)
  }

  function updateAll() {
    if (root.busy["*"]) return
    root.busy["*"] = true
    root.gitInfo = {}
    root.gitChecks = []
    root.gitCurrentId = ""
    actionProc.command = PM.updateAllCommand()
    actionProc._successMsg = "Updated all plugins"
    actionProc._failMsg = "Failed to update plugins"
    actionProc.running = true
  }

  function updateCursor() {
    var row = root.cursorRow()
    if (row) root.updateRow(row)
  }

  function configureRow(row) {
    if (!row || !row.canConfigure) return
    var cmd = PM.configureCommand(row, root.home)
    if (cmd) Quickshell.execDetached(cmd)
  }

  function openMarketplace() {
    Quickshell.execDetached(PM.marketplaceCommand())
  }

  function setNotice(text) {
    root.notice = text
    noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: root.notice = ""
  }

  Process {
    id: actionProc
    property string _successMsg: ""
    property string _failMsg: ""
    // The exit code is the ground truth — an action may print nothing yet
    // still fail (offline, local edits blocking a fast-forward, invalid repo).
    onExited: function(exitCode) {
      root.finishAction(exitCode === 0 ? root.actionProc._successMsg : root.actionProc._failMsg)
    }
  }

  function finishAction(msg) {
    var hasBusy = false
    for (var id in root.busy) {
      if (root.busy[id]) { hasBusy = true; root.busy[id] = false }
    }
    root.setNotice(msg)
    Qt.callLater(function() { root.refresh() })
  }

  // ---- Keyboard cursor ---------------------------------------------------
  function clampIndex(i) {
    if (root.rows.length === 0) return -1
    if (i < 0) return 0
    if (i >= root.rows.length) return root.rows.length - 1
    return i
  }

  function moveCursor(dy) {
    if (root.rows.length === 0) return
    if (root.cursorIndex < 0) { root.cursorIndex = 0; return }
    root.cursorIndex = root.clampIndex(root.cursorIndex + dy)
  }

  function cursorRow() {
    return root.cursorIndex >= 0 && root.cursorIndex < root.rows.length
      ? root.rows[root.cursorIndex] : null
  }

  function activateCursor() {
    var row = root.cursorRow()
    if (row) root.toggleRow(row)
  }

  function deleteCursor() {
    var row = root.cursorRow()
    if (row) root.removeRow(row)
  }

  function configureCursor() {
    var row = root.cursorRow()
    if (row) root.configureRow(row)
  }

  // ---- Lifecycle ---------------------------------------------------------
  onOpenedChanged: {
    if (opened && root.allPlugins.length === 0) root.refresh()
  }

  Component.onCompleted: root.refresh()

  // ---- Bar button --------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    active: root.opened
    tooltipText: root.updateCount() > 0
      ? "Plugin Manager — " + root.updateCount() + (root.updateCount() > 1 ? " updates" : " update") + " available"
      : "Plugin Manager"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.close()
      else root.toggle()
    }
  }

  // Update notifier: an accent dot on the bar button whenever any git-managed
  // plugin has a newer commit on its origin.
  Rectangle {
    visible: root.updateCount() > 0
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: 1
    anchors.topMargin: 1
    width: Style.space(9)
    height: Style.space(9)
    radius: width / 2
    color: Color.accent
    border.color: root.bar ? root.bar.background : Color.background
    border.width: 2
    z: 2
  }

  // ---- Popup panel -------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0 && root.cursorIndex >= 0) {
          var row = root.cursorRow()
          if (row) {
            if (dx > 0) root.configureRow(row)
            else root.toggleRow(row)
          }
        }
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: root.deleteCursor()
      onTextKey: function(t) {
        var c = String(t)
        if (c === "/") searchField.forceActiveFocus()
        else if (c === "c" || c === "C") root.configureCursor()
        else if (c === "m" || c === "M") root.openMarketplace()
        else if (c === "r" || c === "R") root.refresh()
        else if (c === "u" || c === "U") root.updateCursor()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconText
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroActions.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Plugin Manager"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.loading ? "LOADING…" : root.heroSummary()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: heroActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              id: updateAllBtn
              visible: root.updateCount() > 0
              iconText: "\uf01e"
              tooltipText: "Update all plugins (" + root.updateCount() + " available)"
              foreground: Color.accent
              hoverColor: Color.accent
              fontFamily: root.bar.fontFamily
              enabled: !root.busy["*"] && !root.loading
              onClicked: root.updateAll()
            }

            PanelActionButton {
              iconText: "\uf021"
              tooltipText: "Refresh"
              foreground: root.bar.foreground
              hoverColor: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.refresh()
            }

            PanelActionButton {
              iconText: "\uf0ac"
              tooltipText: "Open Plugin Marketplace"
              foreground: root.bar.foreground
              hoverColor: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.openMarketplace()
            }
          }
        }

        // ---------- Search ----------
        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search plugins…"
          foreground: root.bar.foreground
          accent: root.bar.foreground
          text: root.query
          onTextChanged: {
            root.query = text
            root.rows = PM.applyFilter(root.allPlugins, root.query)
            root.cursorIndex = -1
          }
        }

        // ---------- Notice ----------
        Text {
          visible: root.notice !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.notice
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // ---------- List ----------
        Item {
          id: listClip
          width: parent.width
          height: root.listHeight()

          ListView {
            id: itemList
            anchors.fill: parent
            clip: true
            model: root.rows

delegate: Item {
              id: rowItem
              required property var modelData
              required property int index
              readonly property var row: modelData
              width: ListView.view.width
              height: root.listRowHeight

              readonly property bool cursorSelected: itemList.currentIndex === index || root.cursorIndex === index

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: rowItem.cursorSelected
                  ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                  : (rowHover.containsMouse
                      ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                      : "transparent")
                Behavior on color { ColorAnimation { duration: 60 } }
              }

              MouseArea {
                id: rowHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor

                onEntered: {
                  root.cursorIndex = index
                  itemList.currentIndex = index
                }
                onClicked: function(mouse) {
                  root.cursorIndex = index
                  itemList.currentIndex = index
                  if (mouse.button === Qt.RightButton) root.removeRow(row)
                  else root.toggleRow(row)
                }
              }

              Item {
                id: rowContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(6)
                implicitHeight: Math.max(kindIcon.implicitHeight, info.implicitHeight)

                Text {
                  id: kindIcon
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.isBar ? "\uf0e8" : (row.isBarWidget ? "\uf1b3" : "\uf1b2")
                  color: row.enabled ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.heading
                  opacity: row.enabled ? 1 : 0.6
                }

                Column {
                  id: info
                  spacing: Style.space(1)
                  anchors.left: kindIcon.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: actions.visible ? actions.left : parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    textFormat: Text.PlainText
                    text: row.name
                    color: row.enabled ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: row.firstParty
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    id: meta
                    textFormat: Text.PlainText
                    text: root.rowMeta(row)
                    color: row.enabled ? Qt.darker(root.bar.foreground, 1.35) : Qt.darker(root.bar.foreground, 1.7)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Row {
                  id: actions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)
                  visible: row.canToggle || row.canConfigure || row.canRemove
                    || (root.gitInfo[row.id] && root.gitInfo[row.id].status === "stale")

                  PanelActionButton {
                    id: updateBtn
                    visible: root.gitInfo[row.id] && root.gitInfo[row.id].status === "stale" && !row.firstParty
                    iconText: "\uf01e"
                    tooltipText: "Update " + row.name
                    foreground: Color.accent
                    hoverColor: Color.accent
                    fontFamily: root.bar.fontFamily
                    enabled: !root.rowBusy(row.id) && !root.busy["*"]
                    onClicked: root.updateRow(row)
                  }

                  PanelActionButton {
                    id: configureBtn
                    visible: row.canConfigure
                    iconText: "\uf013"
                    tooltipText: "Configure " + row.name
                    foreground: root.bar.foreground
                    hoverColor: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    enabled: !root.rowBusy(row.id)
                    onClicked: root.configureRow(row)
                  }

                  PanelActionButton {
                    id: toggleBtn
                    visible: row.canToggle
                    iconText: row.enabled ? "\uf011" : "\uf00c"
                    tooltipText: row.enabled ? "Disable " + row.name : "Enable " + row.name
                    foreground: root.bar.foreground
                    hoverColor: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    enabled: !root.rowBusy(row.id)
                    onClicked: root.toggleRow(row)
                  }

                  PanelActionButton {
                    id: removeBtn
                    visible: row.canRemove
                    iconText: "\uf1f8"
                    tooltipText: "Uninstall " + row.name
                    foreground: root.bar.foreground
                    hoverColor: root.bar.urgent
                    fontFamily: root.bar.fontFamily
                    enabled: !root.rowBusy(row.id)
                    onClicked: root.removeRow(row)
                  }
                }
              }
            }
          }

          Column {
            visible: root.rows.length === 0 && !root.loading
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "\uf05a"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.heading
              anchors.horizontalCenter: parent.horizontalCenter
            }
            Text {
              text: root.query === ""
                ? "No plugins found"
                : "No plugins match \"" + root.query + "\""
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.horizontalCenter: parent.horizontalCenter
            }
          }

          Column {
            visible: root.loading
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "\uf110"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.heading
              anchors.horizontalCenter: parent.horizontalCenter
            }
            Text {
              text: "Loading plugins…"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.horizontalCenter: parent.horizontalCenter
            }
          }
        }

        // ---------- Footer ----------
        Text {
          visible: root.allPlugins.length > 0
          width: parent.width
          textFormat: Text.PlainText
          text: "  /  search   ·   enter  toggle   ·   c  configure   ·   u  update   ·   del  remove   ·   m  marketplace"
          color: Qt.darker(root.bar.foreground, 1.7)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // ---- Helpers used from delegates / hero -------------------------------
  function heroSummary() {
    var s = PM.summary(root.allPlugins)
    var part = s.installed + " plugins"
    var state = s.enabled + " enabled"
    if (root.query !== "") part = root.rows.length + " of " + s.installed
    var up = root.updateCount()
    if (up > 0) state = up + " update" + (up > 1 ? "s" : "") + " available"
    return (part + "  ·  " + state).toUpperCase()
  }

  function rowMeta(row) {
    var parts = []
    parts.push(row.id)
    if (row.firstParty) parts.push("first-party")
    else parts.push("third-party")
    if (row.hasSchema) parts.push("configurable")
    if (row.clonedFrom) parts.push("clone of " + row.clonedFrom)
    if (!row.enabled) parts.push("disabled")
    var g = root.gitInfo[row.id]
    if (g) {
      if (g.status === "stale") parts.push("update available")
      if (g.status === "checking") parts.push("checking…")
      if (g.sha) parts.push("@" + g.sha)
    }
    if (root.rowBusy(row.id)) parts.push("working…")
    return parts.join("  ·  ")
  }
}