#!/bin/sh
# Holds every check of tools/fork-guard.sh against its failure case. It copies the
# working tree (without .git and target) to a throw-away directory, breaks one thing
# at a time, and requires that the guard exits non-zero AND names exactly that check.
# A guard that never went red is untested.
#
#   sh tools/fork-guard-selftest.sh
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

(cd "$here" && tar --exclude=./.git --exclude=./target -cf - .) | tar -xf - -C "$tmp"
cd "$tmp"

total=0
bad=0
out="$tmp/.guard-out"

note_bad() {
  bad=$((bad + 1))
  echo "NOT DETECTED: $1"
}

# run_guard: exit code in $rc, output in $out
run_guard() {
  rc=0
  sh tools/fork-guard.sh >"$out" 2>&1 </dev/null || rc=$?
}

# expect_red <label> <text the guard output must contain>
expect_red() {
  total=$((total + 1))
  run_guard
  if [ "$rc" -eq 0 ]; then
    note_bad "$1 (guard stayed green)"
  elif ! grep -qF -- "$2" "$out"; then
    note_bad "$1 (guard is red, but not for this check; output: $(head -1 "$out"))"
  fi
}

# expect_green <label>: negative control, the guard must not react
expect_green() {
  total=$((total + 1))
  run_guard
  [ "$rc" -eq 0 ] || note_bad "$1 (guard went red: $(head -1 "$out"))"
}

backup() { cp -p "$1" "$1.selftest-orig"; }
restore() { mv "$1.selftest-orig" "$1"; }

# remove_text <file> <fixed text> [occurrence]: delete the n-th occurrence (default 1)
remove_text() {
  T=$2 N=${3:-1} awk '
    { s = $0; t = ENVIRON["T"]; n = ENVIRON["N"] + 0
      i = index(s, t)
      if (i && !done) { c++; if (c == n) { s = substr(s, 1, i - 1) substr(s, i + length(t)); done = 1 } }
      print s }' "$1" >"$1.selftest-new"
  cat "$1.selftest-new" >"$1"
  rm -f "$1.selftest-new"
}

# move_line_to_end <file> <fixed text>: first line containing it goes to the end
move_line_to_end() {
  T=$2 awk '
    { if (!m && index($0, ENVIRON["T"])) { m = $0; next } print }
    END { if (m != "") print m }' "$1" >"$1.selftest-new"
  cat "$1.selftest-new" >"$1"
  rm -f "$1.selftest-new"
}

append_line() { printf '%s\n' "$2" >>"$1"; }

# baseline: the unbroken copy must be green, or nothing below means anything
run_guard
if [ "$rc" -ne 0 ] || ! grep -qF 'fork patches present' "$out"; then
  echo "baseline is not green:"
  cat "$out"
  exit 1
fi
list=$(sh tools/fork-guard.sh --list)
[ "$(printf '%s\n' "$list" | grep -c .)" -ge 90 ] || {
  echo "--list printed fewer than 90 checks, the mutation run would measure nothing"
  exit 1
}

# need / deny / before, straight from the guard's own list
TAB=$(printf '\t')
printf '%s\n' "$list" >"$tmp/.checks"

while IFS=$TAB read -r kind f a b c; do
  [ -f "$f" ] || {
    note_bad "$kind $f: file does not exist, the check cannot be mutated"
    total=$((total + 1))
    continue
  }
  backup "$f"
  case "$kind" in
    need)
      # a=text, b=patch
      remove_text "$f" "$a"
      expect_red "need $f '$a'" "fork patch $b is missing: '$a' not in $f"
      ;;
    deny)
      # a=ERE, b=patch, c=sample
      if ! printf '%s\n' "$c" | grep -qE -- "$a"; then
        note_bad "deny $f: sample '$c' does not match /$a/"
        total=$((total + 1))
      else
        append_line "$f" "$c"
        expect_red "deny $f sample '$c'" "fork patch $b lost: /$a/ found in $f"
      fi
      ;;
    before)
      # a=text a, b=text b, c=patch
      move_line_to_end "$f" "$a"
      expect_red "before $f '$a' < '$b'" "fork patch $c lost: '$a' is not before '$b' in $f"
      ;;
  esac
  restore "$f"
done <"$tmp/.checks"

# checks that are not need/deny/before lines
backup Cargo.toml
rm Cargo.toml
expect_red "Cargo.toml missing" "engine source missing"
restore Cargo.toml

f=crates/context/src/context_cli.rs
backup $f
remove_text $f 'if crate::telemetry::OEG_PHONE_HOME_DISABLED {' 2
expect_red "context_cli.rs: second update guard removed" "the update notice from the cache is not blocked"
restore $f

f=crates/skills/src/bundle.rs
backup $f
remove_text $f 'if OEG_DOWNLOADS_DISABLED {' 2
expect_red "bundle.rs: second download guard removed" "download block in bundle.rs"
restore $f

for m in loop_install loop_connect; do
  : >"crates/cli/src/$m.rs"
  expect_red "$m.rs is back" "the Loop modules are back"
  rm -f "crates/cli/src/$m.rs"
done

f=crates/cli/Cargo.toml
backup $f
append_line $f 'upstream-account-tests = []'
expect_red "feature upstream-account-tests is back" "upstream-account-tests is back"
restore $f

: >tests/launcher-download.test.mjs
expect_red "launcher-download test is back" "launcher-download.test.mjs (upstream download) is back"
rm -f tests/launcher-download.test.mjs

# launcher copies: too few found, or one of them drifts from skill/scripts
copies=$(find . -type f -path '*/skills/impeccable/scripts/impeccable' | sort)
mkdir "$tmp/.moved"
n=0
for c in $copies; do
  n=$((n + 1))
  [ "$n" -le 5 ] || break
  mkdir -p "$tmp/.moved/$n"
  mv "$c" "$tmp/.moved/$n/impeccable"
done
expect_red "fewer than 20 launcher copies" "fewer than 20 launcher copies found"
n=0
for c in $copies; do
  n=$((n + 1))
  [ "$n" -le 5 ] || break
  mv "$tmp/.moved/$n/impeccable" "$c"
done
d=$(dirname "$(printf '%s\n' "$copies" | tail -1)")
for name in impeccable impeccable.cmd engine-checksums.txt; do
  backup "$d/$name"
  append_line "$d/$name" '# drift'
  expect_red "copy $d/$name drifts" "$d/$name differs from skill/scripts/$name"
  restore "$d/$name"
done

# j) engine-release.txt: format and copies
rel=skill/scripts/engine-release.txt
backup $rel
append_line $rel 'engine-fork-0.1.25-2'
expect_red "engine-release.txt has two lines" "$rel is not exactly one line"
restore $rel
backup $rel
printf 'latest\n' >$rel
expect_red "engine-release.txt is not a release tag" "$rel is not a release tag"
restore $rel
backup $rel
printf 'engine-fork-0.1.25-1\r\n' >$rel
expect_red "engine-release.txt has a carriage return" "$rel has stray whitespace"
restore $rel
backup $rel
rm $rel
expect_red "engine-release.txt is missing" "$rel is missing"
restore $rel
d=$(dirname "$(printf '%s\n' "$copies" | tail -1)")
backup "$d/engine-release.txt"
printf 'engine-fork-0.1.25-9\n' >"$d/engine-release.txt"
expect_red "engine-release.txt copy drifts" "$d/engine-release.txt differs from $rel"
restore "$d/engine-release.txt"
backup "$d/engine-release.txt"
rm "$d/engine-release.txt"
expect_red "engine-release.txt copy is missing" "$d/engine-release.txt is missing"
restore "$d/engine-release.txt"

# f) upstream host or release download in the source
f=crates/cli/src/router.rs
backup $f
append_line $f 'const U: &str = "https://impeccable.style/api/x";'
expect_red "router.rs: impeccable.style" "impeccable.style or releases/download in the source"
restore $f
f=crates/live/assets/detect-antipatterns-browser.js
backup $f
append_line $f 'var u = "x/releases/download/y";'
expect_red "a .js asset: releases/download" "impeccable.style or releases/download in the source"
restore $f
# every launcher copy together, so the copy comparison stays quiet and only f) can fire
for name in impeccable impeccable.cmd; do
  for c in $copies skill/scripts/impeccable; do
    d=$(dirname "$c")
    backup "$d/$name"
    if [ "$name" = impeccable.cmd ]; then append_line "$d/$name" 'rem impeccable.style'; else append_line "$d/$name" '# impeccable.style'; fi
  done
  expect_red "launcher $name: impeccable.style" "impeccable.style or releases/download in the source"
  for c in $copies skill/scripts/impeccable; do restore "$(dirname "$c")/$name"; done
done
# plugin/ is a copy as well; skill/scripts is not under */skills/, handled above
# negative controls: a comment and a #[cfg(test)] module must not trigger f)
f=crates/cli/src/router.rs
backup $f
append_line $f '// impeccable.style is only named in this comment'
expect_green "negative control: impeccable.style in a comment"
restore $f
backup $f
printf '#[cfg(test)]\nmod probe {\n    let u = "https://impeccable.style";\n}\n' >>$f
expect_green "negative control: impeccable.style in a cfg(test) module"
restore $f
# the file list must hold router.rs exactly once
mkdir -p crates/cli/src/dup/crates/cli/src
: >crates/cli/src/dup/crates/cli/src/router.rs
expect_red "router.rs listed twice" "file list without crates/cli/src/router.rs"
rm -rf crates/cli/src/dup

run_guard
[ "$rc" -eq 0 ] || {
  echo "the copy is not green again after restoring everything: $(head -1 "$out")"
  exit 1
}

echo "self-test: $total mutations and controls, $bad not detected"
[ "$bad" -eq 0 ]
