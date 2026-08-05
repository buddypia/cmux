---
name: cmux-testing
description: "cmux testing rules for Swift Testing, test target compilation, test wiring, and package/refactor validation. Use when adding or changing tests, touching package/refactor code, or deciding whether reload.sh is enough validation."
---

# cmux Testing

## Regression test commit policy

A regression test for a bug fix ships as two commits so the test is proven to catch the bug:

1. The failing test only, no fix. The suite fails.
2. The fix. The suite passes.

The GitHub PR Commits tab then shows the test genuinely fails without the fix.

**Run both yourself.** No CI runs on pull requests (`.github/workflows/ci.yml` is `workflow_dispatch` only), so nothing turns red on your behalf; put both results in the PR body. Confirm commit 1 fails on the assertion you expect — a test that fails to compile is not a red test.

## Test wiring

Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj` with a matching `PBXFileReference` and `PBXSourcesBuildPhase` entry. A `.swift` file added without them is silently ignored by Xcode: `xcodebuild test -only-testing:cmuxTests/<TestClass>` and bot reviews both pass with "Executed 0 tests", so the missing wiring is indistinguishable from a clean red/green regression test until a real user hits the bug. Surfaced during https://github.com/manaflow-ai/cmux/issues/4529 against https://github.com/manaflow-ai/cmux/pull/4536.

The `workflow-guard-tests` CI job runs `./scripts/lint-pbxproj-test-wiring.sh`. Add the file through Xcode (drag into the cmuxTests target) or hand-edit the pbxproj entries using a wired sibling such as `cmuxTests/TabManagerUnitTests.swift` as the template.

## Test quality policy

- No tests that only verify source text, method signatures, AST fragments, or grep-style patterns.
- No tests that read checked-in metadata or project files (`Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, source files) just to assert a key, string, plist entry, or snippet exists.
- Tests verify observable runtime behavior through executable paths (unit, integration, e2e, CLI), not implementation shape.
- For metadata changes, verify the built app bundle or the runtime behavior that depends on the metadata.
- If a behavior cannot be exercised end to end yet, add a small runtime seam or harness first, then test through it.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and say so.

## Test framework

Swift Testing (Swift 6 / Xcode 16) is the default for every unit and integration test: `import Testing`, `@Test`, `@Suite`, `#expect(...)`, `try #require(...)`. Do not write new `import XCTest` tests except UI tests.

- **UI tests stay on XCTest/XCUITest.** Swift Testing has no `XCUIApplication` integration. Files under `cmuxUITests/` keep `XCTestCase`; do not migrate or bridge them.
- **New test targets start on Swift Testing.** Every new package's `Tests/<Name>Tests/` ships with it from the first commit; Xcode 16 auto-detects the framework from `import Testing` with no `Package.swift` configuration.
- **Parameterized tests** use `@Test(arguments: [...])` instead of duplicate methods.
- **Parallelization.** Swift Testing runs tests in parallel by default, including across suites. A suite that needs ordering or guards shared mutable state gets `.serialized`, not locks or sleeps.
- **Tags** via `@Test(.tags(.something))` let CI and local runs filter selectively.
- Migrate an existing XCTest file in place only when an edit already crosses it. Mapping in [references/swift-testing-migration.md](references/swift-testing-migration.md).

## Test target validation

`reload.sh` builds only the `cmux` scheme, so a green reload says nothing about whether `cmuxTests`/`cmuxUITests` still compile. A moved or renamed symbol can keep the app building while breaking the test target (real case: a `write(to:atomically:)` typo and a removed `TabManager.CommandResult` surfaced only in the `tests` job). Build the `cmux-unit` scheme with `-derivedDataPath /tmp/cmux-<tag>` (plus the GlobalISel workaround flag for `cmuxApp`/`AppDelegate` churn) before pushing.

There is no CI fallback: the `tests` job only runs on `workflow_dispatch`. A target that stops compiling reports "0 tests executed", which reads like a pass — check the count.

## A green suite is not a fixed bug

A unit test proves the function you changed now returns what you decided it should. It cannot tell you that value reaches the runtime, so for any fix whose symptom the user can see, observe the symptom gone in a tagged build before calling it fixed.

Two failures in one session, both green at the time:

- A hook-disable flag was "cleared" by removing the key from the spawn environment dictionary. Every assertion passed. The spawned terminal still reported the old value, because that dictionary is *added* to an environment the child already inherits — a key that is merely absent keeps the inherited value. Only `env | grep` in a real terminal showed it (`e2b1a080a5`).
- Before that, a sidebar status fix was verified by suite alone and shipped. The symptom it was meant to fix reproduced on the first live check, because the real cause was one lane further upstream.

The check is usually one command — read the env, dump the state over the debug socket, watch the sidebar through a turn. Neutralizing an inherited variable is the specific case worth remembering: the correct value differs per key (`""` for a `-n` guard, `"0"` where the consumer reads `"${VAR:-1}" != "0"`), so read the consumer instead of copying the last fix.

## Detailed references

- [references/swift-testing-migration.md](references/swift-testing-migration.md): XCTest to Swift Testing conversion mapping.
- [references/regression-and-quality.md](references/regression-and-quality.md): deciding whether a test is behavioral enough.
- [references/local-vs-ci-validation.md](references/local-vs-ci-validation.md): choosing between `reload.sh`, `cmux-unit`, GitHub Actions, E2E/UI tests, and Python socket tests.
- [references/remote-tmux-sizing-e2e.md](references/remote-tmux-sizing-e2e.md): the remote-tmux mirror sizing UI suite, its ssh shim, the `remote.tmux.pane_grids` / `remote.tmux.test_exec` debug verbs, and the live layout fuzz harness.
