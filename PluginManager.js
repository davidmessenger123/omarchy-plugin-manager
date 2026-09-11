.pragma library

var SELF_ID = "davidjm.plugin-manager"
var MARKETPLACE_URL = "https://plugins.omarchy.org/"

function listCommand() {
  return ["omarchy", "plugin", "list", "--json"]
}

function catalogCommand() {
  return ["omarchy-plugin-catalog"]
}

function parseList(text) {
  try {
    var arr = JSON.parse(text || "[]")
    return Array.isArray(arr) ? arr : []
  } catch (e) {
    return []
  }
}

function parseCatalog(text) {
  try {
    var arr = JSON.parse(text || "[]")
    return Array.isArray(arr) ? arr : []
  } catch (e) {
    return []
  }
}

function merge(list, catalog) {
  var rows = []
  for (var i = 0; i < catalog.length; i++) {
    var cat = catalog[i] || {}
    if (!cat.id) continue
    var st = {}
    for (var k = 0; k < list.length; k++) {
      if (list[k] && list[k].id === cat.id) { st = list[k]; break }
    }
    var kinds = Array.isArray(cat.kinds) ? cat.kinds : []
    var bw = cat.barWidget || {}
    var schema = Array.isArray(bw.schema) ? bw.schema : []
    var id = String(cat.id)

    rows.push({
      id: id,
      name: String(cat.name || id),
      description: String(cat.description || ""),
      kinds: kinds,
      kindLabel: kinds.join(", "),
      enabled: !!st.enabled,
      canToggle: st.canDisable !== false,
      firstParty: !!cat.firstParty,
      clonedFrom: String(st.clonedFrom || ""),
      schema: schema,
      hasSchema: schema.length > 0,
      sourceDir: String(cat.sourceDir || ""),
      manifestPath: String(cat.manifestPath || ""),
      isBar: kinds.indexOf("bar") !== -1,
      isBarWidget: kinds.indexOf("bar-widget") !== -1,
      isSelf: id === SELF_ID,
      // A plugin is configurable when its manifest exposes a settings
      // schema, when it is a bar widget (inline settings in shell.json),
      // or when it is a user/third-party copy the user owns.
      canConfigure: !cat.firstParty || kinds.indexOf("bar-widget") !== -1 || schema.length > 0,
      canRemove: !cat.firstParty && kinds.indexOf("bar") === -1 && id !== SELF_ID
    })
  }

  rows.sort(function(a, b) {
    var aEnabled = a.enabled ? 1 : 0
    var bEnabled = b.enabled ? 1 : 0
    if (aEnabled !== bEnabled) return bEnabled - aEnabled
    return a.name.localeCompare(b.name)
  })
  return rows
}

function applyFilter(rows, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return rows
  return rows.filter(function(r) {
    var source = r.firstParty ? "first-party" : "third-party"
    return r.name.toLowerCase().indexOf(q) !== -1
      || r.id.toLowerCase().indexOf(q) !== -1
      || r.kindLabel.toLowerCase().indexOf(q) !== -1
      || source.indexOf(q) !== -1
  })
}

function summary(rows) {
  var enabled = 0
  var installed = 0
  for (var i = 0; i < rows.length; i++) {
    installed += 1
    if (rows[i].enabled) enabled += 1
  }
  return { installed: installed, enabled: enabled }
}

function enableCommand(id) {
  return ["omarchy", "plugin", "enable", id]
}

function disableCommand(id) {
  return ["omarchy", "plugin", "disable", id]
}

function removeCommand(id) {
  return ["omarchy", "plugin", "remove", id, "--yes"]
}

// --yes must come after the id, so callers pass the id explicitly as the
// runPluginsCommand idOverride (the last-argv fallback would read "--yes").
function updateCommand(id) {
  return ["omarchy", "plugin", "update", id, "--yes"]
}

function updateAllCommand() {
  return ["omarchy", "plugin", "update", "--yes"]
}

function configureCommand(row, home) {
  // Third-party copies live in the user config dir and are owned by the
  // user; open the plugin folder for editing. First-party widgets configure
  // through their inline shell.json entry.
  if (!row.firstParty) {
    var dir = row.sourceDir || String(home) + "/.config/omarchy/plugins/" + row.id
    return ["omarchy-launch-editor", dir]
  }
  return ["omarchy-launch-editor", String(home) + "/.config/omarchy/shell.json"]
}

function marketplaceCommand() {
  return ["omarchy-launch-browser", MARKETPLACE_URL]
}