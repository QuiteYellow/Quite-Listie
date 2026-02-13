//
//  extensions.swift
//  Listie.md
//
//  Created by Jack Weekes on 25/05/2025.
//

import Foundation

import SwiftUI

// MARK: - Environment Keys

private struct ChipsInlineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chipsInline: Bool {
        get { self[ChipsInlineKey.self] }
        set { self[ChipsInlineKey.self] = newValue }
    }
}

// MARK: - Focused Value Keys

struct NewListSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct FileImporterKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct NewConnectedExporterKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct ExportMarkdownKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct ExportJSONKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct ShareLinkKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct IsReadOnlyKey: FocusedValueKey {
    typealias Value = Bool
}

struct SettingsSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var newListSheet: Binding<Bool>? {
        get { self[NewListSheetKey.self] }
        set { self[NewListSheetKey.self] = newValue }
    }
    
    var fileImporter: Binding<Bool>? {
        get { self[FileImporterKey.self] }
        set { self[FileImporterKey.self] = newValue }
    }
    
    var newConnectedExporter: Binding<Bool>? {
        get { self[NewConnectedExporterKey.self] }
        set { self[NewConnectedExporterKey.self] = newValue }
    }
    
    var exportMarkdown: Binding<Bool>? {
        get { self[ExportMarkdownKey.self] }
        set { self[ExportMarkdownKey.self] = newValue }
    }

    var exportJSON: Binding<Bool>? {
        get { self[ExportJSONKey.self] }
        set { self[ExportJSONKey.self] = newValue }
    }

    var shareLink: Binding<Bool>? {
        get { self[ShareLinkKey.self] }
        set { self[ShareLinkKey.self] = newValue }
    }
    
    var isReadOnly: Bool? {
            get { self[IsReadOnlyKey.self] }
            set { self[IsReadOnlyKey.self] = newValue }
        }

    var settingsSheet: Binding<Bool>? {
        get { self[SettingsSheetKey.self] }
        set { self[SettingsSheetKey.self] = newValue }
    }
}

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

// MARK: - List Background

struct BackgroundGradient: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let lightFromHex: String
    let lightToHex: String
    let darkFromHex: String
    let darkToHex: String

    var fromColor: Color {
        Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(Color(hex: darkFromHex))
                : UIColor(Color(hex: lightFromHex))
        })
    }

    var toColor: Color {
        Color(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(Color(hex: darkToHex))
                : UIColor(Color(hex: lightToHex))
        })
    }

    // All gradients, grouped by mood. Light mode: soft pastels/mid-tones. Dark mode: deeper, richer.
    static let all: [BackgroundGradient] = [

        // ── Warm ──────────────────────────────────────────────
        BackgroundGradient(id: "sunrise",       name: "Sunrise",
            lightFromHex: "#FFECD2", lightToHex: "#FCB69F",
            darkFromHex:  "#4A2C1A", darkToHex:  "#8B3A2A"),
        BackgroundGradient(id: "peach-fuzz",    name: "Peach Fuzz",
            lightFromHex: "#FDD6BD", lightToHex: "#F9A8B8",
            darkFromHex:  "#5C3429", darkToHex:  "#6E3044"),
        BackgroundGradient(id: "golden-hour",   name: "Golden Hour",
            lightFromHex: "#F6D365", lightToHex: "#FDA085",
            darkFromHex:  "#5A4520", darkToHex:  "#6E3A2A"),
        BackgroundGradient(id: "rosewater",     name: "Rosewater",
            lightFromHex: "#FECFEF", lightToHex: "#FF989C",
            darkFromHex:  "#4E2840", darkToHex:  "#6B2E30"),
        BackgroundGradient(id: "ember",         name: "Ember",
            lightFromHex: "#FF9A9E", lightToHex: "#FECFEF",
            darkFromHex:  "#6B2E30", darkToHex:  "#4E2840"),
        BackgroundGradient(id: "coral-reef",    name: "Coral Reef",
            lightFromHex: "#F093FB", lightToHex: "#F5576C",
            darkFromHex:  "#502855", darkToHex:  "#6E2233"),

        // ── Cool ──────────────────────────────────────────────
        BackgroundGradient(id: "arctic",        name: "Arctic",
            lightFromHex: "#E0F7FA", lightToHex: "#B2EBF2",
            darkFromHex:  "#0E3A40", darkToHex:  "#1A4E55"),
        BackgroundGradient(id: "deep-ocean",    name: "Deep Ocean",
            lightFromHex: "#A8EDEA", lightToHex: "#FED6E3",
            darkFromHex:  "#1A4040", darkToHex:  "#4E2838"),
        BackgroundGradient(id: "moonrise",      name: "Moonrise",
            lightFromHex: "#C1DEFF", lightToHex: "#E8D5F5",
            darkFromHex:  "#1A2E4A", darkToHex:  "#32254A"),
        BackgroundGradient(id: "pacific",       name: "Pacific",
            lightFromHex: "#667EEA", lightToHex: "#764BA2",
            darkFromHex:  "#1E2755", darkToHex:  "#2D1A40"),
        BackgroundGradient(id: "frost",         name: "Frost",
            lightFromHex: "#D4FC79", lightToHex: "#96E6A1",
            darkFromHex:  "#2A4020", darkToHex:  "#1E3A28"),
        BackgroundGradient(id: "northern-lights", name: "Northern Lights",
            lightFromHex: "#43E97B", lightToHex: "#38F9D7",
            darkFromHex:  "#0E3A1E", darkToHex:  "#0C3A38"),

        // ── Purple & Lavender ─────────────────────────────────
        BackgroundGradient(id: "wisteria",      name: "Wisteria",
            lightFromHex: "#C471F5", lightToHex: "#FA71CD",
            darkFromHex:  "#381850", darkToHex:  "#501838"),
        BackgroundGradient(id: "amethyst",      name: "Amethyst",
            lightFromHex: "#DDD6F3", lightToHex: "#FAACA8",
            darkFromHex:  "#2A2540", darkToHex:  "#4A2828"),
        BackgroundGradient(id: "grape-soda",    name: "Grape Soda",
            lightFromHex: "#9795F0", lightToHex: "#FBC8D4",
            darkFromHex:  "#262445", darkToHex:  "#4A2838"),
        BackgroundGradient(id: "twilight",      name: "Twilight",
            lightFromHex: "#A18CD1", lightToHex: "#FBC2EB",
            darkFromHex:  "#2A1845", darkToHex:  "#4E2845"),
        BackgroundGradient(id: "velvet",        name: "Velvet",
            lightFromHex: "#C33764", lightToHex: "#1D2671",
            darkFromHex:  "#6B1A34", darkToHex:  "#0E1338"),

        // ── Nature ────────────────────────────────────────────
        BackgroundGradient(id: "sage-mist",     name: "Sage Mist",
            lightFromHex: "#C9D6C4", lightToHex: "#E8DFD0",
            darkFromHex:  "#2A3828", darkToHex:  "#38322A"),
        BackgroundGradient(id: "forest-floor",  name: "Forest Floor",
            lightFromHex: "#56AB2F", lightToHex: "#A8E063",
            darkFromHex:  "#1A3A0E", darkToHex:  "#2A4A18"),
        BackgroundGradient(id: "spring-meadow", name: "Spring Meadow",
            lightFromHex: "#FBED96", lightToHex: "#ABECD6",
            darkFromHex:  "#4A4220", darkToHex:  "#1E4038"),
        BackgroundGradient(id: "moss",          name: "Moss",
            lightFromHex: "#134E5E", lightToHex: "#71B280",
            darkFromHex:  "#0A2830", darkToHex:  "#254030"),

        // ── Sunset & Sky ──────────────────────────────────────
        BackgroundGradient(id: "california",    name: "California",
            lightFromHex: "#FF7E5F", lightToHex: "#FEB47B",
            darkFromHex:  "#6B3028", darkToHex:  "#6E4828"),
        BackgroundGradient(id: "mango",         name: "Mango",
            lightFromHex: "#FFD89B", lightToHex: "#19547B",
            darkFromHex:  "#5A4820", darkToHex:  "#0E2838"),
        BackgroundGradient(id: "flamingo",      name: "Flamingo",
            lightFromHex: "#EE9CA7", lightToHex: "#FFDDE1",
            darkFromHex:  "#4A2830", darkToHex:  "#4E3840"),

        // ── Elegant & Neutral ─────────────────────────────────
        BackgroundGradient(id: "silver-lining", name: "Silver Lining",
            lightFromHex: "#D7D2CC", lightToHex: "#304352",
            darkFromHex:  "#3A3835", darkToHex:  "#141A20"),
        BackgroundGradient(id: "charcoal",      name: "Charcoal",
            lightFromHex: "#C9D6FF", lightToHex: "#E2E2E2",
            darkFromHex:  "#1A2040", darkToHex:  "#1E1E22"),
        BackgroundGradient(id: "dusty-rose",    name: "Dusty Rose",
            lightFromHex: "#D4A5A5", lightToHex: "#F0E6E6",
            darkFromHex:  "#3E2020", darkToHex:  "#2E2828"),
        BackgroundGradient(id: "sandstone",     name: "Sandstone",
            lightFromHex: "#EACDA3", lightToHex: "#D6AE7B",
            darkFromHex:  "#3A3020", darkToHex:  "#3E2E1A"),

        // ── Vivid ─────────────────────────────────────────────
        BackgroundGradient(id: "electric",      name: "Electric",
            lightFromHex: "#4568DC", lightToHex: "#B06AB3",
            darkFromHex:  "#1A2250", darkToHex:  "#3A1A40"),
        BackgroundGradient(id: "neon-glow",     name: "Neon Glow",
            lightFromHex: "#FA8BFF", lightToHex: "#2BD2FF",
            darkFromHex:  "#501858", darkToHex:  "#0E3848"),
        BackgroundGradient(id: "aurora",        name: "Aurora",
            lightFromHex: "#36D1DC", lightToHex: "#5B86E5",
            darkFromHex:  "#0E3840", darkToHex:  "#1A2850"),
    ]

    static func find(_ id: String) -> BackgroundGradient? {
        all.first { $0.id == id }
    }
}

enum ListBackground: Codable, Equatable {
    case gradient(String) // BackgroundGradient id

    func resolved() -> BackgroundGradient? {
        if case .gradient(let id) = self {
            return BackgroundGradient.find(id)
        }
        return nil
    }
}
