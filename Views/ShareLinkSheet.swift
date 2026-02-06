//
//  ShareLinkSheet.swift
//  Listie-md
//
//  Sheet for generating and sharing compressed deeplink URLs
//

import SwiftUI

struct ShareLinkSheet: View {
    let listName: String
    let listId: String?
    let items: [ShoppingItem]
    let labels: [ShoppingLabel]

    @Environment(\.dismiss) var dismiss

    @State private var compress = true
    @State private var includeComments = false
    @State private var includeActiveOnly = true
    @State private var showCopiedConfirmation = false

    // MARK: - Computed Properties

    private var filteredItems: [ShoppingItem] {
        includeActiveOnly ? items.filter { !$0.checked } : items
    }

    private var generatedURL: String {
        generateShareURL()
    }

    private var urlCharacterCount: Int {
        generatedURL.count
    }

    private var warningLevel: WarningLevel {
        if generatedURL.hasPrefix("Error") { return .none }
        if urlCharacterCount >= 4000 { return .error }
        if urlCharacterCount >= 2000 { return .warning }
        return .none
    }

    private enum WarningLevel {
        case none, warning, error
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            Form {
                // Info
                Section {
                    Text("Anyone with this link can import these items into their Listie app.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                // Toggles
                Section {
                    Toggle(isOn: $compress) {
                        Label("Compress", systemImage: "archivebox")
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $includeComments) {
                        Label("Comments", systemImage: "note.text")
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $includeActiveOnly) {
                        Label("Active Only", systemImage: "circle")
                    }
                    .toggleStyle(.switch)
                } header: {
                    Text("Options")
                }

                // Details & warnings
                Section {
                    HStack {
                        Label("\(filteredItems.count) items\(includeComments ? " with comments" : "")", systemImage: "list.bullet")
                            .font(.subheadline)
                        Spacer()
                        Text("\(urlCharacterCount) characters")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(warningColor)
                    }

                    if warningLevel != .none {
                        warningView
                    }
                }

                // Actions
                Section {
                    Button {
                        UIPasteboard.general.string = generatedURL
                        withAnimation {
                            showCopiedConfirmation = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation {
                                showCopiedConfirmation = false
                            }
                        }
                    } label: {
                        Label(
                            showCopiedConfirmation ? "Copied!" : "Copy Link",
                            systemImage: showCopiedConfirmation ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                    }

                    ShareLink(item: generatedURL) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                }

                // URL preview (at the bottom since it can be very long)
                Section {
                    Text(generatedURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                } header: {
                    Text("Share URL")
                }
            }
            .navigationTitle("Share as Link")
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
            }
        }
    }

    // MARK: - Warning Color

    private var warningColor: Color {
        switch warningLevel {
        case .error: return .red
        case .warning: return .orange
        case .none: return .secondary
        }
    }

    // MARK: - Warning View

    @ViewBuilder
    private var warningView: some View {
        HStack(alignment: .top) {
            Image(systemName: warningLevel == .error
                  ? "exclamationmark.triangle.fill"
                  : "exclamationmark.triangle")
                .foregroundColor(warningLevel == .error ? .red : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(warningLevel == .error
                     ? "URL is very long"
                     : "URL is getting long")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(warningLevel == .error ? .red : .orange)

                Text(warningLevel == .error
                     ? "URLs over 4,000 characters may not work on all platforms and messaging apps. Try enabling compression, removing comments, or switching to active items only."
                     : "URLs over 2,000 characters may be truncated by some apps. Consider enabling compression if it's not already on, or reducing the number of items.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - URL Generation

    private func generateShareURL() -> String {
        guard let id = listId else {
            return "Error: List ID not available."
        }

        let result = MarkdownListGenerator.generate(
            listName: listName,
            items: filteredItems,
            labels: labels,
            activeOnly: includeActiveOnly,
            includeNotes: includeComments
        )
        let markdown = result.markdown

        let encodedMarkdown: String
        let encParam: String

        if compress {
            guard let compressed = DeeplinkCompression.compress(markdown) else {
                return "Error: Failed to compress markdown."
            }
            encodedMarkdown = compressed
            encParam = "zlib"
        } else {
            guard let base64 = markdown.data(using: .utf8)?.base64EncodedString() else {
                return "Error: Failed to encode markdown."
            }
            encodedMarkdown = base64
            encParam = "b64"
        }

        return "listie://import?list=\(id)&markdown=\(encodedMarkdown)&enc=\(encParam)&preview=true"
    }
}
