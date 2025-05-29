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
                                    Button {
                                        showingSettings = true
                                    } label: {
                                        Image(systemName: "gear")
                                    }
                                }
                            }
                    } detail: {
            if let id = selectedListID,
               let list = viewModel.lists.first(where: { $0.id == id }) {
                ShoppingListView(shoppingListId: list.id, listName: list.name, tokenID: list.tokenId)
                    .id(list.id)
            } else {
                ContentUnavailableView("Select a list", systemImage: "list.bullet")
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
    
    var groupedLists: [String: [ShoppingListSummary]] {
        Dictionary(grouping: viewModel.lists) { list in
            AppSettings.shared.tokens.first(where: { $0.id == list.tokenId })?.identifier ?? "Unknown"
        }
    }
    
    var body: some View {
        List(selection: $selectedListID) {
            ForEach(groupedLists.sorted(by: { $0.key < $1.key }), id: \.key) { identifier, lists in
                Section(header: Text(identifier)) {
                    ForEach(lists, id: \.id) { list in
                        HStack {
                            Image(systemName: "list.bullet")
                            Text(list.name)
                            Spacer()
                            if let count = viewModel.uncheckedCounts[list.id], count >= 0 {
                                Text("\(count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(list.id)
                    }
                }
            }
        }
        .navigationTitle("All Lists")
        .refreshable {
            await viewModel.loadLists()
        }
    }
}
