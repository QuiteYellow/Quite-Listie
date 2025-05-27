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

    func isDarkColor(threshold: Float = 0.6) -> Bool {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        // Luminance formula
        let brightness = Float((red * 299 + green * 587 + blue * 114) / 1000)
        return brightness < threshold
    }

    func appropriateForegroundColor() -> Color {
        isDarkColor() ? .white : .black
    }
    
    func lightened(forBackground background: Color, threshold: CGFloat = 0.6) -> Color {

            let uiSelf = UIColor(self)
            let uiBackground = UIColor(background)

            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

            uiSelf.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            uiBackground.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

            let luminance1 = (0.299 * r1 + 0.587 * g1 + 0.114 * b1)
            let luminance2 = (0.299 * r2 + 0.587 * g2 + 0.114 * b2)
            let contrast = abs(luminance1 - luminance2)

            // If contrast is already good enough, return self
            guard contrast < threshold else {
                return self
            }

            // Lighten color (move toward white)
            let lightenFactor: CGFloat = 0.5
            let newR = min(r1 + (1 - r1) * lightenFactor, 1.0)
            let newG = min(g1 + (1 - g1) * lightenFactor, 1.0)
            let newB = min(b1 + (1 - b1) * lightenFactor, 1.0)

            return Color(red: newR, green: newG, blue: newB)
        }
    
    func closestSystemColor() -> Color {
            let systemColors: [(name: String, color: UIColor)] = [
                ("systemRed", .systemRed),
                ("systemOrange", .systemOrange),
                ("systemYellow", .systemYellow),
                ("systemGreen", .systemGreen),
                ("systemBlue", .systemBlue),
                ("systemIndigo", .systemIndigo),
                ("systemPurple", .systemPurple),
                ("systemPink", .systemPink),
                ("systemTeal", .systemTeal),
                ("systemGray", .systemGray)
            ]

            let targetColor = UIColor(self)

            var bestMatch = systemColors.first!
            var smallestDistance: CGFloat = .greatestFiniteMagnitude

            for systemColor in systemColors {
                let distance = targetColor.distance(to: systemColor.color)
                if distance < smallestDistance {
                    smallestDistance = distance
                    bestMatch = systemColor
                }
            }

            return Color(bestMatch.color)
        }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

extension UIColor {
    func distance(to other: UIColor) -> CGFloat {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        let dr = r1 - r2
        let dg = g1 - g2
        let db = b1 - b2

        return sqrt(dr * dr + dg * dg + db * db)
    }
}

