import SwiftUI

struct WelcomeView: View {
    @StateObject private var viewModel = WelcomeViewModel()
    @State private var selectedListID: String? = nil
    @State private var showingSettings = false
    @State private var isPresentingNewList = false
    @EnvironmentObject var settings: AppSettings
    
    @State private var showingLabelManager = false
    @EnvironmentObject var networkMonitor: NetworkMonitor
    
    
    private var selectedListIsReadOnly: Bool {
        if let id = selectedListID,
           let list = viewModel.lists.first(where: { $0.id == id }) {
            return list.isReadOnlyExample
        }
        return false
    }
    

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
                        //print("👋 WelcomeView task triggered")
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

    @EnvironmentObject var settings: AppSettings

    @State private var listToDelete: ShoppingListSummary? = nil
    @State private var showingDeleteConfirmation = false

    @State private var showFavouritesWarning: Bool = !UserDefaults.standard.bool(forKey: "hideFavouritesWarning")

    var groupedLists: [String: [ShoppingListSummary]] {
        Dictionary(grouping: viewModel.lists) { list in
            if let tokenId = list.localTokenId,
               let token = AppSettings.shared.tokens.first(where: { $0.id == tokenId }) {
                return token.identifier
            } else if list.isLocal {
                return TokenInfo.localDeviceToken.identifier
            } else {
                return "Unknown"
            }
        }
    }

    var body: some View {
        let favourites = viewModel.lists.filter { list in
            let userIDForList = list.isLocal
                ? TokenInfo.localDeviceToken.identifier
                : AppSettings.shared.tokens.first(where: { $0.id == list.localTokenId })?.username ?? "unknown-user"

            return list.extras?["favouritedBy"]?.components(separatedBy: ",").contains(userIDForList) ?? false
        }

        let nonFavourites = viewModel.lists.filter { list in
            let userIDForList = list.isLocal
                ? TokenInfo.localDeviceToken.identifier
                : AppSettings.shared.tokens.first(where: { $0.id == list.localTokenId })?.username ?? "unknown-user"

            return !(list.extras?["favouritedBy"]?.components(separatedBy: ",").contains(userIDForList) ?? false)
        }

        let groupedNonFavourites = Dictionary(grouping: nonFavourites) { list in
            AppSettings.shared.tokens.first(where: { $0.id == list.localTokenId })?.identifier ?? "Unknown"
        }

        if !favourites.isEmpty && showFavouritesWarning {
            VStack(alignment: .leading, spacing: 8) {
                Label("Favourites are visible to admins and other users in your household", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .padding(.horizontal)
                    .padding(.top, 4)

                HStack {
                    Spacer()
                    Button("Don't show again") {
                        UserDefaults.standard.set(true, forKey: "hideFavouritesWarning")
                        withAnimation {
                            showFavouritesWarning = false
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    Spacer()
                }
            }
            .padding(8)
            .background(.yellow.opacity(0.05))
            .cornerRadius(8)
        }

        List(selection: $selectedListID) {
            if !favourites.isEmpty {
                Section(header: Label("Favourites", systemImage: "star.fill").foregroundColor(.yellow)) {
                    ForEach(favourites, id: \.id) { list in
                        listRow(for: list, showTokenCaption: true)
                    }
                }
            }

            ForEach(groupedNonFavourites.sorted(by: { $0.key < $1.key }), id: \.key) { identifier, lists in
                Section(header: Label(identifier, systemImage: "person.2.fill")) {
                    ForEach(lists, id: \.id) { list in
                        listRow(for: list)
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
                        try await CombinedShoppingListProvider.shared.deleteList(list)
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
        .onChange(of: settings.tokens) { _ in
            Task {
                await viewModel.loadLists()
            }
        }
    }

    @ViewBuilder
    private func listRow(for list: ShoppingListSummary, showTokenCaption: Bool = false) -> some View {
        let userIDForList = list.isLocal
            ? TokenInfo.localDeviceToken.identifier
            : AppSettings.shared.tokens.first(where: { $0.id == list.localTokenId })?.username ?? "unknown-user"

        let isFavourited = list.extras?["favouritedBy"]?.components(separatedBy: ",").contains(userIDForList) ?? false
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
            if !list.isReadOnlyExample {
                Button(isFavourited ? "Unfavourite" : "Favourite") {
                    Task {
                        await viewModel.toggleFavourite(for: list)
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
            } else {
                Text("Read-only list").foregroundColor(.gray)
            }
        }
        .swipeActions(edge: .leading) {
            if !list.isReadOnlyExample {
                Button {
                    viewModel.selectedListForSettings = list
                    viewModel.showingListSettings = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            if !list.isReadOnlyExample {
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
