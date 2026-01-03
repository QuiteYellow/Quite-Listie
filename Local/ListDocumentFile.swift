//
//  ListDocumentFile.swift (V2)
//  Listie.md
//
//  Updated to use V2 format with automatic migration support
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var listie: UTType {
        UTType(exportedAs: "com.listie.list")  // Must match Info.plist UTTypeIdentifier
    }
}

struct ListDocumentFile: FileDocument {
    static var readableContentTypes: [UTType] { [.listie, .json] }
    
    var document: ListDocument
    
    init(document: ListDocument = ListDocument(
        list: ModelHelpers.createNewList(name: "New List", icon: "checklist"),
        items: [],
        labels: []
    )) {
        self.document = document
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        document = try decoder.decode(ListDocument.self, from: data)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(document)
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
