import SwiftUI

class LabelEditorViewModel: ObservableObject {
    @Published var name: String
    @Published var color: Color
    @Published var groupId: String?
    
    let label: ShoppingLabel?

    var isNameValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var isEditing: Bool {
            label != nil
        }

    init() {
            self.name = ""
            self.color = .black
            self.groupId = nil
            self.label = nil
        }

        init(from label: ShoppingLabel) {
            self.name = label.name
            self.color = Color(hex: label.color)
            self.groupId = label.groupId
            self.label = label
        }
}
