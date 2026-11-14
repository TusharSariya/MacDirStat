# MacDirStat

A native macOS disk-usage explorer inspired by WinDirStat. SwiftUI supplies the window and controls, AppKit supplies the virtualized file outline and system dialogs, and Canvas draws a squarified treemap.

## Install on your Mac

Requires macOS 14 or later. If you already have a built `MacDirStat.app`, copy it into **Applications** and open it from there. For the signed direct build, the app is in `.build/direct-derived/Build/Products/Release/` inside this repository. In Finder, press **⌘⇧G** to enter that folder's full path.

Install the app in its final location before enabling the optional administrator scanner. When updating an installation with the scanner enabled, disable the scanner in **Scan Access**, quit the app, replace it, then reopen and enable the scanner again.

To scan privacy-protected locations, add the installed app under **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. Administrator scanning is a separate, optional permission; see below.

This repository currently provides source code rather than a notarized installer. The development-signed build has been tested locally; it is not a public distribution release.

## Build and run from source

Requires macOS 14 or later and an Xcode toolchain supporting Swift 6.

```sh
xcodebuild -project MacDirStat.xcodeproj -scheme MacDirStat \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/MacDirStat-build CODE_SIGNING_ALLOWED=NO build
open /tmp/MacDirStat-build/Build/Products/Debug/MacDirStat.app
```

You can also open `MacDirStat.xcodeproj` in Xcode and run the MacDirStat scheme. Signed builds request sandbox access to user-selected files with read/write permission for Trash operations. The unsigned command above is for local development, not distribution or sandbox validation.

Choose **Open Folder** (⌘O), select a folder, application bundle or volume, and click **Scan Folder**. Nothing is scanned automatically. **Rescan** (⌘R) refreshes the selected scan. Cancel stops at the next filesystem-operation boundary and retains the previous completed result.

Click an outline row or treemap tile to select it. Double-click a folder in the outline to zoom; double-click a file tile to zoom into its parent. Use breadcrumbs or ⌘↑ to return to enclosing folders. The Size/Name menu and clickable column headers control the outline order. The Navigate menu includes Finder reveal (⇧⌘R), folder zoom (⌘↓), and confirmed Trash (⌘Delete). File size / Size on disk controls the displayed sizes and treemap areas.

## Implemented

Right-click (or Control-click) any file or folder in the tree for **Refresh Size**, **Reveal in Finder**, and **Move to Trash…**. Trashing a folder includes its contents and asks for confirmation; the scan root is protected. Refresh Size rescans the original scan root so all parent totals and the treemap stay consistent, retaining the selected item and zoom when they still exist. Refresh and Trash are disabled while a scan or file operation is running.

- Background metadata-only traversal, throttled progress and cancellation.
- Hidden files and package contents included; symbolic links never followed.
- Cached directory totals and precomputed sort orders, sparse-file allocation reporting, and bounded scan-issue reporting.
- Native outline, linked selection, folder navigation, file details and type totals.
- Native Canvas treemap with a modern file-type palette, subtle gradient depth, named folder boundaries and a distinct disk-image category. Detail budgets are reserved across sibling folders so a single branch cannot consume the whole map. Grouped contents show their actual type composition and byte totals; double-click to explore. Selection outlines a folder once, and selecting the root adds no repeated borders. The existing three-pane window arrangement is preserved.
- Finder reveal and confirmed native Move to Trash off the main thread. The scan root cannot be trashed. Identity checks refuse entries or ancestors replaced since scanning. Successful moves trigger a rescan.

## Filesystem semantics and limitations

- **File size** sums logical file sizes per pathname. **Size on disk** sums the allocation macOS reports per pathname, excluding directory metadata. These are not estimates of guaranteed reclaimable space. Hard links are counted per pathname, APFS clones can share blocks, and snapshots/purgeable storage are not attributed to files by this scanner.
- Scans are observations, not filesystem snapshots. Files may change while being scanned. Rescan after making changes.
- No file contents are opened by the scanner. Cloud-provider metadata requests and network filesystems can still be slow; a blocked OS call cannot be cancelled until it returns.
- Inaccessible descendants are skipped and reported. Totals are partial when issues exist. An inaccessible root fails explicitly. Only the first 500 detailed errors are retained.
- macOS privacy controls and Unix ownership permissions are separate. Full Disk Access must be granted by the user in System Settings when needed. Root privileges do not bypass all macOS privacy protections.
- Optional administrator-assisted scanning is implemented in the signed direct build described below. Its real system authorization and privileged filesystem flow still need end-to-end verification. The GUI runs as the current user; it never invokes sudo or elevates file deletion.
- The current tree is retained in memory. Local release profiling scanned 167,226 Xcode bundle entries in 2.47 seconds with approximately 211 MB peak test-process memory; this is a warm local measurement, not a guarantee for other disks. The treemap is limited to 6,000 tiles and 64 nested layout levels, grouping smaller items when necessary.
- File-type categories currently use filename extensions. They are a visual guide, not content inspection.
- `MockData.swift` preserves the original prototype fixture and is no longer used by the application.

## Tests

```sh
swift test
scripts/test-integration.sh
```

Tests exercise the same core source files compiled into the application. Coverage includes nested and empty folders, hidden files, package contents, directory aggregation, symlink cycles and external targets, missing and inaccessible roots, partial access errors, sparse files, hard links, link sizes, named pipes, cancellation, sorting, treemap area/proportions/non-overlap, a synthetic 100,000-node layout, stale-item refusal, and native Trash/restore using disposable fixtures. The integration harness exercises the production main-actor view model for superseded scans, cancellation, failure retention, rescan targeting and navigation.

The scan engine and layout have no UI dependency. The app publishes immutable scan results on the main actor. The scanner performs a linear aggregation pass after traversal rather than recursively summing directory sizes during drawing.

## Remaining validation and work

- End-to-end verification of administrator helper registration, approval, elevated scanning, cancellation and unregistration.
- Real authorization and helper lifecycle validation. Signed XPC transport, mutual peer-identity rejection, snapshot serialization and invalid-authorization rejection have passed. An ad-hoc signed sandbox build has also been exercised through the native folder picker, scan, sort, navigation and rescan flows.
- Sandboxed UI-to-Trash-to-restore validation. Treemap selection/zoom, empty folders and Finder reveal have been exercised; cancellation is covered by scanner and production-view-model tests.
- Further profiling on larger and network trees, plus UI refinement.

### Read-only performance probe

```sh
MACDIRSTAT_BENCHMARK_PATH=/path/to/existing/folder swift test -c release \
  --filter DiskScannerTests/testReadOnlyPerformanceProbe
```

This optional test scans metadata without modifying that folder. Normal test runs skip it. Reported peak RSS includes the test runner and retained snapshot. Unit Trash tests create their own temporary files, move only those fixtures to Trash, and restore them before cleanup.

Native Trash validates scanned device/inode identities immediately before the move; this reduces stale-path mistakes but is not an atomic defense against a malicious process racing filesystem renames.

## Optional administrator scanner

The default Xcode build remains sandboxed. A separate direct-distribution build includes an unsandboxed, read-only helper, because current macOS does not allow a sandboxed app to register an unsandboxed daemon.

```sh
scripts/build-direct.sh "Apple Development: your signing identity"
open .build/direct-derived/Build/Products/Release/MacDirStat.app
```

Use an Apple Development identity for local testing or Developer ID for distribution. The script signs both executables with the same team and verifies them. It does **not** register or launch the helper. This local build is not notarized or packaged for distribution.

1. Scan a folder normally, then open **Scan Access** in the toolbar.
2. Choose **Enable Administrator Scanner…**. macOS may require approval in **System Settings → General → Login Items & Extensions**; use **Approval Settings…** to open it.
3. Choose **Scan “[folder]” as Administrator…** and complete the OS authorization prompt. Results are labeled **Administrator scan**. Full Disk Access is separate and may still be necessary.
4. Use **Disable Scanner** to unregister the helper when it is no longer needed. The helper otherwise remains registered with macOS; do not delete or move the app while it is registered.

The helper exposes only metadata scanning and status polling. There is no shell execution, file-content reading, or mutation in its protocol. Both XPC peers enforce Apple signing-team and executable-identifier requirements. The helper verifies an OS-issued administrator authorization for each requested scan and cancels work when the connection closes. Progress retains only its latest update. Results are sent as a binary property-list snapshot; very large results temporarily require additional memory for encoding/decoding.

OS authorization may reuse credentials according to macOS policy. If cancellation occurs while an authentication prompt is open, dismiss that prompt as well; the app ignores the cancelled result. Native file operations still run under the ordinary user account, including when viewing elevated results.

To run signed XPC integration checks without registering a daemon or requesting administrator access:

```sh
scripts/test-integration.sh "Apple Development: your signing identity"
```

See [the verification record](plans/verification.md) for observed workflows, performance measurements and the remaining elevated-access gate.

For a correctness comparison against an independent Python `os.walk`/`lstat` traversal on a readable, stable tree:

```sh
scripts/verify-real-scan.py /Applications/Xcode.app
```

The current Xcode baseline matches exactly at 167,226 entries and 10,348,945,117 logical bytes. Earlier measurements of 57,160 Xcode nodes or 197,861 Applications items were incomplete due to a now-fixed `skipDescendants()`/symlink bug and must not be used as correctness or performance results.
