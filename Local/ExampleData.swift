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
        name: "Welcome to Listie",
        modifiedAt: Date(),
        icon: "book",
        hiddenLabels: nil,
        labelOrder: [
            "welcome-getting-started",
            "welcome-items",
            "welcome-labels",
            "welcome-views",
            "welcome-reminders",
            "welcome-import-export",
            "welcome-collaboration",
            "welcome-shortcuts"
        ]
    )

    // MARK: - Labels (categories for help topics)

    private static let labelGettingStarted = ShoppingLabel(id: "welcome-getting-started", name: "Start Here", color: "#34C759")
    private static let labelItems = ShoppingLabel(id: "welcome-items", name: "Items & Editing", color: "#FF9500")
    private static let labelLabels = ShoppingLabel(id: "welcome-labels", name: "Labels & Organisation", color: "#AF52DE")
    private static let labelViews = ShoppingLabel(id: "welcome-views", name: "Views & Layout", color: "#5AC8FA")
    private static let labelReminders = ShoppingLabel(id: "welcome-reminders", name: "Reminders", color: "#FF3B30")
    private static let labelImportExport = ShoppingLabel(id: "welcome-import-export", name: "Import & Export", color: "#007AFF")
    private static let labelCollaboration = ShoppingLabel(id: "welcome-collaboration", name: "Collaboration", color: "#FF2D55")
    private static let labelShortcuts = ShoppingLabel(id: "welcome-shortcuts", name: "Keyboard Shortcuts", color: "#8E8E93")

    static let welcomeLabels: [ShoppingLabel] = [
        labelGettingStarted,
        labelItems,
        labelLabels,
        labelReminders,
        labelViews,
        labelImportExport,
        labelCollaboration,
        labelShortcuts
    ]

    // MARK: - Items

    static let welcomeItems: [ShoppingItem] = [

        // ── Getting Started ──────────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "About Listie",
            quantity: 1,
            checked: false,
            labelId: labelGettingStarted.id,
            markdownNotes: """
## Welcome to Listie!

Listie is a powerful list app that works **your way** — keep lists private on your device, or share them as files for real-time collaboration.

### Two Ways to Work

**Private Lists** — stored on your device (with optional iCloud sync):
- No files to manage
- Works completely offline
- Your data stays on your device

**Connected Lists** — saved as `.listie` files you can put anywhere:
- Share via iCloud Drive, Dropbox, or any cloud service
- Multiple people can edit the same list
- Changes merge automatically with conflict resolution

### Your First List

Tap the **+** button in the sidebar to get started:
1. **New Private List...** — a quick personal list
2. **New List File...** — a shareable file you choose where to save
3. **Open File** — open an existing `.listie` or `.json` file

> Tip: You can hide this welcome list at any time by swiping it in the sidebar, or toggling it off in Settings.
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Private vs Connected Lists",
            quantity: 1,
            checked: false,
            labelId: labelGettingStarted.id,
            markdownNotes: """
## Private vs Connected Lists

### Private Lists
- Stored locally on this device
- Optionally synced via **iCloud** to your other Apple devices
- Toggle iCloud sync in **Settings**
- Fastest option — no file access needed

### Connected Lists
- Saved as a `.listie` file to a location you choose (iCloud Drive, Dropbox, a shared folder, etc.)
- Anyone with access to that file can open it in Listie
- The app syncs changes whenever you open, refresh, or return to the list
- Grouped by folder in the sidebar for easy navigation

### Which Should I Use?

| Use Case | Recommended |
|---|---|
| Personal shopping list | Private |
| Shared household groceries | Connected (via iCloud Drive) |
| Team project tasks | Connected (via shared folder) |
| Quick temporary list | Private |
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Settings & Preferences",
            quantity: 1,
            checked: false,
            labelId: labelGettingStarted.id,
            markdownNotes: """
## Settings & Preferences

Open **Settings** from the sidebar (gear icon) or press `⌘,` to customise the app.

### Available Settings

- **Show Welcome List** — toggle this help list on or off
- **Quick Add Items** — show an inline "Add Item" field below each label section
- **Show Empty Labels** — display label sections even when they have no items
- **Kanban Column Width** — choose Narrow, Normal, or Wide columns for Kanban view
- **iCloud Sync** — enable or disable iCloud synchronisation for private lists

### Per-List Settings

Each list also has its own settings (tap the gear icon in the list toolbar):
- Change the **list name** and **icon**
- Manage **labels** (create, edit, delete, change colours)
- **Hide labels** you don't need without deleting them
- Choose to show **completed items** inline or at the bottom
""",
            modifiedAt: Date()
        ),

        // ── Items & Editing ──────────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "Adding & Editing Items",
            quantity: 1,
            checked: false,
            labelId: labelItems.id,
            markdownNotes: """
## Adding & Editing Items

### Adding Items
- Tap the **+** button in the toolbar to add a new item
- Or use the **Quick Add** inline field (enable in Settings if hidden)
- Set a name, quantity, label, and optional markdown notes

### Editing Items
- **Tap on item text** to open the full detail editor
- Change the name, quantity, label, notes, and reminder
- On wide screens the editor shows a split view with the form on the left and markdown preview on the right

### Quantities
- Each item has a quantity (default is 1)
- Quantities above 1 are shown as a badge next to the item name
- Use the stepper in the editor, or swipe gestures for quick adjustments
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Gestures & Quick Actions",
            quantity: 1,
            checked: false,
            labelId: labelItems.id,
            markdownNotes: """
## Swipe Gestures & Quick Actions

### Swipe Actions
- **Swipe left** on an item → **Increase** quantity
- **Swipe right** on an item → **Decrease** quantity (or delete if quantity is 1)

### Tap Actions
- **Tap the checkbox** → mark item as complete or incomplete
- **Tap the item text** → open the detail editor

### Context Menu
Long-press (or right-click on Mac) an item for more options:
- Edit Item...
- Increase Quantity
- Decrease Quantity
- Delete Item
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Markdown Notes",
            quantity: 1,
            checked: false,
            labelId: labelItems.id,
            markdownNotes: """
## Markdown Notes

Every item can have rich **markdown notes** attached to it. Use them for recipes, brand names, links, sublists, or any extra detail.

### Supported Markdown

- **Bold**, *italic*, ~~strikethrough~~
- [Links](https://example.com)
- `Inline code` and code blocks
- Headings (`#`, `##`, `###`)
- Bullet lists and numbered lists
- Block quotes
- Images (`![alt](url)`)
- Tables

### Editing Notes
- In the item detail view, tap **Edit Notes** to open the full-screen markdown editor
- On wide screens you get a live side-by-side preview
- On narrow screens you can toggle between the **Edit** and **Preview** tabs
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Recycle Bin",
            quantity: 1,
            checked: false,
            labelId: labelItems.id,
            markdownNotes: """
## Recycle Bin

Deleted items aren't gone forever — they go to the **Recycle Bin**.

### How It Works
- When you delete an item, it moves to the Recycle Bin
- Items stay there for **30 days** before being permanently removed
- A countdown shows how many days are left for each deleted item
- Items with less than 7 days remaining are highlighted in orange; less than 1 day in red

### Actions
- **Restore** — bring an item back to its original list and label
- **Delete Forever** — permanently remove an item immediately
- **Restore All** — restore every item in the bin at once
- **Empty Bin** — permanently delete everything

Open the Recycle Bin from the list toolbar menu.
""",
            modifiedAt: Date()
        ),

        // ── Labels & Organisation ────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "Creating & Managing Labels",
            quantity: 1,
            checked: false,
            labelId: labelLabels.id,
            markdownNotes: """
## Creating & Managing Labels

Labels let you organise items into categories — like "Produce", "Dairy", or "Household".

### Creating a Label
1. Open **List Settings** (gear icon in the list toolbar)
2. Scroll to the **Labels** section
3. Tap **Add Label**
4. Enter a name and pick a colour (or tap the dice for a random colour)

### Editing & Deleting
- Tap a label in List Settings to change its name or colour
- Swipe to delete a label
- Colours auto-adjust for readability on your background

### Common Presets
When creating labels for a grocery list, Listie suggests common categories:
Produce, Dairy, Meat, Bakery, Frozen, Pantry, Snacks, Beverages, Household, Personal Care
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Organising Items with Labels",
            quantity: 1,
            checked: false,
            labelId: labelLabels.id,
            markdownNotes: """
## Organising Items with Labels

### Automatic Grouping
- Items are automatically grouped by their label into collapsible sections
- Each section header shows the label name and a count of items
- Unlabelled items appear under a **No Label** section

### Section Controls
- **Tap a section header** to collapse or expand it
- Collapsed/expanded state is remembered per list
- Completed items can optionally be shown in a separate section at the bottom (toggle in List Settings)

### Hiding Labels
- You can **hide** labels per list without deleting them
- Hidden labels won't appear as sections, and their items won't be shown
- Useful for temporarily focusing on certain categories
- Manage hidden labels in **List Settings**

### Favourites
- **Star a list** in the sidebar to pin it to the Favourites section at the top
- Quick access to the lists you use most often
""",
            modifiedAt: Date()
        ),

        // ── Reminders ────────────────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "Creating Reminders",
            quantity: 1,
            checked: false,
            labelId: labelReminders.id,
            markdownNotes: """
## Setting Reminders

You can set a reminder on any item to get a notification at a specific date and time.

### Adding a Reminder
1. Open an item's detail view (tap the item text)
2. Toggle **Reminder** on
3. Pick a date and time
4. Optionally set a **repeat rule**

### Repeat Options
- **Daily** — every day at the same time
- **Weekly** — same day each week
- **Bi-weekly** — every two weeks
- **Monthly** — same day each month
- **Yearly** — same day each year
- **Weekdays** — Monday through Friday only
- **Custom** — e.g. every 3 days, every 2 months

### Repeat Modes
- **Fixed Schedule** — repeats on the same day/time regardless of when you complete it
- **After Completion** — the next reminder is scheduled relative to when you mark the item done
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Smart Boxes & Notifications",
            quantity: 1,
            checked: false,
            labelId: labelReminders.id,
            markdownNotes: """
## Reminder Views & Notifications

### Smart Boxes
Two smart boxes appear at the top of the sidebar when you have reminders:
- **Today** — shows overdue items and items due today (orange)
- **Scheduled** — shows all items with upcoming reminders (blue)

Tap either one to see a dedicated list of reminders, grouped by date.

### Searching Reminders
In the reminder views you can search across:
- Item text
- List name
- Label name

### Notifications
- Listie sends a **push notification** at the scheduled time
- Notifications appear even when the app is open
- Tap a notification to jump straight to the item's list
- Use the **Complete** action on the notification to mark the item done without opening the app
""",
            modifiedAt: Date()
        ),

        // ── Views & Layout ───────────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "Default List View",
            quantity: 1,
            checked: false,
            labelId: labelViews.id,
            markdownNotes: """
## List View

The default view shows items in a vertical list, grouped by label.

### What You See
- **Item name** with strikethrough when checked
- **Quantity badge** (only shown when quantity is greater than 1)
- **Reminder chip** showing the due date
- **Checkbox** to mark complete/incomplete

### Section Headers
- Each label becomes a collapsible section
- Headers show the label name and item count
- Tap to expand or collapse

### Completed Items
- By default, completed items appear inline within their label section
- In **List Settings**, you can choose to move all completed items to a separate section at the bottom

### Search
- Use the search field to filter items by name or markdown notes content
- Results update live as you type
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Kanban Board View",
            quantity: 1,
            checked: false,
            labelId: labelViews.id,
            markdownNotes: """
## Kanban Board View

Switch to Kanban view for a card-based, column layout — perfect for project tasks or visual workflows.

### How It Works
- Each **label** becomes a **column**
- Items are displayed as cards within their column
- Scroll horizontally to navigate between columns
- A **Completed** column can optionally collect all checked items

### Column Width
Adjust column width in **Settings**:
- **Narrow** (300pt) — fits more columns on screen
- **Normal** (400pt) — balanced default
- **Wide** (500pt) — more room for content

On iPhone, columns are always narrow regardless of this setting.

### Quick Add
If **Quick Add Items** is enabled in Settings, each column gets an inline add button at the bottom for fast item entry.

### Switching Views
Toggle between List and Kanban view using the view mode button in the list toolbar. Each list remembers its own view preference.
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Sidebar & Navigation",
            quantity: 1,
            checked: false,
            labelId: labelViews.id,
            markdownNotes: """
## Sidebar & Navigation

### Sidebar Sections
The sidebar is organised into sections (top to bottom):
1. **Reminder Smart Boxes** — Today and Scheduled (only shown when you have reminders)
2. **Getting Started** — this welcome list
3. **Favourites** — lists you've starred
4. **Private** — your iCloud/local lists
5. **Connected** — external files, grouped by folder

### List Actions
- **Tap** a list to open it
- **Swipe right** to delete a list
- **Star/unstar** with the context menu or swipe action
- **Unchecked count** is shown next to each list name

### Folder Grouping
Connected lists from the same folder are grouped together in the sidebar, with the folder name as the section header.
""",
            modifiedAt: Date()
        ),

        // ── Import & Export ──────────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "Importing from Markdown",
            quantity: 1,
            checked: false,
            labelId: labelImportExport.id,
            markdownNotes: """
## Importing from Markdown

Paste any markdown checklist and Listie will parse it into items.

### How to Import
1. Open a list
2. Tap the **menu** (toolbar) → **Import from Markdown**
3. Paste your markdown text
4. Preview the parsed items
5. Select which items to import

### Markdown Format
```
## Label Name

- [ ] Unchecked item
- [x] Checked item
- [ ] Item with quantity x3
  - This indented line becomes a markdown note
```

### Parsing Rules
- `# Heading` — treated as the list title (skipped)
- `## Heading` — becomes a **label**
- `- [ ] Text` — unchecked item
- `- [x] Text` — checked item
- `Text x3` — sets quantity to 3
- Indented sub-items → become **markdown notes** on the parent item

### Smart Merging
The importer can intelligently merge with existing items in your list, so you won't get duplicates.
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Exporting Lists",
            quantity: 1,
            checked: false,
            labelId: labelImportExport.id,
            markdownNotes: """
## Exporting Lists

From any list, tap the **menu** → **Export As...** to choose a format.

### Export Formats

| Format | Description |
|---|---|
| **Markdown** | A readable `.md` file. Great for pasting into messages, email, or notes apps. |
| **Share Link** | A `quitelistie://` URL that another Quite Listie user can tap to import your items. |
| **Listie File** | A full `.listie` JSON backup with all data, labels, reminders, and metadata. |

### Markdown Export Options
- **Include completed items** — toggle whether checked items appear in the export
- **Include notes** — toggle whether markdown notes are included
- **Active only** — export only unchecked items
- Preview the rendered markdown or view the raw text before exporting
- Copy to clipboard or save as a file

### Share Links
- Generate a `quitelistie://import` URL
- Enable **compression** to reduce URL length (recommended)
- Links under 2,000 characters work everywhere
- Links over 4,000 characters may be truncated by some messaging apps
- The recipient taps the link → Quite Listie opens → items are imported
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "URL Scheme & Shortcuts",
            quantity: 1,
            checked: false,
            labelId: labelImportExport.id,
            markdownNotes: """
## Deep Links & Apple Shortcuts

### URL Scheme
Quite Listie supports the `quitelistie://` URL scheme for automation and sharing.

**URL format:**
```
quitelistie://import?list=LIST_ID&markdown=ENCODED&enc=zlib&preview=true
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `list` | No | Target list ID. If omitted, the user picks a list. |
| `markdown` | Yes | Encoded list content (see below). |
| `enc` | No | `zlib` (compressed) or `b64` (plain Base64). Defaults to `b64`. |
| `preview` | No | If `true`, shows the import preview. |

### Encoding

**Plain (no compression):**
1. Write your list as markdown
2. Convert to UTF-8 → Base64 encode
3. Set `enc=b64` or omit `enc`

**Compressed (shorter URLs):**
1. Write your list as markdown
2. UTF-8 → zlib deflate → Base64URL encode
3. Use `-` instead of `+`, `_` instead of `/`, strip `=` padding
4. Set `enc=zlib`

### Apple Shortcuts Integration
- Use **Get Contents of URL** to open `quitelistie://` links
- Use **Base64 Encode** for the markdown parameter
- Build the URL with **Combine Text**
- Generate lists from Reminders, Notes, or any text source
""",
            modifiedAt: Date()
        ),

        // ── Collaboration ────────────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "Sharing & Real-Time Collaboration",
            quantity: 1,
            checked: false,
            labelId: labelCollaboration.id,
            markdownNotes: """
## Sharing & Real-Time Collaboration

Connected lists enable multiple people to work on the same list simultaneously.

### Setting Up a Shared List
1. Create a **New List File** (`⌘⇧N`)
2. Save the file to a **shared location** (e.g. a shared iCloud Drive folder, Dropbox, Google Drive)
3. Have collaborators open the same file in their copy of Listie (`⌘O`)

### How Syncing Works
- Changes sync when you **open** the list, **refresh**, or **return to the app**
- The app detects when the file has been modified externally
- Works fully **offline** — changes sync the next time the file is accessible

### Conflict Resolution
When two people edit the list at the same time:
- **Different items edited** → both changes are kept
- **Same item edited** → the newest timestamp wins
- **New items or labels** → always added, never lost
- No data is ever silently discarded
""",
            modifiedAt: Date()
        ),

        ShoppingItem(
            id: UUID(),
            note: "Working with External Files",
            quantity: 1,
            checked: false,
            labelId: labelCollaboration.id,
            markdownNotes: """
## External File Management

### Opening Files
- Use **Open File** (`⌘O`) or the **+** menu in the sidebar
- Listie remembers file permissions via bookmarks so you don't need to re-open each time
- Files are grouped by their containing folder in the sidebar

### File Status
If a file becomes unavailable, Listie shows the reason:
- File not found
- File moved to trash
- Bookmark expired
- iCloud file not downloaded yet

The list entry stays in the sidebar so you can try again later.

### File Format
Connected lists use the `.listie` JSON format (Version 2):
- Clean, flat structure
- All items, labels, reminders, and metadata in one file
- Backward-compatible with older formats (auto-migrates on open)
""",
            modifiedAt: Date()
        ),

        // ── Keyboard Shortcuts ───────────────────────────────────

        ShoppingItem(
            id: UUID(),
            note: "All Keyboard Shortcuts",
            quantity: 1,
            checked: false,
            labelId: labelShortcuts.id,
            markdownNotes: """
## Keyboard Shortcuts

Listie supports keyboard shortcuts on Mac and iPad with a hardware keyboard.

### General
| Shortcut | Action |
|---|---|
| `⌘,` | Open Settings |
| `⌘N` | New Private List |
| `⌘⇧N` | New Connected List (As File) |
| `⌘O` | Open File |

### Exporting
| Shortcut | Action |
|---|---|
| `⌘E` | Export as Markdown |
| `⌘⇧E` | Export as Listie File (JSON) |
| `⌘⇧L` | Generate Share Link |

### Navigation
| Shortcut | Action |
|---|---|
| `Escape` | Close current modal or sheet |
""",
            modifiedAt: Date()
        ),
    ]
}
