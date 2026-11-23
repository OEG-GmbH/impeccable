#!/usr/bin/env python3
"""Pack the Claude Code plugin with both engine binaries into one reproducible zip.

    python3 -I tools/package-plugin.py <plugin-dir> <linux-x64 binary> <darwin-arm64 binary> <out.zip>

The zip is what the marketplace pins as an `archive` source (url plus sha256), so
Claude Code installs plugin and engine in one verified step. Its root is the
plugin directory itself; the binaries go to skills/impeccable/scripts/bin/<platform>/impeccable,
next to the launcher, which runs them only when their sha256 is listed in
skills/impeccable/scripts/engine-checksums.txt. This script refuses a binary that
is not listed there, so a zip can never carry an engine its own launcher rejects.

Reproducible: entries sorted, fixed timestamp, fixed modes (directories and
executables 0755, other files 0644), no symlinks, no extra attributes. The same
inputs give the same bytes on any machine.
"""
import hashlib
import os
import stat
import sys
import zipfile

FIXED_TIME = (1980, 1, 1, 0, 0, 0)
BIN_REL = "skills/impeccable/scripts/bin"
MANIFEST_REL = "skills/impeccable/scripts/engine-checksums.txt"
PLATFORMS = (("linux-x64", 1), ("darwin-arm64", 2))


def die(msg):
    sys.stderr.write(f"package-plugin: {msg}\n")
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def listed_digests(manifest):
    out = {}
    with open(manifest, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 3 and not line.startswith("#"):
                out[parts[1]] = parts[2]
    return out


def entry(name, mode):
    zi = zipfile.ZipInfo(name, date_time=FIXED_TIME)
    zi.create_system = 3
    zi.external_attr = mode << 16
    zi.compress_type = zipfile.ZIP_DEFLATED
    return zi


def main(argv):
    if len(argv) != 5:
        die("usage: package-plugin.py <plugin-dir> <linux-x64 binary> <darwin-arm64 binary> <out.zip>")
    plugin, out = argv[1], argv[4]
    bins = {"linux-x64": argv[2], "darwin-arm64": argv[3]}
    if not os.path.isfile(os.path.join(plugin, ".claude-plugin", "plugin.json")):
        die(f"{plugin} has no .claude-plugin/plugin.json")
    if os.path.exists(os.path.join(plugin, BIN_REL)):
        die(f"{plugin}/{BIN_REL} exists already; pack from a clean checkout")
    listed = listed_digests(os.path.join(plugin, MANIFEST_REL))
    for platform, path in bins.items():
        asset = f"impeccable-{platform}"
        got = sha256(path)
        if listed.get(asset) != got:
            die(f"{asset} sha256 {got} is not listed in {MANIFEST_REL} ({listed.get(asset)})")

    files = {}  # zip name -> (source path, mode)
    dirs = set()
    for root, dnames, fnames in os.walk(plugin):
        dnames.sort()
        rel_root = os.path.relpath(root, plugin)
        for d in dnames:
            p = os.path.join(root, d)
            if os.path.islink(p):
                die(f"symlink {p}")
            dirs.add(os.path.normpath(os.path.join(rel_root, d)))
        for n in fnames:
            p = os.path.join(root, n)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
                die(f"not a regular file: {p}")
            mode = 0o755 if st.st_mode & 0o111 else 0o644
            files[os.path.normpath(os.path.join(rel_root, n))] = (p, mode)
    for platform, path in bins.items():
        dirs.update({BIN_REL, f"{BIN_REL}/{platform}"})
        files[f"{BIN_REL}/{platform}/impeccable"] = (path, 0o755)

    tmp = out + ".tmp"
    with zipfile.ZipFile(tmp, "w") as z:
        for d in sorted(dirs):
            zi = entry(d + "/", stat.S_IFDIR | 0o755)
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, b"")
        for name in sorted(files):
            src, mode = files[name]
            with open(src, "rb") as f:
                z.writestr(entry(name, stat.S_IFREG | mode), f.read(), compresslevel=9)
    os.replace(tmp, out)
    print(f"{sha256(out)}  {os.path.basename(out)}")


if __name__ == "__main__":
    main(sys.argv)
