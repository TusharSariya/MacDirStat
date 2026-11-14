# Treemap redesign

Status: first implementation completed. Current window arrangement preserved.

Implemented: sibling-reserved detail budgets, disjoint aggregate composition, named
folder overlays, modern palette and disk-image type, subtle Canvas gradients,
folder/file selection outlines, hover composition, and background cancellable layout.
Verified with core tests, native UI fixture and signed arm64 build. The native UI
check caught overlapping header labels, which were corrected by reserving label space.

Future refinements in the design below (not implemented): optional extension/flat
modes, legend hover filtering, spatial hit index, treemap context menus, and cached
per-folder type summaries. Current hover searches at most the bounded 6,000 tiles;
aggregate composition is recomputed off the main actor from disjoint subtrees when
layout changes. The file-tree context menu remains available.

## Purpose

Make disk usage readable from the whole disk down to individual files. Preserve
WinDirStat's area-based overview and file-type colors, with clear folder context,
restrained shading, native navigation, and responsive interaction on large scans.

## Current failures

- Depth-first refinement spends the global 6,000-tile budget on early branches.
  Large later branches become undifferentiated directory tiles.
- Directory and remainder tiles inherit the directory's Other classification.
  Most of the screen becomes gray even when its contents have known types.
- Aggregation labels show counts without identifying the containing directory.
  The same field currently describes either immediate omitted children or all
  descendants, so the displayed counts do not have consistent semantics.
- Selecting the scan root strokes every descendant tile. White outlines overwhelm
  the type colors and make the resting state look selected everywhere.

## Window and navigation

Preserve the current horizontal arrangement: file outline on the left, treemap in
 the center, details and legend on the right. Keep existing breadcrumbs and toolbar.
 Selection does not change map scope; double-click and breadcrumbs zoom.

## Visual language

- Area encodes the selected size metric, consistently throughout the window.
- Hue encodes file type, never folder depth. Stable category hues: video violet,
  audio pink, images green, documents amber, source cyan, archives orange, disk
  images indigo. Unknown files use subdued blue-gray, not a dominant neutral fill.
- Add disk-image recognition, including img, dmg, iso, qcow2, vhd/vhdx, vmdk.
  An extensionless file remains unknown unless reliably classified from metadata.
- Start with category colors; an optional extension mode can subdivide category
  hues. The legend always matches the active mode and current zoom scope.
- Folder hierarchy uses subtle nested boundary strokes and named header overlays
  where space permits. Show only a few useful ancestor levels at once.
- Use a low-contrast cushion-style gradient for file tiles, with a flat appearance
  option. Keep exact tiling geometry; avoid rounded tile corners and thick gaps.
- Labels show folder/file name and size when there is room, one or two truncated
  lines. Tiny tiles have no labels. Hover reveals full path, type, size and percent.
- Hover outlines one item. File selection outlines one tile; directory selection
  outlines its enclosing rectangle once. Root selection has no repeated tile stroke.
- Color is supplemented by names, type descriptions, borders and the native outline.

## Detail allocation and honest grouping

First partition the visible root into its children. Refine directory rectangles
using a best-first queue based on visible screen area, rather than exhausting one
branch in a depth-first walk. Stop refinement at a useful pixel threshold and a
global rendering budget; bound both output geometry and refinement work.

If a large folder cannot be fully refined, preserve its name and exact byte total.
Fill its rectangle with a small mosaic of its file-type byte totals rather than
painting it gray. Mark it as a folder summary. These colored regions are aggregates,
not individual files, and must never expose a file deletion action.

Small omitted siblings form an explicitly labeled remainder such as
“Other files in Library · 4.2 GB”. Distinguish direct child counts from recursive
file counts in the model and tooltip. Remainder actions select/zoom their containing
folder; a summary cannot silently claim to represent a particular file.

Click selects and links to the outline. Double-click a folder or its summary to
refine that scope. Right-click actual files/folders offers Reveal, Refresh and Trash
with the existing guards. Right-click aggregates offers Open Containing Folder.
Hovering a legend type highlights matching tiles without relayout. Filtering, if
added later, must explicitly report excluded bytes and avoid silently changing areas.

## Implementation design

Keep scanning separate from display refinement. A pure layout module takes a
snapshot, root, size metric and viewport/detail settings; it returns a scene with
file tiles, folder bounds and explicit aggregate records. Each aggregate carries
its represented bytes, containing folder, count semantics and type composition.
Renderer and hit-testing consume the same scene and node identities.

Calculate type aggregates off the main actor once per snapshot, with compact storage
and measured memory overhead. Cache geometry by snapshot/root/metric/viewport.
Selection and hover must not re-run layout. Keep Canvas initially; consider Metal
only if profiling identifies drawing as the limiting factor. A spatial index should
bound pointer hit-testing costs rather than scanning every rectangle on each event.

## Delivery sequence and checks

1. Correct budget distribution, directory summaries, meaningful labels, and root
   selection outlines. Verify that every visible root branch receives representation.
2. Add stable colors, disk-image category, folder bounds, restrained shading and
   type legend highlighting. Inspect representative mixed-content and whole-disk scans.
3. Restructure the window and finish zoom, tooltip and context-menu behavior.

Tests must verify area conservation, no overlaps, aggregate byte/type sums, truthful
counts, valid hit targets, and bounded output/work. Include a tree whose largest
branch contains many tiny files alongside large sibling folders: detail in the first
branch must not erase context for the rest. Measure layout, memory and pointer latency
on million-entry synthetic snapshots and real scans. Aim for cached hover/selection
within a 16 ms frame and viewport layout under 100 ms on the development Mac, but
report measurements rather than treating those targets as established performance.

Acceptance: a whole-disk view immediately identifies its largest folders, shows the
types consuming their space, and provides a clear route to an individual file without
large anonymous gray blocks or a screen full of selection borders.
