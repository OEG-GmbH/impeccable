/**
 * The npm shim (`cli/bin/cli.js`), this fork contract.
 *
 * The shim runs only the `@impeccable/cli-<os>-<arch>` optional dependency
 * (never `$IMPECCABLE_BIN`), and only when the candidate's sha256 is listed in
 * `skill/scripts/engine-checksums.txt`. It never downloads and keeps no
 * cache. A fixture server records every request, and every case asserts it
 * saw none, with IMPECCABLE_DOWNLOAD_BASE pointing at it; a case that ever
 * reaches the network fails loudly.
 *
 * The shim runs from a staged copy (`<tmp>/cli/bin/cli.js` beside a copy of
 * the repo's package.json) with no node_modules above it, so the optional
 * dependency is absent unless a case installs a fake one.
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

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PKG_PATH = path.join(REPO, 'package.json');
const VERSION = JSON.parse(fs.readFileSync(PKG_PATH, 'utf8'))
  .optionalDependencies['@impeccable/cli-darwin-arm64'];
const TARGET = `${{ darwin: 'darwin', linux: 'linux', win32: 'windows' }[process.platform] || process.platform}`
  + `-${{ arm64: 'arm64', x64: 'x64' }[process.arch] || process.arch}`;
const PLATFORM_PKG = `@impeccable/cli-${TARGET}`;
const ASSET = `impeccable-${TARGET}${process.platform === 'win32' ? '.exe' : ''}`;

// A stand-in engine binary: a script that prints its argv.
const PAYLOAD = Buffer.from('#!/bin/sh\necho "fake-engine $*"\n');
const DIGEST = createHash('sha256').update(PAYLOAD).digest('hex');

/** Every path the server was asked for since the last test started. */
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

/** A staged shim whose manifest holds `line`. */
function stageShim(line = `${VERSION} ${ASSET} ${DIGEST}`) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'impeccable-shim-'));
  fs.mkdirSync(path.join(dir, 'cli', 'bin'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'skill', 'scripts'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'skill', 'scripts', 'engine-checksums.txt'), `# test manifest\n\n${line}\n`);
  fs.copyFileSync(PKG_PATH, path.join(dir, 'package.json'));
  fs.copyFileSync(path.join(REPO, 'cli', 'bin', 'cli.js'), path.join(dir, 'cli', 'bin', 'cli.js'));
  return { dir, shim: path.join(dir, 'cli', 'bin', 'cli.js') };
}

/** Run a staged shim (async: the fixture server lives in this process). */
function run(shim, args, env, cwd) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [shim, ...args], { env, cwd });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (status) => resolve({ status, stdout, stderr }));
  });
}

function envFor(dir, extra = {}) {
  const env = { ...process.env, IMPECCABLE_HOME: dir, IMPECCABLE_DOWNLOAD_BASE: base, ...extra };
  if (!('IMPECCABLE_BIN' in extra)) delete env.IMPECCABLE_BIN;
  return env;
}

/** A fake platform package, every mode 0755; returns its binary's path. */
function installPlatformPackage(dir, body) {
  const pkgDir = path.join(dir, 'node_modules', PLATFORM_PKG);
  fs.mkdirSync(path.join(pkgDir, 'bin'), { recursive: true });
  // Explicit modes: the shim checks every directory up to the shared root,
  // and a CI runner may run with umask 000.
  for (const d of [dir, path.join(dir, 'node_modules'), path.dirname(pkgDir)]) fs.chmodSync(d, 0o755);
  fs.chmodSync(pkgDir, 0o755);
  fs.chmodSync(path.join(pkgDir, 'bin'), 0o755);
  fs.writeFileSync(path.join(pkgDir, 'package.json'), `${JSON.stringify({ name: PLATFORM_PKG, version: VERSION }, null, 2)}\n`);
  const bin = path.join(pkgDir, 'bin', 'impeccable');
  fs.writeFileSync(bin, body, { mode: 0o755 });
  fs.chmodSync(bin, 0o755);
  return bin;
}

describe('npm shim, this fork: listed binaries only, no download', { skip: process.platform === 'win32' ? 'posix only' : false }, () => {
  it('stops without a binary and makes no request', async () => {
    const { dir, shim } = stageShim();
    const res = await run(shim, ['engine-probe'], envFor(dir));
    assert.equal(res.status, 127);
    assert.match(res.stderr, /downloads nothing/);
    assert.deepEqual(requests, []);
    assert.deepEqual(fs.readdirSync(dir).sort(), ['cli', 'package.json', 'skill']);
  });

  it('ignores IMPECCABLE_BIN, even for a listed binary', async () => {
    const { dir, shim } = stageShim();
    const bin = path.join(dir, 'engine');
    fs.writeFileSync(bin, PAYLOAD, { mode: 0o755 });
    const res = await run(shim, ['hi'], envFor(dir, { IMPECCABLE_BIN: bin }));
    assert.equal(res.status, 127);
    assert.doesNotMatch(res.stdout, /fake-engine/);
    assert.deepEqual(requests, []);
  });

  it('refuses when the manifest has no line for the version', async () => {
    const { dir, shim } = stageShim(`9.9.9 ${ASSET} ${DIGEST}`);
    installPlatformPackage(dir, PAYLOAD);
    const res = await run(shim, ['hi'], envFor(dir));
    assert.equal(res.status, 127);
    assert.match(res.stderr, /no checksum for engine/);
    assert.deepEqual(requests, []);
  });

  it('refuses a symlinked package binary, even to a listed file', async () => {
    const { dir, shim } = stageShim();
    const bin = installPlatformPackage(dir, PAYLOAD);
    const real = path.join(dir, 'real-engine');
    fs.renameSync(bin, real);
    fs.symlinkSync(real, bin);
    const res = await run(shim, ['hi'], envFor(dir));
    assert.equal(res.status, 127);
    assert.doesNotMatch(res.stdout, /fake-engine/);
    assert.match(res.stderr, /symlink/);
  });

  it('refuses a package binary or directory that group or others can write', async () => {
    // scope, node_modules, root: renaming any directory above the package
    // swaps the binary too (Codex review), up to the one shared with the shim.
    for (const which of ['bin', 'bindir', 'pkgdir', 'scope', 'node_modules', 'root']) {
      const { dir, shim } = stageShim();
      const bin = installPlatformPackage(dir, PAYLOAD);
      const pkgdir = path.dirname(path.dirname(bin));
      const target = {
        bin, bindir: path.dirname(bin), pkgdir, scope: path.dirname(pkgdir), node_modules: path.join(dir, 'node_modules'), root: dir,
      }[which];
      fs.chmodSync(target, 0o775);
      const res = await run(shim, ['hi'], envFor(dir));
      assert.equal(res.status, 127, which);
      assert.doesNotMatch(res.stdout, /fake-engine/, which);
      assert.match(res.stderr, /writable by group or others/, which);
      fs.chmodSync(target, 0o755);
      assert.equal((await run(shim, ['hi'], envFor(dir))).status, 0, `${which}: back to 0755 runs again`);
    }
  });

  it('runs a listed platform package and refuses an unlisted one', async () => {
    const listed = stageShim();
    installPlatformPackage(listed.dir, PAYLOAD);
    let res = await run(listed.shim, ['hi'], envFor(listed.dir));
    assert.equal(res.status, 0, res.stderr);
    assert.match(res.stdout, /fake-engine hi/);
    const upstream = stageShim();
    installPlatformPackage(upstream.dir, '#!/bin/sh\necho "upstream-package $*"\n');
    res = await run(upstream.shim, ['hi'], envFor(upstream.dir));
    assert.equal(res.status, 127);
    assert.doesNotMatch(res.stdout, /upstream-package/);
    assert.deepEqual(requests, []);
  });

  it('answers --version and -v from its own package.json without touching a binary', async () => {
    const { dir, shim } = stageShim();
    const pkgVersion = JSON.parse(fs.readFileSync(PKG_PATH, 'utf8')).version;
    for (const flag of ['--version', '-v']) {
      const res = await run(shim, [flag], envFor(dir));
      assert.equal(res.status, 0, res.stderr);
      assert.equal(res.stdout, `${pkgVersion}\n`);
    }
    assert.deepEqual(requests, []);
  });
});
