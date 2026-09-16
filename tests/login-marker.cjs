const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');

function fixture(run) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pia-marker-test-'));
  const runtime = path.join(dir, 'runtime');
  fs.mkdirSync(runtime, { mode: 0o700 });
  const marker = path.join(runtime, 'omarchy-pia-login');
  const env = { ...process.env, XDG_RUNTIME_DIR: runtime, PATH: `${dir}:${process.env.PATH}` };
  for (const [name, script] of Object.entries({
    gum: 'if [[ $1 == input ]]; then echo test-account; fi',
    piactl: 'exit 0', sleep: 'exit 0'
  })) fs.writeFileSync(path.join(dir, name), `#!/bin/bash\n${script}\n`, { mode: 0o700 });
  const helper = (op, value = '', overrides = {}) => spawnSync('python3',
    [path.join(root, 'bin/pia-login-marker'), op, value], { env: { ...env, ...overrides }, encoding: 'utf8', input: value });
  const login = () => spawnSync('bash', [path.join(root, 'bin/pia-login'), 'piactl', marker, 'en'], { env, encoding: 'utf8' });
  try { run({ dir, runtime, marker, env, helper, login }); }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

test('login never overwrites a symlink target planted at the marker path', () => fixture(({ dir, marker, login }) => {
  const victim = path.join(dir, 'victim');
  fs.writeFileSync(victim, 'untouched');
  fs.symlinkSync(victim, marker);
  login();
  assert.equal(fs.readFileSync(victim, 'utf8'), 'untouched');
  assert.equal(fs.lstatSync(marker).isSymbolicLink(), true);
}));

test('successful login produces a private marker consumed exactly once', () => fixture(({ marker, helper, login }) => {
  assert.equal(login().status, 0);
  assert.equal(fs.statSync(marker).mode & 0o777, 0o600);
  const result = helper('read');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'test-account\n');
  assert.equal(fs.existsSync(marker), false);
  assert.equal(helper('read').status, 3);
}));

test('missing, relative, public and symlink runtime directories fail closed', () => fixture(({ dir, runtime, marker, helper }) => {
  const alias = path.join(dir, 'alias');
  fs.symlinkSync(runtime, alias);
  for (const value of ['', 'relative', alias, `${alias}/child`, '/tmp']) {
    for (const op of ['check', 'write', 'read', 'clear', 'launch']) {
      assert.notEqual(helper(op, 'account\n', { XDG_RUNTIME_DIR: value }).status, 0, `${op}: ${value}`);
    }
  }
  for (const mode of [0o755, 0o770, 0o1777]) {
    fs.chmodSync(runtime, mode);
    assert.notEqual(helper('write', 'account\n').status, 0);
  }
  assert.equal(fs.existsSync(marker), false);
}));

test('existing files cannot be overwritten, and symlinks cannot be read or removed', () => fixture(({ dir, marker, helper }) => {
  const victim = path.join(dir, 'victim');
  fs.writeFileSync(victim, 'private\n', { mode: 0o600 });
  fs.symlinkSync(victim, marker);
  for (const op of ['write', 'read', 'clear']) {
    const result = helper(op, 'replacement\n');
    assert.notEqual(result.status, 0);
    assert.equal(result.stdout, '');
    assert.equal(fs.lstatSync(marker).isSymbolicLink(), true);
  }
  assert.equal(fs.readFileSync(victim, 'utf8'), 'private\n');
  fs.unlinkSync(marker);
  fs.writeFileSync(marker, 'original\n', { mode: 0o600 });
  assert.notEqual(helper('write', 'replacement\n').status, 0);
  assert.equal(fs.readFileSync(marker, 'utf8'), 'original\n');
  assert.equal(helper('clear').status, 0);
}));

test('reads reject public files, hard links and FIFOs without consuming them', () => fixture(({ dir, marker, helper }) => {
  fs.writeFileSync(marker, 'private\n', { mode: 0o644 });
  for (const op of ['read', 'clear']) assert.notEqual(helper(op).status, 0);
  fs.chmodSync(marker, 0o600);
  fs.linkSync(marker, path.join(dir, 'hardlink'));
  for (const op of ['read', 'clear']) assert.notEqual(helper(op).status, 0);
  fs.unlinkSync(marker);
  assert.equal(spawnSync('mkfifo', [marker]).status, 0);
  for (const op of ['read', 'clear']) assert.notEqual(helper(op).status, 0);
}));

test('incomplete writes remain available for a subsequent poll', () => fixture(({ marker, helper }) => {
  fs.writeFileSync(marker, '', { mode: 0o600 });
  assert.equal(helper('read').status, 3);
  assert.equal(fs.existsSync(marker), true);
  fs.writeFileSync(marker, 'complete\n');
  assert.equal(helper('read').stdout, 'complete\n');
}));

test('concurrent exclusive writers have one winner', async () => {
  const { spawn } = require('node:child_process');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pia-marker-race-'));
  try {
    const results = await Promise.all(Array.from({ length: 12 }, (_, i) => new Promise(resolve => {
      const child = spawn('python3', [path.join(root, 'bin/pia-login-marker'), 'write'], {
        env: { ...process.env, XDG_RUNTIME_DIR: dir }, stdio: ['pipe', 'ignore', 'ignore']
      });
      child.stdin.end(`account-${i}\n`);
      child.on('exit', resolve);
    })));
    assert.equal(results.filter(code => code === 0).length, 1);
    assert.match(fs.readFileSync(path.join(dir, 'omarchy-pia-login'), 'utf8'), /^account-\d+\n$/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('launch validates and clears the marker before opening the terminal', () => fixture(({ dir, marker, env }) => {
  const captured = path.join(dir, 'launched');
  fs.writeFileSync(path.join(dir, 'omarchy-launch-tui'), '#!/bin/bash\nprintf "%s\\n" "$@" >"$TEST_LAUNCH"\n', { mode: 0o700 });
  const launch = () => spawnSync('python3', [path.join(root, 'bin/pia-login-marker'), 'launch', '/test/piactl', 'pt'], {
    env: { ...env, TEST_LAUNCH: captured }, encoding: 'utf8'
  });
  fs.writeFileSync(marker, 'stale\n', { mode: 0o600 });
  assert.equal(launch().status, 0);
  assert.equal(fs.existsSync(marker), false);
  const deadline = Date.now() + 2000;
  while ((!fs.existsSync(captured) || !fs.readFileSync(captured, 'utf8').endsWith('pt\n')) && Date.now() < deadline) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
  }
  assert.deepEqual(fs.readFileSync(captured, 'utf8').trim().split('\n'),
    ['--app-id=pia-login', 'bash', path.join(root, 'bin/pia-login'), '/test/piactl', 'omarchy-pia-login', 'pt']);
  fs.unlinkSync(captured);
  fs.symlinkSync(path.join(dir, 'victim'), marker);
  assert.notEqual(launch().status, 0);
  assert.equal(fs.existsSync(captured), false);
}));

test('foreign ownership is rejected for both directory and marker descriptors', () => fixture(({ env }) => {
  // Model a foreign uid without requiring root/chown in the test runner.
  const result = spawnSync('python3', ['-c', `
import os, runpy, stat, sys
from types import SimpleNamespace
from unittest.mock import patch
module = runpy.run_path(sys.argv[1])
foreign = SimpleNamespace(st_uid=os.geteuid() + 1, st_mode=stat.S_IFDIR | 0o700)
with patch('os.fstat', return_value=foreign):
    try:
        fd = module['runtime_fd']()
    except ValueError:
        pass
    else:
        os.close(fd)
        raise AssertionError('foreign runtime accepted')
foreign.st_mode = stat.S_IFREG | 0o600
foreign.st_nlink = 1
try:
    module['checked'](foreign)
except ValueError:
    pass
else:
    raise AssertionError('foreign marker accepted')
`, path.join(root, 'bin/pia-login-marker')], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
}));
