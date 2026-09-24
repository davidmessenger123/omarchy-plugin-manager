.pragma library

var SELF_ID = "davidjm.plugin-manager"
var MARKETPLACE_URL = "https://plugins.omarchy.org/"
var OMARCHY_PATH = "/usr/share/omarchy/bin/omarchy"
var CATALOG_PATH = "/usr/share/omarchy/bin/omarchy-plugin-catalog"
var EDITOR_PATH = "/usr/share/omarchy/bin/omarchy-launch-editor"
var BROWSER_PATH = "/usr/share/omarchy/bin/omarchy-launch-browser"
var MAX_DATA_BYTES = 2 * 1024 * 1024
var MAX_ENTRIES = 10000
var MAX_GIT_CHECKS = 256
var MAX_TEXT = 4096

function listCommand() {
  return [OMARCHY_PATH, "plugin", "list", "--json"]
}

function catalogCommand() {
  return [CATALOG_PATH]
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function text(value, fallback) {
  if (value === undefined || value === null) return fallback || ""
  var result = String(value)
  return result.length > MAX_TEXT ? result.slice(0, MAX_TEXT) : result
}

function validPluginId(value) {
  var id = String(value || "")
  if (id === "constructor" || id === "prototype" || id === "__proto__") return false
  return id.length > 0 && id.length <= 128 && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)
}

function validPath(value) {
  var path = String(value || "")
  return path.length > 0 && path.length <= 4096 && path.charAt(0) === "/" &&
    !/[\x00-\x1f\x7f]/.test(path) &&
    !path.split("/").some(function(part) { return part === ".." })
}

function validHelperPath(value) {
  var path = String(value || "")
  return path.length > 0 && path.length <= 4096 && path.charAt(0) === "/" &&
    !/[\x00-\x1f\x7f]/.test(path) &&
    !path.split("/").some(function(part) { return part === ".." })
}

function scriptPath(value) {
  var text = String(value || "")
  if (text.indexOf("file://") !== 0) return ""
  text = text.slice(7)
  return validPath(text) ? text : ""
}

function validExternalCommand(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 8) return false
  if (value.some(function(item) { return typeof item !== "string" || item.length > 4096 || /[\x00-\x1f\x7f]/.test(item) })) return false
  if (value[0] === OMARCHY_PATH) {
    if (value.length === 4 && value[1] === "plugin" && value[2] === "list" && value[3] === "--json") return true
    if (value.length === 4 && value[1] === "plugin" && (value[2] === "enable" || value[2] === "disable") && validPluginId(value[3])) return true
    if (value.length === 5 && value[1] === "plugin" && value[2] === "remove" && validPluginId(value[3]) && value[4] === "--yes") return true
    return false
  }
  if (value[0] === CATALOG_PATH) return value.length === 1
  if (value[0] === "/usr/bin/python3") {
    return value.length === 4 && value[1] === "-I" && validHelperPath(value[2]) &&
      (value[3] === "all" || validPath(value[3]))
  }
  return false
}

function parseArrayResult(value) {
  var source = String(value || "")
  if (source.length > MAX_DATA_BYTES) return { ok: false, data: [], error: "output too large" }
  var parsed = null
  try {
    parsed = JSON.parse(source || "[]")
  } catch (e) {
    return { ok: false, data: [], error: "invalid JSON" }
  }
  if (!Array.isArray(parsed) || parsed.length > MAX_ENTRIES) {
    return { ok: false, data: [], error: "expected a bounded array" }
  }
  return { ok: true, data: parsed, error: "" }
}

function parseListResult(value) {
  var result = parseArrayResult(value)
  if (!result.ok) return result
  var list = []
  for (var i = 0; i < result.data.length; i++) {
    var item = result.data[i]
    if (!isObject(item) || !validPluginId(item.id)) continue
    var copy = {}
    copy.id = String(item.id)
    if (typeof item.enabled === "boolean") copy.enabled = item.enabled
    if (typeof item.canDisable === "boolean") copy.canDisable = item.canDisable
    if (typeof item.clonedFrom === "string") copy.clonedFrom = text(item.clonedFrom, "")
    list.push(copy)
  }
  return { ok: true, data: list, error: "" }
}

function clippedText(value, limit, fallback) {
  if (value === undefined || value === null) return fallback || ""
  return String(value).slice(0, limit)
}

function cleanSchemaField(value) {
  if (!isObject(value) || typeof value.key !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value.key)) return null
  var type = String(value.type || "text").toLowerCase()
  if (["string", "text", "enum", "bool", "boolean", "int", "integer", "number", "float", "double"].indexOf(type) < 0) return null
  var label = clippedText(value.label || value.key, 256, value.key)
  if (/[\x00-\x1f\x7f]/.test(label)) return null
  var field = { key: value.key, type: type, label: label }
  if (value.defaultValue !== undefined && (typeof value.defaultValue === "string" || typeof value.defaultValue === "number" || typeof value.defaultValue === "boolean")) {
    if (typeof value.defaultValue === "number" && !isFinite(value.defaultValue)) return null
    field.defaultValue = clippedText(value.defaultValue, 4096, "")
  }
  if (Array.isArray(value.options)) {
    field.options = []
    for (var i = 0; i < value.options.length && field.options.length < 256; i++) {
      var option = value.options[i]
      if (typeof option !== "string" && typeof option !== "number" && typeof option !== "boolean") continue
      field.options.push(clippedText(option, 256, ""))
    }
  }
  for (var j = 0; j < 2; j++) {
    var key = j === 0 ? "min" : "max"
    if (typeof value[key] === "number" && isFinite(value[key])) field[key] = value[key]
    else if (value[key] !== undefined && value[key] !== null) return null
  }
  if (field.min !== undefined && field.max !== undefined && field.min > field.max) return null
  return field
}

function parseCatalogResult(value) {
  var result = parseArrayResult(value)
  if (!result.ok) return result
  var catalog = []
  for (var i = 0; i < result.data.length; i++) {
    var item = result.data[i]
    if (!isObject(item) || !validPluginId(item.id)) continue
    var copy = {}
    copy.id = String(item.id)
    copy.name = text(item.name, copy.id)
    copy.description = text(item.description, "")
    copy.kinds = Array.isArray(item.kinds) ? item.kinds.slice(0, 32).map(function(k) {
      return text(k, "")
    }) : []
    copy.firstParty = item.firstParty === true
    copy.sourceDir = validPath(item.sourceDir) ? String(item.sourceDir) : ""
    copy.manifestPath = validPath(item.manifestPath) ? String(item.manifestPath) : ""
    if (isObject(item.barWidget)) {
      var schema = []
      if (Array.isArray(item.barWidget.schema)) {
        for (var s = 0; s < item.barWidget.schema.length && schema.length < 256; s++) {
          var field = cleanSchemaField(item.barWidget.schema[s])
          if (field) schema.push(field)
        }
      }
      copy.barWidget = { schema: schema }
    } else {
      copy.barWidget = { schema: [] }
    }
    catalog.push(copy)
  }
  return { ok: true, data: catalog, error: "" }
}

function parseList(textValue) {
  var result = parseListResult(textValue)
  return result.ok ? result.data : []
}

function parseCatalog(textValue) {
  var result = parseCatalogResult(textValue)
  return result.ok ? result.data : []
}

function merge(list, catalog) {
  var byId = {}
  for (var k = 0; k < (Array.isArray(list) ? list.length : 0) && k < MAX_ENTRIES; k++) {
    if (list[k] && validPluginId(list[k].id)) byId[String(list[k].id)] = list[k]
  }
  var rows = []
  var source = Array.isArray(catalog) ? catalog : []
  for (var i = 0; i < source.length && rows.length < MAX_ENTRIES; i++) {
    var cat = source[i] || {}
    if (!validPluginId(cat.id)) continue
    var st = byId[String(cat.id)] || {}
    var kinds = Array.isArray(cat.kinds) ? cat.kinds.slice(0, 32).map(function(kind) { return text(kind, "") }) : []
    var bw = isObject(cat.barWidget) ? cat.barWidget : {}
    var schema = Array.isArray(bw.schema) ? bw.schema : []
    var id = String(cat.id)
    var hasEnabled = typeof st.enabled === "boolean"
    var enabled = hasEnabled && st.enabled === true
    var enabledState = hasEnabled ? (enabled ? "enabled" : "disabled") : "unknown"
    var canToggle = hasEnabled && st.canDisable !== false

    rows.push({
      id: id,
      name: text(cat.name, id),
      description: text(cat.description, ""),
      kinds: kinds,
      kindLabel: kinds.join(", "),
      enabled: enabled,
      enabledState: enabledState,
      canToggle: canToggle,
      firstParty: cat.firstParty === true,
      clonedFrom: text(st.clonedFrom, ""),
      schema: schema,
      hasSchema: schema.length > 0,
      sourceDir: validPath(cat.sourceDir) ? String(cat.sourceDir) : "",
      manifestPath: validPath(cat.manifestPath) ? String(cat.manifestPath) : "",
      isBar: kinds.indexOf("bar") !== -1,
      isBarWidget: kinds.indexOf("bar-widget") !== -1,
      isSelf: id === SELF_ID,
      canConfigure: cat.firstParty !== true || kinds.indexOf("bar-widget") !== -1 || schema.length > 0,
      canRemove: cat.firstParty !== true && kinds.indexOf("bar") === -1 && id !== SELF_ID
    })
  }

  rows.sort(function(a, b) {
    var aRank = a.enabledState === "enabled" ? 2 : (a.enabledState === "unknown" ? 1 : 0)
    var bRank = b.enabledState === "enabled" ? 2 : (b.enabledState === "unknown" ? 1 : 0)
    if (aRank !== bRank) return bRank - aRank
    return a.name.localeCompare(b.name)
  })
  return rows
}

function applyFilter(rows, query) {
  var sourceRows = Array.isArray(rows) ? rows : []
  var q = String(query || "").trim().toLowerCase().slice(0, MAX_TEXT)
  if (q === "") return sourceRows
  return sourceRows.filter(function(r) {
    if (!isObject(r)) return false
    var source = r.firstParty ? "first-party" : "third-party"
    return text(r.name, "").toLowerCase().indexOf(q) !== -1
      || text(r.id, "").toLowerCase().indexOf(q) !== -1
      || text(r.kindLabel, "").toLowerCase().indexOf(q) !== -1
      || source.indexOf(q) !== -1
  })
}

function summary(rows) {
  var enabled = 0
  var installed = 0
  var unknown = 0
  for (var i = 0; i < (rows || []).length; i++) {
    if (!isObject(rows[i])) continue
    installed += 1
    if (rows[i].enabledState === "enabled") enabled += 1
    else if (rows[i].enabledState === "unknown") unknown += 1
  }
  return { installed: installed, enabled: enabled, unknown: unknown }
}

function enableCommand(id) {
  return validPluginId(id) ? [OMARCHY_PATH, "plugin", "enable", String(id)] : []
}

function disableCommand(id) {
  return validPluginId(id) ? [OMARCHY_PATH, "plugin", "disable", String(id)] : []
}

function removeCommand(id) {
  return validPluginId(id) ? [OMARCHY_PATH, "plugin", "remove", String(id), "--yes"] : []
}

function updateCommand(id, helperPath, dir) {
  return validPluginId(id) && validHelperPath(helperPath) && validPath(dir)
    ? ["/usr/bin/python3", "-I", String(helperPath), String(dir)]
    : []
}

function updateAllCommand(home, helperPath) {
  return validPath(home) && validHelperPath(helperPath)
    ? ["/usr/bin/python3", "-I", String(helperPath), "all"]
    : []
}

function configureCommand(row, home) {
  if (!isObject(row) || !validPluginId(row.id)) return null
  var base = validPath(home) ? String(home) : ""
  if (!row.firstParty) {
    var dir = validPath(row.sourceDir) ? String(row.sourceDir) : ""
    if (!dir && base) dir = base + "/.config/omarchy/plugins/" + String(row.id)
    return dir ? [EDITOR_PATH, dir] : null
  }
  return base ? [EDITOR_PATH, base + "/.config/omarchy/shell.json"] : null
}

function marketplaceCommand() {
  return [BROWSER_PATH, MARKETPLACE_URL]
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    SELF_ID: SELF_ID,
    MAX_DATA_BYTES: MAX_DATA_BYTES,
    MAX_ENTRIES: MAX_ENTRIES,
    MAX_GIT_CHECKS: MAX_GIT_CHECKS,
    OMARCHY_PATH: OMARCHY_PATH,
    CATALOG_PATH: CATALOG_PATH,
    isObject: isObject,
    validPluginId: validPluginId,
    validPath: validPath,
    validHelperPath: validHelperPath,
    validExternalCommand: validExternalCommand,
    scriptPath: scriptPath,
    cleanSchemaField: cleanSchemaField,
    parseListResult: parseListResult,
    parseCatalogResult: parseCatalogResult,
    parseList: parseList,
    parseCatalog: parseCatalog,
    merge: merge,
    applyFilter: applyFilter,
    summary: summary,
    listCommand: listCommand,
    catalogCommand: catalogCommand,
    enableCommand: enableCommand,
    disableCommand: disableCommand,
    removeCommand: removeCommand,
    updateCommand: updateCommand,
    updateAllCommand: updateAllCommand,
    configureCommand: configureCommand,
    marketplaceCommand: marketplaceCommand
  }
}