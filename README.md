# Listie — iOS, iPadOS and macOS
A native Swift app for iOS, iPadOS and macOS (designed for iPad) for managing lists with support for both private local storage and collaborative file-based lists.

<img width="1310" alt="Screenshot 2025-05-31 at 16 20 24" src="https://github.com/user-attachments/assets/c4ea3a65-4db1-4d05-903d-cd8a9708a0f7" />

## Features

### Two Ways to Work
- **Private Lists** — Local device storage, completely offline, lightning fast
- **Connected Lists** — Shareable `.listie` files with real-time collaboration and automatic conflict resolution (JSON files)

### List Management
- Modern two-pane navigation with sidebar
- Favorite lists for quick access
- Custom list icons with symbol picker
- Group lists by type (Private, Connected, Favorites, Read-Only)
- Smart unchecked item counts

### Items & Organization
- Add, edit, delete items with quantity tracking
- Color-coded labels with automatic contrast adjustment for readability
- Rich markdown notes on any item
- Collapsible sections (remembers state per list)
- Bulk operations (mark all complete/active)
- Swipe gestures for quick actions
- Right-click context menus on macOS

### Import & Export
- **Markdown import** — Paste any markdown checklist, intelligently merges with existing items
- **Markdown export** — Share lists as readable text
- **Listie file export** — Full backup with all data
- Deeplink support for sharing lists via URLs

### Collaboration & Sync
- File-based collaboration via iCloud Drive, Dropbox, or any file service
- Automatic conflict resolution using timestamps
- Three-way merge for simultaneous edits
- Offline-first design with background sync
- Read-only mode for shared reference lists

### Smart Features
- Recycle bin with 30-day auto-delete
- Quantity tracking with increment/decrement
- Show completed items inline or as separate section
- Welcome list with interactive tutorial
- Keyboard shortcuts and menu commands on macOS
- File type association (double-click `.listie` files to open)

---

## Screenshots
![Welcome](https://github.com/user-attachments/assets/52fbc711-f990-40f9-9377-cc97331c037b)
![Item](https://github.com/user-attachments/assets/6ad8e269-5964-4e90-a5f2-aafeef0310b4)
![markdown](https://github.com/user-attachments/assets/e24852c8-3a01-47d3-a5ed-270f88de4993)

---

## Technical Details
- Built with SwiftUI
- Actor-based file coordination for thread safety
- Automatic migration from legacy formats
- Security-scoped bookmark storage for external files
- NSFileCoordinator for reliable iCloud sync

---

## Requirements
- iOS 18+ / iPadOS 18+ / macOS 15+

---

## License
GPL – see [LICENSE](LICENSE) file for details.
