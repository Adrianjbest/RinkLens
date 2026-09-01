// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

/// Configuration UI for the direct RinkLens RTMP/RTMPS publisher.
struct StreamDestinationSettingsView: View {
    @ObservedObject var store: StreamDestinationStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftPlatformName: String = ""
    @State private var draftStreamURL: String = ""
    @State private var draftStreamKey: String = ""
    @State private var draftUseRTMPS: Bool = false
    @State private var draftIngestProtocol: StreamDestinationStore.IngestProtocol = .rtmps

    @State private var showStreamKey = false
    @State private var showClearConfirmation = false
    @State private var showSavedConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                BroadcastMenuBackgroundView()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        headerCard
                        streamRowDivider
                        destinationFormCard
                        streamRowDivider
                        futureStreamingBoundaryCard
                        streamRowDivider
                        actionButtons
                    }
                    .padding(18)
                    .broadcastMenuCard()
                }
                .rinkLensScrollPerformance("StreamDestination")
            }
            .navigationTitle("Stream Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .onAppear(perform: loadDraftValues)
            .alert("Streaming destination saved", isPresented: $showSavedConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The destination is saved locally and is ready for the direct RinkLens programme publisher.")
            }
            .confirmationDialog(
                "Clear streaming destination?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) {
                    store.clear()
                    loadDraftValues()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the saved platform name, stream URL and stream key. It will not affect cameras, OCR or overlays.")
            }
        }
        .rinkLensOperatorChrome("Stream Destination Settings")
        .preferredColorScheme(.dark)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Broadcast Stream")
                        .font(.headline.weight(.bold))
                    Text("RinkLens-only programme output over RTMPS or HLS")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer()
            }

            StreamDestinationStatusPill(store: store)
        }
        .padding(14)
        .foregroundStyle(.white)
    }

    private var destinationFormCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            fieldTitle("Platform name")
            TextField("YouTube, Facebook, Custom RTMP", text: $draftPlatformName)
                .textInputAutocapitalization(.words)
                .textFieldStyle(StreamTextFieldStyle())

            Picker("Ingest protocol", selection: $draftIngestProtocol) {
                ForEach(StreamDestinationStore.IngestProtocol.allCases) { ingest in
                    Text(ingest.rawValue).tag(ingest)
                }
            }
            .pickerStyle(.segmented)

            fieldTitle("Stream URL")
            TextField(draftIngestProtocol == .hls ? "https://a.upload.youtube.com/http_upload_hls" : "rtmps://server/app", text: $draftStreamURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(StreamTextFieldStyle())

            fieldTitle("Stream key")
            HStack(spacing: 8) {
                Group {
                    if showStreamKey {
                        TextField("Paste stream key", text: $draftStreamKey)
                    } else {
                        SecureField("Paste stream key", text: $draftStreamKey)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

                Button {
                    showStreamKey.toggle()
                } label: {
                    Image(systemName: showStreamKey ? "eye.slash.fill" : "eye.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))

            if draftIngestProtocol == .rtmps {
                Toggle(isOn: $draftUseRTMPS) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use RTMPS")
                        .font(.subheadline.weight(.semibold))
                    Text("Stores RTMPS as the preferred protocol. It does not start publishing.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                }
                }
                .tint(.cyan)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }

    private var futureStreamingBoundaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Programme Output", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.yellow)

            Text("Only the composed RinkLens camera picture, scorebug and enabled overlays are published. The iPad screen, Settings and other apps are never captured.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(14)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear", systemImage: "trash.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.hasAnyValue && draftPlatformName.isEmpty && draftStreamURL.isEmpty && draftStreamKey.isEmpty && !draftUseRTMPS)

            Button {
                store.ingestProtocol = draftIngestProtocol
                store.save(
                    platformName: draftPlatformName,
                    streamURL: draftStreamURL,
                    streamKey: draftStreamKey,
                    useRTMPS: draftUseRTMPS
                )
                loadDraftValues()
                showSavedConfirmation = true
            } label: {
                Label("Save", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
        .padding(14)
    }

    private var streamRowDivider: some View {
        Rectangle()
            .fill(RinkLensDesignSystem.border.opacity(0.72))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    private func fieldTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.82))
    }

    private func loadDraftValues() {
        draftPlatformName = store.platformName
        draftStreamURL = store.streamURL
        draftStreamKey = store.streamKey
        draftUseRTMPS = store.useRTMPS
        draftIngestProtocol = store.ingestProtocol
    }
}

struct StreamDestinationStatusCard: View {
    @ObservedObject var store: StreamDestinationStore
    var compact: Bool = false
    var onOpenSettings: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 9) {
                Image(systemName: store.isConfigured ? "dot.radiowaves.left.and.right" : "dot.radiowaves.left.and.right.slash")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(store.isConfigured ? .cyan : .orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Stream")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.64))

                    Text(store.isConfigured ? store.displayPlatformName : "Not configured")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    if !compact {
                        Text(store.isConfigured ? "\(store.protocolLabel) configured" : "Add RTMP/RTMPS target")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.44))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, compact ? 7 : 10)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: compact ? 15 : 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 15 : 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isConfigured ? "Stream destination configured as \(store.displayPlatformName)" : "Stream destination not configured")
    }
}

private struct StreamDestinationStatusPill: View {
    @ObservedObject var store: StreamDestinationStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isConfigured ? Color.cyan : Color.orange)
                .frame(width: 8, height: 8)

            Text(store.isConfigured ? "Configured • \(store.protocolLabel)" : "Not configured")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.82))

            if store.isConfigured {
                Text("Key saved")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.56))
            }

            Spacer()
        }
    }
}

private struct StreamTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
            .foregroundStyle(.white)
    }
}
#endif
