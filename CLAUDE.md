# cmux agent notes

## Setup

`./scripts/setup.sh` initializes submodules, builds GhosttyKit, and installs the pbxproj normalization pre-commit hook.

## Build and reload

Always build with a tag. **Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`**: untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <branch-slug>            # build Debug, kill same-tag app, do not launch
./scripts/reload.sh --tag <branch-slug> --launch   # also open it
```

A tag gives the app its own name, bundle ID, socket, and derived data path, so it runs side-by-side with the user's main app. Report the build to the user as a markdown link to `http://127.0.0.1:17320/<tag>`. Never put a `file://` URL, a raw `.app` path, or `/tmp/cmux-<tag>/...` in chat output.

Other variants: `reloadp.sh` (Release), `reloads.sh` (Release as isolated "cmux STAGING"), `reload2.sh --tag <tag>` (both).

Compile-only check, no launch. Use `cmux-unit`, not `cmux`: the `cmux` scheme (and `reload.sh`) does not build `cmuxTests`, so it stays green while the test target is broken — and a test target that does not compile runs **zero** tests, in every suite, silently.

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build-for-testing
```

If that fails in the Ghostty CLI helper with `cannot execute tool 'metal' due to missing Metal Toolchain`, either install the component once (`xcodebuild -downloadComponent MetalToolchain`) or prefix the command with `CMUX_SKIP_ZIG_BUILD=1`, which `scripts/build-ghostty-cli-helper.sh` supports. The skip substitutes a stub for the bundled `bin/ghostty` CLI; terminal rendering comes from GhosttyKit and is unaffected, so it is fine for tests and dogfood but not for shipping a build.

## When xcodebuild hangs with no output

If a build sits forever at `ExecuteExternalTool ... clang -v -E -dM -x c -c /dev/null`, the machine is out of kernel pipe buffer, not stuck on this project. macOS carves pipe buffers from a fixed pool; once it is exhausted every new pipe gets 2 KB or less instead of 16-64 KB. xcodebuild's compiler probe writes ~20 KB into a pipe SWBBuildService does not drain while clang writes, so clang blocks in `write()` with no timeout and no error. It reproduces on an empty one-file package, so a hang here is never evidence about your branch.

`reload.sh` checks for this before building and aborts in about a second. Run `scripts/diagnose-pipe-pressure.sh` to see the capacity and the biggest holders — long-lived agents, shells, and node processes accumulate pipes over days. Quit the top offenders or reboot. `CMUX_SKIP_PIPE_CAPACITY_CHECK=1` forces a build anyway, which will hang.

Never trust a `==> reload succeeded` line on its own: confirm it also printed `App path:`. A successful reload always does.

Rebuild GhosttyKit.xcframework with Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

Clean up older tags you started this session (quit the app, remove its `/tmp` socket and derived data) before launching a new one.

## Tag-bound debug CLI

For CLI or socket dogfood against a tagged Debug app, set `CMUX_TAG` and use the helper. Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from DerivedData. It scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the tag.

## iOS builds open on the iPhone by default

Any work verified by opening the iOS app installs BOTH an isolated-simulator build AND the same build on the user's iPhone. Never stop at simulator-only. Use `ios/scripts/reload-cloud.sh --tag <tag>` (or `ios/scripts/reload.sh --tag <tag>`); with a default iPhone configured (`CMUX_IPHONE_DEVICE_ID` or `~/.config/cmux/iphone-device-id`) the device leg is automatic, and `--device-id <id>` still overrides (`xcrun devicectl list devices`). Auto sign-in and auto-pair apply as usual; launch the app so it is immediately open on the phone. The simulator leg uses the tag's own isolated device `cmux-dev-<slug>`, created on demand; do not target a shared or user-visible simulator.

Every phone build requires the same-tag Mac dev build (the iOS app is unusable without its Mac). The reload scripts build the Mac tag first when it is missing and refuse to ship a phone-only build if that fails; do not bypass this with `CMUX_IOS_SKIP_MAC_BUILD_CHECK` in normal work.

If the iPhone is unreachable at build time, the reload still completes: the signed build is parked in the offline install queue (`scripts/iphone-install-queue.sh`, persistent under `~/Library/Application Support/cmux-dev/iphone-install-queue`), and a LaunchAgent auto-installs and launches it within seconds of the phone being plugged back in or reappearing on the network, then sends a `cmux notify` with the installed tags. The LaunchAgent is a one-time per-Mac setup: `scripts/install-iphone-queue-agent.sh install`; it runs a stable copy of the queue script, so re-run the installer after changing that script. In the handoff, report the queued state (`scripts/iphone-install-queue.sh list`) instead of treating an unreachable phone as a failure; `drain` retries manually, `clear` abandons a queued build.

## iOS dev auth

`ios/scripts/reload.sh` and `scripts/mobile-dev-launch.sh` auto-sign-in from `~/.secrets/cmuxterm-dev.env`. If the phone lands on the login screen or the helper reports missing credentials, do not ask the user to authenticate every build. Tell them to run `scripts/setup-team-dev.sh` once; it verifies their Stack login and writes the file chmod 600. Manual fallback: create it with `CMUX_DOGFOOD_STACK_EMAIL=...` and `CMUX_DOGFOOD_STACK_PASSWORD=...`.

## Regression test commits

Two commits, so the test is proven to catch the bug: commit 1 adds the failing test only, commit 2 adds the fix. This is visible in the PR Commits tab.

**No CI runs on pull requests here.** `.github/workflows/ci.yml` is `workflow_dispatch` only, and `gh pr checks <n>` reports `no checks reported`. Nothing turns red for you, so you are the gate, in two steps. First, the `cmux-unit` build above must succeed — that is the only *total* check available, since 8.8k tests across 653 files cannot be run locally in one pass. Then run the suites covering your change (`-only-testing:cmuxTests/<Suite>`) at commit 1 and again after commit 2, and put both results in the PR body. A test that fails to *compile* is not a red test — it proves nothing about the bug. Verify against a real repro before believing a suite that passes.

## First pass, then dogfood

A first pass ends when the change is implemented, the tagged build succeeded on the pushed HEAD, focused tests ran, and the PR is open (for `web/` PRs, also the live Vercel preview URL). Then hand off to the user. Do not sit in the main conversation watching CI or running speculative review passes after that point.

Do not launch a background review agent (`$autoreview`, `codex review`, `claude review`, or a judge loop) by default. Second-model review is explicit user opt-in in the current conversation; an implementation request, open PR, CI failure, closeout, or handoff is not that opt-in. Let the automatic review bots run asynchronously, then return to address only their actionable findings before merge. Do not wait on GitHub checks — none run on pull requests (see Regression test commits).

The main agent owns dogfood, approval, mergeability, and every pushed fix. Merging app/runtime/UI changes requires the user's explicit approval after dogfood; if a fix changes runtime behavior mid-dogfood, rebuild the tag and re-notify, since the earlier verdict covers only the build the user tested.

Notify through `cmux notify` so the user can leave and return. Handoff: `--title "Dogfood ready: <short task>" --subtitle "<branch> · <tag>" --body "Was: <prior bad behavior>. Now: <expected behavior>. <concrete check>. PR: <pr-url>"`. Later closeout notifications use `"CI green: <branch>"` or `"CI blocked: <branch>"` with a one-line cause and the next decision. Titles carry outcome and branch, bodies carry the single next action. Skip notify if there is no cmux socket.

## Pitfalls

Each of these has full detail in the skill or command named in parentheses.

- **Typing-latency-sensitive paths** (`cmux-debugging`): `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`, `TabItemView` in `ContentView.swift`, and `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift` run on every keystroke. Read the skill before touching them.
- **SwiftUI list boundaries** (`cmux-debugging`): no view below a `LazyVStack`/`LazyHStack`/`List`/`ForEach` boundary may hold an observable store reference, and no function called from `body` may write state. Violating either reintroduces the 100% CPU spin loop from https://github.com/manaflow-ai/cmux/issues/2586. Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **Do not add an app-level display link or manual `ghostty_surface_draw` loop.** Rely on Ghostty wakeups and its renderer, or typing lags.
- **Terminal find layering** (`cmux-debugging`): `SurfaceSearchOverlay` mounts from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), never from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- **Upstream tag merges** (`/merge-upstream`): `git merge <upstream tag>` succeeds textually and still leaves the tree non-compiling, because upstream files call APIs this fork changed. Merge on a branch and compile `cmux-unit` before it reaches `main`.
- **Submodule safety** (`cmux-ghostty`): push the submodule commit to its remote `main` before committing the pointer in the parent repo. Never commit on a detached HEAD. Verify with `git merge-base --is-ancestor HEAD origin/main`.
- **Localize every user-facing string** (`cmux-localization`): `String(localized:)` with keys in `Resources/Localizable.xcstrings`, plus every web message catalog (`web/messages/en.json`, `web/messages/ja.json`). A localization audit is required for any UI, Settings, menu, schema, docs, or help-text change, and the handoff must state what was audited.
- **Shortcut policy** (`cmux-keyboard-shortcuts`): every new cmux-owned shortcut goes in `KeyboardShortcutSettings`, is editable in Settings, is supported in `~/.config/cmux/cmux.json`, and is documented.
- **Test wiring** (`cmux-testing`): a `.swift` file in `cmuxTests/` without a `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently skipped, and both `xcodebuild test` and bot reviews pass with "Executed 0 tests". `workflow-guard-tests` runs `./scripts/lint-pbxproj-test-wiring.sh` to catch it.
- **SPM package groups** (`cmux-architecture`): packages live under `Packages/{Shared,iOS,macOS}/<pkg>` and the workspace mirrors that folder shape. To move one, `git mv` the directory then `python3 scripts/check-workspace-package-groups.py --write`. Never hand-edit workspace group membership.
- **Do not gitignore cmux-owned `Package.resolved`.** SwiftPM resolution changes must show in PR diffs; package-local lockfiles are not replaced by the root one. `python3 scripts/check-package-resolved-policy.py` fails on drift.
- **"Feature flag" means a remote PostHog runtime flag.** Implement through `CmuxFeatureFlags` with a PostHog key, explicit unavailable fallback, registry metadata, live update behavior, and focused tests. A local override may support dogfood but must not be the production control plane.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change between macOS major versions.** `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 (https://github.com/manaflow-ai/cmux/issues/4529); CI and maintainer machines were all on the fixed side while every reporter was on the broken side. Test on the reporter's macOS before declaring a repro disproven. AWS M4 Pro builders (`aws-m4pro-1..6`) run macOS 15.7.4.

## Shared behavior policy

When a behavior is exposed through multiple entrypoints (shortcut, command palette, context menu, CLI, settings, debug menu), implement one shared action path and verify every entrypoint. Do not patch one surface and leave the others with duplicated logic.

For optimistic UI or CLI updates, keep one mutation path, record pending state with a request id or previous snapshot, reconcile from the authoritative result, and roll back explicitly on failure. Do not let each entrypoint keep its own optimistic copy.

When a user says tests missed a bug, add behavior-level coverage around the exact repro path before claiming the fix is complete.

## Skills

Detailed contributor rules live in `skills/`. Use the task-specific skill before changing that area.

- `cmux-dev-workflow`: setup, tagged reloads, Xcode project normalization, sidebar extension tagging, build isolation.
- `cmux-architecture`: package boundaries, file/API discipline, testability, Swift concurrency.
- `cmux-backend`: backend TypeScript, Effect, Cloud VM control plane, provider secrets, Postgres and migrations.
- `cmux-billing`: Stripe checkout, entitlements, webhooks, pricing dev stack, live provisioning.
- `cmux-debugging`: debug event log, Debug menu, runtime pitfalls, typing-sensitive paths, SwiftUI list boundaries.
- `cmux-localization`: user-facing strings, localization files, shortcut text, localization audit.
- `cmux-testing`: regression policy, Swift Testing, test quality, test wiring, local vs CI validation.
- `cmux-socket-policy`: socket command threading and focus preservation.
- `cmux-shared-behavior`: shared action paths for multi-entrypoint behavior and optimistic updates.
- `cmux-ghostty`: Ghostty submodule and GhosttyKit workflow.
- `cmux-release`: release, version bump, changelog, pretag guard, release assets.
