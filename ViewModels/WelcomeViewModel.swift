import Foundation

@MainActor
class WelcomeViewModel: ObservableObject {
    @Published var lists: [ShoppingListSummary] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadLists() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            lists = try await ShoppingListAPI.shared.fetchShoppingLists()
        } catch {
            errorMessage = "Failed to load lists: \(error.localizedDescription)"
            print("⭐️ Failed to load lists: \(error.localizedDescription)")
        }
    }
}
