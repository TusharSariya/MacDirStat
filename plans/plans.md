# MacDirStat — macOS Native Implementation Plan

A disk usage visualizer with a treemap view, sidebar file tree, and detail panel — all using native macOS APIs and SwiftUI.

---

## Architecture

**MVVM + Actor-based concurrency**

```
MacDirStatApp
├── Models/
│   ├── FileNode.swift          # Recursive tree node (file/dir + size)
│   └── ScanResult.swift        # Top-level scan output
├── Services/
│   └── DiskScanner.swift       # Async file system traversal
├── ViewModels/
│   └── ScanViewModel.swift     # Drives UI state
└── Views/
    ├── ContentView.swift        # Root NavigationSplitView
    ├── Sidebar/
    │   └── FileTreeView.swift   # Collapsible tree list
    ├── Treemap/
    │   └── TreemapView.swift    # Main visualization
    └── Detail/
        └── FileDetailView.swift # Info panel
```

---

## Key Technologies

| Need | macOS Native Tool |
|---|---|
| File scanning | `FileManager` + `URLResourceValues` (batch key fetching — fast) |
| Async scanning | Swift `async/await` + `Actor` to avoid data races |
| Treemap rendering | `SwiftUI Canvas` (GPU-accelerated, perfect for this) |
| File tree UI | `List` with `OutlineGroup` for recursive disclosure |
| Layout | `NavigationSplitView` (sidebar + content + detail) |
| Charts (pie/bar) | `Swift Charts` framework |
| File operations | `NSWorkspace` (reveal in Finder, move to trash) |
| Bookmarks/access | `NSOpenPanel` + security-scoped bookmarks (sandboxing) |
| App icon + polish | SF Symbols throughout |

---

## Phase 1 — File Scanning Engine

- `DiskScanner` as a Swift `Actor` — safe concurrent access
- Use `FileManager.enumerator` with `URLResourceValues` to batch-fetch size, kind, dates in one syscall (much faster than stat per file)
- Build a `FileNode` tree: each node stores `url`, `size`, `children`, `isDirectory`
- Report progress via `AsyncStream` so the UI updates live during scanning
- Handle permission errors gracefully (skip + log inaccessible dirs)

## Phase 2 — Treemap Visualization

- Implement **Squarified Treemap** algorithm (best aspect ratios)
- Render with `SwiftUI Canvas` — draw colored `CGRect` per node, no views
- Color by file type (using `UTType` for proper type detection)
- Hover to highlight + show tooltip (`onHover`, `NSCursor`)
- Click to zoom into subdirectory; breadcrumb bar to navigate back
- Performance: only recompute layout on resize/rescan, cache rects

## Phase 3 — Sidebar File Tree

- `List` + `OutlineGroup` with lazy loading of children
- Show file icon via `NSWorkspace.icon(forFile:)`
- Sort by size descending by default
- Selection syncs bidirectionally with treemap

## Phase 4 — Detail Panel + Actions

- Shows: size on disk, item count, date modified, kind (`UTType.localizedDescription`)
- Buttons: **Reveal in Finder** (`NSWorkspace.open`), **Move to Trash** (`FileManager.trashItem`)
- Top files/folders list (biggest items sorted)

## Phase 5 — Polish

- `Swift Charts` bar chart showing top 10 largest items
- Toolbar with rescan, sort options, filter by type
- Progress indicator during scan with cancel support
- Remember last scanned folder via `UserDefaults` + security-scoped bookmarks
- Menu bar commands (File > Open Folder, View > Zoom Out)
- Dark mode — use semantic colors, not hardcoded
- Smooth animations on zoom/selection with `withAnimation`

---

## Data Flow

```
NSOpenPanel → URL
    → DiskScanner (Actor, async)
        → AsyncStream<Progress>
            → ScanViewModel (@MainActor, @Observable)
                → FileTreeView (sidebar)
                → TreemapView (Canvas)
                → FileDetailView (panel)
```

---

## What Makes It Feel Native

- `NavigationSplitView` gives the standard 3-column Mac layout
- SF Symbols for all icons
- Context menus on right-click (Reveal in Finder, Get Info, Trash)
- Keyboard shortcuts: `Space` for Quick Look, `Cmd+R` to rescan, `Esc` to zoom out
- Quick Look integration via `QLPreviewPanel` for file previews
- Drag files out of the app into Finder

---

## Milestones

1. Scanner engine + basic file tree list (no visualization yet)
2. Treemap renders correctly and is interactive
3. Bidirectional selection sync (tree ↔ treemap)
4. File actions (trash, reveal)
5. Charts + polish + keyboard shortcuts
