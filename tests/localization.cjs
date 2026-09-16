const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
function load(name) {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(path.join(root, name), 'utf8').replace('.pragma library', ''), context);
  return context;
}
const Model = load('Model.js');
const I18n = load('I18n.js');
const panel = fs.readFileSync(path.join(root, 'Panel.qml'), 'utf8');
const service = fs.readFileSync(path.join(root, 'Service.qml'), 'utf8');
function qmlFunction(source, name) {
  const match = source.match(new RegExp('  function ' + name + '\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}'));
  assert.ok(match, name);
  return match[0];
}
function panelContext(locale, overrides = {}) {
  const pia = {
    language: I18n.language(locale), installed: true, daemonUp: true, checkedInstall: true,
    connected: true, region: 'auto', connectedRegion: 'br', pendingRegion: '',
    vpnIp: '192.0.2.1', pubIp: '198.51.100.1', protocol: 'wireguard', protocolLabel: 'WireGuard',
    portForward: Model.portForwardInfo('1234'), requestPortForward: true,
    loggedIn: true, accountName: 'test-account', maxRecentRegions: 5,
    regions: Model.regionEntries(['auto', 'br', 'es', 'us-east']), ...overrides
  };
  pia.t = (source, args) => I18n.t(pia.language, source, args);
  pia.regionLabel = I18n.regionLabel(pia.language, Model.connectionRegionLabel(pia.region, pia.connectedRegion, pia.connected));
  const context = vm.createContext({ Model, I18n, pia, recentRegions: [], pickerOpen: false,
    pickerQuery: '', revealIps: false, localizedRegions: I18n.regionEntries(pia.language, pia.regions) });
  for (const name of ['t', 'regionIcon', 'regionRow', 'buildRows']) {
    // t is a one-line QML helper.
    vm.runInContext(name === 't' ? 'function t(source, args) { return pia.t(source, args) }' : qmlFunction(panel, name), context);
  }
  return context;
}

test('locale variants and POSIX precedence use English for unsupported languages', () => {
  const expr = service.match(/readonly property string language: (.*)/)[1];
  for (const [env, expected] of [
    [{ LANG: 'pt_BR.UTF-8' }, 'pt'], [{ LANG: 'es-MX' }, 'es'],
    [{ LANG: 'pt_PT@euro' }, 'pt'], [{ LANG: 'en_GB.UTF-8' }, 'en'],
    [{ LANG: 'fr_FR.UTF-8' }, 'en'], [{ LANG: 'C.UTF-8' }, 'en'],
    [{ LANG: 'pt_BR', LC_MESSAGES: 'es_ES' }, 'es'],
    [{ LANG: 'pt_BR', LC_MESSAGES: 'es_ES', LC_ALL: 'C' }, 'en'],
    [{}, 'en']
  ]) assert.equal(vm.runInNewContext(expr, { I18n, Quickshell: { env: key => env[key] || '' }, Qt: { locale: () => ({ name: 'C' }) } }), expected);
});

test('catalogs cover messages, countries and preserve interpolation placeholders', () => {
  for (const lang of ['es', 'pt']) {
    assert.deepEqual(Object.keys(I18n.messages[lang]).sort(), Object.keys(I18n.messages.en).sort());
    for (const [source, translated] of Object.entries(I18n.messages[lang])) {
      assert.ok(translated.length > 0);
      assert.deepEqual(translated.match(/\{\w+\}/g), source.match(/\{\w+\}/g));
    }
    for (const country of Object.values(Model.COUNTRIES)) assert.ok(I18n.countries[lang][country]);
  }
  assert.equal(I18n.t('de', 'Switch to {name}', { name: 'WireGuard' }), 'Switch to WireGuard');
  assert.equal(I18n.t('es', 'Untranslated {name}', { name: '$& {literal}' }), 'Untranslated $& {literal}');
  const translated = I18n.messages.es['Choose region…'];
  try {
    delete I18n.messages.es['Choose region…'];
    assert.equal(I18n.t('es', 'Choose region…'), 'Choose region…');
  } finally { I18n.messages.es['Choose region…'] = translated; }
});

test('actual panel rows show all three languages and keep machine region IDs', () => {
  for (const [lang, region, section, choose, port] of [
    ['en', 'Automatic · Brazil', 'CONNECTION', 'Choose region…', 'Port 1234'],
    ['es', 'Automática · Brasil', 'CONEXIÓN', 'Elegir región…', 'Puerto 1234'],
    ['pt', 'Automática · Brasil', 'CONEXÃO', 'Escolher região…', 'Porta 1234']
  ]) {
    const ctx = panelContext(lang);
    const rows = ctx.buildRows();
    const row = id => rows.find(r => r.id === id);
    assert.equal(row('region').title, region);
    assert.equal(row('sec-connection').text, section);
    assert.equal(row('choose').title, choose);
    assert.equal(row('portforward').subtitle, port);
    assert.equal(row('pin:auto').region, 'auto');
    assert.equal(row('pin:auto').current, true);
    assert.equal(row('vpnip').blur, true);
    assert.equal(row('logout').subtitle, I18n.t(lang, 'Signed in as {name}', { name: 'test-account' }));
    for (const state of Object.values(Model.STATES)) assert.ok(I18n.messages[lang][state.label]);
  }
});

test('localized region search accepts accents, English names and IDs', () => {
  const entries = I18n.regionEntries('es', Model.regionEntries(['auto', 'es', 'us-east']));
  for (const query of ['España', 'espana', 'Spain']) assert.equal(Model.filterRegions(entries, query)[0].id, 'es');
  assert.ok(Model.filterRegions(entries, 'es').some(entry => entry.id === 'es'));
  assert.equal(Model.filterRegions(entries, 'United States')[0].id, 'us-east');
  const ctx = panelContext('pt'); ctx.pickerOpen = true; ctx.pickerQuery = 'inexistente';
  assert.equal(ctx.buildRows().find(r => r.id === 'hint-nomatch').text, 'Nenhuma região corresponde a “inexistente”.');
});

test('notifications are localized without translating daemon state comparisons', () => {
  for (const lang of ['en', 'es', 'pt']) {
    let command;
    const context = vm.createContext({ Model, t: (key, args) => I18n.t(lang, key, args),
      regionLabel: I18n.regionLabel(lang, 'Automatic · Brazil'),
      Quickshell: { execDetached: args => { command = args; } } });
    vm.runInContext(qmlFunction(service, 'sendNotification'), context);
    for (const [state, title] of [['Connected', 'VPN connected'], ['Disconnected', 'VPN disconnected'], ['Interrupted', 'VPN interrupted']]) {
      context.sendNotification(state);
      assert.equal(command[command.length - 2], I18n.t(lang, title));
      assert.equal(command[command.length - 1], state === 'Connected' ? context.regionLabel : 'Private Internet Access');
    }
  }
  assert.match(panel, /function status\(\): string \{ return pia.stateLabel \}/);
});

test('terminal login uses translated prompts, preserves credentials and cleans its private file', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pia-login-test-'));
  function executable(name, content) { fs.writeFileSync(path.join(dir, name), '#!/bin/bash\n' + content, { mode: 0o700 }); }
  executable('gum', `if [ "$1" = input ]; then
  printf '%s\\n' "\${!#}" >>"$TEST_PROMPTS"
  if [[ " $* " = *' --password '* ]]; then printf '%s' 'dummy-secret'; else printf '%s' 'test-account'; fi
else printf '%s\\n' "\${!#}"; fi`);
  executable('piactl', `[[ "$1" = login && $(stat -c %a "$2") = 600 ]] || exit 1
[[ $(head -n1 "$2") = test-account && $(tail -n1 "$2") = dummy-secret ]] || exit 1
printf '%s' "$2" >"$TEST_CREDENTIAL_PATH"
exit 0`);
  executable('sleep', 'exit 0');
  try {
    for (const [locale, prompt, success] of [
      ['en_US', 'Username: ', 'Logged in as test-account'],
      ['es_MX', 'Usuario: ', 'Sesión iniciada como test-account'],
      ['pt_BR.UTF-8', 'Usuário: ', 'Conectado como test-account'],
      ['de_DE', 'Username: ', 'Logged in as test-account']
    ]) {
      const prompts = path.join(dir, 'prompts'); fs.writeFileSync(prompts, '');
      const result = spawnSync('bash', [path.join(root, 'bin/pia-login'), path.join(dir, 'piactl'), path.join(dir, 'omarchy-pia-login'), locale], {
        env: { ...process.env, XDG_RUNTIME_DIR: dir, PATH: dir + ':' + process.env.PATH, TEST_PROMPTS: prompts, TEST_CREDENTIAL_PATH: path.join(dir, 'credential-path') }, encoding: 'utf8'
      });
      assert.equal(result.status, 0, result.stderr);
      assert.ok(result.stdout.includes(success));
      assert.equal(fs.readFileSync(prompts, 'utf8').split('\n')[0], prompt);
      assert.equal(fs.readFileSync(path.join(dir, 'omarchy-pia-login'), 'utf8'), 'test-account\n');
      fs.unlinkSync(path.join(dir, 'omarchy-pia-login'));
      assert.equal(fs.existsSync(fs.readFileSync(path.join(dir, 'credential-path'), 'utf8')), false);
      assert.equal(result.stdout.includes('dummy-secret'), false);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
