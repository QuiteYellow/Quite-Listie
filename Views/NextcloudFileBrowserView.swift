//
//  NextcloudFileBrowserView.swift
//  Listie.md
//
//  Folder browser for selecting a .listie file from Nextcloud.
//

import SwiftUI
import NextcloudKit  // for NKFile

struct NextcloudFileBrowserView: View {
    /// Called when the user taps "Open" on a file.
    var onFileSelected: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var currentPath: String = "/"
    @State private var pathStack: [String] = []
    @State private var files: [NKFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showNewListSheet = false
    @State private var newListName = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    ContentUnavailableView(
                        "Could Not Load",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
                    .toolbar { refreshButton }
                } else {
                    fileList
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                if !pathStack.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            navigateBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if isCreating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Button {
                                newListName = ""
                                showNewListSheet = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                        refreshButton
                    }
                }
            }
            .sheet(isPresented: $showNewListSheet) {
                newListSheet
            }
            .task(id: currentPath) {
                await loadFiles()
            }
        }
    }

    // MARK: - Subviews

    private var fileList: some View {
        List(files, id: \.ocId) { file in
            fileRow(for: file)
        }
    }

    @ViewBuilder
    private func fileRow(for file: NKFile) -> some View {
        if file.directory {
            Button {
                navigateInto(path: remotePathFor(file: file))
            } label: {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.yellow)
                    Text(file.fileName)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
            }
            .buttonStyle(.plain)
        } else if isListieFile(file) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.blue)
                Text(file.fileName)
                Spacer()
                Button("Open") {
                    let remote = remotePathFor(file: file)
                    onFileSelected(remote)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else {
            HStack {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(file.fileName)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var newListSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $newListName)
                        .autocorrectionDisabled(false)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    LabeledContent("File") {
                        Text(newListName.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "name.listie"
                             : "\(newListName.trimmingCharacters(in: .whitespaces)).listie")
                            .foregroundStyle(newListName.trimmingCharacters(in: .whitespaces).isEmpty ? .tertiary : .primary)
                            .monospaced()
                    }
                    LabeledContent("Location") {
                        Text(currentPath == "/" ? "Nextcloud (root)" : currentPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewListSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        showNewListSheet = false
                        Task { await createNewList() }
                    }
                    .disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }

    private var refreshButton: some View {
        Button {
            Task { await loadFiles() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
    }

    // MARK: - Navigation

    private var navigationTitle: String {
        if currentPath == "/" { return "Nextcloud" }
        return currentPath.split(separator: "/").last.map(String.init) ?? "Nextcloud"
    }

    private func navigateInto(path: String) {
        pathStack.append(currentPath)
        currentPath = path
    }

    private func navigateBack() {
        guard let prev = pathStack.popLast() else { return }
        currentPath = prev
    }

    // MARK: - Create new list

    private func createNewList() async {
        let name = newListName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let fileName = name.hasSuffix(".listie") ? name : "\(name).listie"
        let remotePath = currentPath == "/" ? "/\(fileName)" : "\(currentPath)/\(fileName)"

        let doc = ListDocument(
            list: ShoppingListSummary(id: UUID().uuidString, name: name),
            items: [],
            labels: []
        )

        isCreating = true
        do {
            try await NextcloudManager.shared.saveFile(doc, to: remotePath)
            onFileSelected(remotePath)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }

    // MARK: - Data loading

    private func loadFiles() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await NextcloudManager.shared.listFiles(at: currentPath)
            // Sort: folders first, then files — alphabetically within each group
            files = result
                .filter { !$0.fileName.hasPrefix(".") }  // hide hidden files
                .filter { $0.directory || isListieFile($0) || $0.directory }
                .sorted {
                    if $0.directory != $1.directory { return $0.directory }
                    return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
                }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Helpers

    private func isListieFile(_ file: NKFile) -> Bool {
        let name = file.fileName.lowercased()
        return name.hasSuffix(".listie") || name.hasSuffix(".json")
    }

    /// Constructs the remote path for an NKFile.
    /// NKFile.path is the server-relative path to the *parent* folder (e.g. "/files/user/lists/").
    /// We append the filename to get the full remote path relative to the DAV files root.
    private func remotePathFor(file: NKFile) -> String {
        // NKFile.serverUrl is the full https:// URL to the parent folder.
        // We want just the path after /remote.php/dav/files/<username>.
        // The simplest approach: join currentPath + "/" + fileName.
        let base = currentPath == "/" ? "" : currentPath
        return "\(base)/\(file.fileName)"
    }
}

#Preview {
    NextcloudFileBrowserView { path in
        print("Selected: \(path)")
    }
}
