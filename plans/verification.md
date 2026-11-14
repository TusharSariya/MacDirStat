# Verification record

Status: implementation is usable for ordinary scans; the administrator helper's real system authorization/lifecycle test is awaiting user approval. Do not mark the overall goal complete until that test has been resolved.

## Automated evidence

- `swift test`: 19 regular tests pass; the optional existing-tree performance probe is skipped unless a path is supplied.
- Scanner fixtures cover nested/empty/hidden folders, package contents, parent totals, sparse allocation, symlink cycles and external targets, link metadata sizes, preservation of siblings after links, hard-link per-path semantics, named pipes, missing/inaccessible roots, partial failures, cancellation and sorting.
- Layout tests check area conservation, size proportions, non-overlap, empty frames and bounded rendering for a synthetic 100,000-node directory, and prioritization of large folders within the tile budget.
- File-action tests use only disposable fixtures: native Trash/restore, symlink target preservation, refusal of the root, refusal of replaced files and symlink-replaced ancestors.
- `scripts/test-integration.sh`: the production main-actor view model passes superseded-scan, cancellation, prior-result retention, failed-root/rescan-target, navigation and root-protection checks. Helper serialization preserves totals, identities and ordering. Empty and forged authorization forms are rejected without returning metadata.
- `scripts/test-integration.sh <Apple signing identity>`: actual signed anonymous XPC exchange succeeds; wrong client and server identifiers are rejected. This needs no system daemon or administrator permission.

## Native app observations

The ad-hoc signed sandbox build's entitlements were inspected: App Sandbox and user-selected read/write access are enabled.

Using the native folder picker, a disposable fixture was scanned with videos, an image, text, a hidden file, a link and an empty directory. Observed:

- Size-sorted outline, color-coded treemap and correct category totals.
- Clicking a treemap tile selects its file in the outline and expands its ancestors.
- Double-clicking a tile zooms into its enclosing directory.
- Selecting an item outside the zoomed subtree changes the view appropriately.
- File details update correctly; empty folders show an empty-state message.
- Finder reveal opens the fixture folder and selects the intended item.
- Name/Size column controls, Open Folder (Command-O), Rescan (Command-R) and folder navigation (Command-Up/Down) work.
- An early Applications scan displayed live progress, but its count and timing were invalidated by the subsequently discovered symlink-pruning bug. They are not retained as performance evidence.
- The corrected signed direct app accepted Xcode.app through the picker and displayed 167,225 descendants (167,226 entries including the root), 10.35 GB logical size, and 4.80 seconds scan time. This agrees with the independent count/size baseline.
- UI cancellation was attempted, but that scan finished before the click could be applied. Cancellation is proved by scanner and production-view-model integration tests, not by that UI attempt.

## Performance evidence

A corrected release-core scan of `/Applications/Xcode.app` found 167,226 entries and 10,348,945,117 logical bytes in 2.47 seconds, with approximately 211 MB peak test-process RSS. `scripts/verify-real-scan.py` independently derives the expected count and bytes with Python `os.walk` and `lstat`, then asserts both against the production scanner. Both match exactly.

Earlier measurements of 57,160 Xcode nodes and 197,861 Applications items were incomplete. A regression test exposed `skipDescendants()` called on a symbolic link pruning a later directory's contents. The scanner now relies on Foundation's built-in no-follow behavior and only explicitly prunes confirmed directories. The regression fixture checks 100 directories with files and nested folders on both sides of links.

Names and sort indexes are cached off the main thread, sorting drains autorelease pools, and cancellation is checked periodically during comparisons. Tree expansion and sort switches use cached arrays. Memory remains O(number of entries).

## Privileged feature evidence and remaining gate

- The direct build and helper are Apple Development signed with matching teams and pass strict codesign verification.
- The launchd plist validates and is embedded at the expected bundle path.
- The helper exposes start-scan and poll only, with no shell, read-file-content or mutation interface. Its executable refuses non-root manual startup.
- The app requires explicit registration and OS authorization. It never registers on launch. Signed XPC peer checks are enforced on both ends.
- The real access panel has been inspected with registration available and removal disabled for the unregistered service.
- `launchctl` confirmed that no system service was registered during preparation.
- Still required: user-approved registration, native OS approval/authentication, elevated result verification, cancellation/disconnection behavior with the running daemon, and unregistration afterward.

## Limits that remain documented

Per-path totals are not unique physical storage or guaranteed reclaimable space. Hard links, APFS clones, snapshots, directory metadata, mounted filesystems and privacy restrictions can affect interpretation. Scans are not atomic filesystem snapshots. Blocking network/provider metadata calls cannot be interrupted until the OS returns. The complete tree stays in memory; the renderer groups small items. The build is for local use, not a notarized release.

Native Trash's production implementation is tested with real disposable files. Its full UI-to-Trash-to-restore workflow under App Sandbox has not been exercised; that is a remaining permission-specific validation gap.
