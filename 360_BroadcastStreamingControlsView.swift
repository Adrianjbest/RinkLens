// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

/// v0.6.7
/// Operator-facing projection of requested, connected and physically publishing
/// state owned by the in-process RinkLens programme publisher.
struct BroadcastStreamingControlsView: View {
    @ObservedObject var destinationStore: StreamDestinationStore
    @ObservedObject var controlStore: StreamControlStore
    var onOpenSettings: () -> Void
    var onStartInApp: (() -> Void)? = nil
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            destinationRow
            acknowledgementRow
            healthRow
            statusRow
            actionRow
            boundaryNote
        }
        .padding(embedded ? 0 : 14)
        .frame(width: embedded ? nil : 390)
        .modifier(StreamControlsSurfaceModifier(embedded: embedded))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .onAppear {
            controlStore.updateConfigurationWarnings(destination: destinationStore)
        }
        .onChange(of: destinationStore.streamURL) { _, _ in controlStore.updateConfigurationWarnings(destination: destinationStore) }
        .onChange(of: destinationStore.streamKey) { _, _ in controlStore.updateConfigurationWarnings(destination: destinationStore) }
        .onChange(of: destinationStore.useRTMPS) { _, _ in controlStore.updateConfigurationWarnings(destination: destinationStore) }
    }

    private var acknowledgementRow: some View {
        HStack(spacing: 7) {
            acknowledgement("REQUESTED", active: controlStore.requestedStateActive, colour: .cyan)
            acknowledgement("CONNECTED", active: controlStore.connectedStateActive, colour: .green)
            acknowledgement("PUBLISHING", active: controlStore.activelyPublishingStateActive, colour: .green)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Requested \(controlStore.requestedStateActive ? "yes" : "no"), connected \(controlStore.connectedStateActive ? "yes" : "no"), actively publishing \(controlStore.activelyPublishingStateActive ? "yes" : "no")")
    }

    private func acknowledgement(_ title: String, active: Bool, colour: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(active ? colour : .white.opacity(0.22)).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(active ? .white : .white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.headline.weight(.bold))
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 1) {
                Text("Broadcast Stream")
                    .font(.subheadline.weight(.bold))
                Text("YouTube RTMPS Publisher")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer()

            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.caption.weight(.bold))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controlStore.broadcastSafeModeActive)
        }
    }

    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(destinationStore.validationWarnings.isEmpty ? Color.cyan : Color.orange)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(destinationStore.isConfigured ? destinationStore.displayPlatformName : "Destination not configured")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(destinationStore.isConfigured ? "\(destinationStore.protocolLabel) target saved" : "Open Settings to add RTMP/RTMPS target")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            if !destinationStore.validationWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(destinationStore.validationWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .streamControlDivider()
    }

    private var healthRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: healthSystemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(healthColour)

                Text(controlStore.connectionStatusText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(healthColour)

                Spacer()

                Text(healthBadgeText)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(healthBadgeForeground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(healthBadgeBackground, in: Capsule())
            }

            Text(controlStore.healthMessageText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            if !controlStore.lastRecoveryText.isEmpty {
                Text(controlStore.lastRecoveryText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .streamControlDivider()
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: controlStore.statusSystemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColour)

                Text(controlStore.statusTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColour)

                Spacer()

                if controlStore.broadcastSafeModeActive {
                    Text("SAFE MODE")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.yellow, in: Capsule())
                }
            }

            Text(controlStore.broadcastStatusText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            if !controlStore.lastErrorText.isEmpty {
                Text(controlStore.lastErrorText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Video \(controlStore.lastVideoBufferCount)  App audio \(controlStore.lastAppAudioBufferCount)  Mic \(controlStore.lastMicAudioBufferCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.56))

            Text("Codec \(controlStore.requestedVideoCodec) → \(controlStore.resolvedVideoCodec) → \(controlStore.appliedVideoCodec)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.56))

            Text("Profile \(controlStore.requestedStreamQualityProfile) → \(controlStore.resolvedStreamQualityProfile) → \(controlStore.appliedStreamQualityProfile)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.56))

            Text("Applied \(bitrateText)  Transport \(controlStore.transportEvidenceText)  Reconnects \(controlStore.reconnectCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.56))

            Text("Source: RinkLens programme compositor")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .padding(.vertical, 10)
        .streamControlDivider()
        .accessibilityLabel(controlStore.statusAccessibilityText)
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            if streamIsPublishing {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(primaryStreamActionTitle)
                }
                .font(RinkLensDesignSystem.font(.bodyStrong))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.green, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("RinkLens is live")
            } else {
                Button {
                    onStartInApp?()
                } label: {
                    HStack(spacing: 8) {
                        if streamStartupInProgress {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                        Text(primaryStreamActionTitle)
                    }
                        .font(RinkLensDesignSystem.font(.bodyStrong))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(!destinationStore.isReadyForBroadcastFlow || onStartInApp == nil || controlStore.requestedStateActive)
                .accessibilityLabel(primaryStreamActionTitle)
            }

            Text(startSubtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))

            Button(role: .destructive) {
                controlStore.requestStopPublishing(origin: .operatorStreamPanel)
            } label: {
                Label(controlStore.runtimeState == .stopRequested ? "Closing Stream…" : "Stop Stream", systemImage: "stop.fill")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            // RL-195: the stop action is exposed only after the publisher has
            // physically acknowledged media publication. During startup the
            // primary action itself is the persistent intent acknowledgement.
            .disabled(controlStore.runtimeState != .publishing)

            HStack(spacing: 8) {
                Button {
                    controlStore.resetLocalStatusOnly()
                    controlStore.updateConfigurationWarnings(destination: destinationStore)
                } label: {
                    Label("Clear Status", systemImage: "xmark.circle")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var startSubtitle: String {
        if streamIsPublishing { return "YouTube has accepted RinkLens programme media — use Stop Stream below to finish" }
        if streamStartupInProgress { return "Go Live was received — connecting and waiting for the first accepted programme media" }
        if !destinationStore.isReadyForBroadcastFlow { return "Fix configuration warnings before starting" }
        if onStartInApp == nil { return "Open Broadcast to start the RinkLens programme stream" }
        if controlStore.reconnectAvailable { return "Reconnects the RinkLens programme publisher without restarting recording" }
        return "Publishes only the RinkLens camera, scorebug and enabled overlays"
    }

    private var streamIsPublishing: Bool {
        controlStore.runtimeState == .publishing
    }

    private var primaryStreamActionTitle: String {
        if streamIsPublishing {
            return "LIVE • \(controlStore.publishingElapsedText())"
        }
        if streamStartupInProgress { return "Starting Live…" }
        return controlStore.reconnectAvailable ? "Reconnect Programme Stream" : "Go Live from RinkLens"
    }

    private var streamStartupInProgress: Bool {
        switch controlStore.runtimeState {
        case .openingPicker, .connecting, .connected: return true
        default: return false
        }
    }

    private var boundaryNote: some View {
        Text("RinkLens publishes the programme composite directly. Other apps, Settings, menus and the iPad screen are never included.")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.56))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bitrateText: String {
        guard controlStore.appliedVideoBitrate > 0 else { return "-- Mbps" }
        return String(format: "%.1f Mbps", Double(controlStore.appliedVideoBitrate) / 1_000_000)
    }

    private var statusColour: Color {
        switch controlStore.runtimeState {
        case .publishing: return .green
        case .connecting, .connected, .openingPicker: return .cyan
        case .stopRequested: return .yellow
        case .failed: return .orange
        default: return .white.opacity(0.72)
        }
    }

    private var healthColour: Color {
        switch controlStore.healthLevel {
        case .good: return .green
        case .warning: return .yellow
        case .failed: return .orange
        case .info: return .cyan
        }
    }

    private var healthSystemImage: String {
        switch controlStore.healthLevel {
        case .good: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var healthBadgeText: String {
        switch controlStore.healthLevel {
        case .good: return "HEALTHY"
        case .warning: return "WARNING"
        case .failed: return "FAILED"
        case .info: return "INFO"
        }
    }

    private var healthBadgeForeground: Color {
        controlStore.healthLevel == .warning ? .black : .white
    }

    private var healthBadgeBackground: Color {
        switch controlStore.healthLevel {
        case .good: return .green.opacity(0.75)
        case .warning: return .yellow
        case .failed: return .orange.opacity(0.85)
        case .info: return .cyan.opacity(0.60)
        }
    }
}

private struct StreamControlsSurfaceModifier: ViewModifier {
    let embedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if embedded { content } else { content.settingsEmbeddedCard() }
    }
}

private extension View {
    func streamControlDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(RinkLensDesignSystem.border.opacity(0.72))
                .frame(height: 1)
        }
    }
}

struct BroadcastSafeModeMinimalControls: View {
    @ObservedObject var controlStore: StreamControlStore

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controlStore.runtimeState == .publishing ? Color.red : healthDotColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 1) {
                Text(controlStore.runtimeState == .publishing ? "EXTENSION" : controlStore.statusTitle)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                Text(controlStore.connectionStatusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Button(role: .destructive) {
                controlStore.requestStopPublishing(origin: .operatorStreamPanel)
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .foregroundStyle(.white)
        .accessibilityLabel("Broadcast Safe Mode active. \(controlStore.statusAccessibilityText)")
    }

    private var healthDotColor: Color {
        switch controlStore.healthLevel {
        case .failed: return .orange
        case .warning: return .yellow
        case .good: return .green
        case .info: return .cyan
        }
    }
}
#endif
