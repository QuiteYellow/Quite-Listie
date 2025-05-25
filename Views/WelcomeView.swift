import SwiftUI

struct WelcomeView: View {
    @StateObject private var viewModel = WelcomeViewModel()
    @State private var showingSettings = false  // Add this

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("Loading lists...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    VStack(spacing: 20) {
                        Text(error)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task {
                                await viewModel.loadLists()
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.lists) { list in
                        NavigationLink(value: list.id) {
                            Text(list.name)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("All Lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .navigationDestination(for: String.self) { listId in
                ShoppingListView(shoppingListId: listId)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                await viewModel.loadLists()
            }
        }
    }
}

