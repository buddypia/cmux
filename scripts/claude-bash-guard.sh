#!/usr/bin/env bash
# PreToolUse(Bash) guard for Claude Code agents working in this repo.
#
# Three rules only, and each one earns its place the same way: the damage lands
# outside the agent's own session, so the agent cannot see that it happened.
# Everything an agent can notice and correct itself stays advisory in CLAUDE.md
# or a skill — a guard that fires on recoverable mistakes just trains people to
# work around it.
#
# Exit 2 blocks the call and shows stderr to the agent, so each message says
# what to run instead. Any other non-zero exit is *not* blocking, which means
# a guard that cannot start is a guard that silently stops guarding — hence
# the `${CLAUDE_PROJECT_DIR:-.}` fallback in .claude/settings.json and the
# self-test below (`--self-test`), which is the only thing that can tell you
# the rules still match what they are supposed to.
set -uo pipefail

if [ "${1:-}" = "--self-test" ]; then
    self="${BASH_SOURCE[0]}"
    self_test_failed=0
    check() {
        local want="$1" cmd="$2" got
        printf '%s' "$cmd" \
            | python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.stdin.read()}}))' \
            | "$self" >/dev/null 2>&1
        got=$?
        if [ "$got" != "$want" ]; then
            printf 'FAIL  want=%s got=%s  %s\n' "$want" "$got" "$cmd" >&2
            self_test_failed=1
        fi
    }

    # Blocked.
    check 2 'xcodebuild -project cmux.xcodeproj -scheme cmux-unit build-for-testing'
    check 2 'CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -destination x test'
    check 2 'cd /tmp && xcodebuild -scheme cmux build'
    check 2 'xcodebuild -scheme cmux \
  build'
    check 2 '/tmp/cmux-cli list-workspaces'
    check 2 'git add -A'
    check 2 'git add .'
    check 2 'cd /x && git add --all'
    check 2 'git add -u'
    check 2 'git commit -am "wip"'
    check 2 'git commit -a'

    # Allowed. Each one is a command this repo's own docs tell you to run,
    # or a read that only looks at a guarded path.
    check 0 'xcodebuild -project cmux.xcodeproj -scheme cmux-unit -derivedDataPath /tmp/cmux-t build-for-testing'
    check 0 'xcodebuild -downloadComponent MetalToolchain'
    check 0 'xcodebuild -list'
    check 0 './scripts/reload.sh --tag t'
    check 0 'CMUX_TAG=t scripts/cmux-debug-cli.sh list-workspaces'
    check 0 'ls -la /tmp/cmux-cli'
    check 0 'git add Sources/Foo.swift cmuxTests/Bar.swift'
    check 0 'git commit -q -m "msg"'
    # Writing about a build failure is not running one. Matching the whole
    # command as one blob used to block exactly the commit that fixes it.
    # Writing about a build failure is not running one. Matching the whole
    # command as one blob used to block exactly the commit that fixes it: the
    # token on one line of the message, a bare `build` on another.
    check 0 'git commit -q -m "$(cat <<XEOF
xcodebuild hangs forever at ExecuteExternalTool clang -v -E -dM when the
machine runs out of kernel pipe buffer. The cmux-unit build above must
succeed before anything else is believed.
XEOF
)"'
    check 0 'ps aux | grep xcodebuild'
    check 0 'cmux notify --body "Was: xcodebuild deadlocked here. Now: cmux-unit build-for-testing succeeds."'
    check 0 'git commit --amend'
    check 0 'git status --short'

    if [ "$self_test_failed" = 0 ]; then
        echo "claude-bash-guard: all cases pass"
        exit 0
    fi
    exit 1
fi

command_line="$(
    python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    print("")
' 2>/dev/null
)"

[ -n "$command_line" ] || exit 0

block() {
    printf '%s\n' "$1" >&2
    exit 2
}

# 1. An xcodebuild that builds without -derivedDataPath writes into the shared
#    default DerivedData, which the user's own app and every other agent's
#    build also use. Informational subcommands are fine, and so is the
#    Metal Toolchain download CLAUDE.md tells you to run.
#
#    Matched per line, with the build verb required to follow the token on that
#    same line. Scanning the whole command as one blob meant any text that
#    happened to contain both words tripped it -- including a commit message
#    describing a build failure, which is a thing you write precisely when you
#    are trying to fix one.
if printf '%s' "$command_line" | python3 -c '
import re
import sys

# Line continuations first: `xcodebuild \<newline> ... build` is one command.
text = sys.stdin.read().replace("\\\n", " ")
# xcodebuild in command position: start of line or after a shell separator,
# optionally behind FOO=bar env assignments.
# Command position only: start of line, or after a shell separator, possibly
# behind FOO=bar env assignments. A bare word boundary matched the token
# mid-sentence, which is how prose about a build kept tripping this.
invocation = re.compile(
    r"(?:^|[;&|]\s*|\(\s*|`\s*)(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*xcodebuild(\s.*)?$"
)
verb = re.compile(r"\s(build|build-for-testing|test|test-without-building|archive)(\s|$)")

for line in text.splitlines():
    for match in invocation.finditer(line):
        rest = match.group(1) or ""
        if verb.search(rest) and "-derivedDataPath" not in rest:
            sys.exit(0)
sys.exit(1)
' 2>/dev/null; then
    block "Blocked: xcodebuild without -derivedDataPath shares the default DerivedData with the user's app and other agents.

  ./scripts/reload.sh --tag <tag>                       # to build and run
  xcodebuild ... -derivedDataPath /tmp/cmux-<tag> ...   # to compile only

See CLAUDE.md 'Build and reload'."
fi

# 2. /tmp/cmux-cli points at whichever build reloaded last, which is often the
#    user's main app. Commands sent through it land in the wrong window.
if printf '%s' "$command_line" | grep -qE '(^|[;&|]\s*)/tmp/cmux-cli(\s|$)'; then
    block "Blocked: /tmp/cmux-cli targets the most recent reload, which may be the user's main app.

  CMUX_TAG=<tag> scripts/cmux-debug-cli.sh <command>

See CLAUDE.md 'Tag-bound debug CLI'."
fi

# 3. This working tree is shared with other agents, and their work-in-progress
#    sits in it uncommitted. A whole-tree stage sweeps their files into your
#    commit, where neither of you will look for them.
if printf '%s' "$command_line" | grep -qE '(^|[;&|]\s*)git\s+add\s+(-A|--all|-u|\.)(\s|$)'; then
    block "Blocked: this working tree is shared with other agents; a whole-tree stage would commit their uncommitted work.

  git add <path> [<path>...]        # name every file you are committing
  git status --short                # anything you did not touch is someone else's"
fi

if printf '%s' "$command_line" | grep -qE '(^|[;&|]\s*)git\s+commit\s+(-[a-zA-Z]*a|--all)'; then
    block "Blocked: 'git commit -a' stages every tracked change, including other agents' work-in-progress in this shared tree.

  git add <path> && git commit      # name every file you are committing"
fi

exit 0
