# Quite Listie — iOS, iPadOS and macOS

[![TestFlight Beta](https://img.shields.io/badge/TestFlight-Join%20Beta-blue?style=for-the-badge&logo=apple)](https://testflight.apple.com/join/XCUw3f3Y)

A native Swift app for iOS, iPadOS and macOS (designed for iPad) for managing lists with support for private local storage, file-based collaboration, and Nextcloud sync.

> Also available on Linux: **[Quite Listie for GNOME](https://github.com/QuiteYellow/Quite-Listie-Linux)** (GTK4 + libadwaita). Both apps share the `.listie` file format and Nextcloud sync, so lists move between them.

<img width="1394" height="594" alt="Screenshot 2026-03-13 at 16 45 07" src="https://github.com/user-attachments/assets/ff491cdb-ada5-4b6c-8e10-dae242c8f29f" />
<img width="1394" height="594" alt="Screenshot 2026-03-13 at 16 44 53" src="https://github.com/user-attachments/assets/a8a493e6-11a4-4133-9aad-eea1e9440135" />

## Features

### Three Ways to Store Lists
- **Private Lists** — Local device storage synced via iCloud, completely offline-first
- **File-Based Lists** — Shareable `.listie` files on iCloud Drive or local files (Dropbox, or any file provider on macOS)
- **Nextcloud** — Native Nextcloud integration with Login Flow v2 (supports 2FA and SSO), offline-first with background sync and automatic conflict resolution

### List Management
- Modern two-pane navigation with sidebar
- Favourite lists for quick access
- Custom list icons with SF Symbols picker
- Folders grouped alphabetically across all storage sources
- Smart unchecked item counts

### Items & Organisation
- Add, edit, delete items with quantity tracking
- Color-coded labels with automatic contrast adjustment for readability
- Rich markdown notes on any item
- Collapsible sections (remembers state per list)
- Bulk operations (mark all complete/active)
- Swipe gestures for quick actions
- Right-click context menus on macOS

### Views
- **List view** — standard checklist
- **Map view** — per-list map showing items pinned to locations, with label filtering and long-press to add items
- **Kanban board** — drag items between label columns
- **Markdown preview** — rendered markdown view of the list

### Import & Export
- **Markdown import** — paste any markdown checklist, intelligently merges with existing items
- **Markdown export** — share lists as readable text
- **Quite Listie file export** — full backup with all data
- Deeplink support for sharing lists via URLs

### Collaboration & Sync
- File-based collaboration via iCloud Drive, Dropbox, or any file service
- Nextcloud sync with ETag-based change detection and three-way merge
- Offline-first: writes to local cache immediately, uploads in background
- Automatic conflict resolution using item timestamps
- Read-only mode for shared reference lists

### Reminders
- Set due-date reminders on individual items
- "Today" and "Scheduled" smart boxes in the sidebar
- Complete items directly from a notification
- Background refresh to keep reminder counts current

### Locations & Maps
- Pin a location to any item by pasting a Google Maps or Apple Maps link, or using the location picker
- **Per-list map view** — see all pinned items for the current list on an interactive map; markers inherit the item's label colour and symbol
- **Global Locations view** — a single map aggregating every pinned item across all lists; tap a pin to jump straight to that item
- Filter map pins by label or toggle visibility of completed items
- Long-press on the map to drop a new item at that coordinate
- Open any pinned location in Apple Maps, Google Maps, or TomTom GO

### CarPlay
Drive-friendly access to items in your lists that have a pinned location, under Apple's Driving Task entitlement (`com.apple.developer.carplay-driving-task`).

- **Map tab** — your pinned places (up to 12) shown as POIs on a system-rendered map, in the order you set on the phone
- **List tab** — drill-down by label: tap a label to see its items, distance-sorted from your current location, then tap an item to choose a navigation app
- **Pin management on the phone** — Settings → CarPlay Pins lets you choose, reorder, and remove pinned places and pinned labels with drag-to-reorder and swipe-to-delete; changes propagate to a live in-car session within a frame
- **Navigation handoff** to Apple Maps, Google Maps, or TomTom GO via a modal action sheet; set a default app in Settings to skip the picker on every tap
- Respects Apple's CarPlay driver-distraction rules: list refresh rate-limited to 10s, POI updates to 60s (when pins are unchanged), and per-section row caps so the most relevant items are always reachable

> CarPlay text-input search is reserved for Apple's Navigation category, so the in-car UI is read-only — curate the pin set on the phone first and the driver picks from it.

### Smart Features
- Recycle bin with 30-day auto-delete
- Quantity tracking with increment/decrement
- Show completed items inline or as a separate section
- Welcome list with interactive tutorial
- Keyboard shortcuts and menu commands on macOS
- File type association (double-click `.listie` files to open)
- Multi-window support

---

## Screenshots


---

## Technical Details
- Built with SwiftUI
- Actor-based concurrency for thread-safe file I/O
- Nextcloud Login Flow v2 — browser-based sign-in, no app passwords required
- ETag-based sync with three-way merge for conflict resolution
- Security-scoped bookmark storage for external files
- NSFileCoordinator for reliable iCloud sync
- Automatic migration from legacy formats

---

## Requirements
- iOS 18+ / iPadOS 18+ / macOS 15+
- CarPlay support requires iOS 26+ (head unit, in-dash factory, or aftermarket CarPlay receiver)

---

## Open Source Libraries
- [MarkdownView](https://github.com/LiYanan2004/MarkdownView) — Markdown rendering for SwiftUI (MIT)
- [SymbolPicker](https://github.com/xnth97/SymbolPicker) — SF Symbols picker for SwiftUI (MIT)
- [NextcloudKit](https://github.com/nextcloud/NextcloudKit) — Nextcloud API client for Swift (LGPL-3.0)

---

## License
GPL – see [LICENSE](LICENSE) file for details.
