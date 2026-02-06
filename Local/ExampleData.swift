//
//  ExampleData_v2.swift
//  Listie.md
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

Listie is a powerful list app that works **your way** — keep lists private on your device, or share them as files for collaboration.

### 📱 Two Ways to Work

**Private Lists** (device-only):
- ✅ No files to manage
- ✅ Works completely offline
- ✅ Lightning fast
- ✅ Your data stays private
- ✅ Perfect for personal shopping

**Connected Lists** (shareable files):
- 📂 Saved as `.json` files anywhere you choose
- 🔗 Share via iCloud Drive, Dropbox, or any file service
- 👥 Real-time collaboration with automatic conflict resolution
- 🔄 Auto-syncs when you open, refresh, or return to the app
- 💾 Full backup control

### 🚀 Getting Started

Tap the **+** button in the sidebar:
1. **New Private List** — Quick personal list on this device
2. **New List As File...** — Create a shareable file
3. **Open File** — Import existing lists

Or use keyboard shortcuts:
- `⌘N` — New private list
- `⌘⇧N` — New connected list
- `⌘O` — Open file

### 📝 Managing Items

**Adding & Editing:**
- Tap **+** to add new items
- Tap item text to edit details
- Add **markdown notes** for recipes, brands, or reminders
- Set quantities (automatically tracks totals)

**Quick Actions:**
- ✓ Tap checkbox to mark complete
- ← Swipe left to **increase** quantity
- → Swipe right to **decrease** or delete
- Long-press for context menu

**Bulk Operations:**
- Mark all items as complete/active
- Import lists from markdown
- Export to markdown or JSON

### 🏷️ Organizing with Labels

**Create & Manage:**
1. Open **List Settings** (swipe or tap ⋯ menu)
2. Add labels like "Produce," "Dairy," "Bakery"
3. Pick colors (auto-adjust for visibility)
4. Show/hide labels per list

**Smart Grouping:**
- Items automatically group by label
- Tap section headers to collapse/expand
- Item counts shown per section
- Completed items can show inline or as separate label

**Favorite Lists:**
- Star lists to keep them at the top
- Quick access to your most-used lists

### 📥 Import & Export

**Import from Markdown:**
- Paste any markdown checklist
- Headings become labels
- Numbers become quantities
- Sub-items become notes
- Intelligently merges with existing items

**Export Options:**
- **Markdown** — Share as readable text (`⌘E`)
- **JSON** — Full backup with all data (`⌘⇧E`)
- Toggle completed items and notes in exports

### 🗑️ Recycle Bin

Deleted items aren't gone forever:
- Soft-deleted items move to Recycle Bin
- Auto-cleanup after 30 days
- Restore anytime before deletion
- See countdown to permanent removal

### 🔄 Collaboration Features

**Connected lists** sync automatically and merge changes intelligently:
- **Timestamp-based merging** — newest changes win
- **No data loss** — conflicting edits are preserved
- **Offline-first** — work without internet, sync later

**How merging works:**
- If you both edit different items → both changes kept
- If you both edit same item → newest timestamp wins
- New items and labels are always added

### ⚙️ All Features

**Display Options:**
- Custom list icons
- Color-coded labels
- Show completed inline or separately
- Collapsible sections (remembers per list)

**Smart Details:**
- Unchecked counts in sidebar
- Read-only mode for examples
- Automatic format migration
- Works fully offline

**Keyboard & Menus:**
- Full File menu support on Mac
- Export commands in menus
- Context menus everywhere
- Swipe gestures for speed

### 💡 Pro Tips

1. **Use favorites** for lists you check daily
2. **Hide labels** you don't need right now
3. **Collapse sections** to focus on what matters
4. **Add markdown notes** for details like "organic" or "store brand"
5. **Export to markdown** to share via Messages or email
6. **Connected lists** are perfect for household shopping

---

### 🔒 This is a Read-Only Example

This welcome list can't be edited — it's here to help you learn!

**Ready to start?** Tap the **+** button to create your first list.
""",
            modifiedAt: Date()
        ),
        ShoppingItem(
            id: UUID(),
            note: "📤 Exporting & Sharing Lists",
            quantity: 1,
            checked: false,
            labelId: nil,
            markdownNotes: """
## 📤 Exporting & Sharing

Listie gives you several ways to get your lists out of the app — whether you're sharing with someone, backing up, or building automations.

### Export Options

From any list, tap the **⋯** menu and choose **Export As...**:

| Format | What it does |
|---|---|
| **Markdown** | A readable text file (`.md`) you can copy, download, or paste anywhere. Great for Messages, email, or notes apps. |
| **Share Link** | A `listie://` URL that anyone with Listie can tap to import your items directly. |
| **Listie File** | A full JSON backup (`.listie`) with all data, labels, and metadata. |

### Share Links

Share Links are the fastest way to send a list to another Listie user.

**How it works:**
1. Go to **Export As... → Share Link**
2. Choose your options:
   - **Compress** — Reduces URL length (recommended)
   - **Comments** — Include item notes
   - **Active Only** — Only unchecked items
3. Copy or share the generated link
4. The recipient taps the link → Listie opens → items are imported

**Good to know:**
- Links under 2,000 characters work everywhere
- Links over 4,000 characters may not work in some messaging apps
- Compression typically cuts the link length in half
- If the recipient doesn't have the matching list, they can pick which list to import into

### Keyboard Shortcuts

- `⌘E` — Export as Markdown
- `⇧⌘L` — Share Link
- `⇧⌘E` — Export as Listie File

---

### 🔧 For Power Users & Shortcuts

Share Links use a URL scheme you can build manually or with Apple Shortcuts.

**URL format:**
```
listie://import?list=LIST_ID&markdown=ENCODED&enc=zlib&preview=true
```

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `list` | No | The target list ID. If omitted, the user picks a list. |
| `markdown` | Yes | The list content, encoded (see below). |
| `enc` | No | Encoding type: `zlib` (compressed) or `b64` (plain Base64). Defaults to `b64` if omitted. |
| `preview` | No | If `true`, shows the import preview automatically. |

**Encoding the `markdown` parameter:**

*Plain (no compression):*
1. Write your list as a markdown checklist
2. Convert to UTF-8 data
3. Base64 encode it
4. Set `enc=b64` (or omit `enc`)

*Compressed (smaller URLs):*
1. Write your list as a markdown checklist
2. Convert to UTF-8 data
3. Compress with zlib (deflate)
4. Base64URL encode the result (use `-` instead of `+`, `_` instead of `/`, strip `=` padding)
5. Set `enc=zlib`

**Markdown format the app expects:**
```
# List Name

## Label Name

- [ ] Item 1
- [ ] Item 2 x3
- [x] Completed Item
  - This is a note/comment on the item above
```

- Headings (`##`) become labels
- `- [ ]` is an unchecked item, `- [x]` is checked
- `x3` at the end sets quantity to 3
- Indented sub-items become markdown notes

**Apple Shortcuts tips:**
- Use the **Get Contents of URL** action to open `listie://` links
- Use **Base64 Encode** to encode your markdown
- Build the URL with **Combine Text**
- You can generate lists from Reminders, Notes, or any text source
""",
            modifiedAt: Date()
        )
    ]
}
