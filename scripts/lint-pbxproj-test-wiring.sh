#!/usr/bin/env bash
# Lint: every Swift file under cmuxTests/ must be wired into
# cmux.xcodeproj/project.pbxproj.
#
# A test file added to the worktree but not registered as a PBXFileReference +
# PBXSourcesBuildPhase entry in project.pbxproj is silently ignored by Xcode and
# never compiles or runs on CI. Both bot reviews and
# `xcodebuild test -only-testing:cmuxTests/<TestClass>` pass with
# "Executed 0 tests" — so missing wiring is indistinguishable from a passing
# regression test until a real user hits the bug the test was supposed to catch.
#
# Originally surfaced during the https://github.com/manaflow-ai/cmux/issues/4529
# investigation, where SessionIndexJSONLStreamTests.swift on
# https://github.com/manaflow-ai/cmux/pull/4536 looked like a clean two-commit
# red/green test fix but never actually ran on CI.
#
# Usage:
#   ./scripts/lint-pbxproj-test-wiring.sh [--repo-root <path>]
#
# Exit codes:
#   0 — all test files wired correctly (or no test files present)
#   1 — at least one test file is missing pbxproj wiring
#   2 — invocation error (e.g. project.pbxproj not found)

set -euo pipefail

REPO_ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,25p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
fi

PBXPROJ="$REPO_ROOT/cmux.xcodeproj/project.pbxproj"
TESTS_DIR="$REPO_ROOT/cmuxTests"

if [ ! -f "$PBXPROJ" ]; then
  echo "lint-pbxproj-test-wiring: not found: $PBXPROJ" >&2
  echo "  (run from the cmux repo root or pass --repo-root)" >&2
  exit 2
fi
if [ ! -d "$TESTS_DIR" ]; then
  echo "lint-pbxproj-test-wiring: not found: $TESTS_DIR" >&2
  exit 2
fi

# Locate the cmuxTests PBXNativeTarget, resolve its Sources build phase UUID,
# and list the basenames wired into that phase.
#
# Targeting the cmuxTests Sources phase specifically (instead of the whole
# pbxproj) catches three failure modes:
#   1. File missing entirely (no `<file>.swift in Sources` anywhere).
#   2. File has a PBXFileReference + group child but no PBXBuildFile /
#      Sources phase entry (in the project tree but not a member of any
#      target).
#   3. File is a member of the wrong target (e.g. cmuxUITests or cmux). Its
#      `<file>.swift in Sources` lines exist in the pbxproj, so a global grep
#      would pass, but they are not inside the cmuxTests Sources block.
#
# `/* cmuxTests */ = {` appears twice in a typical pbxproj: once for the
# PBXGroup that holds the test files, and once for the PBXNativeTarget. Only
# the native-target block matters, so keep the one containing
# `isa = PBXNativeTarget;`.
#
# Everything below goes through files rather than pipes or shell variables. An
# earlier version held the whole Sources phase in a variable and re-scanned it
# once per test file with `grep -qF <<<"$block"`. `grep -q` exits at its first
# match, so the shell was left writing the remainder of a ~57 KB here-string
# into a pipe with no reader: fine only while the content still fit in the
# kernel's pipe buffer, and a permanent hang for everyone the moment the phase
# outgrew it. One pass, no per-file subprocesses, no capacity assumption.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

tests_sources_uuid="$(awk '
  /\/\* cmuxTests \*\/ = \{/ { capture = 1; buf = ""; uuid = "" }
  capture { buf = buf $0 "\n" }
  capture && /[A-Z0-9]{24} \/\* Sources \*\// && uuid == "" {
    match($0, /[A-Z0-9]{24}/)
    uuid = substr($0, RSTART, RLENGTH)
  }
  capture && /^[[:space:]]*\};[[:space:]]*$/ {
    if (buf ~ /isa = PBXNativeTarget;/ && uuid != "") { print uuid; exit }
    capture = 0; buf = ""; uuid = ""
  }
' "$PBXPROJ")"

if [ -z "$tests_sources_uuid" ]; then
  echo "lint-pbxproj-test-wiring: could not resolve the cmuxTests target's Sources build phase in $PBXPROJ" >&2
  exit 2
fi

# Slice that PBXSourcesBuildPhase and emit one wired basename per line.
awk -v uuid="$tests_sources_uuid" '
  $0 ~ uuid " /\\* Sources \\*/ = \\{" { capture = 1; next }
  capture && /^[[:space:]]*\};[[:space:]]*$/ { exit }
  capture && /\/\* [^*]+ in Sources \*\/,$/ {
    entry = $0
    sub(/^.*\/\* /, "", entry)
    sub(/ in Sources \*\/,$/, "", entry)
    print entry
  }
' "$PBXPROJ" | LC_ALL=C sort -u > "$work_dir/wired"

if [ ! -s "$work_dir/wired" ]; then
  echo "lint-pbxproj-test-wiring: cmuxTests Sources build phase (uuid=$tests_sources_uuid) has no files" >&2
  exit 2
fi

# -L so a symlinked cmuxTests is followed rather than silently yielding nothing.
find -L "$TESTS_DIR" -maxdepth 1 -type f -name '*.swift' \
  | sed 's|.*/||' \
  | LC_ALL=C sort -u > "$work_dir/present"

checked="$(wc -l < "$work_dir/present" | tr -d ' ')"

# A lint that inspected nothing must not report success — that is the same
# "passes without running" failure this lint exists to catch.
if [ "$checked" -eq 0 ]; then
  echo "lint-pbxproj-test-wiring: found no .swift files in $TESTS_DIR" >&2
  exit 2
fi
missing=()
while IFS= read -r base; do
  [ -n "$base" ] && missing+=("$base")
done < <(LC_ALL=C comm -23 "$work_dir/present" "$work_dir/wired")

if [ "${#missing[@]}" -eq 0 ]; then
  echo "lint-pbxproj-test-wiring: ok (checked $checked test files)"
  exit 0
fi

echo "lint-pbxproj-test-wiring: ${#missing[@]} test file(s) not a member of the cmuxTests target's Sources build phase (uuid=$tests_sources_uuid) in cmux.xcodeproj/project.pbxproj"
for entry in "${missing[@]}"; do
  echo "  - $entry"
done
echo ""
echo "Each cmuxTests/<file>.swift must be wired into cmux.xcodeproj/project.pbxproj"
echo "as a full target member of cmuxTests:"
echo "  1. a PBXBuildFile entry (line ends with '<file>.swift in Sources */ = { ... };')"
echo "  2. a PBXFileReference entry"
echo "  3. an entry in the cmuxTests group children list"
echo "  4. an entry in the cmuxTests target's PBXSourcesBuildPhase files"
echo "     (line ends with '<file>.swift in Sources */,')"
echo ""
echo "This lint slices the cmuxTests Sources phase and looks for entry 4 there."
echo "Files wired only into cmuxUITests, cmux, or the project tree (without"
echo "cmuxTests target membership) are silently skipped by Xcode and will be"
echo "flagged here."
echo ""
echo "Add via Xcode (drag the file into the cmuxTests target) or hand-edit"
echo "the four blocks (see any wired sibling test as a template)."
exit 1
