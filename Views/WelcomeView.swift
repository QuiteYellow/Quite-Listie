import SwiftUI

struct WelcomeView: View {
    @StateObject private var viewModel = WelcomeViewModel()
    @State private var selectedListID: String? = nil
    @State private var showingSettings = false
    @State private var isPresentingNewList = false
    
    @State private var showingLabelManager = false
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
                        Button() {
                            isPresentingNewList = true
                        } label: {
                            Label("Add List", systemImage: "plus")
                        }
                        Menu {
                            Button() {
                                showingSettings = true
                            } label: {
                                Label("Settings...", systemImage: "gear")
                            }
                            Button {
                                showingLabelManager = true
                                } label: {
                                    Label("Label Manager...", systemImage: "tag")
                                }
                            //Button() {
                              // do a thing
                            //} label: {
                            //    Label("Label Editor (dummy)...", systemImage: "label")
                            //}
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
        } detail: {
            if let id = selectedListID,
               let list = viewModel.lists.first(where: { $0.id == id }) {
                ShoppingListView(list: list, welcomeViewModel: viewModel)
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
        .sheet(isPresented: $isPresentingNewList) {
            NewShoppingListView {
                Task {
                    await viewModel.loadLists()
                }
            }
        }
        .sheet(isPresented: $showingLabelManager) {
            LabelManagerView(viewModel: LabelManagerViewModel())
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
        let userID = AppSettings.shared.tokens.first(where: { !$0.token.isEmpty })?.username ?? ""

        let favourites = viewModel.lists.filter {
            $0.extras?["favouritedBy"]?.components(separatedBy: ",").contains(userID) ?? false
        }

        let nonFavourites = viewModel.lists.filter {
            !($0.extras?["favouritedBy"]?.components(separatedBy: ",").contains(userID) ?? false)
        }

        let groupedNonFavourites = Dictionary(grouping: nonFavourites) { list in
            AppSettings.shared.tokens.first(where: { $0.id == list.localTokenId })?.identifier ?? "Unknown"
        }

        List(selection: $selectedListID) {
            // 🔶 Favourites Section
            if !favourites.isEmpty {
                Section(
                    header:
                        Label {
                            Text("Favourites")
                        } icon: {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                        }
                ) {
                    ForEach(favourites, id: \.id) { list in
                        listRow(for: list, userID: userID, showTokenCaption: true)
                    }
                }
            }

            // 🔷 Grouped Lists Section
            ForEach(groupedNonFavourites.sorted(by: { $0.key < $1.key }), id: \.key) { identifier, lists in
                Section(header:
                            Label {
                                Text(identifier)
                            } icon: {
                                Image(systemName: "person.2.fill")
                                    //.foregroundColor(.accentColor)
                            }
                ) {
                    ForEach(lists, id: \.id) { list in
                        listRow(for: list, userID: userID)
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
    
    @ViewBuilder
    private func listRow(for list: ShoppingListSummary, userID: String, showTokenCaption: Bool = false) -> some View {
        let isFavourited = list.extras?["favouritedBy"]?.components(separatedBy: ",").contains(userID) ?? false
        let tokenIdentifier = AppSettings.shared.tokens.first(where: { $0.id == list.localTokenId })?.identifier ?? "Unknown"

        HStack {
            Image(systemName: list.extras?["listsForMealieListIcon"] ?? "list.bullet")
                .frame(minWidth: 30)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)

                if showTokenCaption {
                    Text(tokenIdentifier)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let count = viewModel.uncheckedCounts[list.id], count >= 0 {
                Text("\(count)")
                    .foregroundColor(.secondary)
            }
        }
        .tag(list.id)
        .contextMenu {
            Button(isFavourited ? "Unfavourite" : "Favourite") {
                Task {
                    await viewModel.toggleFavourite(for: list, userID: userID)
                }
            }
            Button("List Settings") {
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
