/**
 * The skill launchers (`skill/scripts/impeccable`, `impeccable.cmd`), this fork
 * contract. Replaces the upstream download tests: the fork's launcher runs
 * only `bin/<os>-<arch>/impeccable` next to it, when its sha256 is listed in
 * `engine-checksums.txt` next to it, downloads nothing and writes nothing.
 *
 * A fixture server records every request, with IMPECCABLE_DOWNLOAD_BASE
 * pointing at it; every case asserts it saw none. The sh launcher is run
 * against a stand-in engine (a script printing its argv); the cmd launcher
 * cannot run here and is pinned at the source level. Owner, mode and symlink
 * refusals are covered by crates/skills/tests/launcher_contract_tests.rs.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, beforeEach, describe, it } from 'node:test';
import { installEngine } from './lib/engine-bin.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const WINDOWS = process.platform === 'win32';
const TARGET = `${process.platform === 'darwin' ? 'darwin' : 'linux'}-${process.arch === 'arm64' ? 'arm64' : 'x64'}`;
const ASSET = `impeccable-${TARGET}`;
const PAYLOAD = Buffer.from('#!/bin/sh\necho "verified-engine $*"\n');
const HASH = createHash('sha256').update(PAYLOAD).digest('hex');

let requests = [];
let server;
let base;

before(async () => {
  server = http.createServer((req, res) => {
    requests.push(req.url);
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.end(PAYLOAD);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => new Promise((resolve) => server.close(resolve)));

beforeEach(() => { requests = []; });

/** Every file below `dir`, relative, sorted. */
function tree(dir) {
  return fs.readdirSync(dir, { recursive: true }).map(String).sort();
}

/**
 * A skill copy in a temp dir (a space in its path on purpose): the launcher,
 * VERSION, a manifest holding `manifest` (null: none) and, unless `binary` is
 * null, the stand-in engine at bin/<os>-<arch>/impeccable with mode `mode`.
 */
function stage(t, { manifest = `# test manifest\n\n0.0.0-test ${ASSET} ${HASH}\n`, binary = PAYLOAD, mode = 0o755 } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'impeccable-launcher-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const scripts = path.join(root, 'skill scripts');
  const binDir = path.join(scripts, 'bin', TARGET);
  fs.mkdirSync(binDir, { recursive: true });
  for (const d of [root, scripts, path.join(scripts, 'bin'), binDir]) fs.chmodSync(d, 0o755);
  fs.writeFileSync(path.join(scripts, 'VERSION'), '0.0.0-test\n');
  const launcher = path.join(scripts, 'impeccable');
  fs.copyFileSync(path.join(ROOT, 'skill/scripts/impeccable'), launcher);
  fs.chmodSync(launcher, 0o755);
  if (manifest !== null) fs.writeFileSync(path.join(scripts, 'engine-checksums.txt'), manifest);
  const bin = path.join(binDir, 'impeccable');
  if (binary !== null) {
    fs.writeFileSync(bin, binary);
    fs.chmodSync(bin, mode);
  }
  return { root, scripts, launcher, bin };
}

function run(launcher, args = ['context'], extraEnv = {}) {
  return new Promise((resolve) => {
    const env = { ...process.env, IMPECCABLE_DOWNLOAD_BASE: base, HOME: path.dirname(path.dirname(launcher)), ...extraEnv };
    delete env.IMPECCABLE_BIN;
    delete env.IMPECCABLE_SKILL_DIR;
    const child = spawn('sh', [launcher, ...args], { env });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (status) => resolve({ status, stdout, stderr }));
  });
}

describe('sh launcher, this fork: the listed sibling binary only, no download', { skip: WINDOWS ? 'POSIX launcher' : false }, () => {
  it('runs a listed sibling binary with the arguments and writes nothing', async (t) => {
    const s = stage(t);
    const before = tree(s.root);
    const res = await run(s.launcher, ['context', '--json']);
    assert.equal(res.status, 0, res.stderr);
    assert.equal(res.stdout, 'verified-engine context --json\n');
    assert.deepEqual(tree(s.root), before);
    assert.deepEqual(requests, []);
  });

  it('reads a CRLF manifest whose last line has no newline', async (t) => {
    const s = stage(t, { manifest: `# test manifest\r\n\r\n0.0.0-test ${ASSET} ${HASH}` });
    const res = await run(s.launcher);
    assert.equal(res.status, 0, res.stderr);
    assert.match(res.stdout, /verified-engine/);
  });

  it('says the engine is not installed (exit 3) when no binary is there', async (t) => {
    const s = stage(t, { binary: null });
    const before = tree(s.root);
    const res = await run(s.launcher);
    assert.equal(res.status, 3, res.stderr);
    assert.match(res.stderr, /engine 0\.0\.0-test is not installed: no binary at /);
    assert.ok(res.stderr.includes(s.bin), res.stderr);
    assert.match(res.stderr, /downloads nothing/);
    assert.deepEqual(tree(s.root), before);
    assert.deepEqual(requests, []);
  });

  // Codex review: the manifest lists only linux-x64, so on darwin-arm64 a
  // launcher-only copy has neither binary nor digest; that is still exit 3.
  it('says not installed (exit 3) when neither binary nor platform digest exists', async (t) => {
    const s = stage(t, { binary: null, manifest: `0.0.0-test impeccable-linux-x64 ${HASH}\n` });
    const fake = path.join(s.root, 'fake-uname');
    fs.mkdirSync(fake);
    fs.writeFileSync(path.join(fake, 'uname'), '#!/bin/sh\necho "Darwin arm64"\n', { mode: 0o755 });
    const res = await run(s.launcher, ['context'], { PATH: `${fake}${path.delimiter}${process.env.PATH}` });
    assert.equal(res.status, 3, res.stderr);
    assert.match(res.stderr, /is not installed: no binary at .*bin\/darwin-arm64\/impeccable/);
    assert.match(res.stderr, /lists no digest for engine 0\.0\.0-test \(impeccable-darwin-arm64\) yet/);
    assert.doesNotMatch(res.stderr, /no checksum for engine/);
    assert.deepEqual(requests, []);
  });

  for (const [name, manifest, message] of [
    ['an unlisted version', `9.9.9 ${ASSET} ${HASH}\n`, /no checksum for engine 0\.0\.0-test/],
    ['a missing manifest', null, /no checksum for engine 0\.0\.0-test/],
    ['a digest mismatch', `0.0.0-test ${ASSET} ${'0'.repeat(64)}\n`, /checksum mismatch for /],
  ]) {
    it(`refuses ${name} (exit 127) without running the binary`, async (t) => {
      const s = stage(t, { manifest });
      const res = await run(s.launcher);
      assert.equal(res.status, 127, res.stderr);
      assert.doesNotMatch(res.stdout, /verified-engine/);
      assert.match(res.stderr, message);
      assert.deepEqual(requests, []);
    });
  }

  // Review: the skill-behavior harness stages a copy without bin/; its
  // installEngine() must leave a copy the launcher runs.
  it('runs an engine that installEngine() put into a staged copy', async (t) => {
    const s = stage(t, { binary: null, manifest: `0.0.0-test ${ASSET} ${'0'.repeat(64)}\n` });
    const engine = path.join(s.root, 'built-engine');
    fs.writeFileSync(engine, PAYLOAD);
    const installed = installEngine(s.scripts, engine);
    assert.equal(installed, s.bin);
    const res = await run(s.launcher, ['context']);
    assert.equal(res.status, 0, res.stderr);
    assert.equal(res.stdout, 'verified-engine context\n');
  });

  it('restores a lost executable bit on a listed binary and runs it', async (t) => {
    const s = stage(t, { mode: 0o644 });
    const res = await run(s.launcher);
    assert.equal(res.status, 0, res.stderr);
    assert.match(res.stdout, /verified-engine/);
  });
});

describe('cmd launcher, this fork (source level)', () => {
  const source = fs.readFileSync(path.join(ROOT, 'skill/scripts/impeccable.cmd'));
  const text = source.toString('utf8');

  it('is checked out with CRLF line endings', () => {
    const withoutCrlf = Buffer.from(source.toString('binary').replaceAll('\r\n', ''));
    assert.equal(withoutCrlf.includes(10), false, 'cmd.exe batch labels require CRLF line endings');
  });

  it('runs only the sibling binary and downloads nothing', () => {
    assert.match(text, /set "run=%~dp0bin\\windows-%arch%\\impeccable\.exe"/);
    for (const banned of ['curl', 'IMPECCABLE_DOWNLOAD_BASE', 'where impeccable', 'IMPECCABLE_HOME', '.verified', '%IMPECCABLE_BIN%']) {
      assert.equal(text.includes(banned), false, banned);
    }
  });

  it('says the engine is not installed (exit 3) when no binary is there', () => {
    assert.match(text, /:no_binary\r\necho impeccable: engine %version% is not installed: no binary at "%run%" 1>&2\r\n(?:[^\r\n]*\r\n){1,2}exit \/b 3\r\n/);
  });

  it('checks that the binary exists before it looks for a digest (Codex review)', () => {
    const exists = text.indexOf('if not exist "%run%" goto no_binary');
    const digest = text.indexOf('goto no_checksum');
    assert.ok(exists > 0 && digest > 0 && exists < digest, `${exists} < ${digest}`);
    assert.match(text, /lists no digest for engine %version% asset %asset% yet/);
  });
});
