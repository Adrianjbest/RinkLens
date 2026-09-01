// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import AVKit
import Photos
import Foundation

// MARK: - v0.8.8j Native iPad Media Browser Interaction Fix
// Replaces the v0.8.8i List(selection:)/EditMode approach with explicit iPad-style
// buttons and row taps. The previous native selection binding looked correct but
// could swallow taps inside the split-view sheet, leaving Select/Refresh actions
// appearing to do nothing.

struct BroadcastRecordingMediaBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAlbum: LocalRecordingAlbum = .recordings
    @State private var items: [LocalRecordingMediaItem] = []
    @State private var albumCounts: [LocalRecordingAlbum: Int] = [:]
    @State private var selectedItem: LocalRecordingMediaItem?
    @State private var selectedItemIDs = Set<URL>()
    @State private var isSelectionMode = false
    @State private var searchText = ""
    @State private var sortOrder: LocalRecordingSortOrder = .newestFirst
    @State private var lastStatusMessage: String?
    @State private var pendingDeletedItemIDs = Set<URL>()
    @State private var isReloading = false
    @State private var reloadGeneration = 0

    private var displayedItems: [LocalRecordingMediaItem] {
        sortOrder.apply(to: searchedItems).filter { !pendingDeletedItemIDs.contains($0.id) }
    }
    private var searchedItems: [LocalRecordingMediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.fileName.localizedCaseInsensitiveContains(query)
                || item.detailText.localizedCaseInsensitiveContains(query)
                || item.albumHint.localizedCaseInsensitiveContains(query)
        }
    }
    private var selectedItems: [LocalRecordingMediaItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }
    private var selectedCount: Int { selectedItemIDs.count }
    private var allDisplayedSelected: Bool {
        !displayedItems.isEmpty && Set(displayedItems.map(\.id)).isSubset(of: selectedItemIDs)
    }

    var body: some View {
        NavigationView {
            mediaPane
        }
        .navigationViewStyle(.stack)
        .sheet(item: $selectedItem, onDismiss: { reload() }) { item in
            LocalRecordingPlayerView(item: item) {
                delete([item])
            }
        }
        .onAppear { reload() }
    }

    private var mediaPane: some View {
        VStack(spacing: 0) {
            albumStrip
            actionBar

            if let lastStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(lastStatusMessage)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            }

            if isSelectionMode {
                selectionBar
            }

            if isReloading && items.isEmpty {
                ProgressView("Loading media…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedItems.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No recovery files" : "No matching recovery files",
                    systemImage: selectedAlbum.icon,
                    description: Text(searchText.isEmpty ? "Only media that could not be physically confirmed in Photos is retained here." : "Try another search or clear the search field.")
                )
            } else {
                List {
                    ForEach(displayedItems) { item in
                        Button {
                            handleRowTap(item)
                        } label: {
                            LocalRecordingMediaRow(
                                item: item,
                                icon: selectedAlbum.icon,
                                isSelecting: isSelectionMode,
                                isSelected: selectedItemIDs.contains(item.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                confirmDelete([item])
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                selectedItem = item
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                selectedItem = item
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }

                            ShareLink(item: item.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                isSelectionMode = true
                                selectedItemIDs = [item.id]
                                lastStatusMessage = "1 selected"
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }

                            Button(role: .destructive) {
                                confirmDelete([item])
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteOffsets)
                }
                .listStyle(.insetGrouped)
                .rinkLensScrollPerformance("RecordingMediaBrowser")
            }
        }
        .navigationTitle("Local Recovery Files")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search clips")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isSelectionMode ? "Cancel" : "Close") {
                    if isSelectionMode {
                        exitSelectionMode()
                    } else {
                        dismiss()
                    }
                }
            }
        }
    }

    private var albumStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LocalRecordingAlbum.allCases) { album in
                        Button {
                            selectedAlbum = album
                            exitSelectionMode()
                            reload(message: "Showing \(album.title)")
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: album.icon)
                                    .font(.title3)
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .font(RinkLensDesignSystem.font(.bodyStrong))
                                    Text("\(albumCounts[album] ?? 0) file\((albumCounts[album] ?? 0) == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(minWidth: 170, alignment: .leading)
                            .background(selectedAlbum == album ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(selectedAlbum == album ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .background(.regularMaterial)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            RinkLensStableActionMenu(
                title: "Sort Media",
                width: 330,
                actions: LocalRecordingSortOrder.allCases.map { order in
                    .init(
                        title: order.title,
                        systemImage: order.icon,
                        isSelected: sortOrder == order,
                        action: { sortOrder = order }
                    )
                }
            ) {
                Label(sortOrder.shortTitle, systemImage: "arrow.up.arrow.down")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Spacer()

            Button {
                reload(message: "Library refreshed")
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Button {
                if isSelectionMode {
                    exitSelectionMode()
                } else {
                    enterSelectionMode()
                }
            } label: {
                Label(isSelectionMode ? "Done" : "Select", systemImage: isSelectionMode ? "checkmark" : "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(displayedItems.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button(allDisplayedSelected ? "Clear" : "Select All") {
                if allDisplayedSelected {
                    selectedItemIDs.subtract(displayedItems.map(\.id))
                } else {
                    selectedItemIDs.formUnion(displayedItems.map(\.id))
                }
                lastStatusMessage = "\(selectedItemIDs.count) selected"
            }
            .buttonStyle(.bordered)
            .disabled(displayedItems.isEmpty)

            Text("\(selectedCount) selected")
                .font(RinkLensDesignSystem.font(.caption))
                .foregroundStyle(.secondary)

            Spacer()

            if let singleShareItem = selectedItems.first, selectedItems.count == 1 {
                ShareLink(item: singleShareItem.url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                confirmDelete(selectedItems)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(selectedItemIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private func enterSelectionMode() {
        selectedItemIDs.removeAll()
        isSelectionMode = true
        lastStatusMessage = "Selection mode on. Tap clips to select them."
    }

    private func exitSelectionMode() {
        selectedItemIDs.removeAll()
        isSelectionMode = false
        lastStatusMessage = nil
    }

    private func handleRowTap(_ item: LocalRecordingMediaItem) {
        if isSelectionMode {
            toggleSelection(item)
        } else {
            selectedItem = item
        }
    }

    private func toggleSelection(_ item: LocalRecordingMediaItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
        lastStatusMessage = "\(selectedItemIDs.count) selected"
    }

    private func confirmDelete(_ targets: [LocalRecordingMediaItem]) {
        // v0.9.2 Stage 7c2: do not show a second in-app delete confirmation.
        // iOS presents the required Photos-library delete confirmation when matching
        // Photos assets are removed, so an app confirmation creates a confusing double prompt.
        delete(targets)
    }

    private func deleteOffsets(_ offsets: IndexSet) {
        let visible = displayedItems
        let targets = offsets.compactMap { index in visible.indices.contains(index) ? visible[index] : nil }
        confirmDelete(targets)
    }

    private func delete(_ targets: [LocalRecordingMediaItem]) {
        guard !targets.isEmpty else { return }
        let targetIDs = Set(targets.map(\.id))
        selectedItemIDs.subtract(targetIDs)
        MainThreadStallMonitor.shared.trace("media delete requested count=\(targets.count)")
        lastStatusMessage = "Deleting… confirm the Photos prompt if shown."

        // Stage 7c6: delete Photos first, then remove local files only after the
        // Photos result is known. This avoids the previous behaviour where the
        // item vanished from the app even if the Photos delete was cancelled,
        // denied, or failed to find the matching asset.
        LocalRecordingMediaIndex.deletePhotosCopies(for: targets) { photosDeleted, photosFailed, skippedReason in
            let canRemoveLocal = photosFailed == 0
                && (skippedReason == nil || skippedReason == LocalRecordingMediaIndex.noMatchingPhotosAssetsReason)

            guard canRemoveLocal else {
                MainThreadStallMonitor.shared.trace("media delete cancelled or failed photosDeleted=\(photosDeleted) photosFailed=\(photosFailed) reason=\(skippedReason ?? "none")")
                reload(message: "Delete cancelled or Photos delete failed. The app copy was kept so it does not disappear while the Photos copy remains.")
                return
            }

            pendingDeletedItemIDs.formUnion(targetIDs)
            items.removeAll { targetIDs.contains($0.id) }
            refreshAlbumCountsFromDisk()

            let localResult = LocalRecordingMediaIndex.deleteLocalCopies(targets)
            MediaRepository.shared.remove(
                localFilenames: targets.map(\.fileName),
                albumName: selectedAlbum.folderName
            )

            let localMessage = localResult.failed == 0
                ? "Deleted \(localResult.deleted) local clip\(localResult.deleted == 1 ? "" : "s")."
                : "Deleted \(localResult.deleted) local, failed \(localResult.failed)."

            let photosMessage: String
            if skippedReason == LocalRecordingMediaIndex.noMatchingPhotosAssetsReason {
                photosMessage = "Photos: no matching copy found."
            } else {
                photosMessage = "Photos: deleted \(photosDeleted) matching cop\(photosDeleted == 1 ? "y" : "ies")."
            }

            MainThreadStallMonitor.shared.trace("media delete completed local=\(localResult.deleted) photos=\(photosDeleted)")
            pendingDeletedItemIDs.subtract(targetIDs)
            reload(message: "\(localMessage) \(photosMessage)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                reload(message: "Library refreshed after delete.")
            }
            if items.isEmpty { exitSelectionMode() }
        }
    }


    private func refreshAlbumCountsFromDisk() {
        guard !RinkLensRiskFeaturePolicy.isEnabled(.asyncMediaIndexV22) else { return }
        albumCounts = Dictionary(uniqueKeysWithValues: LocalRecordingAlbum.allCases.map { album in
            (album, LocalRecordingMediaIndex.items(for: album).count)
        })
    }

    private func reload(message: String? = nil) {
        guard RinkLensRiskFeaturePolicy.isEnabled(.asyncMediaIndexV22) else {
            items = LocalRecordingMediaIndex.items(for: selectedAlbum)
            refreshAlbumCountsFromDisk()
            selectedItemIDs = selectedItemIDs.intersection(Set(items.map(\.id)))
            if let message { lastStatusMessage = message }
            return
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        let album = selectedAlbum
        isReloading = true
        if let message { lastStatusMessage = message }
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                LocalRecordingMediaIndex.librarySnapshot(selectedAlbum: album)
            }.value
            guard generation == reloadGeneration else { return }
            items = snapshot.items
            albumCounts = snapshot.counts
            selectedItemIDs = selectedItemIDs.intersection(Set(snapshot.items.map(\.id)))
            isReloading = false
            MainThreadStallMonitor.shared.trace("Build 741 async media library snapshot items=\(snapshot.items.count)")
        }
    }
}

private struct LocalRecordingMediaRow: View {
    let item: LocalRecordingMediaItem
    let icon: String
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thinMaterial)
                Image(systemName: icon)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(item.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if !isSelecting {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct LocalRecordingPlayerView: View {
    let item: LocalRecordingMediaItem
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(item: LocalRecordingMediaItem, onDelete: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
        _player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .background(Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                List {
                    Section("File") {
                        LabeledContent("Name", value: item.fileName)
                        LabeledContent("Modified", value: item.modifiedDate.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Size", value: item.sizeText)
                        LabeledContent("Location", value: item.albumHint)
                    }

                    Section("Actions") {
                        ShareLink(item: item.url) {
                            Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            // v0.9.2 Stage 7c2: rely on Apple's Photos confirmation only.
                            player.pause()
                            onDelete()
                            dismiss()
                        } label: {
                            Label("Delete from App Library and Photos", systemImage: "trash")
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: item.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .onAppear { player.play() }
            .onDisappear { player.pause() }
        }
    }
}

nonisolated private enum LocalRecordingAlbum: String, CaseIterable, Identifiable, Hashable, Sendable {
    case recordings
    case manualHighlights
    case autoHighlights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .manualHighlights: return "Manual Highlights"
        case .autoHighlights: return "Auto Highlights"
        }
    }

    var folderName: String {
        switch self {
        case .recordings: return "RinkLens Recordings"
        case .manualHighlights: return "RinkLens Manual Highlights"
        case .autoHighlights: return "RinkLens Auto Highlights"
        }
    }

    var icon: String {
        switch self {
        case .recordings: return "record.circle"
        case .manualHighlights: return "star.square"
        case .autoHighlights: return "bolt.badge.automatic"
        }
    }
}

private enum LocalRecordingSortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case nameAscending
    case nameDescending
    case largestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        case .nameAscending: return "Name A-Z"
        case .nameDescending: return "Name Z-A"
        case .largestFirst: return "Largest First"
        }
    }

    var shortTitle: String {
        switch self {
        case .newestFirst: return "Newest"
        case .oldestFirst: return "Oldest"
        case .nameAscending: return "Name A-Z"
        case .nameDescending: return "Name Z-A"
        case .largestFirst: return "Largest"
        }
    }

    var icon: String {
        switch self {
        case .newestFirst: return "clock.arrow.circlepath"
        case .oldestFirst: return "clock"
        case .nameAscending: return "textformat.abc"
        case .nameDescending: return "textformat.abc.dottedunderline"
        case .largestFirst: return "externaldrive"
        }
    }

    func apply(to items: [LocalRecordingMediaItem]) -> [LocalRecordingMediaItem] {
        switch self {
        case .newestFirst:
            return items.sorted { $0.modifiedDate > $1.modifiedDate }
        case .oldestFirst:
            return items.sorted { $0.modifiedDate < $1.modifiedDate }
        case .nameAscending:
            return items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .nameDescending:
            return items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedDescending }
        case .largestFirst:
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }
}

nonisolated private struct LocalRecordingMediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let modifiedDate: Date
    let sizeBytes: Int64
    let album: LocalRecordingAlbum

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var detailText: String {
        "\(modifiedDate.formatted(date: .abbreviated, time: .shortened)) · \(sizeText)"
    }

    var albumHint: String {
        url.deletingLastPathComponent().lastPathComponent
    }
}

private enum LocalRecordingMediaIndex {
    struct LibrarySnapshot: Sendable {
        let items: [LocalRecordingMediaItem]
        let counts: [LocalRecordingAlbum: Int]
    }

    static let noMatchingPhotosAssetsReason = "no matching Photos assets found"

    nonisolated static func librarySnapshot(selectedAlbum: LocalRecordingAlbum) -> LibrarySnapshot {
        var all: [LocalRecordingAlbum: [LocalRecordingMediaItem]] = [:]
        for album in LocalRecordingAlbum.allCases {
            all[album] = items(for: album)
        }
        return LibrarySnapshot(
            items: all[selectedAlbum] ?? [],
            counts: Dictionary(uniqueKeysWithValues: LocalRecordingAlbum.allCases.map { ($0, all[$0]?.count ?? 0) })
        )
    }

    nonisolated static func items(for album: LocalRecordingAlbum) -> [LocalRecordingMediaItem] {
        let fm = FileManager.default
        guard let documents = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return [] }
        let appRoot = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
        let primary = appRoot.appendingPathComponent(album.folderName, isDirectory: true)
        try? fm.createDirectory(at: primary, withIntermediateDirectories: true)

        var candidates: [URL] = []
        if let enumerator = fm.enumerator(at: appRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { continue }
                switch album {
                case .recordings:
                    if url.path.contains(RecordingEngine.recordingsAlbumName)
                        || url.path.contains(RecordingEngine.legacyRecordingsAlbumName)
                        || url.lastPathComponent.contains("full_game") { candidates.append(url) }
                case .manualHighlights:
                    if url.path.contains(RecordingEngine.manualHighlightsAlbumName)
                        || url.path.contains(RecordingEngine.legacyManualHighlightsAlbumName)
                        || url.lastPathComponent.contains("manual_clip") { candidates.append(url) }
                case .autoHighlights:
                    if url.path.contains(RecordingEngine.autoHighlightsAlbumName)
                        || url.path.contains(RecordingEngine.legacyAutoHighlightsAlbumName)
                        || url.lastPathComponent.contains("auto") { candidates.append(url) }
                }
            }
        }

        let mapped = candidates.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return LocalRecordingMediaItem(url: url, modifiedDate: values?.contentModificationDate ?? .distantPast, sizeBytes: Int64(values?.fileSize ?? 0), album: album)
        }
        return dedupedItems(mapped, preferredFolderName: album.folderName)
            .sorted { $0.modifiedDate > $1.modifiedDate }
    }

    private static func photoAlbumNames(for album: LocalRecordingAlbum) -> Set<String> {
        switch album {
        case .recordings:
            return [RecordingEngine.recordingsAlbumName, RecordingEngine.legacyRecordingsAlbumName]
        case .manualHighlights:
            return [RecordingEngine.manualHighlightsAlbumName, RecordingEngine.legacyManualHighlightsAlbumName]
        case .autoHighlights:
            return [RecordingEngine.autoHighlightsAlbumName, RecordingEngine.legacyAutoHighlightsAlbumName]
        }
    }

    static func deleteLocalCopies(_ items: [LocalRecordingMediaItem]) -> (deleted: Int, failed: Int) {
        var deleted = 0
        var failed = 0
        for item in items {
            do {
                if FileManager.default.fileExists(atPath: item.url.path) {
                    try FileManager.default.removeItem(at: item.url)
                    deleted += 1
                }
            } catch {
                failed += 1
            }
        }
        return (deleted, failed)
    }

    static func deletePhotosCopies(
        for items: [LocalRecordingMediaItem],
        completion: @escaping (_ deleted: Int, _ failed: Int, _ skippedReason: String?) -> Void
    ) {
        guard !items.isEmpty else {
            DispatchQueue.main.async { completion(0, 0, "no matching media items") }
            return
        }

        let albumNames = Set(items.flatMap { item -> [String] in
            switch item.album {
            case .recordings:
                return [RecordingEngine.recordingsAlbumName, RecordingEngine.legacyRecordingsAlbumName]
            case .manualHighlights:
                return [RecordingEngine.manualHighlightsAlbumName, RecordingEngine.legacyManualHighlightsAlbumName]
            case .autoHighlights:
                return [RecordingEngine.autoHighlightsAlbumName, RecordingEngine.legacyAutoHighlightsAlbumName]
            }
        })

        guard RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI else {
            DispatchQueue.main.async { completion(0, 0, RinkLensPhotoLibraryPrivacyGuard.missingUsageMessage) }
            return
        }

        let proceed: (PHAuthorizationStatus) -> Void = { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(0, 0, "Photos read/write permission not granted") }
                return
            }

            let assets = findPhotoAssets(matching: items, inAlbumNames: albumNames)
            guard !assets.isEmpty else {
                DispatchQueue.main.async { completion(0, 0, noMatchingPhotosAssetsReason) }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(assets.count, 0, nil)
                    } else {
                        completion(0, assets.count, error?.localizedDescription ?? "Photos delete failed")
                    }
                }
            })
        }

        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        proceed(current)
    }

    private static func findPhotoAssets(matching items: [LocalRecordingMediaItem], inAlbumNames albumNames: Set<String>) -> [PHAsset] {
        var matched: [PHAsset] = []
        var seen = Set<String>()
        let registeredAssetIDs = MediaRepository.shared.photosAssetIdentifiers(
            forLocalFilenames: items.map(\.fileName)
        )

        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, albumNames.contains(title) else { return }

            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                guard !seen.contains(asset.localIdentifier) else { return }
                let resourceNames = PHAssetResource.assetResources(for: asset).map(\.originalFilename)
                if registeredAssetIDs.contains(asset.localIdentifier)
                    || items.contains(where: { item in photoAsset(asset, resourceNames: resourceNames, likelyMatches: item) }) {
                    seen.insert(asset.localIdentifier)
                    matched.append(asset)
                }
            }
        }

        MainThreadStallMonitor.shared.trace("media photos delete match requested=\(items.count) matched=\(matched.count) registered=\(registeredAssetIDs.count)")
        return matched
    }

    private static func photoAsset(_ asset: PHAsset, resourceNames: [String], likelyMatches item: LocalRecordingMediaItem) -> Bool {
        if resourceNames.contains(where: { candidateMatches($0, filename: item.fileName) }) {
            return true
        }

        // Photos may rewrite the original filename when an app saves a local video.
        // Match by nearby creation/modification time so app-created videos do not
        // re-import as a second local file with an IMG_*.MOV style name.
        if let created = asset.creationDate, abs(created.timeIntervalSince(item.modifiedDate)) < 8 {
            return true
        }
        return false
    }

    private static func candidateMatches(_ candidate: String, filename: String) -> Bool {
        let candidateBase = canonicalMediaKey(candidate)
        let filenameBase = canonicalMediaKey(filename)
        return candidateBase == filenameBase
            || candidateBase.hasPrefix(filenameBase)
            || filenameBase.hasPrefix(candidateBase)
    }

    nonisolated private static func dedupedItems(_ items: [LocalRecordingMediaItem], preferredFolderName: String) -> [LocalRecordingMediaItem] {
        var byKey: [String: LocalRecordingMediaItem] = [:]
        for item in items {
            let key = canonicalMediaKey(item.fileName)
            guard let existing = byKey[key] else {
                byKey[key] = item
                continue
            }
            byKey[key] = preferredItem(existing, item, preferredFolderName: preferredFolderName)
        }
        return Array(byKey.values)
    }

    nonisolated private static func preferredItem(_ lhs: LocalRecordingMediaItem, _ rhs: LocalRecordingMediaItem, preferredFolderName: String) -> LocalRecordingMediaItem {
        let lhsPreferred = lhs.url.deletingLastPathComponent().lastPathComponent == preferredFolderName
        let rhsPreferred = rhs.url.deletingLastPathComponent().lastPathComponent == preferredFolderName
        if lhsPreferred != rhsPreferred { return lhsPreferred ? lhs : rhs }
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes ? lhs : rhs }
        return lhs.modifiedDate >= rhs.modifiedDate ? lhs : rhs
    }

    nonisolated private static func canonicalMediaKey(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        var stem = url.deletingPathExtension().lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        stem = stem.replacingOccurrences(of: #"_copy$"#, with: "", options: .regularExpression)
        stem = stem.replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
        stem = stem.replacingOccurrences(of: #"\(\d+\)$"#, with: "", options: .regularExpression)
        return stem
    }

    private static func normalisedMediaName(_ name: String) -> String {
        canonicalMediaKey(name)
    }

}
#endif
