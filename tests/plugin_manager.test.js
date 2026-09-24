const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')

const source = fs.readFileSync(require.resolve('../PluginManager.js'), 'utf8').replace('.pragma library\n', '')
const context = { module: { exports: {} }, exports: {}, console }
vm.runInNewContext(source, context)
const pm = context.module.exports

test('rejects malformed and oversized command data', () => {
  assert.equal(pm.parseListResult('{').ok, false)
  assert.equal(pm.parseListResult(JSON.stringify({})).ok, false)
  assert.equal(pm.parseCatalogResult('[' + 'x'.repeat(pm.MAX_DATA_BYTES) + ']').ok, false)
})

test('keeps unknown plugin state distinct from disabled', () => {
  const rows = pm.merge([
    { id: 'known.on', enabled: true },
    { id: 'known.off', enabled: false },
    { id: 'known.unknown' }
  ], [
    { id: 'known.on', name: 'On', kinds: ['service'] },
    { id: 'known.off', name: 'Off', kinds: ['service'] },
    { id: 'known.unknown', name: 'Unknown', kinds: ['bar-widget'] }
  ])
  assert.equal(rows[0].enabledState, 'enabled')
  assert.equal(rows[1].enabledState, 'unknown')
  assert.equal(rows[2].enabledState, 'disabled')
  assert.equal(rows[1].canToggle, false)
})

test('rejects command identifiers and paths that could escape argv', () => {
  assert.equal(pm.enableCommand('../plugin').length, 0)
  assert.equal(pm.removeCommand('plugin;rm').length, 0)
  assert.equal(pm.configureCommand({ id: 'x', firstParty: false, sourceDir: '/tmp/x' }, '/home/u')[1], '/tmp/x')
  assert.equal(pm.configureCommand({ id: '../x', firstParty: false }, '/home/u'), null)
})

test('filters and summarizes bounded rows', () => {
  const rows = pm.merge([], [
    { id: 'a', name: 'Alpha', kinds: ['bar-widget'] },
    { id: 'b', name: 'Beta', kinds: ['service'] }
  ])
  assert.equal(pm.applyFilter(rows, 'alp').length, 1)
  const summary = pm.summary(rows)
  assert.equal(summary.installed, 2)
  assert.equal(summary.enabled, 0)
  assert.equal(summary.unknown, 2)
})

test('uses fixed command paths and bounds external output queues', () => {
  assert.equal(pm.listCommand()[0], pm.OMARCHY_PATH)
  assert.equal(pm.catalogCommand()[0], pm.CATALOG_PATH)
  assert.equal(pm.enableCommand('x')[0], pm.OMARCHY_PATH)
  assert.equal(pm.marketplaceCommand()[0].endsWith('omarchy-launch-browser'), true)
  assert.equal(pm.updateCommand('x', '/tmp/git_update.py', '/tmp/x')[0], '/usr/bin/python3')
  assert.equal(pm.updateCommand('x', '/tmp/git_update.py', '/tmp/x')[2], '/tmp/git_update.py')
  assert.equal(pm.updateAllCommand('/home/u', '/tmp/git_update.py')[3], 'all')
  assert.equal(pm.cleanSchemaField({ key: '../bad', label: 'x' }), null)
  assert.equal(pm.cleanSchemaField({ key: 'ok', label: 'x'.repeat(1000) }).label.length, 256)
  assert.equal(pm.cleanSchemaField({ key: 'ok', type: 'object' }), null)
  assert.equal(pm.validExternalCommand(pm.listCommand()), true)
  assert.equal(pm.validExternalCommand(['/bin/sh', '-c', 'id']), false)
  assert.equal(pm.MAX_GIT_CHECKS > 0, true)
})
