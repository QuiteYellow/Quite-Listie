//
//  ExampleData.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 07/06/2025.
//


import Foundation

enum ExampleData {
    static let welcomeListId = "example-welcome-list"

    static let welcomeList = ShoppingListSummary(
        id: welcomeListId,
        name: "👋 Welcome to Lists for Mealie!",
        localTokenId: TokenInfo.localDeviceToken.id,
        groupId: "local-group",
        userId: nil,
        householdId: nil,
        extras: ["listsForMealieListIcon": "lightbulb"]
    )

    static let welcomeItems: [ShoppingItem] = [
        ShoppingItem(
            id: UUID(),
            note: "✨ Click here to get started...",
            checked: false,
            shoppingListId: welcomeListId,
            label: nil,
            quantity: nil,
            groupId: nil,
            householdId: nil,
            localTokenId: TokenInfo.localDeviceToken.id,
            extras: ["markdownNotes": "## 👋 Welcome to Lists for Mealie!\n\nThis app lets you quickly manage your shopping lists — whether you're offline or connected.\n\n### 📝 Use Locally, Anywhere  \nYou can create and manage **local shopping lists** right on your device, no account or internet needed. It's perfect for:\n\n- Quick personal checklists  \n- Offline use on the go  \n- Keeping things simple\n\n### 🌐 Designed for Mealie  \nFor full functionality, this app pairs beautifully with a **[Mealie](https://mealie.io)** server. When connected, you'll unlock:\n\n- 🧑‍🤝‍🧑 Shared lists across users  \n- 🏠 Household and group syncing  \n- 🏷️ Labeling, organization, and color-coded tags  \n- 🛒 Seamless syncing with Mealie meal plans\n\n### 🔒 Read-Only Example List\nThis example list and its items are **read-only** and just here to help you get started.\n\nTo begin using the app:\n\n- ➕ Create a **new local list** from the main screen, or\n- 🔐 Connect a **Mealie server** in Settings to unlock full features.\n\n---\n\n> ✨ You can start with local lists, and connect a Mealie server any time from settings.\n\nHappy list-making! 🛍️"]
        )
    ]
}
