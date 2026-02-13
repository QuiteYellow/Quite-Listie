//
//  ChipAlignedRow.swift
//  Listie.md
//
//  Reusable layout that displays chips inline with the title on wide screens,
//  falling back to stacked when titles are too long or the screen is narrow.
//

import SwiftUI

struct ChipAlignedRow<Title: View, Chips: View>: View {
    @Environment(\.chipsInline) private var chipsInline

    @ViewBuilder let title: () -> Title
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        if chipsInline {
            HStack(spacing: 12) {
                title()
                Spacer()
                chips()
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                title()
                chips()
            }
        }
    }
}

struct ListWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

func shouldShowChipsInline(
    itemTitles: [String],
    availableWidth: CGFloat,
    chipWidth: CGFloat = 120,
    checkboxWidth: CGFloat = 40,
    averageCharWidth: CGFloat = 8
) -> Bool {
    guard availableWidth > 600 else { return false }
    let usableWidth = availableWidth - chipWidth - checkboxWidth - 40
    let maxTitleLength = itemTitles.map(\.count).max() ?? 0
    return CGFloat(maxTitleLength) * averageCharWidth < usableWidth
}
