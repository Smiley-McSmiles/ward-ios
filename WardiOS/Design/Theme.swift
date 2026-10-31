import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let red = Double((number >> 16) & 0xFF) / 255
        let green = Double((number >> 8) & 0xFF) / 255
        let blue = Double(number & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    func mix(with other: Color, by amount: Double) -> Color {
        let a = UIColor(self)
        let b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(.sRGB,
                     red: Double(r1 + (r2 - r1) * t),
                     green: Double(g1 + (g2 - g1) * t),
                     blue: Double(b1 + (b2 - b1) * t),
                     opacity: Double(a1 + (a2 - a1) * t))
    }
}

enum WardAccent: String, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple, slate
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: return Color(hex: "#3584E4")
        case .teal: return Color(hex: "#2190A4")
        case .green: return Color(hex: "#3A944A")
        case .yellow: return Color(hex: "#C88800")
        case .orange: return Color(hex: "#ED5B00")
        case .red: return Color(hex: "#E62D42")
        case .pink: return Color(hex: "#D56199")
        case .purple: return Color(hex: "#9141AC")
        case .slate: return Color(hex: "#6F8396")
        }
    }
    var name: String {
        switch self {
        case .blue: return "Blue"; case .teal: return "Teal"; case .green: return "Green"
        case .yellow: return "Yellow"; case .orange: return "Orange"; case .red: return "Red"
        case .pink: return "Pink"; case .purple: return "Purple"; case .slate: return "Slate"
        }
    }
}

struct WardPalette {
    var dark: Bool
    var accent: Color
    var onAccent: Color
    var background: Color
    var backgroundElevated: Color
    var surface: Color
    var surfaceContainer: Color
    var surfaceVariant: Color
    var text: Color
    var secondaryText: Color
    var tertiaryText: Color
    var outline: Color
    var outgoingBubble: Color
    var outgoingText: Color
    var incomingBubble: Color
    var incomingText: Color
    var danger: Color
    var success: Color
    var warning: Color

    init(accentName: String, dark: Bool) {
        let accent = (WardAccent(rawValue: accentName) ?? .blue).color
        let resolved = dark ? accent.mix(with: .white, by: 0.34) : accent
        self.dark = dark
        self.accent = resolved
        self.onAccent = resolved.isBright ? Color(hex: "#15161A") : .white
        if dark {
            background = Color(hex: "#18151D")
            backgroundElevated = Color(hex: "#211D28")
            surface = Color(hex: "#221E28")
            surfaceContainer = Color(hex: "#2D2834")
            surfaceVariant = Color(hex: "#3B3544")
            text = Color(hex: "#EEEAEF")
            secondaryText = Color(hex: "#B6AFBC")
            tertiaryText = Color(hex: "#8E8795")
            outline = Color(hex: "#4A4451")
            outgoingBubble = resolved.mix(with: Color(hex: "#221E28"), by: 0.22)
            outgoingText = resolved.isBright ? Color(hex: "#15161A") : .white
            incomingBubble = Color(hex: "#2B2632")
            incomingText = Color(hex: "#EEEAEF")
            danger = Color(hex: "#FF6B6B")
            success = Color(hex: "#58C46A")
            warning = Color(hex: "#F4B740")
        } else {
            background = Color(hex: "#F5F5FA")
            backgroundElevated = Color(hex: "#FFFFFF")
            surface = Color(hex: "#FFFFFF")
            surfaceContainer = Color(hex: "#F0EFF5")
            surfaceVariant = Color(hex: "#E6E4ED")
            text = Color(hex: "#17171C")
            secondaryText = Color(hex: "#55545F")
            tertiaryText = Color(hex: "#85838F")
            outline = Color(hex: "#D4D1DC")
            outgoingBubble = resolved
            outgoingText = resolved.isBright ? Color(hex: "#15161A") : .white
            incomingBubble = Color(hex: "#FFFFFF")
            incomingText = Color(hex: "#17171C")
            danger = Color(hex: "#D92D3F")
            success = Color(hex: "#2E8B3D")
            warning = Color(hex: "#A66A00")
        }
    }

    var orange: Color { WardAccent.orange.color }
    var pink: Color { WardAccent.pink.color }
    var purple: Color { WardAccent.purple.color }
    var slate: Color { WardAccent.slate.color }
    var blue: Color { WardAccent.blue.color }
    var green: Color { WardAccent.green.color }
    var red: Color { WardAccent.red.color }
    var teal: Color { WardAccent.teal.color }
    var yellow: Color { WardAccent.yellow.color }

    func presenceColor(_ show: String) -> Color {
        switch show {
        case "online", "available", "chat": return success
        case "away": return warning
        case "dnd": return danger
        case "xa": return Color(hex: "#D08A00")
        default: return tertiaryText
        }
    }
}

private struct WardPaletteKey: EnvironmentKey {
    static let defaultValue = WardPalette(accentName: "blue", dark: false)
}

extension EnvironmentValues {
    var ward: WardPalette {
        get { self[WardPaletteKey.self] }
        set { self[WardPaletteKey.self] = newValue }
    }
}

extension Color {
    var isBright: Bool {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.55
    }
}

struct WardThemeModifier: ViewModifier {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let dark: Bool
        switch settings.string("appearance.style", "system") {
        case "dark": dark = true
        case "light": dark = false
        default: dark = systemScheme == .dark
        }
        let palette = WardPalette(accentName: settings.accentName, dark: dark)
        content
            .environment(\.ward, palette)
            .tint(palette.accent)
            .preferredColorScheme(settings.string("appearance.style", "system") == "system" ? nil : (dark ? .dark : .light))
            .dynamicTypeSize(dynamicTypeSize(for: settings.int("appearance.text_scale")))
    }

    private func dynamicTypeSize(for percent: Int) -> DynamicTypeSize {
        switch percent {
        case ..<90: return .small
        case 90..<105: return .large
        case 105..<120: return .xLarge
        case 120..<140: return .xxLarge
        case 140..<170: return .xxxLarge
        case 170..<190: return .accessibility1
        default: return .accessibility2
        }
    }
}

extension View {
    func wardTheme() -> some View { modifier(WardThemeModifier()) }
}
