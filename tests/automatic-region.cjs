const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const Model = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(root, 'Model.js'), 'utf8').replace('.pragma library', ''), Model);
const I18n = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(root, 'I18n.js'), 'utf8').replace('.pragma library', ''), I18n);
const service = fs.readFileSync(path.join(root, 'Service.qml'), 'utf8');
const script = vm.runInNewContext(service.split('readonly property string statusScript: ')[1].split('readonly property string whichScript:')[0].trim());
const label = service.match(/readonly property string regionLabel: (.*)/)[1];

function poll(state, location, dumpMode = 'ok') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pia-region-test-'));
  const ctl = path.join(dir, 'piactl');
  fs.writeFileSync(ctl, `#!/bin/bash
if [ "$1" = get ]; then
  case "$2" in
    connectionstate) echo "$TEST_STATE";;
    region) echo auto;;
  esac
else
  case "$TEST_DUMP" in
    unsupported) exit 1;;
    malformed) echo invalid-json;;
    ok) printf '%s' "$TEST_JSON";;
  esac
fi
`, { mode: 0o700 });
  try {
    const output = execFileSync('bash', ['-c', script, 'test', ctl, 'connectionstate region'], {
      env: { ...process.env, TEST_STATE: state, TEST_DUMP: dumpMode,
        TEST_JSON: JSON.stringify({ connectionState: state, connectedConfig: { vpnLocation: { id: location } } }) },
      encoding: 'utf8'
    });
    const parsed = Model.parseStatus(output);
    assert.equal(parsed.ok, true);
    return vm.runInNewContext(label, { Model, I18n, language: 'en', region: parsed.values.region,
      connected: Model.stateInfo(parsed.values.connectionstate).connected,
      connectedRegion: parsed.values.connectedregion });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

test('automatic connection shows the actual region through the status pipeline', () => {
  assert.equal(poll('Connected', 'br'), 'Automatic · Brazil');
  assert.equal(poll('Connected', 'uk_london'), 'Automatic · United Kingdom · London');
});
test('disconnected and reconnecting states do not show stale locations', () => {
  assert.equal(poll('Disconnected', 'br'), 'Automatic');
  assert.equal(poll('Reconnecting', 'br'), 'Automatic');
});
test('unsupported, malformed and missing location data preserve basic status', () => {
  assert.equal(poll('Connected', 'br', 'unsupported'), 'Automatic');
  assert.equal(poll('Connected', 'br', 'malformed'), 'Automatic');
  assert.equal(poll('Connected', null), 'Automatic');
});
test('manual selection keeps its label', () => {
  assert.equal(Model.connectionRegionLabel('uk-london', 'br', true), 'United Kingdom · London');
});
