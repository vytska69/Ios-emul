import SwiftUI
import EmulatorKit

/// Colour schemes the app can be shown in (Settings → Appearance).
enum AppTheme: String, CaseIterable, Identifiable {
    case aurora, ember, circuit, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .circuit: return "Circuit"
        case .mono: return "Mono"
        }
    }

    /// Two colours the gradients, glows and accents are built from.
    var colors: (Color, Color) {
        switch self {
        case .aurora: return (Color(red: 0.18, green: 0.85, blue: 0.95), Color(red: 0.55, green: 0.36, blue: 1.0))
        case .ember: return (Color(red: 1.0, green: 0.55, blue: 0.2), Color(red: 0.95, green: 0.2, blue: 0.45))
        case .circuit: return (Color(red: 0.3, green: 1.0, blue: 0.55), Color(red: 0.1, green: 0.6, blue: 0.9))
        case .mono: return (Color(white: 0.95), Color(white: 0.55))
        }
    }

    var accent: Color { colors.0 }
    var gradient: LinearGradient { gradient(opacity: 1) }

    /// The gradient faded (gradient.opacity would be ambiguous between View and ShapeStyle).
    func gradient(opacity: Double) -> LinearGradient {
        LinearGradient(colors: [colors.0.opacity(opacity), colors.1.opacity(opacity)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.aurora
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Deep background with two slow colour blooms in the theme's colours.
struct AppBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.07)
            Circle().fill(theme.colors.0.opacity(0.22)).frame(width: 420).blur(radius: 120)
                .offset(x: -160, y: -320)
            Circle().fill(theme.colors.1.opacity(0.2)).frame(width: 460).blur(radius: 140)
                .offset(x: 180, y: 360)
        }
        .ignoresSafeArea()
    }
}

/// Glassy rounded panel used for every group of content.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

/// Small spaced-out caption above a card.
struct SectionLabel: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            Text(text.uppercased()).tracking(1.4)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.leading, 4)
    }
}

/// Coloured capsule label (compatibility, "Signed", "Emulated" …).
struct Chip: View {
    let text: String
    var color: Color = .white
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25)))
    }
}

extension Compatibility {
    var color: Color {
        switch self {
        case .supported: return .green
        case .experimental: return .orange
        case .unsupported: return .red
        }
    }

    var label: String {
        switch self {
        case .supported: return "Supported"
        case .experimental: return "Experimental"
        case .unsupported: return "Unsupported"
        }
    }
}

/// The main call to action: a glowing gradient capsule.
struct GlowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black.opacity(0.85))
            .padding(.vertical, 14).padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background(theme.gradient, in: Capsule())
            .shadow(color: theme.colors.0.opacity(enabled ? 0.45 : 0), radius: 16, y: 6)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary action: outlined capsule.
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.accent)
            .padding(.vertical, 10).padding(.horizontal, 16)
            .background(theme.accent.opacity(configuration.isPressed ? 0.2 : 0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35)))
    }
}

/// Thin gradient progress bar.
struct GlowBar: View {
    @Environment(\.theme) private var theme
    let value: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                if let value {
                    Capsule().fill(theme.gradient)
                        .frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
                        .shadow(color: theme.colors.0.opacity(0.6), radius: 6)
                } else {
                    Capsule().fill(theme.gradient).frame(width: geo.size.width * 0.3).opacity(0.6)
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}

/// Circular gauge for percentages (hardware coverage).
struct RingGauge: View {
    @Environment(\.theme) private var theme
    let value: Double
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: 8)
            Circle().trim(from: 0, to: min(max(value, 0), 1))
                .stroke(AngularGradient(colors: [theme.colors.0, theme.colors.1, theme.colors.0], center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(.headline, design: .rounded).weight(.bold))
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// Key/value line inside a card.
struct InfoRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Rounded square with an SF Symbol on the theme gradient.
struct GlyphTile: View {
    @Environment(\.theme) private var theme
    let symbol: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.black.opacity(0.8))
            .frame(width: size, height: size)
            .background(theme.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A badge for one iOS release: its major version on a gradient in the colours that release is
/// remembered by (its default wallpaper and keynote art). Our own drawing; no Apple artwork.
struct VersionBadge: View {
    let version: String
    var size: CGFloat = 44

    private var major: Int { Int(version.split(separator: ".").first ?? "") ?? 0 }

    var body: some View {
        let colors = Self.palette(major)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            Text(major > 0 ? "\(major)" : "?")
                .font(.system(size: size * (major >= 10 ? 0.5 : 0.58), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .accessibilityHidden(true)
    }

    static func palette(_ major: Int) -> [Color] {
        func c(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
        }
        switch major {
        case 1, 2, 3: return [c(0x8E9AAB), c(0x3A4556)]   // iPhone OS: brushed metal
        case 4: return [c(0x4A90E2), c(0x1C3F94)]
        case 5: return [c(0x5AC8FA), c(0x1D62C4)]
        case 6: return [c(0x7FA7D6), c(0x2B4C7E)]
        case 7: return [c(0x34C3F0), c(0xC643FC), c(0xFF5E3A)]
        case 8: return [c(0x5856D6), c(0x0A84FF)]
        case 9: return [c(0x1AD6FD), c(0x1D62F0)]
        case 10: return [c(0xFF9500), c(0xFF2D55), c(0x5856D6)]
        case 11: return [c(0x0A84FF), c(0x7A1FD1)]
        case 12: return [c(0xFFB340), c(0xFF3B30)]
        case 13: return [c(0x5E5CE6), c(0x1C1C72)]
        case 14: return [c(0x30D5C8), c(0x0A60FF)]
        case 15: return [c(0x64D2FF), c(0x5E5CE6), c(0xBF5AF2)]
        case 16: return [c(0x0A84FF), c(0x2E1A8A)]
        case 17: return [c(0xFF6482), c(0xFF9F0A)]
        case 18: return [c(0x00C7FF), c(0x7D5CFF), c(0xFF4FD8)]
        case 19...: return [c(0xB8F1FF), c(0x4FA8FF), c(0x7B6CFF)]  // iOS 26: Liquid Glass
        default: return [c(0x636366), c(0x2C2C2E)]
        }
    }
}

extension View {
    /// Dark screen chrome shared by every tab.
    func screenStyle() -> some View {
        background(AppBackground())
            .scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// SF Symbol for a product family.
func deviceSymbol(for productType: String) -> String {
    if productType.hasPrefix("iPad") { return "ipad" }
    if productType.hasPrefix("iPod") { return "ipodtouch" }
    return "iphone"
}
