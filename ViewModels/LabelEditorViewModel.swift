import SwiftUI

class LabelEditorViewModel: ObservableObject {
    @Published var name: String
    @Published var color: Color
    @Published var groupId: String?

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && groupId != nil
    }

    init() {
        self.name = ""
        self.color = .black
        self.groupId = nil
    }

    init(from label: ShoppingLabel) {
        self.name = label.name
        self.color = Color(hex: label.color)
        self.groupId = label.groupId
    }
}
