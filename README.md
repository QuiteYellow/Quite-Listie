# Quite Listie — iOS, iPadOS and macOS
A native Swift app for iOS, iPadOS and macOS (designed for iPad) for managing lists with support for private local storage, file-based collaboration, and Nextcloud sync.

<img width="1310" alt="Screenshot 2025-05-31 at 16 20 24" src="https://github.com/user-attachments/assets/c4ea3a65-4db1-4d05-903d-cd8a9708a0f7" />

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
![Welcome](https://github.com/user-attachments/assets/52fbc711-f990-40f9-9377-cc97331c037b)
![Item](https://github.com/user-attachments/assets/6ad8e269-5964-4e90-a5f2-aafeef0310b4)
![markdown](https://github.com/user-attachments/assets/e24852c8-3a01-47d3-a5ed-270f88de4993)

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

---

## Open Source Libraries
- [MarkdownView](https://github.com/LiYanan2004/MarkdownView) — Markdown rendering for SwiftUI (MIT)
- [SymbolPicker](https://github.com/xnth97/SymbolPicker) — SF Symbols picker for SwiftUI (MIT)
- [NextcloudKit](https://github.com/nextcloud/NextcloudKit) — Nextcloud API client for Swift (LGPL-3.0)

---

## License
GPL – see [LICENSE](LICENSE) file for details.
