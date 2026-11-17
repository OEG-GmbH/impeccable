#!/usr/bin/env node
// `impeccable` npm shim, this fork: finds the platform binary and execs it with
// argv. The one candidate is the @impeccable/cli-<os>-<arch> optional
// dependency (no IMPECCABLE_BIN, no user cache, no download). It runs only
// when its sha256 is listed in skill/scripts/engine-checksums.txt (shipped in
// the package); it is hashed on every run. Upstream platform packages are not
// listed, so only a fork build passes. Hash and spawn open the path twice, so
// before hashing the shim requires a regular file (no symlink) owned like
// this shim, with neither it nor any directory above it, up to the one it
// shares with this shim (node_modules, the @impeccable scope included),
// writable by group or others: whoever could still swap it could also
// rewrite this shim.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const pkg = require('../../package.json');
const OS = { darwin: 'darwin', linux: 'linux', win32: 'windows' }[process.platform] || process.platform;
const ARCH = { arm64: 'arm64', x64: 'x64' }[process.arch] || process.arch;
const TARGET = `${OS}-${ARCH}`;
const EXE = OS === 'windows' ? 'impeccable.exe' : 'impeccable';
const PLATFORM_PKG = `@impeccable/cli-${TARGET}`;
// The engine version travels as the pinned optionalDependency range.
const VERSION = String(pkg.optionalDependencies?.[PLATFORM_PKG] || Object.values(pkg.optionalDependencies || {})[0] || '').replace(/^[^\d]*/, '');
const ASSET = `impeccable-${TARGET}${OS === 'windows' ? '.exe' : ''}`;
const MANIFEST = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'skill', 'scripts', 'engine-checksums.txt');

// The digest MANIFEST records for this version and asset, or '' when none.
function expectedDigest(wanted = ASSET) {
  try {
    for (const line of fs.readFileSync(MANIFEST, 'utf8').split(/\r?\n/)) {
      const [version, asset, sum] = line.trim().split(/\s+/);
      if (version === VERSION && asset === wanted) return (sum || '').toLowerCase();
    }
  } catch { /* no manifest: nothing verifies */ }
  return '';
}
function fromPackage() {
  try { return path.join(path.dirname(require.resolve(`${PLATFORM_PKG}/package.json`)), 'bin', EXE); } catch { return null; }
}
// `bin` and every directory above it up to and including the closest one that
// also holds this shim. Renaming any of them swaps the binary, so all must be
// checked, the @impeccable scope directory too (Codex review).
function chainToShim(bin) {
  const shimDir = path.dirname(fileURLToPath(import.meta.url));
  const chain = [bin];
  for (let d = path.dirname(bin); ; d = path.dirname(d)) {
    chain.push(d);
    const rel = path.relative(d, shimDir);
    if (rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel)) break;
    if (path.dirname(d) === d) break;
  }
  return chain;
}
// True when every path of chainToShim(bin) is owned by the owner of this shim
// and none is a symlink or writable by group or others; else false with the
// reason on stderr. (Windows: mode bits do not describe ACLs, and the fork
// lists no Windows digest.)
function privateChain(bin) {
  const owner = fs.statSync(fileURLToPath(import.meta.url)).uid;
  for (const p of chainToShim(bin)) {
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink()) {
      process.stderr.write(`impeccable: ${p} is a symlink; refusing to run the engine\n`);
      return false;
    }
    if (st.uid !== owner) {
      process.stderr.write(`impeccable: ${p} belongs to uid ${st.uid}, the shim to uid ${owner}; refusing to run the engine\n`);
      return false;
    }
    if (st.mode & 0o022) {
      process.stderr.write(`impeccable: ${p} is writable by group or others (mode ${(st.mode & 0o777).toString(8)}); refusing to run the engine\n`);
      return false;
    }
  }
  return true;
}
// The absolute path of `candidate` when it is a file whose sha256 is listed,
// else null with the reason on stderr. The returned absolute path is the one
// that was hashed and the one that runs.
function verified(candidate) {
  if (!candidate) return null;
  const abs = path.resolve(candidate);
  let bytes;
  try {
    if (!fs.lstatSync(abs).isFile()) {
      process.stderr.write(`impeccable: ${abs} is not a regular file (or is a symlink); refusing to run it\n`);
      return null;
    }
    if (process.platform !== 'win32' && !privateChain(abs)) return null;
    bytes = fs.readFileSync(abs);
  } catch { return null; }
  // Windows on ARM runs x64 binaries.
  const accepted = [expectedDigest(), TARGET === 'windows-arm64' && expectedDigest('impeccable-windows-x64.exe')].filter(Boolean);
  if (accepted.length === 0) {
    process.stderr.write(`impeccable: no checksum for engine ${VERSION} (${ASSET}) in ${MANIFEST}; refusing to run ${abs}\n`);
    return null;
  }
  const digest = createHash('sha256').update(bytes).digest('hex');
  if (!accepted.includes(digest)) {
    process.stderr.write(`impeccable: checksum mismatch for ${abs} (sha256 ${digest}); refusing to run it\n`);
    return null;
  }
  return abs;
}
function locate() {
  return verified(fromPackage());
}

// `--version` / `-v` is answered by the shim itself: the number users mean
// is this npm package's version, not the engine's (docs/CLI-CONTRACT.md).
const argv = process.argv.slice(2);
if (argv[0] === '--version' || argv[0] === '-v') {
  process.stdout.write(`${pkg.version}\n`);
  process.exit(0);
}

const bin = locate();
if (!bin) {
  process.stderr.write(
    `impeccable: no verified engine binary for ${TARGET}. This fork downloads nothing: `
    + `install ${PLATFORM_PKG} with the fork build listed in ${MANIFEST}.\n`,
  );
  process.exit(127);
}
const result = spawnSync(bin, argv, {
  stdio: 'inherit',
  env: { IMPECCABLE_SELF: 'npx impeccable', ...process.env },
});
if (result.error) {
  process.stderr.write(`impeccable: failed to run ${bin}: ${result.error.message}\n`);
  process.exit(127);
}
process.exit(result.status === null ? 1 : result.status);
