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
    init(hex: String) {
        var hexFormatted = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        if hexFormatted.hasPrefix("#") {
            hexFormatted.removeFirst()
        }

        var rgbValue: UInt64 = 0
        if hexFormatted.count == 6 {
            Scanner(string: hexFormatted).scanHexInt64(&rgbValue)
        }

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255
        let blue = Double(rgbValue & 0x0000FF) / 255

        self.init(red: red, green: green, blue: blue)
    }
    
    func toHex() -> String {
            #if canImport(UIKit)
            typealias NativeColor = UIColor
            #elseif canImport(AppKit)
            typealias NativeColor = NSColor
            #endif
            
            let nativeColor = NativeColor(self)
            guard let components = nativeColor.cgColor.components, components.count >= 3 else {
                return "#000000"
            }
            
            let r = Int((components[0] * 255).rounded())
            let g = Int((components[1] * 255).rounded())
            let b = Int((components[2] * 255).rounded())
            
            return String(format: "#%02X%02X%02X", r, g, b)
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
    
    static func random() -> Color {
            Color(red: .random(in: 0.2...0.9),
                  green: .random(in: 0.2...0.9),
                  blue: .random(in: 0.2...0.9))
        }
    
    func adjusted(forBackground background: Color, threshold: CGFloat = 0.6) -> Color {
            let uiSelf = UIColor(self)
            let uiBackground = UIColor(background)

            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

            uiSelf.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            uiBackground.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

            let luminance1 = 0.299 * r1 + 0.587 * g1 + 0.114 * b1
            let luminance2 = 0.299 * r2 + 0.587 * g2 + 0.114 * b2
            let contrast = abs(luminance1 - luminance2)

            guard contrast < threshold else {
                return self // Good contrast already
            }

            // Determine current color scheme
            let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark

            let factor: CGFloat = 0.5
            let adjustedR: CGFloat
            let adjustedG: CGFloat
            let adjustedB: CGFloat

            if isDarkMode {
                // Lighten color in dark mode
                adjustedR = min(r1 + (1 - r1) * factor, 1.0)
                adjustedG = min(g1 + (1 - g1) * factor, 1.0)
                adjustedB = min(b1 + (1 - b1) * factor, 1.0)
            } else {
                // Darken color in light mode
                adjustedR = max(r1 * (1 - factor), 0)
                adjustedG = max(g1 * (1 - factor), 0)
                adjustedB = max(b1 * (1 - factor), 0)
            }

            return Color(red: adjustedR, green: adjustedG, blue: adjustedB)
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




extension ShoppingListSummary {
    func updatedExtras(with updates: [String: String?]) -> [String: String] {
        var merged = self.extras ?? [:]
        for (key, value) in updates {
            if let value = value {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }
        return merged
    }
}

/* USAGE (NOT HERE!!!)
 
 let updates = [
     "markdownNotes": "Remember to buy almond milk",
     "notifyAlexa": "true",
     "customKey": "customValue"
 ]

 let updatedExtras = item.updatedExtras(with: updates)
 
 */

//MARK: deduplicator for lableWrapper.
extension Sequence {
    func uniqueBy<T: Hashable>(_ key: (Element) -> T) -> [Element] {
        var seen = Set<T>()
        return filter { seen.insert(key($0)).inserted }
    }
}





extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
