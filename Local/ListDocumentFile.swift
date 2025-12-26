//
//  ListDocumentFile.swift (V2)
//  ListsForMealie
//
//  Updated to use V2 format with automatic migration support
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var shoppingList: UTType {
        UTType(exportedAs: "com.listie.shopping-list", conformingTo: .json)
    }
}

struct ListDocumentFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    
    var document: ListDocument
    
    // MARK: - Default Initializer (V2 Format)
    init(document: ListDocument = ListDocument(
        list: ModelHelpers.createNewList(
            name: "New List",
            icon: "checklist"
        ),
        items: [],
        labels: []
    )) {
        self.document = document
    }
    
    // MARK: - Read from File (with Automatic Migration)
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        // Use migration utility to load and migrate if necessary
        document = try ListDocumentMigration.loadDocument(from: data)
        
        print("📄 [FileDocument] Loaded document: \(document.list.name) (V\(document.version))")
    }
    
    // MARK: - Write to File (Always V2 Format)
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Use migration utility to ensure V2 format
        let data = try ListDocumentMigration.saveDocument(document)
        
        print("💾 [FileDocument] Saving document: \(document.list.name) (V2)")
        
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Convenience Extensions

extension ListDocumentFile {
    /// Creates a file document from a list summary with items and labels
    static func from(
        list: ShoppingListSummary,
        items: [ShoppingItem],
        labels: [ShoppingLabel]
    ) -> ListDocumentFile {
        let document = ListDocument(
            list: list,
            items: items,
            labels: labels
        )
        return ListDocumentFile(document: document)
    }
    
    /// Creates an empty file document with a given name
    static func empty(name: String, icon: String = "checklist") -> ListDocumentFile {
        let list = ModelHelpers.createNewList(name: name, icon: icon)
        let document = ListDocument(list: list, items: [], labels: [])
        return ListDocumentFile(document: document)
    }
}
