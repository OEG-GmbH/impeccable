#!/bin/sh
# Runs the real launcher (plugin/skills/impeccable/scripts/impeccable) against a
# built engine on this machine, once with the good binary and once with a
# tampered copy, and shows the exit codes.
#
#   sh tools/verify-launcher.sh <binary> [<checksums file>]
#
# Without a checksums file the digest of <binary> itself is listed in a staged
# manifest (proves the verification logic on a fresh build). With one, that
# file is used as it is, e.g. the engine-checksums.txt of main (proves that the
# listed digest is the one of the published binary).
#
# Expected: the good binary runs (exit 0), a copy with one flipped byte is
# refused with exit 127 and "checksum mismatch", a copy with one byte appended
# likewise. Anything else makes this script fail.
set -eu

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "usage: sh tools/verify-launcher.sh <binary> [<engine-checksums.txt>]" >&2; exit 2; }
BIN=$1
LISTED=${2:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SRC=$ROOT/plugin/skills/impeccable/scripts

case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) echo "verify-launcher: unsupported OS" >&2; exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x64 ;; *) echo "verify-launcher: unsupported CPU" >&2; exit 1 ;; esac
asset=impeccable-$os-$arch

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

version=$(tr -d ' \t\r\n' < "$SRC/VERSION")
digest=$(sha "$BIN")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chmod 0755 "$tmp"

dir=$tmp/scripts
mkdir -p "$dir/bin/$os-$arch"
cp "$SRC/impeccable" "$SRC/VERSION" "$dir/"
if [ -n "$LISTED" ]; then
  cp "$LISTED" "$dir/engine-checksums.txt"
else
  printf '%s %s %s\n' "$version" "$asset" "$digest" > "$dir/engine-checksums.txt"
fi
chmod 0755 "$dir" "$dir/bin" "$dir/bin/$os-$arch" "$dir/impeccable"
chmod 0644 "$dir/VERSION" "$dir/engine-checksums.txt"
echo "listed for $version $asset: $(grep -E "^${version}[[:space:]]+${asset}[[:space:]]" "$dir/engine-checksums.txt" | cut -d' ' -f3)"
echo "digest of the binary:    $digest"

run() { # run <label> <expected exit> [<stderr pattern>]
  label=$1 want=$2 pat=${3:-}
  set +e
  "$dir/impeccable" --version > "$tmp/out" 2> "$tmp/err"
  got=$?
  set -e
  echo "--- $label: exit $got (expected $want)"
  sed 's/^/    out: /' "$tmp/out"
  sed 's/^/    err: /' "$tmp/err"
  [ "$got" = "$want" ] || { echo "verify-launcher: $label: exit $got, expected $want" >&2; exit 1; }
  if [ -n "$pat" ]; then
    grep -q "$pat" "$tmp/err" || { echo "verify-launcher: $label: stderr lacks '$pat'" >&2; exit 1; }
  fi
}

place() { # place <file>: install it as the engine, as the launcher expects it
  rm -f "$dir/bin/$os-$arch/impeccable"
  cp "$1" "$dir/bin/$os-$arch/impeccable"
  chmod 0755 "$dir/bin/$os-$arch/impeccable"
}

place "$BIN"
run "good binary" 0

# One byte flipped in the middle of the file (same size, different content).
size=$(wc -c < "$BIN" | tr -d ' ')
off=$((size / 2))
cur=$(dd if="$BIN" bs=1 skip="$off" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
new=$(( (cur + 1) % 256 ))
cp "$BIN" "$tmp/flipped"
chmod 0644 "$tmp/flipped"
printf "$(printf '\\%03o' "$new")" | dd of="$tmp/flipped" bs=1 seek="$off" conv=notrunc 2>/dev/null
[ "$(sha "$tmp/flipped")" != "$digest" ] || { echo "verify-launcher: the flipped copy has the same digest, the control is void" >&2; exit 1; }
place "$tmp/flipped"
run "one byte flipped" 127 'checksum mismatch'

# One byte appended.
cp "$BIN" "$tmp/appended"
chmod 0644 "$tmp/appended"
printf 'x' >> "$tmp/appended"
place "$tmp/appended"
run "one byte appended" 127 'checksum mismatch'

# And back to the good one: the refusals above were not a stuck state.
place "$BIN"
run "good binary again" 0
echo "verify-launcher: ok"
