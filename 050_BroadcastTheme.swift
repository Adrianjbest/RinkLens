// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Combine

// MARK: - STYLE1 Central Appearance / Design System

/// Operator-facing look presets used by Settings -> Appearance.
/// These are app chrome styles only. Broadcast output overlays still use the
/// COMPOSITE standard so recordings/clips/streams stay predictable.
enum RinkLensLookPreset: String, CaseIterable, Identifiable {
    case broadcastDark
    case iceBlue
    case highContrast
    case warmArena

    var id: String { rawValue }

    var title: String {
        switch self {
        case .broadcastDark: return "Broadcast Dark"
        case .iceBlue: return "Ice Blue"
        case .highContrast: return "High Contrast"
        case .warmArena: return "Warm Arena"
        }
    }

    var subtitle: String {
        switch self {
        case .broadcastDark: return "Premium dark control-room style"
        case .iceBlue: return "Cool rink-side blue interface"
        case .highContrast: return "Maximum readability in bright rinks"
        case .warmArena: return "Warmer amber-accented operations view"
        }
    }
}

/// Central app appearance settings. STYLE1 keeps these in one place so menus,
/// setup screens and diagnostics can converge on the same typography, colours
/// and control treatment rather than each screen inventing its own style.
final class RinkLensAppearanceSettings: ObservableObject {
    static let shared = RinkLensAppearanceSettings()

    private enum Keys {
        static let preset = "RinkLensAppearanceSettings.preset"
        static let accent = "RinkLensAppearanceSettings.accent"
        static let background = "RinkLensAppearanceSettings.background"
        static let panel = "RinkLensAppearanceSettings.panel"
        static let fontScale = "RinkLensAppearanceSettings.fontScale"
        static let cornerRadius = "RinkLensAppearanceSettings.cornerRadius"
        static let highContrast = "RinkLensAppearanceSettings.highContrast"
    }

    @Published var preset: RinkLensLookPreset {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: Keys.preset) }
    }

    @Published private(set) var accentRGBA: String {
        didSet { UserDefaults.standard.set(accentRGBA, forKey: Keys.accent) }
    }

    @Published private(set) var backgroundRGBA: String {
        didSet { UserDefaults.standard.set(backgroundRGBA, forKey: Keys.background) }
    }

    @Published private(set) var panelRGBA: String {
        didSet { UserDefaults.standard.set(panelRGBA, forKey: Keys.panel) }
    }

    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(min(1.20, max(0.88, fontScale)), forKey: Keys.fontScale) }
    }

    @Published var cornerRadius: Double {
        didSet { UserDefaults.standard.set(min(30.0, max(10.0, cornerRadius)), forKey: Keys.cornerRadius) }
    }

    @Published var highContrastText: Bool {
        didSet { UserDefaults.standard.set(highContrastText, forKey: Keys.highContrast) }
    }

    private init() {
        let savedPreset = UserDefaults.standard.string(forKey: Keys.preset)
        preset = RinkLensLookPreset(rawValue: savedPreset ?? "") ?? .broadcastDark
        accentRGBA = UserDefaults.standard.string(forKey: Keys.accent) ?? "0.0000,0.6400,1.0000,1.0000"
        backgroundRGBA = UserDefaults.standard.string(forKey: Keys.background) ?? "0.0150,0.0250,0.0550,1.0000"
        panelRGBA = UserDefaults.standard.string(forKey: Keys.panel) ?? "0.0400,0.0700,0.1200,1.0000"
        fontScale = UserDefaults.standard.object(forKey: Keys.fontScale) as? Double ?? 1.0
        cornerRadius = UserDefaults.standard.object(forKey: Keys.cornerRadius) as? Double ?? 22.0
        highContrastText = UserDefaults.standard.object(forKey: Keys.highContrast) as? Bool ?? false
    }

    var accentColor: Color { Color(rgbaString: accentRGBA) ?? .cyan }
    var backgroundColor: Color { Color(rgbaString: backgroundRGBA) ?? Color(red: 0.015, green: 0.025, blue: 0.055) }
    var panelColor: Color { Color(rgbaString: panelRGBA) ?? Color(red: 0.04, green: 0.07, blue: 0.12) }

    var primaryText: Color { highContrastText ? .white : Color.white.opacity(0.96) }
    var secondaryText: Color { highContrastText ? Color.white.opacity(0.86) : Color.white.opacity(0.66) }
    var mutedText: Color { highContrastText ? Color.white.opacity(0.72) : Color.white.opacity(0.54) }

    var summaryText: String {
        "\(preset.title); accent=\(accentRGBA); fontScale=\(String(format: "%.2f", fontScale)); radius=\(Int(cornerRadius)); highContrast=\(highContrastText ? "on" : "off")"
    }

    func setAccentColor(_ color: Color) {
        accentRGBA = color.rgbaString
    }

    func setBackgroundColor(_ color: Color) {
        backgroundRGBA = color.rgbaString
    }

    func setPanelColor(_ color: Color) {
        panelRGBA = color.rgbaString
    }

    func applyPreset(_ newPreset: RinkLensLookPreset) {
        preset = newPreset
        switch newPreset {
        case .broadcastDark:
            accentRGBA = "0.0000,0.6400,1.0000,1.0000"
            backgroundRGBA = "0.0150,0.0250,0.0550,1.0000"
            panelRGBA = "0.0400,0.0700,0.1200,1.0000"
            highContrastText = false
        case .iceBlue:
            accentRGBA = "0.3800,0.7100,0.9000,1.0000"
            backgroundRGBA = "0.0110,0.0420,0.0900,1.0000"
            panelRGBA = "0.0300,0.0950,0.1600,1.0000"
            highContrastText = false
        case .highContrast:
            accentRGBA = "1.0000,0.8700,0.0000,1.0000"
            backgroundRGBA = "0.0000,0.0000,0.0000,1.0000"
            panelRGBA = "0.0250,0.0250,0.0250,1.0000"
            highContrastText = true
        case .warmArena:
            accentRGBA = "1.0000,0.5600,0.1200,1.0000"
            backgroundRGBA = "0.0500,0.0250,0.0150,1.0000"
            panelRGBA = "0.1150,0.0600,0.0300,1.0000"
            highContrastText = false
        }
    }

    func resetToDefault() {
        fontScale = 1.0
        cornerRadius = 22.0
        applyPreset(.broadcastDark)
    }
}

/// Shared typography and chrome tokens for non-broadcast operator screens.
/// Use these for menus, settings, diagnostics, media and setup screens. Keep
/// broadcast output-specific layout in COMPOSITE/Scorebug code.
enum RinkLensDesignSystem {
    static var appearance: RinkLensAppearanceSettings { .shared }

    static func font(_ role: RinkLensTextRole) -> Font {
        role.font(scale: appearance.fontScale)
    }

    static var screenBackground: LinearGradient {
        LinearGradient(
            colors: [
                appearance.backgroundColor,
                appearance.panelColor.opacity(0.92),
                Color.black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var accentGlow: RadialGradient {
        RadialGradient(
            colors: [appearance.accentColor.opacity(0.24), Color.clear],
            center: .topTrailing,
            startRadius: 80,
            endRadius: 620
        )
    }

    static var cardBackground: Color { appearance.panelColor.opacity(0.46) }
    static var controlBackground: Color { Color.white.opacity(0.08) }
    static var border: Color { Color.white.opacity(0.12) }
    static var primaryText: Color { appearance.primaryText }
    static var secondaryText: Color { appearance.secondaryText }
    static var mutedText: Color { appearance.mutedText }
    static var accent: Color { appearance.accentColor }

    static var cardCornerRadius: CGFloat { CGFloat(appearance.cornerRadius) }
    static var controlCornerRadius: CGFloat { max(10, CGFloat(appearance.cornerRadius) * 0.58) }
}

enum RinkLensTextRole {
    case screenTitle
    case sectionTitle
    case cardTitle
    case body
    case bodyStrong
    case caption
    case micro
    case monoCaption

    func font(scale: Double) -> Font {
        let s = CGFloat(scale)
        switch self {
        case .screenTitle:
            return .system(size: 34 * s, weight: .black, design: .rounded)
        case .sectionTitle:
            return .system(size: 20 * s, weight: .heavy, design: .rounded)
        case .cardTitle:
            return .system(size: 17 * s, weight: .heavy, design: .rounded)
        case .body:
            return .system(size: 15 * s, weight: .medium, design: .rounded)
        case .bodyStrong:
            return .system(size: 15 * s, weight: .bold, design: .rounded)
        case .caption:
            return .system(size: 12 * s, weight: .semibold, design: .rounded)
        case .micro:
            return .system(size: 10 * s, weight: .bold, design: .rounded)
        case .monoCaption:
            return .system(size: 12 * s, weight: .semibold, design: .monospaced)
        }
    }
}

extension View {
    func rinkLensScreenChrome() -> some View {
        self
            .font(RinkLensDesignSystem.font(.body))
            .foregroundStyle(RinkLensDesignSystem.primaryText)
    }
}



// MARK: - STYLE2 Legacy Operator Screen Migration Helpers

/// STYLE2 keeps older setup, media, sponsor, camera and OCR screens on the same
/// app-chrome contract without changing the COMPOSITE broadcast output renderer.
/// Apply this to operator screens and sheets that previously carried their own
/// local fonts/colours so Settings -> Appearance can influence them centrally.
struct RinkLensOperatorChromeModifier: ViewModifier {
    @ObservedObject private var appearance = RinkLensAppearanceSettings.shared
    let screenName: String?

    func body(content: Content) -> some View {
        content
            .font(RinkLensDesignSystem.font(.body))
            .foregroundStyle(RinkLensDesignSystem.primaryText)
            .tint(RinkLensDesignSystem.accent)
            .preferredColorScheme(.dark)
            .id("style2-\(screenName ?? "operator")-\(appearance.summaryText)")
    }
}

struct RinkLensPanelChromeModifier: ViewModifier {
    @ObservedObject private var appearance = RinkLensAppearanceSettings.shared

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(RinkLensDesignSystem.cardBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous)
                    .stroke(RinkLensDesignSystem.border, lineWidth: 1)
            )
            .id("style2-panel-\(appearance.summaryText)")
    }
}

struct RinkLensControlPillModifier: ViewModifier {
    @ObservedObject private var appearance = RinkLensAppearanceSettings.shared
    var filled: Bool = false

    func body(content: Content) -> some View {
        content
            .font(RinkLensDesignSystem.font(.caption))
            .foregroundStyle(filled ? Color.black : RinkLensDesignSystem.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(filled ? RinkLensDesignSystem.accent : RinkLensDesignSystem.controlBackground, in: Capsule())
            .overlay(Capsule().stroke(RinkLensDesignSystem.border, lineWidth: 1))
            .id("style2-pill-\(appearance.summaryText)")
    }
}

extension View {
    func rinkLensOperatorChrome(_ screenName: String? = nil) -> some View {
        modifier(RinkLensOperatorChromeModifier(screenName: screenName))
    }

    func rinkLensPanelChrome() -> some View {
        modifier(RinkLensPanelChromeModifier())
    }

    func rinkLensControlPill(filled: Bool = false) -> some View {
        modifier(RinkLensControlPillModifier(filled: filled))
    }

    func rinkLensSectionHeading() -> some View {
        self
            .font(RinkLensDesignSystem.font(.sectionTitle))
            .foregroundStyle(RinkLensDesignSystem.primaryText)
    }

    func rinkLensCaptionText() -> some View {
        self
            .font(RinkLensDesignSystem.font(.caption))
            .foregroundStyle(RinkLensDesignSystem.secondaryText)
    }
}

/// Lightweight coverage marker used by diagnostics/build notes to show which
/// legacy screens are in scope for STYLE2 migration.
enum RinkLensStyle2Coverage {
    static let migratedScreens = [
        "Sponsors", "Media", "Stream Setup", "Camera Setup", "OCR Setup",
        "Calibration", "Calibration Control Hub", "Advanced OCR", "Live Camera Settings",
        "Recording Panels", "Recording Media Browser", "Broadcast Operator Controls",
        "Diagnostics subpanels"
    ]

    static var summary: String {
        "STYLE2 migrated operator chrome: " + migratedScreens.joined(separator: ", ")
    }
}



// MARK: - UX2 Shared Heavy-Screen Scroll Performance Standard

/// UX2 defines the standard used by heavy operator screens: lazy content,
/// stable scroll behaviour, no implicit scroll animations and low-noise refreshes.
/// It is intentionally UI-only and must not touch camera, OCR, recording,
/// clip-buffer or COMPOSITE broadcast output paths.
enum RinkLensScrollPerformancePolicy {
    static let statusRefreshMinimumInterval: TimeInterval = 2.0
    static let diagnosticsRefreshMinimumInterval: TimeInterval = 1.25
    static let mediaRefreshMinimumInterval: TimeInterval = 2.0

    static let coveredScreens = [
        "Media", "Sponsors", "Settings", "Diagnostics", "Recording",
        "Recording Media Browser", "Stream Setup", "Stream Destination",
        "Camera Setup", "OCR Setup", "Calibration Control Hub",
        "Advanced OCR", "Sponsor Assignment", "Clip / Recording History"
    ]

    static var summary: String {
        "UX2 lazy-scroll standard: " + coveredScreens.joined(separator: ", ")
    }
}

struct RinkLensScrollPerformanceModifier: ViewModifier {
    let screenName: String

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.visible)
            .scrollDismissesKeyboard(.interactively)
            .transaction { transaction in
                // Heavy list screens should not re-animate every thumbnail,
                // diagnostic row or setting card while the operator scrolls.
                transaction.animation = nil
            }
            .accessibilityIdentifier("rinklens-ux2-scroll-\(screenName)")
    }
}

extension View {
    func rinkLensHeavyScreenContent(maxWidth: CGFloat = 1160, horizontal: CGFloat = 24, vertical: CGFloat = 22) -> some View {
        self
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: maxWidth, alignment: .center)
            .frame(maxWidth: .infinity)
    }

    func rinkLensScrollPerformance(_ screenName: String) -> some View {
        modifier(RinkLensScrollPerformanceModifier(screenName: screenName))
    }
}

// MARK: - Phase 1 Broadcast Theme

/// Public broadcast design constants.
/// This must remain viewer-safe: no OCR debug, calibration boxes or operator controls.
enum BroadcastTheme {
    static var background: Color { RinkLensDesignSystem.appearance.backgroundColor }
    static var panel: Color { RinkLensDesignSystem.appearance.panelColor }
    static let glass = Color.black.opacity(0.68)
    static let glassStrong = Color.black.opacity(0.82)
    static var primaryText: Color { RinkLensDesignSystem.primaryText }
    static var secondaryText: Color { RinkLensDesignSystem.secondaryText }
    static var homeAccent: Color { RinkLensDesignSystem.accent }
    static let awayAccent = Color(red: 1.0, green: 0.23, blue: 0.31)
    static let clockAccent = Color(red: 1.0, green: 0.82, blue: 0.25)
    static let penaltyAccent = Color(red: 1.0, green: 0.48, blue: 0.0)
    static let liveAccent = Color(red: 0.14, green: 0.90, blue: 0.54)
    static var border: Color { RinkLensDesignSystem.accent.opacity(0.72) }
    static var shadow: Color { RinkLensDesignSystem.accent.opacity(0.35) }

    static var scorebugCornerRadius: CGFloat { max(14, min(30, RinkLensDesignSystem.cardCornerRadius)) }
    static let scorebugWidth: CGFloat = 600
    static let compactScorebugWidth: CGFloat = 360

    // UX16d18: reserve the integrated utility + team penalty/manpower scorebug
    // height. The old value only covered the main team row and clipped the new
    // OCR LIVE/game-sponsor rail or penalty details in SwiftUI previews.
    static let broadcastScorebugScale: CGFloat = 0.50
    static let broadcastScorebugScaledWidth: CGFloat = scorebugWidth * broadcastScorebugScale
    static let broadcastScorebugScaledHeight: CGFloat = 112
}

#endif
