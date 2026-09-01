// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - RinkLens NextGen Stage 11F Command Centre Shell

/// Game-day Command Centre shell.
///
/// S11F deliberately removes the engineering-dashboard feel from the home
/// screen. It keeps Command Centre to one non-scrolling iPad page: readiness,
/// launch, and six deep-dive tiles. Detailed telemetry stays in Diagnostics.
struct CommandCentreView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var runtimeStatus: AppRuntimeStatus
    @EnvironmentObject private var appContainer: AppContainer
    @ObservedObject private var recorder = BroadcastRecordingManager.shared
    @ObservedObject private var clipBuffer = ClipBufferManager.shared
    @ObservedObject private var diagnosticsService = DiagnosticsService.shared
    @State private var statusRefreshTask: Task<Void, Never>?
    @State private var lastStatusRefreshAt = Date.distantPast

    private let gameDayRoutes: [AppRoute] = [
        .broadcast,
        .ocrSetup,
        .recording,
        .media,
        .settings,
        .diagnostics
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ZStack {
            CommandCentreBackground()

            VStack(alignment: .leading, spacing: 14) {
                header
                oneLineHealth
                compactStatusBar
                launchPanel
                tileGrid
                operationalFooter
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1200, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .preferredColorScheme(.dark)
        .onAppear { scheduleCommandCentreStatusRefresh(reason: "appear", delayNanoseconds: 350_000_000) }
        .task { await warmRuntimeServicesForCommandCentre() }
        .onChange(of: recorder.state) { _, _ in scheduleCommandCentreStatusRefresh(reason: "recording state") }
        .onChange(of: recorder.recordingProfile) { _, _ in scheduleCommandCentreStatusRefresh(reason: "recording profile") }
        .onChange(of: recorder.photoLibraryStatusText) { _, _ in scheduleCommandCentreStatusRefresh(reason: "storage") }
        .onChange(of: recorder.recordingEncoderBacklogText) { _, _ in scheduleCommandCentreStatusRefresh(reason: "encoder backlog") }
        .onChange(of: recorder.recordingFPSWarningText) { _, _ in scheduleCommandCentreStatusRefresh(reason: "fps warning") }
        .onChange(of: recorder.recordingFormatWarningText) { _, _ in scheduleCommandCentreStatusRefresh(reason: "format warning") }
        .onDisappear { statusRefreshTask?.cancel(); statusRefreshTask = nil }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("RinkLens")
                    .font(RinkLensDesignSystem.font(.screenTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)

                Text("Command Centre")
                    .font(RinkLensDesignSystem.font(.bodyStrong))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
            }

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "sportscourt")
                Text(runtimeStatus.rinkProfile)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        }
    }

    private var oneLineHealth: some View {
        HStack(spacing: 12) {
            Image(systemName: healthIcon)
                .font(.title3.weight(.bold))
                .foregroundStyle(CommandCentreHealthPalette.color(for: runtimeStatus.overallHealth))

            Text(healthHeadline)
                .font(.headline.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(healthShortSummary)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer()

            Text(runtimeStatus.activeRouteTitle)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(CommandCentreHealthPalette.color(for: runtimeStatus.overallHealth).opacity(0.15))
                .foregroundStyle(CommandCentreHealthPalette.color(for: runtimeStatus.overallHealth))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var compactStatusBar: some View {
        HStack(spacing: 10) {
            CommandCentreStatusPill(title: "Camera", value: runtimeStatus.cameraState, level: runtimeStatus.cameraHealth, icon: "camera.fill")
            CommandCentreStatusPill(title: "Recognition", value: runtimeStatus.ocrState, level: runtimeStatus.ocrHealth, icon: "viewfinder")
            CommandCentreStatusPill(title: "Record", value: runtimeStatus.recordingState, level: runtimeStatus.recordingHealth, icon: "record.circle")
            CommandCentreStatusPill(title: "Stream", value: runtimeStatus.streamState, level: runtimeStatus.streamHealth, icon: "dot.radiowaves.left.and.right")
            CommandCentreStatusPill(title: "Storage", value: runtimeStatus.storageState, level: runtimeStatus.storageHealth, icon: "externaldrive")
            CommandCentreStatusPill(title: "Thermal", value: runtimeStatus.thermalState, level: runtimeStatus.thermalHealth, icon: "thermometer.medium")
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var launchPanel: some View {
        HStack(alignment: .center, spacing: 18) {
            CommandCentreBrandMark()

            VStack(alignment: .leading, spacing: 6) {
                Text("Ready for game day")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)

                Text("A clean launch screen for readiness, setup and Broadcast. Detailed engineering views are inside Diagnostics.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }

            Spacer(minLength: 18)

            Button {
                navigateFromCommandCentre(to: .broadcast, context: "Launch Broadcast from Command Centre")
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    Text("Launch Broadcast")
                }
                .font(.title3.weight(.heavy))
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.085))
        )
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private var tileGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Deep dives")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.62))
                    .textCase(.uppercase)
                    .tracking(1.0)

                Spacer()

                Text("Setup lives inside Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(gameDayRoutes) { route in
                    CommandCentreTile(route: route, level: healthLevel(for: route)) {
                        navigateFromCommandCentre(to: route, context: "route selected: \(route.title)")
                    }
                }
            }
        }
    }

    private var operationalFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(CommandCentreHealthPalette.color(for: runtimeStatus.overallHealth))

            Text("\(RinkLensBuildInfo.version) · game-day home")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))

            Spacer()
        }
        .padding(.top, 2)
    }

    private var healthIcon: String {
        switch runtimeStatus.overallHealth {
        case .ready: return "checkmark.seal.fill"
        case .idle: return "moon.zzz.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .degraded: return "thermometer.sun.fill"
        case .failed: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var healthHeadline: String {
        "Health: \(runtimeStatus.overallHealth.label)"
    }

    private var healthShortSummary: String {
        if runtimeStatus.thermalHealth == .degraded || runtimeStatus.thermalHealth == .failed {
            return "iPad is hot. Keep airflow clear and use Production diagnostics for matches."
        }

        if runtimeStatus.diagnosticsHealth == .warning || runtimeStatus.diagnosticsHealth == .degraded {
            return runtimeStatus.diagnosticsWarningSummary
        }

        return runtimeStatus.operationalHealthSummary
    }

    private func warmRuntimeServicesForCommandCentre() async {
        // S12E: do not start camera/OCR runtime from Command Centre. S12D logs
        // showed very large stalls against the old pre-warm completion context.
        // Keep the home screen lightweight and let Broadcast/OCR routes start
        // their own camera work when the operator enters those modules.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard coordinator.route == .commandCentre else { return }
            runtimeStatus.markRouteVisible(.commandCentre)
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Command Centre lightweight status ready"))
        }
    }

    private func scheduleCommandCentreStatusRefresh(
        reason: String,
        delayNanoseconds: UInt64 = 120_000_000
    ) {
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await Task.yield()
            guard !Task.isCancelled, coordinator.route == .commandCentre else {
                MainThreadStallMonitor.shared.trace(
                    RinkLensBuildInfo.traceContext("Recovery U discarded stale Command Centre status refresh after route ownership changed: \(reason)")
                )
                return
            }
            refreshCommandCentreStatus(reason: reason)
        }
    }

    private func refreshCommandCentreStatus(reason: String) {
        guard coordinator.route == .commandCentre else {
            MainThreadStallMonitor.shared.trace(
                RinkLensBuildInfo.traceContext("Recovery U blocked stale Command Centre status work outside route: \(reason)")
            )
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastStatusRefreshAt) >= 0.75 else {
            MainThreadStallMonitor.shared.trace(RinkLensBuildInfo.traceContext("Command Centre status publication coalesced: \(reason)"))
            return
        }
        lastStatusRefreshAt = now
        let wallStarted = CFAbsoluteTimeGetCurrent()
        let started = MainThreadStallMonitor.shared.beginTimedOperation("CommandCentre.statusRefresh")
        runtimeStatus.markRecordingModuleVisible(recorder: recorder, clipBuffer: clipBuffer)
        if Date().timeIntervalSince(diagnosticsService.lastRefreshDate) >= 1.5 {
            diagnosticsService.refresh(viewModel: appContainer.scoreboardViewModel, runtimeStatus: runtimeStatus)
        } else {
            MainThreadStallMonitor.shared.trace(RinkLensBuildInfo.traceContext("Command Centre reused startup diagnostics snapshot: \(reason)"))
        }
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Command Centre status refresh: \(reason)"))
        MainThreadStallMonitor.shared.endTimedOperation("CommandCentre.statusRefresh", startedAt: started)
        let elapsedMilliseconds = max(0, (CFAbsoluteTimeGetCurrent() - wallStarted) * 1_000)
        if elapsedMilliseconds >= 100 {
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "command_centre_status_refresh_slow",
                entityID: "commandCentre",
                previous: ["route": coordinator.route.rawValue],
                next: ["elapsedMs": String(format: "%.1f", elapsedMilliseconds), "reason": reason],
                source: "CommandCentreView.refreshCommandCentreStatus",
                reason: "Recovery U persists route-scoped status work that exceeds 100ms",
                authoritativeOwner: "AppCoordinator"
            )
        }
    }

    private func navigateFromCommandCentre(to route: AppRoute, context: String) {
        // Recovery U: Command Centre owns this delayed presentation task only while
        // it owns the visible route. Cancel it before route publication rather than
        // waiting for onDisappear, which cannot run until the destination mounts.
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext(context))
        coordinator.navigate(to: route)
    }

    private func healthLevel(for route: AppRoute) -> RuntimeHealthLevel {
        switch route {
        case .commandCentre: return .ready
        case .broadcast: return runtimeStatus.cameraHealth
        case .ocrSetup: return runtimeStatus.ocrHealth
        case .recording: return runtimeStatus.cameraHealth
        case .sponsors: return runtimeStatus.sponsorHealth
        case .media: return runtimeStatus.mediaHealth
        case .streamSetup: return runtimeStatus.streamHealth
        case .diagnostics: return runtimeStatus.diagnosticsHealth
        case .cameraSetup: return runtimeStatus.cameraHealth
        case .settings: return .ready
        }
    }
}


struct CommandCentreBrandMark: View {
#if canImport(UIKit)
    /// Embedded JPEG avoids any dependency on target membership or an asset-catalog entry.
    /// The image is decoded once and cached for the lifetime of the process.
    private static let embeddedLogo: UIImage = {
        guard
            let data = Data(base64Encoded: embeddedLogoBase64, options: .ignoreUnknownCharacters),
            let image = UIImage(data: data)
        else {
            return UIImage()
        }
        return image
    }()

    private static let embeddedLogoBase64 = """
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
rvpHRNYCnx/ib//Z
"""
#endif

    @ViewBuilder
    private var logoImage: some View {
#if canImport(UIKit)
        Image(uiImage: Self.embeddedLogo)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
#else
        Image(systemName: "viewfinder")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.blue)
#endif
    }

    var body: some View {
        logoImage
            .padding(8)
            .frame(width: 96, height: 96)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 14, x: 0, y: 8)
            .accessibilityLabel("RinkLens logo")
    }
}

private struct CommandCentreBackground: View {
    @ObservedObject private var appearance = RinkLensAppearanceSettings.shared

    var body: some View {
        ZStack {
            RinkLensDesignSystem.screenBackground
                .ignoresSafeArea()

            Circle()
                .fill(RinkLensDesignSystem.accent.opacity(0.18))
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .offset(x: -260, y: -260)

            Circle()
                .fill(RinkLensDesignSystem.accent.opacity(0.10))
                .frame(width: 460, height: 460)
                .blur(radius: 110)
                .offset(x: 300, y: 260)
        }
    }
}

private struct CommandCentreStatusPill: View {
    let title: String
    let value: String
    let level: RuntimeHealthLevel
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(CommandCentreHealthPalette.color(for: level))
                .frame(width: 8, height: 8)

            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.50))
                    .textCase(.uppercase)

                Text(shortValue(value, fallback: level.label))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func shortValue(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        if trimmed.localizedCaseInsensitiveContains("serious") { return "Hot" }
        if trimmed.localizedCaseInsensitiveContains("critical") { return "Critical" }
        if trimmed.localizedCaseInsensitiveContains("nominal") { return "OK" }
        if trimmed.localizedCaseInsensitiveContains("running") { return "Ready" }
        if trimmed.localizedCaseInsensitiveContains("paused") { return "Paused" }
        if trimmed.count > 18 { return String(trimmed.prefix(16)) + "…" }
        return trimmed
    }
}

private struct CommandCentreTile: View {
    let route: AppRoute
    let level: RuntimeHealthLevel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: route))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(CommandCentreHealthPalette.color(for: level).opacity(0.26))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(route.title)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }

                    Text(shortDescription(for: route))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                        .minimumScaleFactor(0.74)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func iconName(for route: AppRoute) -> String {
        switch route {
        case .commandCentre: return "rectangle.grid.2x2"
        case .broadcast: return "play.rectangle.fill"
        case .ocrSetup: return "viewfinder"
        case .recording: return "camera.aperture"
        case .sponsors: return "star"
        case .media: return "film"
        case .streamSetup: return "dot.radiowaves.left.and.right"
        case .diagnostics: return "waveform.path.ecg"
        case .cameraSetup: return "camera.aperture"
        case .settings: return "gearshape"
        }
    }

    private func shortDescription(for route: AppRoute) -> String {
        switch route {
        case .commandCentre:
            return "Home"
        case .broadcast:
            return "Live production"
        case .ocrSetup:
            return "Clock and score setup"
        case .recording:
            return "Cameras, quality and streaming"
        case .sponsors:
            return "Commercial setup"
        case .media:
            return "Recordings and exports"
        case .streamSetup:
            return "Cameras, quality and streaming"
        case .diagnostics:
            return "Health and logs"
        case .cameraSetup:
            return "Camera setup"
        case .settings:
            return "Teams, scorebug and app"
        }
    }
}

enum CommandCentreHealthPalette {
    static func color(for level: RuntimeHealthLevel) -> Color {
        switch level {
        case .ready:
            return .green
        case .idle:
            return .blue
        case .warning:
            return .yellow
        case .degraded:
            return .orange
        case .failed:
            return .red
        case .unknown:
            return .gray
        }
    }
}

#endif
