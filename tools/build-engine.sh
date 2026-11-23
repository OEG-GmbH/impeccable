#!/bin/sh
# Reproducible build of the fork engine (linux-x64), run by CI and by hand alike.
#
#   sh tools/build-engine.sh <outdir>     <outdir> must be an absolute path
#
# Result: <outdir>/impeccable-linux-x64 and <outdir>/impeccable-linux-x64.sha256.
#
# The recipe is the contract; two runs on any machine with docker must give the
# same sha256 for the same source commit:
#   - the toolchain is the pinned image (digest, not tag), and the image's
#     rustc must equal the channel in rust-toolchain.toml;
#   - dependencies are fetched in a first container (network), the build runs in
#     a second one with --network none, a read-only source mount and --frozen;
#   - fixed mount points and --remap-path-prefix keep host paths out of the binary.
set -eu

# Same Rust release as rust-toolchain.toml (checked below). The digest is the
# multi-arch index of rust:1.98.1-bookworm; bump tag and digest together:
#   curl -sI -H 'Accept: application/vnd.oci.image.index.v1+json' \
#     https://registry-1.docker.io/v2/library/rust/manifests/<tag> (docker-content-digest)
IMAGE='rust:1.98.1-bookworm@sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e'
ASSET='impeccable-linux-x64'

[ "$#" = 1 ] || { echo "usage: sh tools/build-engine.sh <absolute outdir>" >&2; exit 2; }
OUT=$1
case $OUT in /*) ;; *) echo "build-engine: outdir must be absolute: $OUT" >&2; exit 2 ;; esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

channel=$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' rust-toolchain.toml)
[ -n "$channel" ] || { echo "build-engine: no channel in rust-toolchain.toml" >&2; exit 1; }
case $IMAGE in "rust:$channel-"*) ;; *)
  echo "build-engine: rust-toolchain.toml pins $channel, the image is $IMAGE; bump them together" >&2
  exit 1 ;;
esac

SOURCE_DATE_EPOCH=$(git log -1 --format=%ct HEAD)
mkdir -p "$OUT/cargo-home" "$OUT/target"

docker pull --quiet "$IMAGE" >/dev/null

# RUSTUP_TOOLCHAIN makes rustup use the image's toolchain as it is: rust-toolchain.toml
# also lists the wasm32 target, which rustup would install from the network (and
# the engine binary does not need it).
run() {
  net=$1; src_mode=$2; shift 2
  docker run --rm --network "$net" --user "$(id -u):$(id -g)" \
    -v "$ROOT:/src:$src_mode" -v "$OUT/cargo-home:/cargo" -v "$OUT/target:/target" \
    -w /src \
    -e HOME=/tmp -e CARGO_HOME=/cargo -e CARGO_TARGET_DIR=/target \
    -e RUSTUP_TOOLCHAIN="$channel" -e CARGO_INCREMENTAL=0 -e CARGO_TERM_COLOR=never \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e TZ=UTC -e LC_ALL=C \
    -e RUSTFLAGS='--remap-path-prefix=/src=/build/src --remap-path-prefix=/cargo=/build/cargo' \
    "$IMAGE" "$@"
}

got=$(run none ro rustc --version | awk '{print $2}')
[ "$got" = "$channel" ] || { echo "build-engine: image rustc is $got, rust-toolchain.toml pins $channel" >&2; exit 1; }

# Network: only to fill the cargo registry cache.
run bridge ro cargo fetch --locked
# No network from here on. The offline flag stays set as a second guard.
run none ro env CARGO_NET_OFFLINE=true cargo build --release --frozen -p impeccable

# ENGINE_TEST=1: the workspace tests in the same image, without network, before the
# binary is handed out (fork_no_network among them). A red test fails the recipe.
# The tests build into a separate target directory, so the release binary above
# stays the one that was compared.
#
# Skipped by exact name: the tests that drive a real Chromium (tests/motion.rs and one
# test of tests/component_capture.rs). The pinned image has no browser and the run has
# no network to fetch one. --exact keeps unit tests with the same words in their path
# (motion::tests::motion_*) running; a new browser test fails loudly instead of being
# skipped silently.
BROWSER_TESTS='captures_code_and_png_with_real_pixels_and_rejects_missing_inputs_without_replacing_review
motion_clipped motion_crossfade_dip motion_crossfade_overexposure motion_entrance_replay motion_grid_gap
motion_late_hover motion_orphan_linger motion_paint_order_swap motion_playback_rate motion_playback_reverse
motion_pseudo_twins motion_setup_reaches_the_open_state_before_an_exit motion_shadow_toggle motion_sibling
motion_smooth motion_swap motion_web_component'
if [ "${ENGINE_TEST:-}" = 1 ]; then
  set --
  for t in $BROWSER_TESTS; do set -- "$@" --skip "$t"; done
  run none ro env CARGO_NET_OFFLINE=true CARGO_TARGET_DIR=/target/test \
    cargo test --workspace --frozen --no-fail-fast -- --exact "$@"
fi

cp "$OUT/target/release/impeccable" "$OUT/$ASSET"
chmod 0755 "$OUT/$ASSET"
(cd "$OUT" && sha256sum "$ASSET" > "$ASSET.sha256")
cat "$OUT/$ASSET.sha256"
