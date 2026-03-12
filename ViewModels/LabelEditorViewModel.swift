import SwiftUI

@Observable
class LabelEditorViewModel {
    var name: String
    var color: Color
    var symbol: String?

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
        self.symbol = nil
        self.label = nil
    }

    init(from label: ShoppingLabel) {
        self.name = label.name
        self.color = Color(hex: label.color)
        self.symbol = label.symbol
        self.label = label
    }
}
