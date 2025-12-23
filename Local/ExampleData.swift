//
//  ExampleData_v2.swift
//  ListsForMealie
//
//  Example data using V2 simplified format
//

import Foundation

enum ExampleData {
    static let welcomeListId = "example-welcome-list"
    
    static let welcomeList = ShoppingListSummary(
        id: welcomeListId,
        name: "👋 Welcome to Listie!",
        modifiedAt: Date(),
        icon: "lightbulb",
        hiddenLabels: nil
    )
    
    static let welcomeItems: [ShoppingItem] = [
        ShoppingItem(
            id: UUID(),
            note: "✨ Click here to get started...",
            quantity: 1,
            checked: false,
            labelId: nil,
            markdownNotes: """
## 👋 Welcome to Listie!

This app lets you manage your shopping lists — either privately on your device or as shareable files.

### 📱 Two Ways to Work

**Private Lists** (stored on device):
- ✅ No files to manage
- ✅ Works completely offline
- ✅ Fast and responsive
- ✅ Your data stays private

**Connected Lists** (shareable files):
- 📂 Stored as `.json` files
- 🔗 Share via Files, iCloud, or any file service
- 👥 Collaborate with others
- 🗑️ Includes recycle bin for deleted items

### 🚀 Getting Started

Tap the **+** button in the sidebar to:
1. **New List (Private)** — Quick personal list on this device
2. **New List As File...** — Create a shareable `.listie` file
3. **Open JSON File** — Import an existing list file

### 📝 Working with Lists

- Add items to any list
- Check them off as you shop
- Use **labels** to organize by category (Produce, Dairy, etc.)
- Add **markdown notes** to items for details
- Adjust quantities with swipe gestures

### 🏷️ Managing Labels

Open **List Settings** to:
- Create custom labels with colors
- Show/hide labels per list
- Organize items visually

### 📂 File Sharing Tips

**Connected Lists** automatically sync when:
- You open the list
- You pull to refresh
- The app returns to foreground

If multiple people edit the same file, Listie merges changes intelligently based on timestamps.

### ⚙️ Features

- Custom list icons
- Color-coded labels  
- Mark all items as complete/active
- Swipe to adjust quantities
- Export any list as JSON
- Offline-first design
- Clean V2 data format

---

### 🔒 Read-Only Example

This welcome list is **read-only** — it's just here to help you get started.

**Tap the + button** to create your first list!

Happy Listing! 🛍️
""",
            modifiedAt: Date()
        )
    ]
}
