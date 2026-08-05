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
# what to run instead.
set -uo pipefail

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
if printf '%s' "$command_line" | grep -qE '(^|[;&|]\s*|\s)xcodebuild\s'; then
    if printf '%s' "$command_line" | grep -qE '\s(build|build-for-testing|test|test-without-building|archive)(\s|$)' \
        && ! printf '%s' "$command_line" | grep -q -- '-derivedDataPath'; then
        block "Blocked: xcodebuild without -derivedDataPath shares the default DerivedData with the user's app and other agents.

  ./scripts/reload.sh --tag <tag>                       # to build and run
  xcodebuild ... -derivedDataPath /tmp/cmux-<tag> ...   # to compile only

See CLAUDE.md 'Build and reload'."
    fi
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
