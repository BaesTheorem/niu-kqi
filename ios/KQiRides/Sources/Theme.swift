import SwiftUI

/// MD3 tonal roles themed to the house taste: square corners, no shadows,
/// hairline outlines and tonal surfaces instead of elevation.
enum T {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let primary        = dyn(0x006C4C, 0x63DBAC)
    static let onPrimary      = dyn(0xFFFFFF, 0x003824)
    static let primaryContainer = dyn(0x85F8CA, 0x005138)
    static let onPrimaryContainer = dyn(0x002114, 0x85F8CA)

    static let surface        = dyn(0xF5FBF6, 0x0E1512)
    static let surfaceContainer = dyn(0xE9EFEA, 0x1A211D)
    static let surfaceContainerHigh = dyn(0xE3E9E4, 0x242B27)
    static let onSurface      = dyn(0x171D1A, 0xDEE4DF)
    static let onSurfaceVariant = dyn(0x3F4945, 0xBFC9C3)

    static let outline        = dyn(0xCBD5CF, 0x333B37)
    static let outlineStrong  = dyn(0x6F7975, 0x899390)

    static let error          = dyn(0xBA1A1A, 0xFFB4AB)
    static let errorContainer = dyn(0xFFDAD6, 0x93000A)
    static let onErrorContainer = dyn(0x410002, 0xFFDAD6)

    static let warn           = dyn(0x7A5900, 0xF6BF3E)
    static let warnContainer  = dyn(0xFFDF9A, 0x5C4200)
    static let onWarnContainer = dyn(0x261A00, 0xFFDF9A)

    static let hairline: CGFloat = 1
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A Material Symbols (Sharp cut) glyph. Ligature-based, so the icon name is
/// the literal text. Never an emoji, per the house icon rule.
struct Icon: View {
    let name: String
    var size: CGFloat = 22
    init(_ name: String, size: CGFloat = 22) { self.name = name; self.size = size }
    var body: some View {
        Text(name)
            .font(.custom("MaterialSymbolsSharp-Regular", size: size))
            .accessibilityHidden(true)
    }
}

/// Flat, sharp, outlined container: the only surface primitive this app uses.
struct Panel<Content: View>: View {
    var tone: Color = T.surfaceContainer
    var border: Color = T.outline
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone)
            .overlay(Rectangle().strokeBorder(border, lineWidth: T.hairline))
    }
}

/// Section label in the flat style: small, tracked, muted.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(T.onSurfaceVariant)
    }
}

/// A big number with a unit and a caption, used across the dashboard and stats.
struct Stat: View {
    let value: String
    var unit: String = ""
    let caption: String
    var tint: Color = T.onSurface
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(T.onSurfaceVariant)
                }
            }
            Text(caption).font(.system(size: 12)).foregroundStyle(T.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Outlined button, the house default over filled/elevated.
struct OutlineButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = T.onSurface
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Icon(icon, size: 18) }
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(enabled ? tint : T.outlineStrong)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .overlay(Rectangle().strokeBorder(enabled ? T.outlineStrong : T.outline, lineWidth: T.hairline))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
