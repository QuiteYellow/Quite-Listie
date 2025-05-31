import SwiftUI

struct WelcomeView: View {
    @StateObject private var viewModel = WelcomeViewModel()
    @State private var selectedListID: String? = nil
    @State private var showingSettings = false
    @EnvironmentObject var networkMonitor: NetworkMonitor

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel, selectedListID: $selectedListID)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if !networkMonitor.isConnected {
                            Image(systemName: "wifi.slash")
                                .foregroundColor(.red)
                                .help("No internet connection")
                        }
                        Menu {
                            Button() {
                                showingSettings = true
                            } label: {
                                Label("Settings...", systemImage: "gear")
                            }
                            
                            Button() {
                              // do a thing
                            } label: {
                                Label("Label Editor (dummy)...", systemImage: "label")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
        } detail: {
            if let id = selectedListID,
               let list = viewModel.lists.first(where: { $0.id == id }) {
                ShoppingListView(list: list)
                    .id(list.id)
            } else {
                ContentUnavailableView("Select a list", systemImage: "list.bullet")
            }
        }
        .sheet(isPresented: $viewModel.showingListSettings) {
            if let list = viewModel.selectedListForSettings {
                ListSettingsView(list: list) { updatedName, extras in
                    let updatedExtras = list.updatedExtras(with: extras)

                    Task {
                        await viewModel.updateListName(
                            listID: list.id,
                            newName: updatedName,
                            extras: updatedExtras
                        )
                        await viewModel.loadLists()
                    }
                }
            }
        }
        
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            await viewModel.loadLists()
        }
    }
}

struct SidebarView: View {
    @ObservedObject var viewModel: WelcomeViewModel
    @Binding var selectedListID: String?
    
    @State private var listToDelete: ShoppingListSummary? = nil
    @State private var showingDeleteConfirmation = false
    
    var groupedLists: [String: [ShoppingListSummary]] {
        Dictionary(grouping: viewModel.lists) { list in
            AppSettings.shared.tokens.first(where: { $0.id == list.localTokenId })?.identifier ?? "Unknown"
        }
    }
    
    var body: some View {
        List(selection: $selectedListID) {
            ForEach(groupedLists.sorted(by: { $0.key < $1.key }), id: \.key) { identifier, lists in
                Section(header: Text(identifier)) {
                    ForEach(lists, id: \.id) { list in
                        HStack {
                            Image(systemName: list.extras?["listsForMealieListIcon"] ?? "list.bullet")
                                .frame(minWidth: 30)
                                .foregroundColor(.secondary)
                            Text(list.name)
                            Spacer()
                            if let count = viewModel.uncheckedCounts[list.id], count >= 0 {
                                Text("\(count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(list.id)
                        .contextMenu {
                            Button("List Settings") {
                                // selectedListID = list.id //this loads the list being edited.
                                viewModel.selectedListForSettings = list
                                viewModel.showingListSettings = true
                            }
                            
                            Divider()

                            Button("Delete List", role: .destructive) {
                                listToDelete = list
                                showingDeleteConfirmation = true
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                viewModel.selectedListForSettings = list
                                viewModel.showingListSettings = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.accentColor)
                        }
                        .swipeActions(edge: .trailing) {
                                Button(role: .none) {
                                    listToDelete = list
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                    }
                }
            }
        }
        .navigationTitle("All Lists")
        .refreshable {
            await viewModel.loadLists()
        }
        .alert("Delete List?", isPresented: $showingDeleteConfirmation, presenting: listToDelete) { list in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await ShoppingListAPI.shared.deleteList(list)
                        await viewModel.loadLists()

                        // If the deleted list was selected, clear it
                        if selectedListID == list.id {
                            selectedListID = nil
                        }
                    } catch {
                        print("❌ Failed to delete list: \(error)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { list in
            Text("Are you sure you want to delete the list \"\(list.name)\"?")
        }
    }
}
