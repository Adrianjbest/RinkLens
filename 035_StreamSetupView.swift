// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.

// MARK: - RinkLens Production Setup Streaming Section

/// Dedicated Command Centre stream setup workspace.
///
/// Embedded destination and publisher configuration for Production Setup.
/// StreamDestinationStore and StreamControlStore remain authoritative; this
/// presentation does not mutate camera, OCR, recording or overlay engines.
struct StreamPublishingSectionContent: View {
    @EnvironmentObject private var runtimeStatus: AppRuntimeStatus
    @ObservedObject private var destinationStore = StreamDestinationStore.shared
    @ObservedObject private var controlStore = StreamControlStore.shared
    let viewModel: HockeyScoreboardViewModel

    @State private var showStreamKey = false
    @State private var showClearConfirmation = false
    @State private var showSavedConfirmation = false

    init(viewModel: HockeyScoreboardViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        embeddedContent
            .preferredColorScheme(.dark)
            .onAppear {
                controlStore.updateConfigurationWarnings(destination: destinationStore)
                runtimeStatus.markStreamSetupVisible(destination: destinationStore, control: controlStore)
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Production Setup streaming section appeared"))
            }
            .onChange(of: destinationStore.streamURL) { _, _ in refreshStatus(reason: "stream url") }
            .onChange(of: destinationStore.streamKey) { _, _ in refreshStatus(reason: "stream key") }
            .onChange(of: destinationStore.useRTMPS) { _, _ in refreshStatus(reason: "stream protocol") }
            .onChange(of: destinationStore.ingestProtocol) { _, _ in refreshStatus(reason: "ingest protocol") }
            .streamSetupAlerts(showSavedConfirmation: $showSavedConfirmation, showClearConfirmation: $showClearConfirmation, clearAction: clearDestination)
    }

    private var embeddedContent: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            header
            youtubeSetupCard
            destinationCard
        }
        .frame(maxWidth: 1160, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private func clearDestination() {
        destinationStore.clear()
        controlStore.updateConfigurationWarnings(destination: destinationStore)
        runtimeStatus.markStreamSetupVisible(destination: destinationStore, control: controlStore)
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Stream destination cleared"))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("4. YouTube")
                    .font(RinkLensDesignSystem.font(.cardTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)

            }

            Spacer()

            StreamSetupStatusBadge(destinationStore: destinationStore, controlStore: controlStore)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RinkLensDesignSystem.cardBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }

    private var youtubeSetupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(
                title: "YouTube Live",
                subtitle: "",
                systemImage: "play.rectangle.fill"
            )

            HStack(spacing: 10) {
                Button {
                    destinationStore.prepareYouTubeLiveSetup()
                    refreshStatus(reason: "YouTube Live selected")
                } label: {
                    Label(
                        destinationStore.isYouTubeLiveDestination ? "YouTube Destination Selected" : "Select YouTube Destination",
                        systemImage: destinationStore.isYouTubeLiveDestination ? "checkmark.circle.fill" : "play.rectangle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Link(destination: URL(string: "https://studio.youtube.com/")!) {
                    Label("Open YouTube Studio", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }

            Text("Selecting YouTube chooses the YouTube RTMPS destination workflow. It does not sign in to your account or start a live stream.")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.white.opacity(0.62))

            Divider().overlay(.white.opacity(0.14))

            Text("Open YouTube Studio, create or select the live event, then copy its RTMPS Stream URL and Stream Key into Destination below. RinkLens does not sign in to or access your YouTube account.")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.white.opacity(0.62))

        }
        .padding(14)
        .settingsEmbeddedCard()
    }


    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            BroadcastMenuHeaderLabel(
                title: "Destination",
                subtitle: "",
                systemImage: "dot.radiowaves.left.and.right"
            )

            streamTextField("Platform name", text: $destinationStore.platformName, placeholder: "YouTube, Facebook, Custom RTMP")

            Picker("Ingest protocol", selection: $destinationStore.ingestProtocol) {
                ForEach(StreamDestinationStore.IngestProtocol.allCases) { ingest in
                    Text(ingest.rawValue).tag(ingest)
                }
            }
            .pickerStyle(.segmented)

            streamTextField(
                "Stream URL",
                text: $destinationStore.streamURL,
                placeholder: destinationStore.ingestProtocol == .hls
                    ? "https://a.upload.youtube.com/http_upload_hls"
                    : "rtmps://server/app"
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Stream key")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white.opacity(0.72))
                HStack(spacing: 8) {
                    Group {
                        if showStreamKey {
                            TextField("Paste stream key", text: $destinationStore.streamKey)
                        } else {
                            SecureField("Paste stream key", text: $destinationStore.streamKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                    Button {
                        showStreamKey.toggle()
                    } label: {
                        Image(systemName: showStreamKey ? "eye.slash.fill" : "eye.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
            }

            if destinationStore.ingestProtocol == .rtmps {
                Toggle("Prefer RTMPS", isOn: $destinationStore.useRTMPS)
                    .font(RinkLensDesignSystem.font(.bodyStrong))
                    .tint(.cyan)
            }

            if !destinationStore.validationWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(destinationStore.validationWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    destinationStore.save()
                    controlStore.updateConfigurationWarnings(destination: destinationStore)
                    runtimeStatus.markStreamSetupVisible(destination: destinationStore, control: controlStore)
                    showSavedConfirmation = true
                    MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Stream destination saved"))
                } label: {
                    Label("Save Destination", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Clear", systemImage: "trash.fill")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .settingsEmbeddedCard()
    }

    private func streamTextField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.white.opacity(0.72))
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(RinkLensDesignSystem.font(.bodyStrong))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        }
    }

    private func refreshStatus(reason: String) {
        controlStore.updateConfigurationWarnings(destination: destinationStore)
        runtimeStatus.markStreamSetupVisible(destination: destinationStore, control: controlStore)
        MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Production Setup streaming refresh: \(reason)"))
    }
}


extension View {
    func streamSetupAlerts(showSavedConfirmation: Binding<Bool>, showClearConfirmation: Binding<Bool>, clearAction: @escaping () -> Void) -> some View {
        self
            .alert("Streaming destination saved", isPresented: showSavedConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The destination is saved locally. If this build reports Publisher not installed, setup is complete but live video transport is not yet available.")
            }
            .confirmationDialog("Clear streaming destination?", isPresented: showClearConfirmation, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { clearAction() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the saved platform name, stream URL and stream key. It will not affect cameras, OCR, overlays or recordings.")
            }
    }

    func settingsEmbeddedCard() -> some View {
        self
            .background(.ultraThinMaterial)
            .background(RinkLensDesignSystem.cardBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.cardCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }
}

private struct StreamSetupStatusBadge: View {
    @ObservedObject var destinationStore: StreamDestinationStore
    @ObservedObject var controlStore: StreamControlStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColour)
                .frame(width: 10, height: 10)
            Text(badgeText)
                .font(RinkLensDesignSystem.font(.caption))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var badgeText: String {
        switch controlStore.runtimeState {
        case .publishing: return "Publishing"
        case .connecting, .connected, .openingPicker: return controlStore.connectionStatusText
        case .stopRequested: return "Stopping"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .idle:
            return destinationStore.isReadyForBroadcastFlow && controlStore.publisherAvailable
                ? "Ready"
                : controlStore.connectionStatusText
        }
    }

    private var badgeColour: Color {
        switch controlStore.runtimeState {
        case .publishing: return .green
        case .connecting, .connected, .openingPicker: return .cyan
        case .stopRequested: return .yellow
        case .failed: return .red
        case .idle where destinationStore.isReadyForBroadcastFlow && controlStore.publisherAvailable: return .green
        default: return .orange
        }
    }
}


#endif


#if canImport(SwiftUI)

struct StreamPublishingSettingsView: View {
    let viewModel: HockeyScoreboardViewModel

    var body: some View {
        StreamPublishingSectionContent(viewModel: viewModel)
    }
}

#endif
