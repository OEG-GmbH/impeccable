#!/bin/sh
# Fork guard: every patch of this fork brings its check here, so a merge of
# upstream that drops one turns this script red. It proves that the patches are
# still in the code, not that the engine is free of network access (a URL built
# at run time is invisible to a grep); the behaviour tests under crates/*/tests
# and tests/*.test.mjs do the rest and run outside this script.
#
#   sh tools/fork-guard.sh           run all checks from the repository root
#   sh tools/fork-guard.sh --list    print the need/deny/before checks, run nothing
#                                    (tools/fork-guard-selftest.sh mutates each one)
set -eu

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

fail() {
  echo "$1"
  exit 1
}

# need <file> <fixed text> <patch>: the patch is still in the code.
need() {
  if [ "$LIST" = 1 ]; then
    printf 'need\t%s\t%s\t%s\n' "$1" "$2" "$3"
    return 0
  fi
  [ -f "$1" ] || fail "fork patch $3: $1 is missing"
  grep -qF -- "$2" "$1" || fail "fork patch $3 is missing: '$2' not in $1"
}

# deny <file> <ERE> <patch> <sample>...: the pattern is back in the code. Every
# sample must match the ERE; the self-test appends each one to the file and
# expects this check to fail.
deny() {
  if [ "$LIST" = 1 ]; then
    f=$1 re=$2 p=$3
    shift 3
    for s in "$@"; do printf 'deny\t%s\t%s\t%s\t%s\n' "$f" "$re" "$p" "$s"; done
    return 0
  fi
  [ -f "$1" ] || fail "fork patch $3: $1 is missing"
  if grep -qE -- "$2" "$1"; then
    fail "fork patch $3 lost: /$2/ found in $1"
  fi
}

# before <file> <text a> <text b> <patch>: a stands before b (both fixed, both present).
before() {
  if [ "$LIST" = 1 ]; then
    printf 'before\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
    return 0
  fi
  a=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1)
  b=$(grep -nF -- "$3" "$1" | head -1 | cut -d: -f1)
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" -ge "$b" ]; then
    fail "fork patch $4 lost: '$2' is not before '$3' in $1"
  fi
}

if [ "$LIST" = 0 ]; then
  { [ -f Cargo.toml ] && [ -d crates ]; } || fail "engine source missing (Cargo.toml, crates)"
fi

# a) account, Pro, OAuth and uploads are off for good
need crates/account/src/lib.rs 'pub const OEG_ACCOUNT_DISABLED: bool = true;' a
need crates/account/src/pro/mod.rs 'if crate::OEG_ACCOUNT_DISABLED {' a
need crates/account/src/http.rs 'return Err(ApiError::Network(crate::OEG_DISABLED_MSG.into()));' a
need crates/cli/src/router.rs 'if impeccable_account::OEG_ACCOUNT_DISABLED =>' a
need crates/cli/src/setup_report.rs 'impeccable_account::OEG_ACCOUNT_DISABLED ||' a

# b) telemetry, update check and taste are off for good
need crates/context/src/telemetry.rs 'pub const OEG_PHONE_HOME_DISABLED: bool = true;' b
need crates/context/src/telemetry.rs 'if OEG_PHONE_HOME_DISABLED {' b
need crates/context/src/telemetry.rs 'if OEG_PHONE_HOME_DISABLED || timeout.is_zero() {' b
need crates/context/src/taste.rs 'crate::telemetry::OEG_PHONE_HOME_DISABLED || env.get' b
# two guards in context_cli.rs (the update check and the notice from the cache), so a count, not a need
if [ "$LIST" = 0 ]; then
  [ "$(grep -cF 'if crate::telemetry::OEG_PHONE_HOME_DISABLED {' crates/context/src/context_cli.rs)" -ge 2 ] ||
    fail "fork patch b is missing: the update notice from the cache is not blocked"
fi

# c) the roll service is never asked (local catalog or degraded), no network hint in the text
need crates/context/src/concept_seed.rs 'pub(crate) const OEG_ROLL_SERVICE_DISABLED: bool = true;' c
need crates/context/src/concept_seed.rs 'if OEG_ROLL_SERVICE_DISABLED {' c
need crates/context/src/seed_text.rs 'this OEG build has no roll service' c

# d) no downloads: the launchers run a verified binary only, the engine fetches nothing, Loop is gone
for d in skill/scripts plugin/skills/impeccable/scripts; do
  need "$d/impeccable" 'exec_verified "$@"' d
  need "$d/impeccable" '  candidate=$bin' d
  need "$d/impeccable" 'for p in "$dir" "$dir/bin" "${candidate%/*}" "$candidate"; do' d
  need "$d/impeccable" 'is writable by group or others (mode $m_mode); refusing to run the engine' d
  need "$d/impeccable" '  m_go=00$m_mode' d
  need "$d/impeccable" 'is not installed: no binary at' d
  need "$d/impeccable.cmd" 'is not installed: no binary at' d
  before "$d/impeccable" 'is not installed: no binary at' 'no checksum for engine' d
  before "$d/impeccable.cmd" 'if not exist "%run%" goto no_binary' 'goto no_checksum' d
  deny "$d/impeccable" 'curl|wget|IMPECCABLE_DOWNLOAD_BASE|command -v impeccable|\.impeccable/bin|\.verified|\$\{IMPECCABLE_BIN' d \
    'curl -fsSL "$url"' 'wget -q "$url"' 'echo $IMPECCABLE_DOWNLOAD_BASE' 'command -v impeccable' 'p=$HOME/.impeccable/bin' 'touch x.verified' 'echo ${IMPECCABLE_BIN}'
  need "$d/impeccable.cmd" 'certutil -hashfile' d
  need "$d/impeccable.cmd" 'set "run=%~dp0bin\windows-%arch%\impeccable.exe"' d
  deny "$d/impeccable.cmd" 'curl|IMPECCABLE_DOWNLOAD_BASE|where impeccable|IMPECCABLE_HOME|\.verified|%IMPECCABLE_BIN%' d \
    'curl -o x y' 'set u=%IMPECCABLE_DOWNLOAD_BASE%' 'where impeccable' 'set h=%IMPECCABLE_HOME%' 'type x.verified' 'set b=%IMPECCABLE_BIN%'
done

# d) every provider copy of the launcher is the hardened one from skill/scripts
if [ "$LIST" = 0 ]; then
  copies=$(find . -path ./target -prune -o -type f -path '*/skills/impeccable/scripts/impeccable' -print)
  [ "$(echo "$copies" | grep -c .)" -ge 20 ] || fail "fork patch d: fewer than 20 launcher copies found, the check measures nothing"
  for c in $copies; do
    cd_=$(dirname "$c")
    for f in impeccable impeccable.cmd engine-checksums.txt; do
      cmp -s "$cd_/$f" "skill/scripts/$f" || fail "fork patch d lost: $cd_/$f differs from skill/scripts/$f"
    done
  done
fi

# d) npm shim: listed binaries only, no download, no cache
need cli/bin/cli.js 'if (!accepted.includes(digest)) {' d
deny cli/bin/cli.js 'fetch\(|releases/download|IMPECCABLE_DOWNLOAD_BASE|\.verified|process\.env\.IMPECCABLE_BIN' d \
  'await fetch(url)' 'const u = "x/releases/download/y"' 'process.env.IMPECCABLE_DOWNLOAD_BASE' 'const v = ".verified"' 'process.env.IMPECCABLE_BIN'
need cli/bin/cli.js 'if (process.platform !== '"'"'win32'"'"' && !privateChain(abs)) return null;' d
need cli/bin/cli.js '  for (const p of chainToShim(bin)) {' d
need crates/skills/src/bundle.rs 'pub const OEG_DOWNLOADS_DISABLED: bool = true;' d
if [ "$LIST" = 0 ]; then
  [ "$(grep -cF 'if OEG_DOWNLOADS_DISABLED {' crates/skills/src/bundle.rs)" -ge 2 ] ||
    fail "fork patch d is missing: download block in bundle.rs"
fi
deny crates/skills/src/engine_binary.rs 'bundle::|download\(|fetch_binary|DOWNLOAD_BASE|asset_url' d \
  'use crate::bundle::get;' 'let r = download(u);' 'fn fetch_binary() {}' 'const DOWNLOAD_BASE: &str = "";' 'let a = asset_url(t);'
if [ "$LIST" = 0 ]; then
  if [ -e crates/cli/src/loop_install.rs ] || [ -e crates/cli/src/loop_connect.rs ]; then
    fail "fork patch d lost: the Loop modules are back"
  fi
fi
need crates/cli/src/router.rs 'impeccable loop: im OEG-Fork entfernt' d

# d) help comes from the bundled command metadata, not from /api/commands
need crates/skills/src/commands.rs 'serde_json::from_str(impeccable_context::pin::COMMAND_METADATA_JSON).ok()?' d
deny crates/skills/src/commands.rs 'download\(&format!\("\{API_BASE\}/api/commands' d \
  'let r = download(&format!("{API_BASE}/api/commands"));'

# e) cache and audit log: every component below the base opened with openat(O_NOFOLLOW), no symlink
need crates/hook/src/oeg_fs.rs 'libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC' e
need crates/hook/src/oeg_fs.rs 'flags | libc::O_NOFOLLOW | libc::O_CLOEXEC' e
need crates/hook/src/hook_lib.rs '    crate::oeg_fs::replace_in(' e
need crates/hook/src/hook_lib.rs '    crate::oeg_fs::append_in(&base, &parts, &name, line.as_bytes())' e
need crates/hook/src/hook_lib.rs 'let from_env = rt.env("IMPECCABLE_HOOK_LOG").is_some_and(|v| !v.is_empty());' e
deny crates/hook/src/hook_lib.rs 'std::fs::write\($|OpenOptions::new\(\)$' e \
  'std::fs::write(' 'let f = OpenOptions::new()'

# g) more network paths: remote images (--ref URL, world cards) and font-match (Google Fonts)
need crates/context/src/generate_image.rs 'pub(crate) const OEG_REMOTE_IMAGES_DISABLED: bool = true;' g
need crates/context/src/generate_image.rs 'if OEG_REMOTE_IMAGES_DISABLED {' g
need crates/cli/src/router.rs 'const OEG_GOOGLE_FONTS_DISABLED: bool = true;' g
need crates/cli/src/router.rs 'impeccable font-match: im OEG-Fork deaktiviert' g
deny crates/context/src/serve_question.rs 'src [^;"]*https://fonts\.(googleapis|gstatic)\.com' g \
  'x = "font-src https://fonts.gstatic.com";' 'x = "style-src https://fonts.googleapis.com";'
need crates/context/src/serve_question.rs 'const PAGE_CSP: &str = "img-src '"'"'self'"'"' data: blob:";' g
need crates/context/src/serve_question.rs '.header("content-security-policy", PAGE_CSP).text(&html));' g

# t) behaviour tests of the switches exist (they run elsewhere, this only checks they are there)
need crates/cli/tests/fork_no_network.rs 'fn no_verb_reaches_a_service_even_with_overrides_and_a_sign_in()' t
# the upstream tests of the switched-off services stay off, no feature turns them back on
if [ "$LIST" = 0 ]; then
  if grep -rq 'upstream-account-tests' crates; then
    fail "fork: the feature upstream-account-tests is back"
  fi
fi
for f in crates/account/tests/login.rs crates/cli/tests/health.rs; do need "$f" '#![cfg(any())]' t; done
# the launcher tests check the fork contract, not the upstream download
if [ "$LIST" = 0 ]; then
  [ ! -e tests/launcher-download.test.mjs ] || fail "fork: tests/launcher-download.test.mjs (upstream download) is back"
fi
need scripts/test-suites.mjs "'tests/launcher.test.mjs'," t

# f) no upstream service and no release download in the source. Checked: crates/**/*.rs
#    and *.js without tests/, examples/, benches/, without #[cfg(test)] modules and
#    without comment lines, plus the four launchers.
if [ "$LIST" = 0 ]; then
  files=$(find crates -path '*/tests' -prune -o -path '*/examples' -prune -o -path '*/benches' -prune -o -type f \( -name '*.rs' -o -name '*.js' \) -print | sort)
  [ "$(echo "$files" | grep -c 'crates/cli/src/router.rs')" = 1 ] || fail "fork patch f: file list without crates/cli/src/router.rs, the check measures nothing"
  hits=$(for f in $files; do awk -v F="$f" '
    skip == 0 && prev ~ /^#\[cfg\(test\)\]$/ && $0 ~ /^(pub )?mod [A-Za-z0-9_]+ \{$/ { skip = 1 }
    skip == 1 { if ($0 ~ /^\}$/) skip = 0; prev = $0; next }
    { prev = $0 }
    /^[ \t]*(\/\/|\/\*|\*)/ { next }
    /impeccable\.style|releases\/download/ { print F ":" FNR ": " $0 }
  ' "$f"; done)
  for d in skill/scripts plugin/skills/impeccable/scripts; do
    hits="$hits$(grep -nE 'impeccable\.style|releases/download' "$d/impeccable" "$d/impeccable.cmd" || true)"
  done
  [ -z "$hits" ] || { echo "$hits"; fail "fork patch f lost: impeccable.style or releases/download in the source"; }
  echo "fork patches present"
fi
