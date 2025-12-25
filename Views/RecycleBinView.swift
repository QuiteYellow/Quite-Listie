//
//  RecycleBinView.swift
//  Listie-md
//
//  Created by Jack Nagy on 23/12/2025.
//


import SwiftUI

struct RecycleBinView: View {
    let list: UnifiedList
    let provider: UnifiedListProvider
    var onItemsChanged: (() -> Void)?
    @Environment(\.dismiss) var dismiss
    
    @State private var deletedItems: [ShoppingItem] = []
    @State private var showDeleteAllConfirmation = false
    @State private var showRestoreAllConfirmation = false
    @State private var itemToDelete: ShoppingItem?
    
    var body: some View {
            NavigationView {
                List {
                    if deletedItems.isEmpty {
                        ContentUnavailableView(
                            "Recycle Bin Empty",
                            systemImage: "trash",
                            description: Text("Deleted items will appear here and be automatically removed after 30 days")
                        )
                    } else {
                        Section {
                            Text("Items are automatically deleted after 30 days")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        
                        ForEach(deletedItems) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.note)
                                    .font(.body)
                                
                                // Show deletion date and auto-delete countdown
                                if let deletedAt = item.deletedAt ?? item.modifiedAt as Date? {
                                    let daysAgo = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
                                    let daysRemaining = 30 - daysAgo
                                    
                                    if daysRemaining > 0 {
                                        Text("Deleted \(daysAgo) day\(daysAgo == 1 ? "" : "s") ago • Auto-deletes in \(daysRemaining) day\(daysRemaining == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundColor(daysRemaining <= 7 ? .orange : .secondary)
                                    } else {
                                        Text("Deleted \(daysAgo) day\(daysAgo == 1 ? "" : "s") ago • Will be auto-deleted soon")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            Button("Restore") {
                                Task { await restore(item) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                itemToDelete = item
                            } label: {
                                Label("Delete Forever", systemImage: "trash.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recycle Bin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                
                if !deletedItems.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Restore All") {
                            showRestoreAllConfirmation = true
                        }
                        
                        Button("Delete All", role: .destructive) {
                            showDeleteAllConfirmation = true
                        }
                    }
                }
            }
            .task {
                await loadDeletedItems()
            }
            .alert("Delete Forever?", isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let item = itemToDelete {
                        Task {
                            await permanentlyDelete(item)
                            itemToDelete = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { itemToDelete = nil }
            } message: {
                Text("This item will be permanently deleted and cannot be recovered.")
            }
            .alert("Restore All Items?", isPresented: $showRestoreAllConfirmation) {
                Button("Restore All") {
                    Task { await restoreAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All deleted items will be restored to the list.")
            }
            .alert("Delete All Items Forever?", isPresented: $showDeleteAllConfirmation) {
                Button("Delete All", role: .destructive) {
                    Task { await deleteAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All items will be permanently deleted and cannot be recovered.")
            }
        }
    }
    
    private func loadDeletedItems() async {
        do {
            deletedItems = try await provider.fetchDeletedItems(for: list)
        } catch {
            print("Failed to load deleted items: \(error)")
        }
    }
    
    private func restore(_ item: ShoppingItem) async {
        do {
            try await provider.restoreItem(item, in: list)
            await loadDeletedItems()
            onItemsChanged?()
        } catch {
            print("Failed to restore item: \(error)")
        }
    }
    
    private func permanentlyDelete(_ item: ShoppingItem) async {
        do {
            try await provider.permanentlyDeleteItem(item, from: list)
            await loadDeletedItems()
            onItemsChanged?()
        } catch {
            print("Failed to permanently delete item: \(error)")
        }
    }
    
    private func restoreAll() async {
        for item in deletedItems {
            try? await provider.restoreItem(item, in: list)
        }
        await loadDeletedItems()
        showRestoreAllConfirmation = false
        onItemsChanged?()
    }
    
    private func deleteAll() async {
        for item in deletedItems {
            try? await provider.permanentlyDeleteItem(item, from: list)
        }
        await loadDeletedItems()
        showDeleteAllConfirmation = false
        onItemsChanged?() 
    }
}
