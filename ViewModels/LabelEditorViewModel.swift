import SwiftUI

class LabelEditorViewModel: ObservableObject {
    @Published var name: String
    @Published var color: Color
    @Published var listId: String?  // Changed from shoppingListId
    
    let label: ShoppingLabel?
    
    var isNameValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var isEditing: Bool {
        label != nil
    }
    
    init(listId: String? = nil) {  // Changed parameter name
        self.name = ""
        self.color = .black
        self.listId = listId  // Changed from shoppingListId
        self.label = nil
    }
    
    init(from label: ShoppingLabel) {
        self.name = label.name
        self.color = Color(hex: label.color)
        self.listId = label.listId  // Changed from shoppingListId
        self.label = label
    }
}
