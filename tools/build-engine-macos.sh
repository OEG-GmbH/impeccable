#!/bin/sh
# Reproducible build of the fork engine for macOS arm64, run by CI and by hand alike.
#
#   sh tools/build-engine-macos.sh <outdir>     <outdir> must be an absolute path
#
# Result: <outdir>/impeccable-darwin-arm64 and <outdir>/impeccable-darwin-arm64.sha256.
# Needs an Apple Silicon Mac with rustup, the Xcode command line tools and
# network for the first two steps.
#
# Same contract as tools/build-engine.sh, with the means macOS has. There is no
# container image to pin, and no network namespace; what replaces them:
#   - the toolchain is installed by rustup from the pinned channel into a
#     private RUSTUP_HOME under <outdir> (the host's own toolchain is never
#     used), and its rustc commit hash must equal RUSTC_COMMIT below, which is
#     the hash of the very compiler the linux image carries;
#   - dependencies are fetched first (network), the build then runs with
#     --frozen and CARGO_NET_OFFLINE=true inside sandbox-exec with network*
#     denied and the source tree read-only, so this is a real kernel-enforced
#     "no network" and not only a flag. Before using it the script proves that
#     the sandbox blocks a request that works outside of it;
#   - fixed path prefixes (--remap-path-prefix), CARGO_INCREMENTAL=0,
#     SOURCE_DATE_EPOCH and a fixed deployment target keep host paths and times
#     out of the binary; strip = true (Cargo.toml) removes the symbol table, so
#     no object file paths are left in the Mach-O. The linker's own ad-hoc code
#     signature is kept as it is (no extra signing); the linker's random-looking
#     LC_UUID is left out with -no_uuid, see the RUSTFLAGS below.
# What is NOT pinned: the Xcode command line tools (linker, SDK) of the machine.
# A different Xcode can give a different binary; the two builds of one CI run
# share the runner image, which is what the digest comparison relies on.
set -eu

# rustc commit-hash of 1.98.1 (`rustc -vV`); bump together with rust-toolchain.toml.
RUSTC_COMMIT='48a229ceaefd4985c50990b14116b6d856af0985'
ASSET='impeccable-darwin-arm64'
TARGET='aarch64-apple-darwin'
DEPLOYMENT_TARGET='11.0'

[ "$#" = 1 ] || { echo "usage: sh tools/build-engine-macos.sh <absolute outdir>" >&2; exit 2; }
OUT=$1
case $OUT in /*) ;; *) echo "build-engine-macos: outdir must be absolute: $OUT" >&2; exit 2 ;; esac
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "build-engine-macos: needs Darwin arm64, this is $(uname -sm)" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "build-engine-macos: rustup is not installed" >&2; exit 1; }
command -v sandbox-exec >/dev/null 2>&1 || { echo "build-engine-macos: sandbox-exec is missing, the offline build cannot be enforced" >&2; exit 1; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"

channel=$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' rust-toolchain.toml)
[ -n "$channel" ] || { echo "build-engine-macos: no channel in rust-toolchain.toml" >&2; exit 1; }

mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
case $OUT/ in "$ROOT"/*) echo "build-engine-macos: outdir must not be inside the source tree" >&2; exit 2 ;; esac
rm -rf "${OUT:?}/rustup" "$OUT/cargo-home" "$OUT/target" "$OUT/$ASSET" "$OUT/$ASSET.sha256"
mkdir -p "$OUT/rustup" "$OUT/cargo-home" "$OUT/target"

SOURCE_DATE_EPOCH=$(git log -1 --format=%ct HEAD)
export SOURCE_DATE_EPOCH
export RUSTUP_HOME="$OUT/rustup" CARGO_HOME="$OUT/cargo-home" CARGO_TARGET_DIR="$OUT/target"
# RUSTUP_TOOLCHAIN makes rustup ignore the wasm32 target of rust-toolchain.toml
# (the engine binary does not need it) and use exactly this toolchain.
export RUSTUP_TOOLCHAIN="$channel"
export CARGO_INCREMENTAL=0 CARGO_TERM_COLOR=never TZ=UTC LC_ALL=C
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
# -no_uuid: the linker's LC_UUID differed between two otherwise identical builds
# (measured on macos-15 runners: of 19 MB, 16 bytes of the UUID and the one
# code-signature page hash that covers it); it is not a function of the content.
export RUSTFLAGS="--remap-path-prefix=$ROOT=/build/src --remap-path-prefix=$OUT/cargo-home=/build/cargo --remap-path-prefix=$OUT/rustup=/build/rustup -C link-arg=-Wl,-no_uuid"

# Network step 1: the toolchain, a private copy, minimal profile, no self update.
rustup toolchain install "$channel" --profile minimal --no-self-update --target "$TARGET"
got=$(rustc --version | awk '{print $2}')
[ "$got" = "$channel" ] || { echo "build-engine-macos: rustc is $got, rust-toolchain.toml pins $channel" >&2; exit 1; }
commit=$(rustc -vV | sed -n 's/^commit-hash: //p')
[ "$commit" = "$RUSTC_COMMIT" ] || { echo "build-engine-macos: rustc commit $commit, expected $RUSTC_COMMIT" >&2; exit 1; }
host=$(rustc -vV | sed -n 's/^host: //p')
[ "$host" = "$TARGET" ] || { echo "build-engine-macos: rustc host is $host, expected $TARGET" >&2; exit 1; }

# Network step 2: the registry cache only.
cargo fetch --locked --target "$TARGET"

# The sandbox: no network of any kind, no writes into the source tree.
PROFILE="(version 1)(allow default)(deny network*)(deny file-write* (subpath \"$ROOT\"))"
# Both controls must hold, else "offline" would be a claim and not a fact: the
# probe request works outside the sandbox and fails inside it, and a write into
# the source tree works outside and fails inside.
probe='https://static.rust-lang.org/dist/channel-rust-1.98.1.toml.sha256'
curl -fsS -m 20 -o /dev/null "$probe" || { echo "build-engine-macos: probe request fails outside the sandbox, the control would prove nothing" >&2; exit 1; }
if sandbox-exec -p "$PROFILE" curl -fsS -m 20 -o /dev/null "$probe" 2>/dev/null; then
  echo "build-engine-macos: the sandbox does not block the network; refusing to build" >&2
  exit 1
fi
canary="$ROOT/.build-engine-canary.$$"
if sandbox-exec -p "$PROFILE" sh -c ": > '$canary'" 2>/dev/null || [ -e "$canary" ]; then
  rm -f "$canary"
  echo "build-engine-macos: the sandbox does not make the source tree read-only; refusing to build" >&2
  exit 1
fi
echo "build-engine-macos: sandbox verified (network denied, source read-only); building"

sandbox-exec -p "$PROFILE" env CARGO_NET_OFFLINE=true \
  cargo build --release --frozen -p impeccable --target "$TARGET"

cp "$OUT/target/$TARGET/release/impeccable" "$OUT/$ASSET"
chmod 0755 "$OUT/$ASSET"
(cd "$OUT" && shasum -a 256 "$ASSET" > "$ASSET.sha256")
cat "$OUT/$ASSET.sha256"
