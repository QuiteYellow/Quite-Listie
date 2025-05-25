//
//  extensions.swift
//  ListsForMealie
//
//  Created by Jack Weekes on 25/05/2025.
//

import Foundation

import SwiftUI

extension String {
    func removingLabelNumberPrefix() -> String {
        let pattern = #"^\d+\.\s*"#
        if let range = self.range(of: pattern, options: .regularExpression) {
            return String(self[range.upperBound...])
        }
        return self
    }
}

extension Color {
    init?(hex: String) {
        var hexFormatted = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if hexFormatted.hasPrefix("#") {
            hexFormatted.removeFirst()
        }

        guard hexFormatted.count == 6 else {
            return nil
        }

        var rgbValue: UInt64 = 0
        Scanner(string: hexFormatted).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255
        let blue = Double(rgbValue & 0x0000FF) / 255

        self.init(red: red, green: green, blue: blue)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

