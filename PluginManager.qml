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
  property var listGood: null
  property var catalogGood: null
  property string query: ""
  property bool loading: false
  property string notice: ""
  property var busy: ({})
  property int cursorIndex: -1
  property int dataGeneration: 0
  property int listGeneration: -1
  property int catalogGeneration: -1
  property bool listReady: false
  property bool catalogReady: false
  property bool dataPending: false
  property bool refreshQueued: false
  property var lastGoodRows: []
  property bool gitChecksRequested: false
  property string pendingRemovalId: ""
  property string pendingRemovalName: ""
  property int actionGeneration: 0
  property bool actionRunning: false

  property var gitInfo: ({})
  property var gitChecks: []
  property string gitCurrentId: ""
  property int updatesAvailable: 0
  property int gitGeneration: 0
  property bool gitTimedOut: false
  property bool gitPending: false
  property string lastActionId: ""
  property bool lastActionNeedsGitRecheck: false

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
    if (!root.listReady || !root.catalogReady || root.listGood === null || root.catalogGood === null) return
    root.allPlugins = PM.merge(root.listGood, root.catalogGood)
    root.lastGoodRows = root.allPlugins.slice(0)
    root.rows = PM.applyFilter(root.allPlugins, root.query)
    root.loading = false
    if (root.cursorIndex >= root.rows.length) root.cursorIndex = root.rows.length - 1
    root.recomputeUpdatesAvailable()
    if (root.gitChecksRequested) root.scheduleGitChecks()
  }

  function stopDataProcesses() {
    root.dataPending = true
    root.listGeneration = -1
    root.catalogGeneration = -1
    listProc.running = false
    catalogProc.running = false
    dataTimeout.stop()
  }

  function startDataGeneration() {
    if (!root.dataPending) return
    if (listProc.running || catalogProc.running) {
      dataRestartTimer.restart()
      return
    }
    root.dataPending = false
    var generation = ++root.dataGeneration
    root.listGeneration = generation
    root.catalogGeneration = generation
    root.listReady = false
    root.catalogReady = false
    root.loading = true
    listProc.generation = generation
    catalogProc.generation = generation
    listProc.output = ""
    catalogProc.output = ""
    listProc.overflow = false
    catalogProc.overflow = false
    listProc.timedOut = false
    catalogProc.timedOut = false
    Qt.callLater(fetchAll)
  }

  function beginDataFetch() {
    stopDataProcesses()
    root.listReady = false
    root.catalogReady = false
    root.loading = true
    dataRestartTimer.restart()
  }

  function flushRefresh() {
    if (!root.refreshQueued) return
    root.refreshQueued = false
    if (root.loading || root.dataPending || root.actionRunning) {
      root.refreshQueued = true
      return
    }
    root.beginDataFetch()
  }

  function refresh() {
    root.notice = ""
    root.gitChecksRequested = false
    root.gitInfo = {}
    root.updatesAvailable = 0
    root.stopGitChecks()
    if (root.loading || root.dataPending || root.actionRunning) {
      root.refreshQueued = true
      return
    }
    root.beginDataFetch()
  }

  function softRefresh() {
    if (root.loading || root.dataPending || root.actionRunning) {
      root.refreshQueued = true
      return
    }
    root.beginDataFetch()
  }

  function queueRefresh() {
    if (root.refreshQueued) return
    root.refreshQueued = true
    Qt.callLater(root.flushRefresh)
  }

  function collectData(proc, chunk) {
    if (proc.overflow) return
    var value = String(chunk || "")
    if (proc.output.length + value.length > PM.MAX_DATA_BYTES) {
      proc.overflow = true
      proc.output = ""
      proc.running = false
      return
    }
    proc.output += value + "\n"
  }

  function boundedCommand(command, maximum, timeout) {
    if (!PM.validExternalCommand(command) || root.pluginDir === "") return []
    return ["/usr/bin/python3", "-I", root.pluginDir + "/bounded_exec.py", "run",
      "--max-output", String(maximum), "--timeout", String(timeout), "--"].concat(command)
  }

  function finishData(kind, exitCode) {
    var proc = kind === "list" ? listProc : catalogProc
    if (proc.generation !== root.dataGeneration) {
      if (!listProc.running && !catalogProc.running && root.dataPending) {
        dataRestartTimer.restart()
      }
      return
    }
    var body = String(proc.output || "")
    var valid = exitCode === 0 && !proc.overflow && !proc.timedOut
    var parsed = valid ? (kind === "list" ? PM.parseListResult(body) : PM.parseCatalogResult(body)) : null
    if (parsed && parsed.ok) {
      if (kind === "list") {
        root.listGood = parsed.data
        root.listReady = true
      } else {
        root.catalogGood = parsed.data
        root.catalogReady = true
      }
      root.reconcile()
    } else if (proc.timedOut) {
      root.setNotice(kind === "list" ? "Plugin list timed out" : "Plugin catalog timed out")
    } else {
      root.setNotice(kind === "list" ? "Plugin list unavailable" : "Plugin catalog unavailable")
    }
    proc.output = ""
    proc.overflow = false
    proc.timedOut = false
    if (!listProc.running && !catalogProc.running && root.dataPending) {
      dataRestartTimer.restart()
    } else if (!listProc.running && !catalogProc.running && (!root.listReady || !root.catalogReady)) {
      root.loading = false
    }
    if (!root.loading && !root.dataPending && root.refreshQueued)
      Qt.callLater(root.flushRefresh)
  }

  function fetchAll() {
    if (root.dataPending || root.listGeneration !== root.dataGeneration || root.catalogGeneration !== root.dataGeneration) return
    var listCommand = root.boundedCommand(PM.listCommand(), PM.MAX_DATA_BYTES, 15)
    var catalogCommand = root.boundedCommand(PM.catalogCommand(), PM.MAX_DATA_BYTES, 15)
    if (listCommand.length === 0 || catalogCommand.length === 0) {
      root.listReady = false
      root.catalogReady = false
      root.loading = false
      root.setNotice("Plugin commands are unavailable")
      return
    }
    if (!listProc.running) {
      listProc.command = listCommand
      listProc.running = true
    }
    if (!catalogProc.running) {
      catalogProc.command = catalogCommand
      catalogProc.running = true
    }
    dataTimeout.restart()
  }

  function rowById(id) {
    for (var i = 0; i < root.allPlugins.length; i++) {
      if (root.allPlugins[i].id === id) return root.allPlugins[i]
    }
    return null
  }

  Process {
    id: listProc
    property int generation: -1
    property string output: ""
    property bool overflow: false
    property bool timedOut: false
    command: []
    stdout: SplitParser {
      onRead: function(data) { root.collectData(listProc, data) }
    }
    stderr: SplitParser {}
    onExited: function(exitCode) { root.finishData("list", exitCode) }
  }

  Process {
    id: catalogProc
    property int generation: -1
    property string output: ""
    property bool overflow: false
    property bool timedOut: false
    command: []
    stdout: SplitParser {
      onRead: function(data) { root.collectData(catalogProc, data) }
    }
    stderr: SplitParser {}
    onExited: function(exitCode) { root.finishData("catalog", exitCode) }
  }

  Timer {
    id: dataRestartTimer
    interval: 100
    repeat: false
    onTriggered: root.startDataGeneration()
  }

  Timer {
    id: dataTimeout
    interval: 10000
    repeat: false
    onTriggered: {
      if (listProc.running) {
        listProc.timedOut = true
        listProc.signal(15)
        listProc.running = false
      }
      if (catalogProc.running) {
        catalogProc.timedOut = true
        catalogProc.signal(15)
        catalogProc.running = false
      }
      if (root.dataGeneration > 0 && (!listProc.running || !catalogProc.running)) {
        root.dataPending = true
        root.listGeneration = -1
        root.catalogGeneration = -1
        dataRestartTimer.restart()
      }
    }
  }

  // ---- Git update checks -------------------------------------------------

  readonly property string pluginDir: PM.scriptPath(String(Qt.resolvedUrl(".")))

  function gitState(id) {
    var g = root.gitInfo[id]
    return g ? String(g.status) : ""
  }

  function recomputeUpdatesAvailable() {
    var n = 0
    for (var i = 0; i < root.allPlugins.length; i++) {
      var g = root.gitInfo[root.allPlugins[i].id]
      if (g && g.status === "stale") n++
    }
    root.updatesAvailable = n
  }

  function setGitStatus(id, status, sha, reason) {
    if (!PM.validPluginId(id)) return
    var next = {}
    for (var key in root.gitInfo) next[key] = root.gitInfo[key]
    next[id] = { "status": String(status || "unknown"), "sha": String(sha || ""), "reason": String(reason || "") }
    root.gitInfo = next
    root.recomputeUpdatesAvailable()
  }

  function clearGitStatus(id) {
    if (root.gitInfo[id] === undefined) return
    var next = {}
    for (var key in root.gitInfo) if (key !== id) next[key] = root.gitInfo[key]
    root.gitInfo = next
    root.recomputeUpdatesAvailable()
  }

  function setBusy(id, value) {
    var next = {}
    for (var key in root.busy) next[key] = root.busy[key]
    if (value === true) next[id] = true
    else delete next[id]
    root.busy = next
  }

  function stopGitChecks() {
    root.gitGeneration++
    root.gitPending = true
    gitCheckProc.running = false
    gitTimeout.stop()
    root.gitChecks = []
    root.gitCurrentId = ""
    gitRestartTimer.restart()
  }

  function requestGitChecks() {
    root.gitChecksRequested = true
    root.gitInfo = {}
    root.updatesAvailable = 0
    root.stopGitChecks()
    if (root.loading || root.allPlugins.length === 0) {
      root.setNotice("Open the panel to check for updates")
      return
    }
    root.scheduleGitChecks()
  }

  function scheduleGitChecks() {
    if (!root.gitChecksRequested) return
    for (var i = 0; i < root.allPlugins.length; i++) {
      var p = root.allPlugins[i]
      if (p.firstParty || !p.sourceDir || !PM.validPath(p.sourceDir)) continue
      root.enqueueGitCheck(p.id, String(p.sourceDir))
    }
  }

  function enqueueGitCheck(id, dir) {
    if (!PM.validPluginId(id) || !PM.validPath(dir) || root.gitInfo[id] !== undefined) return
    if (root.gitChecks.length >= PM.MAX_GIT_CHECKS) {
      root.setGitStatus(id, "unknown", "", "queue limit")
      return
    }
    root.setGitStatus(id, "checking", "", "")
    var queue = root.gitChecks.slice(0)
    queue.push({ "id": String(id), "dir": String(dir) })
    root.gitChecks = queue
    root.gitCheckNext()
  }

  function collectGit(data) {
    if (gitCheckProc.overflow) return
    var value = String(data || "")
    if (gitCheckProc.output.length + value.length > 4096) {
      gitCheckProc.overflow = true
      gitCheckProc.output = ""
      gitCheckProc.signal(15)
      gitCheckProc.running = false
      if (root.gitCurrentId) {
        root.setGitStatus(root.gitCurrentId, "unknown", "", "")
        root.gitCurrentId = ""
      }
      gitRestartTimer.restart()
      return
    }
    gitCheckProc.output += value + "\n"
  }

  function gitCheckNext() {
    if (root.gitPending) {
      gitRestartTimer.restart()
      return
    }
    if (root.gitCurrentId !== "" || root.gitChecks.length === 0) return
    var queue = root.gitChecks.slice(0)
    var job = queue.shift()
    root.gitChecks = queue
    root.gitCurrentId = job.id
    var generation = ++root.gitGeneration
    gitCheckProc.generation = generation
    gitCheckProc.output = ""
    gitCheckProc.overflow = false
    gitCheckProc.timedOut = false
    var command = root.boundedCommand([
      "/usr/bin/python3", "-I", root.pluginDir + "/git_check.py", String(job.dir)
    ], 8192, 20)
    if (command.length === 0) {
      root.setGitStatus(job.id, "unknown", "", "helper unavailable")
      root.gitCurrentId = ""
      root.gitCheckNext()
      return
    }
    gitCheckProc.command = command
    gitCheckProc.running = true
    gitTimeout.restart()
  }

  Process {
    id: gitCheckProc
    property int generation: -1
    property string output: ""
    property bool overflow: false
    property bool timedOut: false
    command: []
    stdout: SplitParser {
      onRead: function(data) { root.collectGit(data) }
    }
    stderr: SplitParser {}
    onExited: function(exitCode) {
      if (gitCheckProc.generation !== root.gitGeneration) {
        if (!gitCheckProc.running) gitRestartTimer.restart()
        return
      }
      gitTimeout.stop()
      var id = root.gitCurrentId
      if (!id) return
      root.gitCurrentId = ""
      var body = String(gitCheckProc.output || "")
      var lines = body.trim().split("\n").filter(function(line) { return line.trim() !== "" })
      var sha = lines.length > 0 ? lines[0].trim() : ""
      var status = lines.length > 1 ? lines[1].trim() : ""
      var reason = lines.length > 2 ? lines[2].trim() : ""
      if (gitCheckProc.overflow || gitCheckProc.timedOut || exitCode !== 0) {
        status = "unknown"
        sha = ""
        reason = ""
      } else if (status === "STALE") status = "stale"
      else if (status === "UP-TO-DATE") status = "current"
      else if (status === "DIRTY" || status === "DIVERGED") status = "blocked"
      else { status = "unknown"; sha = ""; reason = "" }
      if (!/^[0-9a-f]{7,64}$/.test(sha) && status !== "unknown") sha = ""
      root.setGitStatus(id, status, sha, reason.slice(0, 256))
      gitCheckProc.output = ""
      gitCheckProc.overflow = false
      gitCheckProc.timedOut = false
      root.gitCheckNext()
    }
  }

  Timer {
    id: gitRestartTimer
    interval: 100
    repeat: false
    onTriggered: {
      if (!gitCheckProc.running) {
        root.gitPending = false
        root.gitCheckNext()
      } else {
        gitRestartTimer.restart()
      }
    }
  }

  Timer {
    id: gitTimeout
    interval: 15000
    repeat: false
    onTriggered: {
      if (!gitCheckProc.running) return
      gitCheckProc.timedOut = true
      gitCheckProc.signal(15)
      gitCheckProc.running = false
      if (root.gitCurrentId) {
        root.setGitStatus(root.gitCurrentId, "unknown", "", "")
        root.gitCurrentId = ""
      }
      gitRestartTimer.restart()
    }
  }

  // ---- Actions -----------------------------------------------------------
  function rowBusy(id) {
    return root.busy[id] === true
  }

  function clearPendingRemoval() {
    root.pendingRemovalId = ""
    root.pendingRemovalName = ""
  }

  function runPluginsCommand(command, successMsg, failMsg, idOverride, needsGitRecheck) {
    if (!Array.isArray(command) || command.length === 0 || command.length > 8) return
    var id = idOverride !== undefined ? String(idOverride) : String(command[command.length - 1])
    if (!PM.validPluginId(id) || id === PM.SELF_ID || root.actionRunning || root.rowBusy(id)) return
    var entry = root.rowById(id)
    if (!entry || entry.isBar || root.loading) return
    var bounded = root.boundedCommand(command, 65536, 120)
    if (bounded.length === 0) return
    root.setBusy(id, true)
    root.lastActionId = id
    root.lastActionNeedsGitRecheck = needsGitRecheck === true
    actionProc.generation = ++root.actionGeneration
    actionProc.timedOut = false
    actionProc.command = bounded
    actionProc._successMsg = String(successMsg || "").slice(0, 256)
    actionProc._failMsg = String(failMsg || "").slice(0, 256)
    root.actionRunning = true
    actionProc.running = true
    actionTimeout.restart()
  }

  function toggleRow(row) {
    if (!row || !row.canToggle || row.enabledState === "unknown" || root.rowBusy(row.id) || root.busy["*"]) return
    if (row.enabled) root.runPluginsCommand(PM.disableCommand(row.id), "Disabled " + row.name, "Failed to disable " + row.name, row.id, false)
    else root.runPluginsCommand(PM.enableCommand(row.id), "Enabled " + row.name, "Failed to enable " + row.name, row.id, false)
  }

  function removeRow(row) {
    if (!row || !row.canRemove || root.rowBusy(row.id) || root.busy["*"]) return
    if (root.pendingRemovalId !== row.id) {
      root.pendingRemovalId = row.id
      root.pendingRemovalName = row.name
      root.setNotice("Click uninstall again to remove " + row.name)
      return
    }
    root.clearPendingRemoval()
    root.runPluginsCommand(PM.removeCommand(row.id), "Removed " + row.name, "Failed to remove " + row.name, row.id, true)
  }

  function updateRow(row) {
    if (!row || row.firstParty || root.rowBusy(row.id) || root.busy["*"]) return
    if (root.gitState(row.id) !== "stale") return
    root.clearGitStatus(row.id)
    root.runPluginsCommand(
      PM.updateCommand(row.id, root.pluginDir + "/git_update.py", row.sourceDir),
      "Updated " + row.name,
      "Failed to update " + row.name,
      row.id,
      true
    )
  }

  function updateAll() {
    if (root.actionRunning || root.updatesAvailable <= 0) return
    for (var id in root.busy) if (root.busy[id] === true) return
    var updateCommand = PM.updateAllCommand()
    if (!PM.validExternalCommand(updateCommand)) return
    root.gitChecksRequested = false
    root.gitInfo = {}
    root.updatesAvailable = 0
    root.stopGitChecks()
    root.setNotice("Updating all plugins…")
    Quickshell.execDetached(updateCommand)
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
    root.notice = String(text || "").slice(0, 512)
    noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: {
      root.notice = ""
      root.clearPendingRemoval()
    }
  }

  function completeAction(success) {
    if (!root.actionRunning) return
    actionTimeout.stop()
    root.actionRunning = false
    root.finishAction(success === true)
  }

  Process {
    id: actionProc
    property int generation: -1
    property bool timedOut: false
    property string _successMsg: ""
    property string _failMsg: ""
    command: []
    stdout: SplitParser {}
    stderr: SplitParser {}
    onExited: function(exitCode) {
      if (actionProc.generation !== root.actionGeneration) return
      completeAction(exitCode === 0 && !actionProc.timedOut)
      actionProc.timedOut = false
    }
  }

  Timer {
    id: actionTimeout
    interval: 120000
    repeat: false
    onTriggered: {
      if (!actionProc.running) return
      actionProc.timedOut = true
      actionProc.signal(15)
      actionProc.running = false
      actionProc.generation = -1
      completeAction(false)
    }
  }

  function finishAction(success) {
    root.busy = {}
    var touched = root.lastActionId
    var recheck = root.lastActionNeedsGitRecheck && success
    root.lastActionId = ""
    root.lastActionNeedsGitRecheck = false
    if (recheck && touched && touched !== "*") root.clearGitStatus(touched)
    var message = success ? actionProc._successMsg : actionProc._failMsg
    root.setNotice(message || (success ? "Action completed" : "Action failed"))
    Qt.callLater(function() { root.softRefresh() })
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

  onOpenedChanged: {
    if (!opened) {
      root.clearPendingRemoval()
      return
    }
    if (!root.loading && root.allPlugins.length === 0) root.softRefresh()
  }

  onSettingsChanged: root.queueRefresh()

  Component.onCompleted: root.softRefresh()

  // ---- Bar button --------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    active: root.opened
    tooltipText: root.updatesAvailable > 0
      ? "Plugin Manager — " + root.updatesAvailable + (root.updatesAvailable > 1 ? " updates" : " update") + " available"
      : "Plugin Manager"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.close()
      else root.toggle()
    }
  }

  // Update notifier: an accent dot on the bar button whenever any git-managed
  // plugin has a newer commit on its origin.
  Rectangle {
    visible: root.updatesAvailable > 0
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
         else if (c === "r" || c === "R") {
           if (!root.loading && !root.actionRunning) root.refresh()
         }
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
              visible: root.updatesAvailable > 0
              iconText: "\uf01e"
              tooltipText: "Update all plugins (" + root.updatesAvailable + " available)"
              foreground: Color.accent
              hoverColor: Color.accent
              fontFamily: root.bar.fontFamily
              enabled: !root.busy["*"] && !root.loading
              onClicked: root.updateAll()
            }

            PanelActionButton {
              id: checkUpdatesBtn
              iconText: "\uf1e0"
              tooltipText: "Check for plugin updates"
              foreground: root.bar.foreground
              hoverColor: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: !root.loading && !root.gitChecksRequested
              onClicked: root.requestGitChecks()
            }

            PanelActionButton {
              id: refreshBtn
              iconText: "\uf021"
              tooltipText: "Refresh"
              foreground: root.bar.foreground
              hoverColor: root.bar.foreground
              fontFamily: root.bar.fontFamily
              enabled: !root.loading && !root.actionRunning
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
             root.query = String(text || "").slice(0, 256)
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
                    || root.gitState(row.id) === "stale"

                  PanelActionButton {
                    id: updateBtn
                    visible: root.gitState(row.id) === "stale" && !row.firstParty
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
                     tooltipText: root.pendingRemovalId === row.id
                       ? "Confirm uninstall " + row.name
                       : "Uninstall " + row.name
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
        Column {
          visible: root.allPlugins.length > 0
          width: parent.width
          spacing: Style.space(6)

          Button {
            id: updateAllFooter
            text: root.updatesAvailable > 0
              ? (root.updatesAvailable > 1
                  ? "Update all (" + root.updatesAvailable + ")"
                  : "Update all")
              : "Up to date"
            iconText: "\uf01e"
            foreground: root.updatesAvailable > 0 ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
            accent: Color.accent
            iconSize: Style.font.caption
            fontSize: Style.font.caption
            fontFamily: root.bar.fontFamily
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(4)
            tooltipText: root.updatesAvailable > 0
              ? "Update all " + root.updatesAvailable + " stale plugin" + (root.updatesAvailable > 1 ? "s" : "")
              : "All plugins are up to date"
            enabled: root.updatesAvailable > 0 && !root.busy["*"] && !root.loading
            iconSpinning: root.busy["*"] === true
            onClicked: root.updateAll()
          }

          Text {
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
  }

  // ---- Helpers used from delegates / hero -------------------------------
  function heroSummary() {
    var s = PM.summary(root.allPlugins)
    var part = s.installed + " plugins"
    var state = s.enabled + " enabled"
    if (s.unknown > 0) state += " · " + s.unknown + " unknown"
    if (root.query !== "") part = root.rows.length + " of " + s.installed
    var up = root.updatesAvailable
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
    if (row.enabledState === "unknown") parts.push("state unknown")
    else if (!row.enabled) parts.push("disabled")
    var g = root.gitInfo[row.id]
    if (g) {
      if (g.status === "stale") parts.push("update available")
      else if (g.status === "blocked") parts.push("no update · " + (g.reason || "has local edits"))
      else if (g.status === "unknown") parts.push("update state unknown")
      else if (g.status === "checking") parts.push("checking…")
      if (g.sha) parts.push("@" + g.sha)
    }
    if (root.rowBusy(row.id)) parts.push("working…")
    return parts.join("  ·  ")
  }

  Component.onDestruction: {
    root.dataGeneration++
    root.listGeneration = -1
    root.catalogGeneration = -1
    root.gitGeneration++
    root.gitPending = true
    root.gitChecks = []
    root.gitCurrentId = ""
    root.actionGeneration++
    root.actionRunning = false
    root.busy = ({})
    listProc.running = false
    catalogProc.running = false
    gitCheckProc.running = false
    actionProc.running = false
    dataTimeout.stop()
    gitTimeout.stop()
    actionTimeout.stop()
    dataRestartTimer.stop()
    gitRestartTimer.stop()
    noticeTimer.stop()
  }
}
