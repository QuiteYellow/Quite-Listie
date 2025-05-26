import SwiftUI

struct WelcomeView: View {
    @StateObject private var viewModel = WelcomeViewModel()
    @State private var showingSettings = false
    @State private var refreshTask: Task<Void, Never>? = nil

    let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    
    


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 0)

                    // Dynamic section for fetched lists
                    if viewModel.isLoading {
                        ProgressView("Loading lists...")
                            .frame(maxWidth: .infinity, alignment: .center)
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
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(viewModel.lists) { list in
                                let uncheckedCount = viewModel.uncheckedCounts[list.id] ?? 0
                                NavigationLink(destination: ShoppingListView(shoppingListId: list.id)) {
                                    gridButtonLabel(list.name, iconName: "list.bullet", count: uncheckedCount)
                                }
                            }

                            // Add your static nav links below
/*
                            NavigationLink(destination: somePlace()) {
                                gridButtonLabel("...", iconName: "book.fill")
                            }
*/
                        }
                        .padding(.horizontal, 0) // outside of grid
                    }

                    //Spacer(minLength: 100)
                }
                .padding()
            }
            .refreshable {
                // Cancel any previous refresh task before starting a new one
                refreshTask?.cancel()
                refreshTask = Task {
                    await viewModel.loadLists()
                    refreshTask = nil
                }
            }
            .background(Color(.systemGroupedBackground))
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
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                await viewModel.loadLists()
            }
        }
    }

    // Reuse this helper to make styled grid buttons
    private func gridButtonLabel(_ text: String, iconName: String = "star", count: Int? = nil) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray5))
                .frame(minHeight: 80)
            
            VStack {
                HStack {
                    Image(systemName: iconName)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(15)
                    
                    Spacer()
                    
                    if let count = count {
                        Text("\(count)")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(15)
                            .multilineTextAlignment(.leading)
                    }
                }
                
                Spacer()
                
                HStack {
                    Text(text)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .padding([.leading, .bottom], 15)
                    Spacer()
                }
            }
        }
    }
}
