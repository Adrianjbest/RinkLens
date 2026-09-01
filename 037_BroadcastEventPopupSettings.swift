// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit

// MARK: - RinkLens NextGen S12J Event Popup Settings

/// Operator-facing event popup controls exposed through
/// Command Centre -> Settings -> Broadcast Setup -> Event Popups.
///
/// S12J keeps actual team names enabled by default after migration so
/// existing installs do not stay stuck on the old HOME / AWAY labels.
@MainActor
final class BroadcastEventPopupSettings: ObservableObject {
    static let shared = BroadcastEventPopupSettings()

    @Published private(set) var policy: BroadcastEventPopupPolicySnapshot

    var goalPopupsEnabled: Bool {
        get { policy.goalPopupsEnabled }
        set { mutate(field: "goalPopupsEnabled", source: "BroadcastEventPopupSettings", reason: "Operator popup configuration mutation") { $0.goalPopupsEnabled = newValue } }
    }
    var penaltyPopupsEnabled: Bool {
        get { policy.penaltyPopupsEnabled }
        set { mutate(field: "penaltyPopupsEnabled", source: "BroadcastEventPopupSettings", reason: "Operator popup configuration mutation") { $0.penaltyPopupsEnabled = newValue } }
    }
    var goalTeamLogosEnabled: Bool {
        get { policy.goalTeamLogosEnabled }
        set { mutate(field: "goalTeamLogosEnabled", source: "BroadcastEventPopupSettings", reason: "Operator popup configuration mutation") { $0.goalTeamLogosEnabled = newValue } }
    }
    var penaltyTeamLogosEnabled: Bool {
        get { policy.penaltyTeamLogosEnabled }
        set { mutate(field: "penaltyTeamLogosEnabled", source: "BroadcastEventPopupSettings", reason: "Operator popup configuration mutation") { $0.penaltyTeamLogosEnabled = newValue } }
    }
    var useActualTeamNames: Bool {
        get { policy.useActualTeamNames }
        set { mutate(field: "useActualTeamNames", source: "BroadcastEventPopupSettings", reason: "Operator popup configuration mutation") { $0.useActualTeamNames = newValue } }
    }
    var popupDurationSeconds: Double {
        get { policy.popupDurationSeconds }
        set { mutate(field: "popupDurationSeconds", source: "BroadcastEventPopupSettings", reason: "Operator popup duration mutation") { $0.popupDurationSeconds = min(max(newValue, 2.0), 12.0) } }
    }

    var useTeamLogos: Bool { goalTeamLogosEnabled && penaltyTeamLogosEnabled }

    private init() {
        let defaults = UserDefaults.standard
        let legacyLogos = defaults.object(forKey: Keys.legacyUseTeamLogos) as? Bool ?? true
        let goal = defaults.object(forKey: Keys.goalPopupsEnabled) as? Bool ?? true
        let penalty = defaults.object(forKey: Keys.penaltyPopupsEnabled) as? Bool ?? true
        let goalLogos = defaults.object(forKey: Keys.goalTeamLogosEnabled) as? Bool ?? legacyLogos
        let penaltyLogos = defaults.object(forKey: Keys.penaltyTeamLogosEnabled) as? Bool ?? legacyLogos
        let migrationApplied = defaults.bool(forKey: Keys.actualNamesMigrationApplied)
        let actualNames: Bool
        if migrationApplied {
            actualNames = defaults.object(forKey: Keys.useActualTeamNames) as? Bool ?? true
        } else {
            actualNames = true
            defaults.set(true, forKey: Keys.useActualTeamNames)
            defaults.set(true, forKey: Keys.actualNamesMigrationApplied)
        }
        let duration = min(max(defaults.object(forKey: Keys.popupDurationSeconds) as? Double ?? 6.0, 2.0), 12.0)
        policy = BroadcastEventPopupPolicySnapshot(
            goalPopupsEnabled: goal,
            penaltyPopupsEnabled: penalty,
            goalTeamLogosEnabled: goalLogos,
            penaltyTeamLogosEnabled: penaltyLogos,
            useActualTeamNames: actualNames,
            popupDurationSeconds: duration
        )
    }

    var snapshot: BroadcastEventPopupPolicySnapshot { policy }

    var summaryText: String {
        let goal = goalPopupsEnabled ? "Goals on" : "Goals off"
        let penalty = penaltyPopupsEnabled ? "Penalties on" : "Penalties off"
        let goalLogo = goalTeamLogosEnabled ? "goal logos" : "goal no logo"
        let penaltyLogo = penaltyTeamLogosEnabled ? "penalty logos" : "penalty no logo"
        let names = useActualTeamNames ? "actual names" : "HOME/AWAY"
        return "\(goal) · \(penalty) · \(Int(popupDurationSeconds))s · \(goalLogo) · \(penaltyLogo) · \(names)"
    }

    func isEnabled(for eventType: BroadcastEventType) -> Bool { policy.isEnabled(for: eventType) }
    func teamLogosEnabled(for eventType: BroadcastEventType) -> Bool { policy.teamLogosEnabled(for: eventType) }

    func resetToDefaults() {
        apply(
            BroadcastEventPopupPolicySnapshot(
                goalPopupsEnabled: true,
                penaltyPopupsEnabled: true,
                goalTeamLogosEnabled: true,
                penaltyTeamLogosEnabled: true,
                useActualTeamNames: true,
                popupDurationSeconds: 6.0
            ),
            source: "BroadcastEventPopupSettings",
            reason: "Operator reset popup configuration atomically"
        )
    }

    func apply(_ next: BroadcastEventPopupPolicySnapshot, source: String, reason: String) {
        let previous = policy
        var clamped = next
        clamped.popupDurationSeconds = min(max(clamped.popupDurationSeconds, 2.0), 12.0)
        guard previous != clamped else { return }
        policy = clamped
        persist(clamped)
        RinkLensStructuredEventLogger.shared.record(
            domain: .popupConfiguration,
            event: "popup_policy_changed",
            entityID: "event-popup-policy",
            previous: Self.summary(previous),
            next: Self.summary(clamped),
            source: source,
            reason: reason
        )
    }

    private func mutate(field: String, source: String, reason: String, _ change: (inout BroadcastEventPopupPolicySnapshot) -> Void) {
        var next = policy
        change(&next)
        apply(next, source: source, reason: "\(reason): \(field)")
    }

    private func persist(_ value: BroadcastEventPopupPolicySnapshot) {
        let defaults = UserDefaults.standard
        defaults.set(value.goalPopupsEnabled, forKey: Keys.goalPopupsEnabled)
        defaults.set(value.penaltyPopupsEnabled, forKey: Keys.penaltyPopupsEnabled)
        defaults.set(value.goalTeamLogosEnabled, forKey: Keys.goalTeamLogosEnabled)
        defaults.set(value.penaltyTeamLogosEnabled, forKey: Keys.penaltyTeamLogosEnabled)
        defaults.set(value.useActualTeamNames, forKey: Keys.useActualTeamNames)
        defaults.set(value.popupDurationSeconds, forKey: Keys.popupDurationSeconds)
    }

    private static func summary(_ value: BroadcastEventPopupPolicySnapshot) -> [String: String] {
        [
            "goalPopups": String(value.goalPopupsEnabled),
            "penaltyPopups": String(value.penaltyPopupsEnabled),
            "goalLogos": String(value.goalTeamLogosEnabled),
            "penaltyLogos": String(value.penaltyTeamLogosEnabled),
            "actualNames": String(value.useActualTeamNames),
            "duration": String(value.clampedDurationSeconds)
        ]
    }

    private enum Keys {
        static let prefix = "broadcast.eventPopup."
        static let goalPopupsEnabled = prefix + "goalPopupsEnabled"
        static let penaltyPopupsEnabled = prefix + "penaltyPopupsEnabled"
        static let legacyUseTeamLogos = prefix + "useTeamLogos"
        static let goalTeamLogosEnabled = prefix + "goalTeamLogosEnabled"
        static let penaltyTeamLogosEnabled = prefix + "penaltyTeamLogosEnabled"
        static let useActualTeamNames = prefix + "useActualTeamNames"
        static let actualNamesMigrationApplied = prefix + "actualNamesMigrationApplied.S12J"
        static let popupDurationSeconds = prefix + "popupDurationSeconds"
    }
}


// MARK: - UX6 Shared Event Popup Template Metrics

/// UX6: Settings preview, Broadcast screen and recording/clips must not invent
/// separate event-popup sizes. The SwiftUI views and cached overlay renderer use
/// these same template values so popup logo, text and sponsor spacing do not drift.
enum BroadcastEventPopupTemplateMetrics {
    static let goalWidth: CGFloat = 760
    static let goalHeight: CGFloat = 132
    static let penaltyWidth: CGFloat = 720
    static let penaltyHeight: CGFloat = 118
    static let strengthWidth: CGFloat = 500
    static let strengthHeight: CGFloat = 88
    static let badgeSize: CGFloat = 60
    static let penaltyBadgeSize: CGFloat = 60
    static let badgePadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 16
    static let bodyGap: CGFloat = 14
    static let cornerRadius: CGFloat = 26
    static let goalTitleFont: CGFloat = 20
    static let goalTeamFont: CGFloat = 24
    static let goalScoreFont: CGFloat = 16
    static let penaltyTypeFont: CGFloat = 18
    static let penaltyTeamFont: CGFloat = 33
    static let penaltyHeadlineFont: CGFloat = 19
    static let penaltyDetailFont: CGFloat = 25
    static let sponsorLogoWidth: CGFloat = 42
    static let sponsorLogoHeight: CGFloat = 30
    static let sponsorGap: CGFloat = 5
}


/// Popup-side Clock presentation. When an immutable stopped Image Relay Clock is
/// available it is rendered with the same component and metrics as the live
/// scorebug. Numeric text remains a fallback for non-relay/manual events only.
struct BroadcastEventClockPresentationView: View {
    let event: BroadcastEvent
    let fallbackText: String
    let fallbackFontSize: CGFloat
    let textColour: Color
    var periodFontSize: CGFloat = 13
    var showsPeriod: Bool = true

    @ObservedObject private var layoutSettings = BroadcastScoreboardLayoutSettings.shared

    private var frozenClockImage: CGImage? {
        guard let data = event.frozenClockImagePNGData else { return nil }
        return UIImage(data: data)?.cgImage
    }

    private var clockZoneSize: CGSize {
        let live = BroadcastScorebugTemplateMetrics.desiredClockZoneSize(for: layoutSettings.snapshot)
        // Popup evidence must remain readable at normal Broadcast distance. The
        // source is still the exact frozen physical Clock image; only its display
        // frame is enlarged.
        let height: CGFloat
        let minimumWidth: CGFloat
        if showsPeriod {
            height = max(68, live.height)
            minimumWidth = 218
        } else {
            height = max(42, min(54, live.height))
            minimumWidth = 142
        }
        return CGSize(width: max(minimumWidth, height * BroadcastScorebugTemplateMetrics.clockZoneWidthToHeightRatio), height: height)
    }

    var body: some View {
        Group {
            if let frozenClockImage {
                VStack(alignment: .trailing, spacing: 2) {
                    if showsPeriod {
                        Text(event.period.map { "P\($0)" } ?? "P–")
                            .font(.system(size: periodFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(textColour.opacity(0.76))
                    }
                    BroadcastImageRelayClockView(
                        image: frozenClockImage,
                        colour: layoutSettings.snapshot.clockColour,
                        zoneSize: clockZoneSize,
                        verticalSafetyInset: 2
                    )
                }
            } else if event.period != nil {
                VStack(alignment: .trailing, spacing: 2) {
                    if showsPeriod, let period = event.period {
                        Text("P\(period)")
                            .font(.system(size: periodFontSize, weight: .heavy, design: .rounded))
                            .foregroundStyle(textColour.opacity(0.82))
                    }
                    Text(event.gameClock ?? fallbackText)
                        .font(.system(size: fallbackFontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(textColour)
                        .monospacedDigit()
                }
            } else {
                Text(fallbackText)
                    .font(.system(size: fallbackFontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(textColour)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.gameClock.map { "Period \(event.period ?? 0), Clock \($0)" } ?? "Period \(event.period ?? 0), stopped Clock image")
    }
}

#endif
