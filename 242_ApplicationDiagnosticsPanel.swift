// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import Foundation

struct ApplicationDiagnosticsPanel: View {
    let monitor: MainThreadStallMonitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.5)) { context in
            VStack(alignment: .leading, spacing: 12) {
                DiagnosticsCard(title: "UI / Main Thread", systemImage: "cpu") {
                    DiagnosticsRow(title: "Refresh", value: context.date.formatted(date: .omitted, time: .standard))
                    DiagnosticsRow(title: "Heartbeat age", value: monitor.heartbeatAgeText(now: context.date))
                    DiagnosticsRow(title: "UI stall count", value: "\(monitor.stallCount)")
                    DiagnosticsRow(title: "Longest UI stall", value: monitor.longestStallText())
                    DiagnosticsRow(title: "Current UI context", value: monitor.currentContext)
                    DiagnosticsRow(title: "Last UI stall", value: monitor.lastStallText)
                    DiagnosticsRow(title: "Last UI stall context", value: monitor.lastStallContext)
                    DiagnosticsRow(title: "Last timed operation", value: monitor.lastTimedOperationText)
                    DiagnosticsRow(title: "Longest timed operation", value: monitor.longestTimedOperationText)
                    DiagnosticsRow(title: "Published updates", value: monitor.publishPressureText)
                    DiagnosticsRow(title: "Largest publish burst", value: monitor.largestPublishBurstText)
                    DiagnosticsRow(title: "Top publish source", value: monitor.topPublishSourceText)
                    DiagnosticsRow(title: "Diagnostics mode", value: monitor.diagnosticsModeText)
                }

                if monitor.shouldShowVerboseDiagnosticLists {
                    DiagnosticsEventList(title: "Switch breadcrumbs", events: monitor.recentEvents)
                    DiagnosticsEventList(title: "Render / Preview / Toggle profiler", events: monitor.renderPreviewToggleEvents)
                } else {
                    DiagnosticsCard(title: "Production Diagnostics", systemImage: "speedometer") {
                        Text("Verbose trace lists are paused while recording. Critical warnings, blocked mutations, FPS problems and clip export failures still appear.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}


@MainActor
struct RiskFeatureFlagsPanel: View {
    private let definitionCount = RinkLensRiskFeature.allCases.count
    private let pendingCount = RinkLensRiskFeature.allCases.count

    var body: some View {
        DiagnosticsCard(title: "Temporary Rollout Snapshot", systemImage: "switch.2") {
            DiagnosticsRow(title: "Definitions", value: "\(definitionCount)")
            DiagnosticsRow(title: "Pending physical acceptance", value: "\(pendingCount)")
            DiagnosticsRow(title: "Runtime mutation", value: "Disabled on operator Diagnostics route")
            Text("R19 removes the 97 live Toggle rows from Diagnostics. The existing rollout values remain authoritative and are exported in All Logs; rollout changes belong to controlled engineering builds, not a performance-critical SwiftUI route.")
                .font(RinkLensDesignSystem.font(.micro))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DiagnosticsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(RinkLensDesignSystem.font(.cardTitle))
                .foregroundStyle(RinkLensDesignSystem.primaryText)
            content
        }
        .rinkLensPanelChrome()
    }
}

struct DiagnosticsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(RinkLensDesignSystem.font(.micro))
    }
}

struct DiagnosticsEventList: View {
    let title: String
    let events: [String]

    var body: some View {
        DiagnosticsCard(title: title, systemImage: "list.bullet.rectangle") {
            if events.isEmpty {
                Text("No events captured yet")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(events.prefix(6).enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(RinkLensDesignSystem.font(.monoCaption))
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}
#endif
