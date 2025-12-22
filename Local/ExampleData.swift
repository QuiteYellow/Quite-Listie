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

This app lets you quickly manage your shopping lists on your device — fast, simple, and always offline.

### 📝 Local Shopping Lists

All your lists are stored **locally on your device**:

- ✅ No account needed
- ✅ Works completely offline
- ✅ Fast and responsive
- ✅ Your data stays private

### 🚀 Getting Started

1. Tap the **+** button to create your first list
2. Add items to your list
3. Check them off as you shop
4. Use **labels** to organize items by category
5. Add **markdown notes** to items for extra details

### 🏷️ Labels

Access the **Label Manager** from the menu to:
- Create custom labels (Produce, Dairy, etc.)
- Assign colors to labels
- Organize your shopping items

### 📋 Features

- Markdown notes on items
- Quantities
- Custom list icons
- Color-coded labels
- Offline-first design
- **New**: Simplified data format (V2)
- **New**: Cleaner JSON exports

---

### 🔒 Read-Only Example

This welcome list is **read-only** and just here to help you get started.

**Tap the + button** to create your first real shopping list!

Happy shopping! 🛍️
""",
            modifiedAt: Date()
        )
    ]
}
