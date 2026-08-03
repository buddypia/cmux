# Merge Upstream

Merge a tag from upstream `manaflow-ai/cmux` into this fork.

This is the fork's highest-risk recurring operation, and until now the only one with no written procedure. `Merge tag 'v0.64.21'` (`8b022c43ba`) changed 5,301 files, went straight onto `main` with no PR, and left the tree non-compiling — git merged the text, but upstream files call APIs the fork had changed. It took three separate repair commits over the following days, each found by whoever tripped over it; two agents wrote the same `cmuxTests` repair in parallel because neither knew the merge was broken.

**A clean `git merge` is not a working merge.** Nothing else here catches the difference: no CI runs on pull requests, and `reload.sh` builds the `cmux` scheme, which never compiles `cmuxTests`.

## Steps

1. **Branch first.** `git fetch upstream --tags`, then `git checkout -b merge/upstream-<tag> main`. Never merge onto `main` directly; the merge has to be repairable before anyone else builds on it.

2. **Merge.** `git merge <tag>`, resolving textual conflicts.

3. **Compile everything.** This is the gate:

   ```bash
   xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build-for-testing
   ```

   `cmux-unit`, not `cmux`: only that scheme compiles `cmuxTests`, and a test target that does not compile runs zero tests in every suite, silently.

4. **Repair on this branch.** Every type error is the fork and upstream disagreeing about an API. Both directions occur, so decide per case and say which you chose:
   - upstream call sites stranded by a fork change → update them to the fork's shape (`b09b4b8b83`);
   - an API the fork dropped that upstream still calls → restore it (`a8cb41df5f`).

   A repair deferred to a follow-up PR is a repair the next person finds by tripping over it.

5. **Run the suites covering what you repaired** with `-only-testing:cmuxTests/<Suite>`. Compiling proves the types agree and nothing about behavior.

6. **Open a PR** naming the tag, the file count, each repair with its direction, and the build plus suite results.

## Notes

- Merging the newest tag still leaves the fork behind upstream's `main`; check `git rev-list HEAD..upstream/main --count` so the report says how far.
- When a conflicting hunk looks unfamiliar, `git log --oneline -- <path>` on this fork usually names the PR that introduced the divergence and why it exists.
