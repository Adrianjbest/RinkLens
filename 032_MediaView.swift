// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Photos
import AVKit

// UX10: simplified Media module. Media is intentionally operational, not a
// live diagnostics dashboard. It avoids repeated live row updates while the
// user scrolls, which was causing visible judder near the bottom of the screen.

private func mediaNonEmptyValue(_ value: String?, fallback: String) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallback : trimmed
}

nonisolated enum RinkLensMediaThumbnailAdmissionDecision: Equatable, Sendable {
    case startNow
    case queued
}

nonisolated struct RinkLensMediaThumbnailAdmissionState: Equatable, Sendable {
    let maximumConcurrentRequests: Int
    private(set) var activeIdentifiers: [String] = []
    private(set) var pendingIdentifiers: [String] = []

    init(maximumConcurrentRequests: Int) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    mutating func submit(_ identifier: String) -> RinkLensMediaThumbnailAdmissionDecision {
        guard !activeIdentifiers.contains(identifier), !pendingIdentifiers.contains(identifier) else {
            return activeIdentifiers.contains(identifier) ? .startNow : .queued
        }
        if activeIdentifiers.count < maximumConcurrentRequests {
            activeIdentifiers.append(identifier)
            return .startNow
        }
        pendingIdentifiers.append(identifier)
        return .queued
    }

    @discardableResult
    mutating func complete(_ identifier: String) -> String? {
        activeIdentifiers.removeAll { $0 == identifier }
        return promoteNext()
    }

    @discardableResult
    mutating func cancel(_ identifier: String) -> String? {
        let wasActive = activeIdentifiers.contains(identifier)
        activeIdentifiers.removeAll { $0 == identifier }
        pendingIdentifiers.removeAll { $0 == identifier }
        return wasActive ? promoteNext() : nil
    }

    private mutating func promoteNext() -> String? {
        guard activeIdentifiers.count < maximumConcurrentRequests,
              !pendingIdentifiers.isEmpty else { return nil }
        let next = pendingIdentifiers.removeFirst()
        activeIdentifiers.append(next)
        return next
    }
}

/// Presentation-only thumbnail broker. PhotoKit retains media authority; this
/// object merely bounds concurrent decoding so an album mount cannot launch all
/// thumbnails at once and starve operator input.
@MainActor
private final class RinkLensMediaThumbnailRequestBroker {
    static let shared = RinkLensMediaThumbnailRequestBroker()

    private struct Request {
        let token: UUID
        let asset: PHAsset
        let targetSize: CGSize
        let completion: (UIImage) -> Void
        var photoKitRequestID: PHImageRequestID = PHInvalidImageRequestID
    }

    private var admission = RinkLensMediaThumbnailAdmissionState(maximumConcurrentRequests: 2)
    private var requests: [String: Request] = [:]

    private init() {}

    func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        completion: @escaping (UIImage) -> Void
    ) -> UUID {
        let token = UUID()
        let identifier = token.uuidString
        requests[identifier] = Request(
            token: token,
            asset: asset,
            targetSize: targetSize,
            completion: completion
        )
        if admission.submit(identifier) == .startNow {
            start(identifier)
        }
        return token
    }

    func cancel(_ token: UUID) {
        let identifier = token.uuidString
        if let requestID = requests[identifier]?.photoKitRequestID,
           requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        requests.removeValue(forKey: identifier)
        if let next = admission.cancel(identifier) {
            start(next)
        }
    }

    private func start(_ identifier: String) {
        guard var request = requests[identifier] else {
            finish(identifier)
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let requestID = PHImageManager.default().requestImage(
            for: request.asset,
            targetSize: request.targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            Task { @MainActor in
                guard let self, let current = self.requests[identifier] else { return }
                if let image { current.completion(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                if !degraded || cancelled || failed {
                    self.finish(identifier)
                }
            }
        }
        // PhotoKit may satisfy a cached request synchronously. In that case the
        // completion above has already removed this token and promoted the next
        // bounded request; do not resurrect the completed entry afterwards.
        guard requests[identifier] != nil else { return }
        request.photoKitRequestID = requestID
        requests[identifier] = request
    }

    private func finish(_ identifier: String) {
        requests.removeValue(forKey: identifier)
        if let next = admission.complete(identifier) {
            start(next)
        }
    }
}

private enum MediaPhotosAlbum: String, Identifiable {
    case recordings
    case manualHighlights
    case autoHighlights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .manualHighlights: return "Manual clips"
        case .autoHighlights: return "Auto clips"
        }
    }

    var albumName: String {
        switch self {
        case .recordings: return MediaRepository.recordingsAlbumName
        case .manualHighlights: return MediaRepository.manualHighlightsAlbumName
        case .autoHighlights: return MediaRepository.autoHighlightsAlbumName
        }
    }

    var icon: String {
        switch self {
        case .recordings: return "video.fill"
        case .manualHighlights: return "hand.tap.fill"
        case .autoHighlights: return "sparkles"
        }
    }
}

// MARK: - RinkLens NextGen Media Module

struct MediaRouteShellView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var runtimeStatus: AppRuntimeStatus

    let viewModel: HockeyScoreboardViewModel
    @ObservedObject private var recorder = AppContainer.shared.recordingEngine
    @ObservedObject private var clipBuffer = ClipBufferManager.shared
    @ObservedObject private var eventJournal: RinkLensMatchEventJournal
    @State private var showMediaBrowser = false
    @State private var selectedPhotosAlbum: MediaPhotosAlbum?

    init(viewModel: HockeyScoreboardViewModel) {
        self.viewModel = viewModel
        _eventJournal = ObservedObject(wrappedValue: viewModel.matchEventJournal)
    }

    private var totalMediaCount: Int {
        recorder.savedRecordingsCount + recorder.savedManualHighlightsCount + recorder.savedAutoHighlightsCount
    }

    private var recordingPresentationWorkSuspended: Bool {
        RinkLensRiskFeaturePolicy.isEnabled(.recordingHiddenPresentationSuspensionV25)
            && recorder.canStop
    }

    var body: some View {
        ZStack {
            BroadcastMenuBackgroundView()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    primaryActionCard
                    mediaSummaryCard
                    eventTimelineCard
                    storageAndAccessCard
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 1040, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .rinkLensScrollPerformance("Media")
        }
        .broadcastMenuText()
        .rinkLensOperatorChrome("Media")
        .sheet(isPresented: $showMediaBrowser) {
            BroadcastRecordingMediaBrowserView()
        }
        .sheet(item: $selectedPhotosAlbum) { album in
            RinkLensPhotosAlbumBrowserView(album: album)
        }
        .onAppear {
            // Photos owns permanent media. Refresh its album counts on every
            // entry so deletions made directly in Photos are reflected here.
            // This metadata-only query runs on MediaRepository's utility queue
            // and does not acquire the capture/writer media lease.
            recorder.refreshSavedMediaCounts()
            if !recordingPresentationWorkSuspended {
                runtimeStatus.markMediaModuleVisible(recorder: recorder, clipBuffer: clipBuffer)
            }
            MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext(
                recordingPresentationWorkSuspended
                    ? "Media module appeared — recording thermal isolation retained cached counts"
                    : "Media module appeared - UX10 simplified"
            ))
            if recordingPresentationWorkSuspended {
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "recording_hidden_presentation_suspended",
                    entityID: "media-library",
                    previous: ["route": "media", "scan": "requested"],
                    next: ["scan": "suspended", "cachedCounts": "retained"],
                    source: "MediaRouteShellView.onAppear",
                    reason: "Writer session already open when Media appeared",
                    authoritativeOwner: "RecordingEngine presentation policy"
                )
            }
        }
        .onChange(of: recorder.state) { _, _ in
            guard recordingPresentationWorkSuspended else { return }
            showMediaBrowser = false
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "recording_hidden_presentation_suspended",
                entityID: "media-library",
                previous: ["browser": "available", "scan": "available"],
                next: ["browser": "closed", "scan": "suspended", "cachedCounts": "retained"],
                source: "MediaRouteShellView",
                reason: "RecordingEngine opened a writer session",
                authoritativeOwner: "RecordingEngine presentation policy"
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Media -> Command Centre"))
                coordinator.navigate(to: .commandCentre)
            } label: {
                Label("Command Centre", systemImage: "chevron.left")
                    .font(RinkLensDesignSystem.font(.caption))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 4) {
                Text("Media")
                    .font(RinkLensDesignSystem.font(.screenTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)

                Text("Open permanent recordings in Photos, inspect recovery files and review the live match event timeline.")
                    .font(RinkLensDesignSystem.font(.bodyStrong))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
            }

            Spacer()

            MediaPill(icon: "film.fill", text: "\(totalMediaCount) item\(totalMediaCount == 1 ? "" : "s")", colour: mediaColour)
        }
    }

    private var primaryActionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            BroadcastMenuHeaderLabel(
                title: "Recordings & clips",
                subtitle: "Photos is the permanent media library after each save is physically verified.",
                systemImage: "play.rectangle.fill"
            )

            HStack(spacing: 12) {
                Button {
                    guard !recordingPresentationWorkSuspended else { return }
                    recorder.openPhotosApp()
                    MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Permanent media opened in Photos"))
                } label: {
                    Label("Open Photos", systemImage: "photo.stack.fill")
                        .font(RinkLensDesignSystem.font(.cardTitle))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recordingPresentationWorkSuspended)

                Button {
                    guard !recordingPresentationWorkSuspended else { return }
                    showMediaBrowser = true
                    MainThreadStallMonitor.shared.markContext(RinkLensBuildInfo.traceContext("Local recovery media browser opened"))
                } label: {
                    Label("Recovery Files", systemImage: "externaldrive.badge.exclamationmark")
                        .font(RinkLensDesignSystem.font(.caption))
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(recordingPresentationWorkSuspended)
            }

            if recordingPresentationWorkSuspended {
                Text("Recovery-file scanning is paused until recording stops. The Recordings, Manual clips and Auto clips summary tiles still open their exact Photos albums inside RinkLens, so live capture is not backgrounded.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(16)
        .broadcastMenuCard(cornerRadius: 20)
    }

    private var mediaSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(
                title: "Summary",
                subtitle: "Tap a media type to open its exact RinkLens Photos album without leaving the app.",
                systemImage: "rectangle.grid.2x2.fill"
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                MediaSummaryTile(
                    title: "Recordings",
                    value: "\(recorder.savedRecordingsCount)",
                    icon: "video.fill",
                    action: { selectedPhotosAlbum = .recordings }
                )
                MediaSummaryTile(
                    title: "Manual clips",
                    value: "\(recorder.savedManualHighlightsCount)",
                    icon: "hand.tap.fill",
                    action: { selectedPhotosAlbum = .manualHighlights }
                )
                MediaSummaryTile(
                    title: "Auto clips",
                    value: "\(recorder.savedAutoHighlightsCount)",
                    icon: "sparkles",
                    action: { selectedPhotosAlbum = .autoHighlights }
                )
                MediaSummaryTile(
                    title: "Photos",
                    value: mediaNonEmptyValue(recorder.photoLibraryStatusText, fallback: "Unknown"),
                    icon: "photo.stack"
                )
            }
        }
        .padding(16)
        .broadcastMenuCard(cornerRadius: 20)
    }

    private var eventTimelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                BroadcastMenuHeaderLabel(
                    title: "Match event timeline",
                    subtitle: "Operator-only audit from the authoritative event journal; it is not burned into Broadcast or recordings.",
                    systemImage: "list.bullet.rectangle.portrait.fill"
                )
                Spacer()
                if !eventJournal.timeline.isEmpty {
                    Button("Clear") {
                        eventJournal.clearTimeline(source: "MediaRouteShellView", reason: "Operator cleared the visible match event timeline")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if eventJournal.timeline.isEmpty {
                Text("No confirmed goals or penalties yet.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
            } else {
                ForEach(Array(eventJournal.timeline.suffix(16).reversed())) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(event.actualObservedAt, style: .time)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 82, alignment: .leading)

                        Image(systemName: eventTimelineIcon(event))
                            .foregroundStyle(eventTimelineColour(event))
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.popupTitle)
                                .font(RinkLensDesignSystem.font(.caption))
                                .foregroundStyle(RinkLensDesignSystem.primaryText)
                            Text(eventTimelineDetail(event))
                                .font(RinkLensDesignSystem.font(.micro))
                                .foregroundStyle(RinkLensDesignSystem.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text(event.periodClockLine)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(16)
        .broadcastMenuCard(cornerRadius: 20)
    }

    private func eventTimelineDetail(_ event: BroadcastEvent) -> String {
        let team = event.team.map(eventTimelineTeamName) ?? "MATCH"
        if event.type == .penalty || event.type == .penalties {
            let player = event.recognisedPenaltyPlayerNumber.map { " #\($0)" } ?? ""
            let name = event.recognisedHomePlayerName.map { " · \($0)" } ?? ""
            return "\(team)\(player)\(name)"
        }
        if event.type == .goal || event.type == .powerPlayGoal || event.type == .shortHandedGoal {
            let home = event.homeScoreAfter.map(String.init) ?? "–"
            let away = event.awayScoreAfter.map(String.init) ?? "–"
            return "\(team) · \(viewModel.homeTeamName) \(home)–\(away) \(viewModel.awayTeamName)"
        }
        return "\(team) · \(event.popupDetail)"
    }

    private func eventTimelineTeamName(_ team: Team) -> String {
        team == .home ? viewModel.homeTeamName : viewModel.awayTeamName
    }

    private func eventTimelineIcon(_ event: BroadcastEvent) -> String {
        switch event.type {
        case .goal, .powerPlayGoal, .shortHandedGoal: return "circle.fill"
        case .penalty, .penalties: return "exclamationmark.octagon.fill"
        case .powerPlayStart: return "bolt.fill"
        case .penaltyEnd: return "checkmark.circle.fill"
        case .timeoutStart: return "timer"
        case .timeoutEnd: return "play.circle.fill"
        case .periodEnd: return "pause.circle.fill"
        case .gameFinal: return "flag.checkered"
        }
    }

    private func eventTimelineColour(_ event: BroadcastEvent) -> Color {
        switch event.type {
        case .goal, .powerPlayGoal, .shortHandedGoal: return .green
        case .penalty, .penalties: return .orange
        case .powerPlayStart: return .yellow
        case .penaltyEnd: return .mint
        case .timeoutStart, .timeoutEnd: return .cyan
        case .periodEnd, .gameFinal: return .blue
        }
    }

    private var storageAndAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuHeaderLabel(
                title: "Storage & access",
                subtitle: "Verified saves live in Photos. RinkLens retains a local file only when persistence is unconfirmed or failed.",
                systemImage: "externaldrive.fill"
            )

            VStack(alignment: .leading, spacing: 8) {
                MediaCompactRow(title: "Recordings album", value: BroadcastRecordingManager.recordingsAlbumName)
                MediaCompactRow(title: "Manual highlights", value: BroadcastRecordingManager.manualHighlightsAlbumName)
                MediaCompactRow(title: "Auto highlights", value: BroadcastRecordingManager.autoHighlightsAlbumName)
                MediaCompactRow(title: "Last saved", value: mediaNonEmptyValue(recorder.lastSavedMediaName, fallback: "No recent save"))
                MediaCompactRow(title: "Photos persistence", value: recorder.photoPersistenceActivityText)
            }

            Divider().overlay(.white.opacity(0.12))

            Stepper(
                "Manual clip pre-roll: \(recorder.snapshotClipSeconds)s + 5s post-roll",
                value: $recorder.snapshotClipSeconds,
                in: 5...60,
                step: 5
            )
            .font(RinkLensDesignSystem.font(.caption))

            MediaCompactRow(title: "Clip state", value: recorder.manualClipExportStateText)
            MediaCompactRow(title: "Rolling buffer", value: clipBuffer.bufferDurationText)

            HStack(spacing: 10) {
                Button("Request Photos Access") { recorder.requestPhotoLibraryAccess() }
                    .buttonStyle(.bordered)
                Text(mediaNonEmptyValue(recorder.photoLibraryAccessDetailText, fallback: recorder.photoLibraryStatusText))
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .broadcastMenuCard(cornerRadius: 20)
    }

    private var mediaColour: Color {
        switch runtimeStatus.mediaHealth {
        case .ready: return .green
        case .warning: return .yellow
        case .degraded: return .orange
        case .failed: return .red
        case .idle: return .blue
        case .unknown: return .gray
        }
    }
}

private struct MediaPill: View {
    let icon: String
    let text: String
    let colour: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(colour).frame(width: 9, height: 9)
            Image(systemName: icon)
            Text(text)
                .monospacedDigit()
        }
        .font(RinkLensDesignSystem.font(.caption))
        .foregroundStyle(RinkLensDesignSystem.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

private struct MediaSummaryTile: View {
    let title: String
    let value: String
    let icon: String
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { tileContent(showDisclosure: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the \(title) Photos album")
            } else {
                tileContent(showDisclosure: false)
            }
        }
    }

    private func tileContent(showDisclosure: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(RinkLensDesignSystem.font(.cardTitle))
                .foregroundStyle(RinkLensDesignSystem.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RinkLensDesignSystem.font(.micro))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
                    .textCase(.uppercase)
                Text(value.isEmpty ? "--" : value)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
            if showDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText.opacity(0.75))
            }
        }
        .contentShape(Rectangle())
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MediaPhotosAssetSelection: Identifiable {
    let id: String
}

private struct MediaPhotosAlbumLoadResult: @unchecked Sendable {
    let assets: [PHAsset]
    let statusText: String
}

/// Recovery CQ / RL-211: exact in-app access to the RinkLens-owned Photos
/// albums. iOS does not provide a reliable public deep link into a particular
/// Photos album, so the Media summary opens the PHAssetCollection directly.
private struct RinkLensPhotosAlbumBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let album: MediaPhotosAlbum

    @State private var assets: [PHAsset] = []
    @State private var loaded = false
    @State private var statusText = "Loading…"
    @State private var selectedAsset: MediaPhotosAssetSelection?
    @State private var selectionState = RinkLensMediaSelectionState()
    @State private var isSelecting = false
    @State private var deletionInProgress = false
    @State private var deletionErrorText: String?

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 310), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                BroadcastMenuBackgroundView()
                ScrollView {
                    if !loaded {
                        ProgressView("Opening \(album.title)…")
                            .padding(.top, 50)
                    } else if assets.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: album.icon)
                                .font(.system(size: 34, weight: .semibold))
                            Text(statusText)
                                .font(RinkLensDesignSystem.font(.bodyStrong))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                        .padding(.top, 50)
                        .padding(.horizontal, 24)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                Button {
                                    if isSelecting {
                                        selectionState.toggle(asset.localIdentifier)
                                    } else {
                                        selectedAsset = MediaPhotosAssetSelection(id: asset.localIdentifier)
                                    }
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        RinkLensPhotosVideoThumbnail(asset: asset)
                                        if isSelecting {
                                            Image(systemName: selectionState.selectedIdentifiers.contains(asset.localIdentifier)
                                                ? "checkmark.circle.fill"
                                                : "circle")
                                                .font(.system(size: 26, weight: .semibold))
                                                .foregroundStyle(selectionState.selectedIdentifiers.contains(asset.localIdentifier)
                                                    ? Color.accentColor
                                                    : Color.white)
                                                .background(.black.opacity(0.55), in: Circle())
                                                .padding(8)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isSelecting
                                    ? "\(selectionState.selectedIdentifiers.contains(asset.localIdentifier) ? "Deselect" : "Select") video"
                                    : "Play video full screen")
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle(album.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(album.title).font(.headline)
                        Text(album.albumName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if isSelecting {
                        Button(selectionState.selectedIdentifiers.count == assets.count ? "Clear" : "Select All") {
                            if selectionState.selectedIdentifiers.count == assets.count {
                                selectionState.clear()
                            } else {
                                selectionState.selectAll(assets.map(\.localIdentifier))
                            }
                        }
                        Button(role: .destructive) {
                            deleteSelection()
                        } label: {
                            if deletionInProgress {
                                ProgressView()
                            } else {
                                Label("Delete \(selectionState.selectedIdentifiers.count)", systemImage: "trash")
                            }
                        }
                        .disabled(selectionState.selectedIdentifiers.isEmpty || deletionInProgress)
                    }
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selectionState.clear() }
                    }
                    .disabled(assets.isEmpty || deletionInProgress)
                }
            }
            .task { await loadAlbum() }
            .fullScreenCover(item: $selectedAsset) { selection in
                RinkLensPhotosVideoPlayerView(assetIdentifier: selection.id)
            }
            .alert("Delete not completed", isPresented: Binding(
                get: { deletionErrorText != nil },
                set: { if !$0 { deletionErrorText = nil } }
            )) {
                Button("OK", role: .cancel) { deletionErrorText = nil }
            } message: {
                Text(deletionErrorText ?? "Photos did not confirm deletion.")
            }
        }
    }

    @MainActor
    private func deleteSelection() {
        let requested = selectionState.selectedIdentifiers
        guard !requested.isEmpty, !deletionInProgress else { return }
        deletionInProgress = true
        MediaRepository.shared.deletePhotosAssets(withIdentifiers: requested) { result in
            deletionInProgress = false
            selectionState.acknowledgeDeleted(result.deletedIdentifiers)
            assets.removeAll { result.deletedIdentifiers.contains($0.localIdentifier) }
            statusText = assets.isEmpty
                ? "No saved \(album.title.lowercased()) yet."
                : "\(assets.count) video\(assets.count == 1 ? "" : "s")"
            if selectionState.selectedIdentifiers.isEmpty {
                isSelecting = false
            }
            BroadcastRecordingManager.shared.refreshSavedMediaCounts()
            if let error = result.errorText {
                deletionErrorText = error
            }
        }
    }

    @MainActor
    private func loadAlbum() async {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized else {
            loaded = true
            statusText = authorization == .limited
                ? "Full Photos access is required to open the RinkLens album."
                : "Photos access is not available. Use Request Photos Access from Media."
            return
        }

        let result = await Self.fetchAlbumAssets(
            albumName: album.albumName,
            emptyTitle: album.title.lowercased()
        )
        guard !Task.isCancelled else { return }
        assets = result.assets
        statusText = result.statusText
        loaded = true
        MainThreadStallMonitor.shared.markContext(
            RinkLensBuildInfo.traceContext("Media exact Photos album opened: \(album.albumName) items=\(result.assets.count)")
        )
    }

    /// Recovery CR / RL-215: PhotoKit collection enumeration may synchronously
    /// hydrate metadata. Keep it off MainActor so opening a 12-item album cannot
    /// reproduce the 18.3-second heartbeat gap observed in Build 107.
    private nonisolated static func fetchAlbumAssets(
        albumName: String,
        emptyTitle: String
    ) async -> MediaPhotosAlbumLoadResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let collectionOptions = PHFetchOptions()
                collectionOptions.predicate = NSPredicate(format: "title == %@", albumName)
                let collections = PHAssetCollection.fetchAssetCollections(
                    with: .album,
                    subtype: .any,
                    options: collectionOptions
                )
                guard let collection = collections.firstObject else {
                    continuation.resume(returning: .init(
                        assets: [],
                        statusText: "No saved \(emptyTitle) yet."
                    ))
                    return
                }

                let assetOptions = PHFetchOptions()
                assetOptions.predicate = NSPredicate(
                    format: "mediaType == %d",
                    PHAssetMediaType.video.rawValue
                )
                assetOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let fetched = PHAsset.fetchAssets(in: collection, options: assetOptions)
                var assets: [PHAsset] = []
                assets.reserveCapacity(fetched.count)
                fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
                continuation.resume(returning: .init(
                    assets: assets,
                    statusText: assets.isEmpty
                        ? "No saved \(emptyTitle) yet."
                        : "\(assets.count) video\(assets.count == 1 ? "" : "s")"
                ))
            }
        }
    }
}

private struct RinkLensPhotosVideoThumbnail: View {
    let asset: PHAsset
    @State private var thumbnail: UIImage?
    @State private var requestToken: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.black.opacity(0.55))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            HStack {
                Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Saved video")
                    .font(RinkLensDesignSystem.font(.micro))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)
                    .lineLimit(1)
                Spacer()
                Text(Self.durationText(asset.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
            }
        }
        .padding(9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear(perform: requestThumbnail)
        .onDisappear {
            if let requestToken {
                RinkLensMediaThumbnailRequestBroker.shared.cancel(requestToken)
                self.requestToken = nil
            }
        }
    }

    private func requestThumbnail() {
        guard thumbnail == nil else { return }
        requestToken = RinkLensMediaThumbnailRequestBroker.shared.requestImage(
            for: asset,
            targetSize: CGSize(width: 480, height: 270)
        ) { image in
            thumbnail = image
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RinkLensPhotosVideoPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let assetIdentifier: String
    @State private var player: AVPlayer?
    @State private var statusText = "Loading video…"

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView(statusText).tint(.white).foregroundStyle(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: loadPlayer)
            .onDisappear { player?.pause() }
        }
    }

    private func loadPlayer() {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = result.firstObject else {
            statusText = "Video is no longer available."
            return
        }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
            DispatchQueue.main.async {
                guard let item else {
                    statusText = "Unable to open this video."
                    return
                }
                let resolved = AVPlayer(playerItem: item)
                player = resolved
                resolved.play()
            }
        }
    }
}

private struct MediaCompactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(RinkLensDesignSystem.secondaryText)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "--" : value)
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(RinkLensDesignSystem.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

#endif
