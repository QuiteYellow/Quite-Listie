//
//  MarkdownExportView.swift
//  Listie-md
//
//  Created by Jack Nagy on 25/12/2025.
//


//
//  MarkdownExportView.swift
//  Listie-md
//
//  View for exporting shopping lists as markdown
//

import SwiftUI
import MarkdownUI
import Textual
import UniformTypeIdentifiers

struct MarkdownExportView: View {
    let listName: String
    let items: [ShoppingItem]
    let labels: [ShoppingLabel]
    let activeOnly: Bool
    
    @Environment(\.dismiss) var dismiss
    @State private var showCopiedConfirmation = false
    @State private var showFileExporter = false
    @State private var showRawMarkdown = false  // Toggle between raw and preview
    @State private var includeNotes = false  // Toggle for including item notes
    @State private var showActiveOnly = true  // Toggle for active items only
    
    // Generate markdown from items and labels
    private var markdownText: String {
        MarkdownListGenerator.generate(
            listName: listName,
            items: items,
            labels: labels,
            activeOnly: !showActiveOnly,
            includeNotes: includeNotes
        )
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                
                // Options section
                HStack {
                    Text("Include:")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()  // Pushes content to the left
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                HStack {
                    
                    Toggle(isOn: $showActiveOnly) {
                        Label("Completed", systemImage: "circle")
                    }
                    .toggleStyle(.switch)
                    
                    Divider()
                        .frame(height: 20)
                        .padding(.horizontal, 16)
                    
                    Toggle(isOn: $includeNotes) {
                        Label("Notes", systemImage: "note.text")
                    }
                    .toggleStyle(.switch)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .scrollDisabled(true)
                
                
                Divider()
                
                // Content
                if showRawMarkdown {
                    // Raw markdown view
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            Text(markdownText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Preview view
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            Markdown(markdownText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StructuredText(
                              markdown: """
                                ## The Problem

                                > After merging PR #347, users reported that tapping "Back" from the detail view would sometimes
                                > navigate to a completely random screen. One user ended up in Settings while trying to return to
                                > their inbox. Another saw the onboarding flow. Creative, but not ideal.

                                Here's what we knew going in:

                                - The issue only appeared **after** the state restoration changes
                                - It happened _inconsistently_—maybe 1 in 5 back navigations
                                - The stack trace was... let's call it "unhelpful"
                                """
                            )
                            
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                Divider()
                
                // Info banner
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Copy and export operations will use raw markdown")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground))
                
            }
            .navigationTitle("Export Markdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .help("Close")
                            
                }
                
                
                ToolbarSpacer(.fixed, placement: .cancellationAction)
                
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showRawMarkdown.toggle()
                    } label: {
                        Image(systemName: showRawMarkdown ? "doc.richtext" : "doc.plaintext")
                    }
                }
                
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    
                    Button {
                        showFileExporter = true
                    } label: {
                        Label("Download", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileExporter(
                isPresented: $showFileExporter,
                document: MarkdownDocument(text: markdownText),
                contentType: .plainText,
                defaultFilename: "\(sanitizeFilename(listName)).md"
            ) { result in
                switch result {
                case .success(let url):
                    print("Ã¢Å“â€¦ Exported markdown to: \(url)")
                case .failure(let error):
                    print("Ã¢ÂÅ’ Export error: \(error)")
                }
            }
            .overlay(
                Group {
                    if showCopiedConfirmation {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Copied to clipboard")
                                    .font(.subheadline)
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .cornerRadius(10)
                            .shadow(radius: 5)
                            .padding(.bottom, 50)
                        }
                        .transition(.move(edge: .bottom))
                    }
                }
            )
            .onAppear {
                showActiveOnly = !activeOnly  // Initialize from parameter
            }
        }
        
#if targetEnvironment(macCatalyst) || os(macOS)
        .frame(minHeight: 500)
#endif
        
    }
    
    private func copyToClipboard() {
        UIPasteboard.general.string = markdownText
        
        withAnimation {
            showCopiedConfirmation = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopiedConfirmation = false
            }
        }
    }
    
    private func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalidCharacters).joined(separator: "-")
    }
}

// MARK: - Markdown Document for FileDocument

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    
    var text: String
    
    init(text: String) {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

#Preview {
    MarkdownExportView(
        listName: "My Shopping List",
        items: [
            ShoppingItem(
                id: UUID(),
                note: "Apples",
                quantity: 2,
                checked: false,
                labelId: "produce"
            ),
            ShoppingItem(
                id: UUID(),
                note: "Bananas",
                quantity: 1,
                checked: true,
                labelId: "produce"
            ),
            ShoppingItem(
                id: UUID(),
                note: "Milk",
                quantity: 1,
                checked: false,
                labelId: "dairy"
            )
        ],
        labels: [
            ShoppingLabel(id: "produce", name: "Produce", color: "#4CAF50"),
            ShoppingLabel(id: "dairy", name: "Dairy", color: "#2196F3")
        ],
        activeOnly: false
    )
}
