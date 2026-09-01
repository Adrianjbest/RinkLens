// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import SwiftUI
import UIKit
import Photos
import AVFoundation

nonisolated struct RinkLensMediaSelectionState: Sendable, Equatable {
    private(set) var selectedIdentifiers: Set<String>

    init(selectedIdentifiers: Set<String> = []) {
        self.selectedIdentifiers = selectedIdentifiers
    }

    mutating func toggle(_ identifier: String) {
        if selectedIdentifiers.remove(identifier) == nil {
            selectedIdentifiers.insert(identifier)
        }
    }

    mutating func selectAll(_ identifiers: [String]) {
        selectedIdentifiers = Set(identifiers)
    }

    mutating func clear() {
        selectedIdentifiers.removeAll()
    }

    mutating func acknowledgeDeleted(_ identifiers: Set<String>) {
        selectedIdentifiers.subtract(identifiers)
    }
}

nonisolated struct RinkLensPhotosDeletionResult: Sendable, Equatable {
    let requestedIdentifiers: Set<String>
    let deletedIdentifiers: Set<String>
    let errorText: String?

    var succeeded: Bool {
        errorText == nil && deletedIdentifiers == requestedIdentifiers
    }
}

nonisolated struct RinkLensStorageClearResult: Sendable {
    let files: Int
    let bytes: Int64
    let blockedReason: String?

    static func blocked(_ reason: String) -> Self {
        .init(files: 0, bytes: 0, blockedReason: reason)
    }
}

// MARK: - UX16d3 Media repository

/// Guards Photos calls because iOS terminates the process before returning an
/// error when a built target omits the corresponding usage description.
nonisolated enum RinkLensPhotoLibraryPrivacyGuard {
    static var hasReadWriteUsageDescription: Bool {
        nonEmptyInfoValue("NSPhotoLibraryUsageDescription")
    }

    static var hasAddUsageDescription: Bool {
        nonEmptyInfoValue("NSPhotoLibraryAddUsageDescription")
    }

    static var canUseReadWritePhotosAPI: Bool {
        hasReadWriteUsageDescription
    }

    static let missingUsageMessage = "Photos integration is disabled because the built app is missing NSPhotoLibraryUsageDescription. Recording remains saved in RinkLens Files."

    private static func nonEmptyInfoValue(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Authoritative repository for local recording identity, Photos persistence,
/// album names and operator-facing media status.
///
/// Registry operations are lock-confined and may be called from Photos worker
/// callbacks. UI publications are always marshalled to the main queue.
final class MediaRepository: ObservableObject, @unchecked Sendable {
    /// Temporary compatibility access for lower-level media-index callbacks.
    /// `AppContainer` owns this same instance. Remove the static bridge in UX16d7.
    static let shared = MediaRepository()

    nonisolated static let recordingsAlbumName = "RinkLens Recordings"
    nonisolated static let autoHighlightsAlbumName = "RinkLens Auto Highlights"
    nonisolated static let manualHighlightsAlbumName = "RinkLens Manual Highlights"
    nonisolated static let logsFolderName = "RinkLens Logs"

    nonisolated static let legacyRecordingsAlbumName = "LiveRinkLensLive_Recordings"
    nonisolated static let legacyAutoHighlightsAlbumName = "LiveRinkLensLive_AutoHighlights"
    nonisolated static let legacyManualHighlightsAlbumName = "LiveRinkLensLive_ManualHighlights"

    struct Entry: Codable, Hashable, Sendable {
        var localFilename: String
        var canonicalLocalKey: String
        var albumName: String
        var photosAssetIdentifier: String
        var photosOriginalFilename: String?
        var registeredAt: Date
    }

    private let countRefreshQueue = DispatchQueue(label: "rinklens.media.count-refresh", qos: .utility)
    private let countRefreshLock = NSLock()
    private var countRefreshInFlight = false
    private var countRefreshPending = false

    @Published private(set) var lastSavedAlbumName: String = "--"
    @Published private(set) var lastSavedMediaName: String = "--"
    @Published private(set) var photoLibraryStatusText: String = "Photos access not requested"
    @Published private(set) var photoLibraryAccessDetailText: String = "Use Request Photos Access before saving clips."
    @Published private(set) var photosOpenHelpText: String = "Use the Media Summary tiles for exact in-app RinkLens album access. Opening Photos leaves RinkLens and cannot reliably deep-link to a specific album."
    @Published private(set) var photoPersistenceActivityText: String = "No pending Photos save"
    @Published private(set) var savedRecordingsCount: Int = 0
    @Published private(set) var savedManualHighlightsCount: Int = 0
    @Published private(set) var savedAutoHighlightsCount: Int = 0

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let storeURL: URL?
    private nonisolated static let photosWorkQueue = DispatchQueue(label: "rinklens.media.repository.photos", qos: .background)
    private let postCaptureLock = NSLock()
    private let postCaptureQueue = DispatchQueue(label: "rinklens.media.repository.post-capture", qos: .background)
    private var postCaptureOperations: [(String, (@escaping () -> Void) -> Void)] = []
    private var postCaptureOperationActive = false
    private var postCaptureOperationExecuting = false
    private let photosPersistenceLock = NSLock()
    private let photosPersistenceQueue = DispatchQueue(label: "rinklens.media.repository.photos-persistence", qos: .utility)
    private var photosPersistenceOperations: [(String, (@escaping () -> Void) -> Void)] = []
    private var photosPersistenceOperationActive = false
    // Recovery CQ / RL-211: MediaRepository is the sole Photos persistence
    // authority. Multiple upstream notifications for the same finalized local
    // file coalesce behind one physical PhotoKit transaction and one asset
    // acknowledgement instead of creating a second save after the source has
    // already been released.
    private var photosPersistenceWaiters: [String: [((Bool, Error?) -> Void)]] = [:]
    private let stagingRecoveryLock = NSLock()
    private var stagingRecoveryStarted = false
    private let duplicateMigrationLock = NSLock()
    private var duplicateMigrationStarted = false
    private var duplicateMigrationSummary = "Not run"

    func enqueuePostCaptureOperation(
        label: String,
        operation: @escaping (@escaping () -> Void) -> Void
    ) {
        postCaptureLock.lock()
        postCaptureOperations.append((label, operation))
        let shouldStart = !postCaptureOperationActive
        if shouldStart { postCaptureOperationActive = true }
        postCaptureLock.unlock()
        if shouldStart { startNextPostCaptureOperation() }
    }

    /// Finalized-file import does not decode, remux or retain camera frames. It
    /// therefore has a separate serial acknowledgement boundary from opaque
    /// post-capture media work and may proceed while CaptureEngine remains live.
    /// The source file remains owned by MediaRepository until Photos verifies the
    /// physical asset identifier.
    private func enqueuePhotosPersistenceOperation(
        label: String,
        operation: @escaping (@escaping () -> Void) -> Void
    ) {
        photosPersistenceLock.lock()
        photosPersistenceOperations.append((label, operation))
        let shouldStart = !photosPersistenceOperationActive
        if shouldStart { photosPersistenceOperationActive = true }
        photosPersistenceLock.unlock()
        if shouldStart { startNextPhotosPersistenceOperation() }
    }

    private func startNextPhotosPersistenceOperation() {
        photosPersistenceQueue.async { [weak self] in
            guard let self else { return }
            self.photosPersistenceLock.lock()
            guard let next = self.photosPersistenceOperations.first else {
                self.photosPersistenceOperationActive = false
                self.photosPersistenceLock.unlock()
                return
            }
            self.photosPersistenceLock.unlock()
            next.1 { [weak self] in
                guard let self else { return }
                self.photosPersistenceLock.lock()
                if !self.photosPersistenceOperations.isEmpty {
                    self.photosPersistenceOperations.removeFirst()
                }
                self.photosPersistenceLock.unlock()
                self.startNextPhotosPersistenceOperation()
            }
        }
    }

    private func startNextPostCaptureOperation() {
        postCaptureQueue.async { [weak self] in
            guard let self else { return }
            guard RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork() else {
                RinkLensExecutionCoordinator.shared.noteDeferredMediaYield()
                let admission = RinkLensExecutionCoordinator.shared.snapshot().deferredMediaCaptureAdmissionText
                MainThreadStallMonitor.traceFromAnyQueue(
                    "Recovery AU post-capture media deferred: live capture media lease/operator/critical admission denied {\(admission)}"
                )
                return
            }
            self.postCaptureLock.lock()
            guard let next = self.postCaptureOperations.first else {
                self.postCaptureOperationActive = false
                self.postCaptureOperationExecuting = false
                self.postCaptureLock.unlock()
                return
            }
            guard !self.postCaptureOperationExecuting else {
                self.postCaptureLock.unlock()
                return
            }
            self.postCaptureOperationExecuting = true
            self.postCaptureLock.unlock()
            MainThreadStallMonitor.traceFromAnyQueue("post-capture media operation started: \(next.0)")
            next.1 { [weak self] in
                guard let self else { return }
                self.postCaptureLock.lock()
                if !self.postCaptureOperations.isEmpty { self.postCaptureOperations.removeFirst() }
                self.postCaptureOperationExecuting = false
                self.postCaptureLock.unlock()
                MainThreadStallMonitor.traceFromAnyQueue("post-capture media operation completed: \(next.0)")
                self.startNextPostCaptureOperation()
            }
        }
    }

    /// Recovery AU / RL-100: MediaRepository is the sole deferred-media queue
    /// owner. The only external resume signal is a verified media-resource
    /// eligibility change from the execution/capture owner; route presentation
    /// is deliberately not part of this API.
    func resumePostCaptureOperationsAfterMediaLeaseRelease(reason: String) {
        guard RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork() else { return }
        postCaptureLock.lock()
        let shouldResume = postCaptureOperationActive
            && !postCaptureOperationExecuting
            && !postCaptureOperations.isEmpty
        postCaptureLock.unlock()
        guard shouldResume else { return }
        MainThreadStallMonitor.traceFromAnyQueue(
            "Recovery AU post-capture media resume admitted after live media lease release: \(reason)"
        )
        startNextPostCaptureOperation()
    }

    init() {
        let fm = FileManager.default
        if let documents = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let root = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            storeURL = root.appendingPathComponent("RinkLensMediaAssetRegistry.json")
        } else {
            storeURL = nil
        }
        entries = Self.loadEntries(from: storeURL)
        refreshSavedCountsFromDisk()

        if !RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI {
            photoLibraryStatusText = "Photos integration unavailable"
            photoLibraryAccessDetailText = RinkLensPhotoLibraryPrivacyGuard.missingUsageMessage
        } else if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            recoverFinalizedStagingRecordingsOnce(reason: "MediaRepository launch")
            runConfirmedDuplicateMigrationOnce(reason: "MediaRepository launch")
        }
    }

    /// Reconciles files left in Staging by the former capture-gated Photos
    /// queue. Only physically playable, non-empty finalized assets are admitted.
    /// Failed/partial recordings live outside Staging and are deliberately not
    /// included in this migration.
    private func recoverFinalizedStagingRecordingsOnce(reason: String) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        stagingRecoveryLock.lock()
        guard !stagingRecoveryStarted else {
            stagingRecoveryLock.unlock()
            return
        }
        stagingRecoveryStarted = true
        stagingRecoveryLock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let documents = try? FileManager.default.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                  ) else { return }
            let staging = documents
                .appendingPathComponent("LiveRinkLensLive", isDirectory: true)
                .appendingPathComponent("Staging", isDirectory: true)
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var admitted = 0
            for url in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                let asset = AVURLAsset(url: url)
                guard let playable = try? await asset.load(.isPlayable), playable,
                      let duration = try? await asset.load(.duration),
                      duration.isNumeric,
                      CMTimeGetSeconds(duration) > 0.25 else { continue }
                admitted += 1
                await MainActor.run {
                    self.saveVideo(
                        url: url,
                        albumName: Self.recordingsAlbumName,
                        mediaKind: "recovered recording"
                    )
                }
            }
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "media_staging_reconciliation_completed",
                entityID: "Staging",
                previous: ["candidates": String(candidates.count)],
                next: ["playableAdmitted": String(admitted)],
                source: "MediaRepository.recoverFinalizedStagingRecordingsOnce",
                reason: reason,
                authoritativeOwner: "MediaRepository"
            )
        }
    }

    var confirmedDuplicateMigrationSummaryText: String {
        duplicateMigrationLock.lock()
        let value = duplicateMigrationSummary
        duplicateMigrationLock.unlock()
        return value
    }

    /// Explicit operator deletion of local sandbox recordings only. Photos is
    /// not touched. The RecordingWriter physical contract is checked before the
    /// scan and before every removal so an active file can never be deleted.
    func clearOperatorRequestedLocalRecordings() async -> RinkLensStorageClearResult {
        guard !RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
              !RinkLensRecordingCaptureLease.shared.isRecordingActive() else {
            return .blocked("Stop recording before clearing local media.")
        }
        return await withCheckedContinuation { continuation in
            countRefreshQueue.async {
                let fm = FileManager.default
                guard let documents = try? fm.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                ) else {
                    continuation.resume(returning: .blocked("The RinkLens Documents folder is unavailable."))
                    return
                }
                let root = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                var files = 0
                var bytes: Int64 = 0
                var blockedReason: String?
                while let url = enumerator?.nextObject() as? URL {
                    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    if relative.hasPrefix("ClipBuffer/") || relative.hasPrefix("ClipExports/") { continue }
                    guard Self.isOwnedRuntimeMediaURL(url) else { continue }
                    guard !RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
                          !RinkLensRecordingCaptureLease.shared.isRecordingActive() else {
                        blockedReason = "Recording became active; remaining files were retained."
                        break
                    }
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    do {
                        try fm.removeItem(at: url)
                        files += 1
                        bytes += size
                    } catch {
                        blockedReason = "Some local recordings could not be removed: \(error.localizedDescription)"
                    }
                }
                self.refreshSavedCountsFromDisk()
                continuation.resume(returning: .init(files: files, bytes: bytes, blockedReason: blockedReason))
            }
        }
    }

    // MARK: Local / Photos identity registry

    func register(localURL: URL, albumName: String, photosAssetIdentifier: String?, photosOriginalFilename: String? = nil) {
        guard let photosAssetIdentifier, !photosAssetIdentifier.isEmpty else { return }
        let filename = localURL.lastPathComponent
        let canonical = Self.canonicalMediaKey(filename)
        lock.lock()
        entries.removeAll {
            $0.photosAssetIdentifier == photosAssetIdentifier
                || ($0.albumName == albumName && $0.canonicalLocalKey == canonical)
                || ($0.albumName == albumName && $0.localFilename == filename)
        }
        entries.append(
            Entry(
                localFilename: filename,
                canonicalLocalKey: canonical,
                albumName: albumName,
                photosAssetIdentifier: photosAssetIdentifier,
                photosOriginalFilename: photosOriginalFilename,
                registeredAt: Date()
            )
        )
        persistLocked()
        lock.unlock()
        MainThreadStallMonitor.traceFromAnyQueue("media repository registered local=\(filename) album=\(albumName)")
    }

    func entry(forLocalFilename filename: String, albumName: String? = nil) -> Entry? {
        let canonical = Self.canonicalMediaKey(filename)
        lock.lock()
        let value = entries.first { entry in
            (albumName == nil || entry.albumName == albumName)
                && (entry.localFilename == filename || entry.canonicalLocalKey == canonical)
        }
        lock.unlock()
        return value
    }

    func entry(forPhotosAssetIdentifier identifier: String) -> Entry? {
        lock.lock()
        let value = entries.first { $0.photosAssetIdentifier == identifier }
        lock.unlock()
        return value
    }

    func photosAssetIdentifiers(forLocalFilenames filenames: [String], albumName: String? = nil) -> Set<String> {
        let names = Set(filenames)
        let keys = Set(filenames.map(Self.canonicalMediaKey))
        lock.lock()
        let value = Set(entries.compactMap { entry -> String? in
            guard albumName == nil || entry.albumName == albumName else { return nil }
            guard names.contains(entry.localFilename) || keys.contains(entry.canonicalLocalKey) else { return nil }
            return entry.photosAssetIdentifier
        })
        lock.unlock()
        return value
    }

    func isKnownPhotosAsset(_ identifier: String) -> Bool {
        entry(forPhotosAssetIdentifier: identifier) != nil
    }

    func remove(localFilenames: [String], albumName: String? = nil) {
        let names = Set(localFilenames)
        let keys = Set(localFilenames.map(Self.canonicalMediaKey))
        lock.lock()
        entries.removeAll { entry in
            (albumName == nil || entry.albumName == albumName)
                && (names.contains(entry.localFilename) || keys.contains(entry.canonicalLocalKey))
        }
        persistLocked()
        lock.unlock()
    }

    func remove(photosAssetIdentifiers: Set<String>) {
        guard !photosAssetIdentifiers.isEmpty else { return }
        lock.lock()
        entries.removeAll { photosAssetIdentifiers.contains($0.photosAssetIdentifier) }
        persistLocked()
        lock.unlock()
    }

    /// Deletes exact PHAsset identities through the repository's serial Photos
    /// transaction boundary. Registry/UI state changes only after PhotoKit
    /// completes and a refetch proves the selected assets are absent.
    func deletePhotosAssets(
        withIdentifiers identifiers: Set<String>,
        completion: @escaping @MainActor (RinkLensPhotosDeletionResult) -> Void
    ) {
        guard !identifiers.isEmpty else {
            completion(.init(requestedIdentifiers: [], deletedIdentifiers: [], errorText: nil))
            return
        }
        guard RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            completion(.init(
                requestedIdentifiers: identifiers,
                deletedIdentifiers: [],
                errorText: "Full Photos access is required to delete videos."
            ))
            return
        }

        enqueuePhotosPersistenceOperation(label: "Delete \(identifiers.count) Photos video(s)") { [weak self] finish in
            guard let self else { finish(); return }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            var assets: [PHAsset] = []
            fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
            guard !assets.isEmpty else {
                self.remove(photosAssetIdentifiers: identifiers)
                Task { @MainActor in
                    completion(.init(
                        requestedIdentifiers: identifiers,
                        deletedIdentifiers: identifiers,
                        errorText: nil
                    ))
                }
                finish()
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { [weak self] success, error in
                guard let self else { finish(); return }
                let remaining = PHAsset.fetchAssets(
                    withLocalIdentifiers: Array(identifiers),
                    options: nil
                )
                var remainingIdentifiers = Set<String>()
                remaining.enumerateObjects { asset, _, _ in
                    remainingIdentifiers.insert(asset.localIdentifier)
                }
                let deleted = success ? identifiers.subtracting(remainingIdentifiers) : []
                if !deleted.isEmpty {
                    self.remove(photosAssetIdentifiers: deleted)
                }
                let errorText: String?
                if !success {
                    errorText = error?.localizedDescription ?? "Photos did not confirm deletion."
                } else if deleted != identifiers {
                    errorText = "Photos did not remove every selected video."
                } else {
                    errorText = nil
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: errorText == nil ? "media_photos_delete_acknowledged" : "media_photos_delete_not_acknowledged",
                    entityID: "media-summary",
                    previous: ["requested": String(identifiers.count)],
                    next: [
                        "deleted": String(deleted.count),
                        "remaining": String(remainingIdentifiers.count),
                        "error": errorText ?? "none"
                    ],
                    source: "MediaRepository.deletePhotosAssets",
                    reason: "PhotoKit completion and exact identifier refetch define the deletion boundary",
                    authoritativeOwner: "MediaRepository"
                )
                Task { @MainActor in
                    completion(.init(
                        requestedIdentifiers: identifiers,
                        deletedIdentifiers: deleted,
                        errorText: errorText
                    ))
                }
                finish()
            }
        }
    }

    nonisolated static func canonicalMediaKey(_ name: String) -> String {
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

    // MARK: Photos status and persistence

    func requestPhotoLibraryAccessIfNeeded() {
        requestPhotoLibraryAccess()
    }

    func refreshPhotoLibraryStatus() {
        guard RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI else {
            markPhotosIntegrationUnavailable()
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        publishStatus(status)
        if status == .authorized {
            runConfirmedDuplicateMigrationOnce(reason: "Photos status refresh")
        }
    }

    func requestPhotoLibraryAccess() {
        guard RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI else {
            markPhotosIntegrationUnavailable()
            return
        }
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized:
            publishStatus(current)
            ensurePhotoAlbumsExist()
            runConfirmedDuplicateMigrationOnce(reason: "Photos access already authorised")
        case .notDetermined:
            publishOnMain {
                self.photoLibraryStatusText = "Requesting Photos access..."
                self.photoLibraryAccessDetailText = "Waiting for iOS permission response."
            }
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                guard let self else { return }
                self.publishOnMain {
                    self.publishStatus(status)
                    if status == .authorized {
                        self.ensurePhotoAlbumsExist()
                        self.runConfirmedDuplicateMigrationOnce(reason: "Photos access granted")
                    }
                }
            }
        case .limited, .denied, .restricted:
            publishStatus(current)
        @unknown default:
            publishOnMain {
                self.photoLibraryStatusText = "Photos access status unknown"
                self.photoLibraryAccessDetailText = "iOS returned an unknown Photos permission state."
            }
        }
    }

    func ensurePhotoAlbumsExist() {
        guard RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI else {
            markPhotosIntegrationUnavailable()
            return
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            MainThreadStallMonitor.shared.trace("Photos album setup skipped; full Photos access is required")
            return
        }
        let names = [Self.recordingsAlbumName, Self.manualHighlightsAlbumName, Self.autoHighlightsAlbumName]
        Self.performEnsurePhotoAlbumsExist(albumNames: names) { success, error in
            MainThreadStallMonitor.shared.trace(success
                ? "Photos albums checked; existing albums reused"
                : "Photos album setup failed: \(error?.localizedDescription ?? "unknown")")
        }
    }


    /// Recovery CR / RL-214: Photos is the permanent media authority after a
    /// physically acknowledged save, so the Media summary must be derived from
    /// the current contents of the three RinkLens albums. The local registry is
    /// identity/recovery evidence only and cannot represent assets an operator
    /// subsequently deleted in Photos.
    func refreshSavedCountsFromDisk() {
        let registeredEntries = registeredEntriesSnapshot()
        guard RinkLensRiskFeaturePolicy.isEnabled(.asyncMediaIndexV22) else {
            let counts = Self.currentMediaCounts(registeredEntries: registeredEntries)
            publishOnMain {
                self.savedRecordingsCount = counts.recordings
                self.savedManualHighlightsCount = counts.manual
                self.savedAutoHighlightsCount = counts.auto
            }
            return
        }
        countRefreshLock.lock()
        if countRefreshInFlight {
            countRefreshPending = true
            countRefreshLock.unlock()
            return
        }
        countRefreshInFlight = true
        countRefreshLock.unlock()
        countRefreshQueue.async { [weak self] in
            guard let self else { return }
            let started = CFAbsoluteTimeGetCurrent()
            let counts = Self.currentMediaCounts(registeredEntries: registeredEntries)
            self.publishOnMain {
                self.savedRecordingsCount = counts.recordings
                self.savedManualHighlightsCount = counts.manual
                self.savedAutoHighlightsCount = counts.auto
                MainThreadStallMonitor.shared.trace(
                    String(format: "Recovery CR authoritative media summary recordings=%d manual=%d auto=%d source=%@ scan=%.1fms", counts.recordings, counts.manual, counts.auto, counts.source, (CFAbsoluteTimeGetCurrent() - started) * 1_000)
                )
            }
            self.countRefreshLock.lock()
            let rerun = self.countRefreshPending
            self.countRefreshPending = false
            self.countRefreshInFlight = false
            self.countRefreshLock.unlock()
            if rerun { self.refreshSavedCountsFromDisk() }
        }
    }

    private nonisolated static func currentMediaCounts(
        registeredEntries: [Entry]
    ) -> (recordings: Int, manual: Int, auto: Int, source: String) {
        guard RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            let local = scanMediaCounts(registeredEntries: registeredEntries)
            return (local.recordings, local.manual, local.auto, "local-recovery")
        }

        func assetCount(inAlbumNamed name: String) -> Int {
            guard let album = fetchAlbum(named: name) else { return 0 }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.video.rawValue
            )
            return PHAsset.fetchAssets(in: album, options: options).count
        }

        return (
            assetCount(inAlbumNamed: recordingsAlbumName),
            assetCount(inAlbumNamed: manualHighlightsAlbumName),
            assetCount(inAlbumNamed: autoHighlightsAlbumName),
            "Photos"
        )
    }

    private func registeredEntriesSnapshot() -> [Entry] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot
    }

    private nonisolated static func scanMediaCounts(registeredEntries: [Entry]) -> (recordings: Int, manual: Int, auto: Int) {
        let fm = FileManager.default
        guard let documents = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return (0, 0, 0)
        }
        let root = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return (0, 0, 0)
        }
        var recordings = Set<String>()
        var manual = Set<String>()
        var auto = Set<String>()
        for entry in registeredEntries {
            switch entry.albumName {
            case recordingsAlbumName, legacyRecordingsAlbumName:
                recordings.insert(entry.canonicalLocalKey)
            case manualHighlightsAlbumName, legacyManualHighlightsAlbumName:
                manual.insert(entry.canonicalLocalKey)
            case autoHighlightsAlbumName, legacyAutoHighlightsAlbumName:
                auto.insert(entry.canonicalLocalKey)
            default:
                break
            }
        }
        for case let url as URL in enumerator {
            guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { continue }
            let path = url.path.lowercased()
            let name = url.lastPathComponent.lowercased()
            let canonical = canonicalMediaKey(url.lastPathComponent)
            if path.contains(manualHighlightsAlbumName.lowercased())
                || path.contains(legacyManualHighlightsAlbumName.lowercased())
                || name.contains("manual_clip") {
                manual.insert(canonical)
            } else if path.contains(autoHighlightsAlbumName.lowercased())
                || path.contains(legacyAutoHighlightsAlbumName.lowercased())
                || name.contains("auto_highlight") {
                auto.insert(canonical)
            } else if path.contains(recordingsAlbumName.lowercased())
                || path.contains(legacyRecordingsAlbumName.lowercased())
                || name.contains("full_game") {
                recordings.insert(canonical)
            }
        }
        return (recordings.count, manual.count, auto.count)
    }

    /// Explicit-export-only inventory. This performs no background polling and
    /// runs off MainActor so storage evidence cannot stall operator controls.
    nonisolated static func storageDiagnosticsLines() -> [String] {
        struct StoredFile {
            let url: URL
            let logicalBytes: Int64
            let allocatedBytes: Int64
            let modified: Date?
        }
        let fm = FileManager.default
        let roots: [(String, URL?)] = [
            ("Documents", try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)),
            ("Library", try? fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)),
            ("Application Support", try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)),
            ("Caches", try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)),
            ("tmp", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        ]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]

        func files(below root: URL) -> [StoredFile] {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var result: [StoredFile] = []
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                result.append(StoredFile(
                    url: url,
                    logicalBytes: Int64(values.fileSize ?? 0),
                    allocatedBytes: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                    modified: values.contentModificationDate
                ))
            }
            return result
        }

        var lines: [String] = ["Inventory mode: on-demand only; no continuous filesystem scan"]
        var allFilesByPath: [String: StoredFile] = [:]
        var seenRoots = Set<String>()
        for (label, root) in roots {
            guard let root else {
                lines.append("\(label): unavailable")
                continue
            }
            let path = root.standardizedFileURL.path
            guard seenRoots.insert(path).inserted else { continue }
            let stored = files(below: root)
            for file in stored { allFilesByPath[file.url.standardizedFileURL.path] = file }
            let logical = stored.reduce(Int64(0)) { $0 + $1.logicalBytes }
            let allocated = stored.reduce(Int64(0)) { $0 + $1.allocatedBytes }
            lines.append("\(label): files=\(stored.count) logicalBytes=\(logical) allocatedBytes=\(allocated) path=\(path)")
        }

        if let documents = roots.first(where: { $0.0 == "Documents" })?.1 {
            let runtime = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
            let namedSubpaths = [
                "", "Staging", recordingsAlbumName, manualHighlightsAlbumName,
                autoHighlightsAlbumName, "ClipBuffer", "ClipBuffer/segments",
                "ClipExports", "ClipExports/working", "ClipExports/complete", "ClipExports/failed",
                logsFolderName
            ]
            for subpath in namedSubpaths {
                let url = subpath.isEmpty ? runtime : runtime.appendingPathComponent(subpath, isDirectory: true)
                let stored = files(below: url)
                let logical = stored.reduce(Int64(0)) { $0 + $1.logicalBytes }
                let allocated = stored.reduce(Int64(0)) { $0 + $1.allocatedBytes }
                lines.append("Runtime/\(subpath.isEmpty ? "total" : subpath): files=\(stored.count) logicalBytes=\(logical) allocatedBytes=\(allocated)")
            }
            let externalLogs = documents.appendingPathComponent(logsFolderName, isDirectory: true)
            let storedLogs = files(below: externalLogs)
            lines.append("Documents/\(logsFolderName): files=\(storedLogs.count) logicalBytes=\(storedLogs.reduce(Int64(0)) { $0 + $1.logicalBytes })")
        }

        let formatter = ISO8601DateFormatter()
        lines.append("Largest 20 files:")
        let allFiles = Array(allFilesByPath.values)
        for file in allFiles.sorted(by: { $0.allocatedBytes > $1.allocatedBytes }).prefix(20) {
            lines.append("\(file.url.path) | logicalBytes=\(file.logicalBytes) allocatedBytes=\(file.allocatedBytes) modified=\(file.modified.map(formatter.string(from:)) ?? "unknown")")
        }
        if allFiles.isEmpty { lines.append("none") }
        return lines
    }

    func noteLocalMediaSaved(url: URL, albumName: String) {
        publishOnMain {
            self.lastSavedAlbumName = albumName
            self.lastSavedMediaName = url.lastPathComponent
            self.refreshSavedCountsFromDisk()
        }
    }

    private func photosPersistenceRequestKey(url: URL, albumName: String) -> String {
        "\(albumName)|\(Self.canonicalMediaKey(url.lastPathComponent))"
    }

    /// Returns true only for the first physical request. Later callers for the
    /// same file are attached to the in-flight acknowledgement and receive the
    /// same final result. This is state coalescing at the authoritative owner,
    /// not a timer/debounce.
    private func beginPhotosPersistenceRequest(
        key: String,
        completion: ((Bool, Error?) -> Void)?
    ) -> Bool {
        photosPersistenceLock.lock()
        if photosPersistenceWaiters[key] != nil {
            if let completion { photosPersistenceWaiters[key, default: []].append(completion) }
            photosPersistenceLock.unlock()
            return false
        }
        photosPersistenceWaiters[key] = completion.map { [$0] } ?? []
        photosPersistenceLock.unlock()
        return true
    }

    private func finishPhotosPersistenceRequest(
        key: String,
        success: Bool,
        error: Error?
    ) {
        photosPersistenceLock.lock()
        let completions = photosPersistenceWaiters.removeValue(forKey: key) ?? []
        photosPersistenceLock.unlock()
        completions.forEach { $0(success, error) }
    }

    func saveVideo(url: URL, albumName: String, mediaKind: String, completion: ((Bool, Error?) -> Void)? = nil) {
        guard RinkLensPhotoLibraryPrivacyGuard.canUseReadWritePhotosAPI else {
            markPhotosIntegrationUnavailable(mediaKind: mediaKind)
            completion?(false, nil)
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            publishStatus(status)
            if status == .notDetermined {
                publishOnMain {
                    self.photoLibraryStatusText = "Photos access not requested"
                    self.photoLibraryAccessDetailText = "\(mediaKind.capitalized) is saved in RinkLens Files. Use Request Photos Access before the next export."
                }
            }
            completion?(false, nil)
            return
        }

        // A registry entry is written only after PhotoKit returns and the
        // physical PHAsset identifier is verified. Treat that as an already
        // acknowledged save rather than attempting to recreate the same asset.
        if entry(forLocalFilename: url.lastPathComponent, albumName: albumName) != nil {
            MainThreadStallMonitor.shared.trace("recording photos save already acknowledged: \(mediaKind) \(url.lastPathComponent)")
            completion?(true, nil)
            return
        }

        let persistenceKey = photosPersistenceRequestKey(url: url, albumName: albumName)
        guard beginPhotosPersistenceRequest(key: persistenceKey, completion: completion) else {
            MainThreadStallMonitor.shared.trace("recording photos save coalesced: \(mediaKind) \(url.lastPathComponent)")
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "media_video_persistence_coalesced",
                entityID: url.lastPathComponent,
                previous: ["photosAsset": "pending"],
                next: ["album": albumName, "owner": "existing-request"],
                source: "MediaRepository.saveVideo",
                reason: "Duplicate persistence request joined the authoritative in-flight PhotoKit transaction",
                authoritativeOwner: "MediaRepository"
            )
            return
        }

        MainThreadStallMonitor.shared.trace("recording photos save queued: \(mediaKind) \(url.lastPathComponent)")
        publishOnMain {
            self.photoPersistenceActivityText = "Saving \(mediaKind) to Photos"
        }
        RinkLensStructuredEventLogger.shared.record(
            domain: .recording,
            event: "media_video_persistence_requested",
            entityID: url.lastPathComponent,
            previous: ["photosAsset": "none"],
            next: ["album": albumName, "queue": "media.repository.photos.background"],
            source: "MediaRepository.saveVideo",
            reason: "Persist completed recording media without blocking route presentation",
            authoritativeOwner: "MediaRepository"
        )
        enqueuePhotosPersistenceOperation(label: "Photos \(mediaKind) \(url.lastPathComponent)") { [weak self] finish in
            guard let self else { finish(); return }
            self.publishOnMain { self.photoPersistenceActivityText = "Saving \(mediaKind) to Photos…" }
            Self.performVideoSaveToPhotosAlbum(url: url, albumName: albumName, mediaKind: mediaKind) { [weak self] success, assetIdentifier, error in
                guard let self else { finish(); return }
                let verifiedAssetIdentifier = success
                    ? assetIdentifier.flatMap(Self.verifiedPhotosAssetIdentifier)
                    : nil
                let persistenceAccepted = success && verifiedAssetIdentifier != nil
                var localSourceReleased = false
                if let verifiedAssetIdentifier {
                    self.register(
                        localURL: url,
                        albumName: albumName,
                        photosAssetIdentifier: verifiedAssetIdentifier,
                        photosOriginalFilename: url.lastPathComponent
                    )
                    localSourceReleased = self.releaseConfirmedLocalSource(
                        at: url,
                        albumName: albumName,
                        photosAssetIdentifier: verifiedAssetIdentifier,
                        reason: "Photos persistence physically acknowledged; Photos is the permanent media authority"
                    )
                    MainThreadStallMonitor.traceFromAnyQueue("recording photos save completed: \(mediaKind) album=\(albumName)")
                } else {
                    MainThreadStallMonitor.traceFromAnyQueue("recording photos save failed: \(mediaKind) error=\(error?.localizedDescription ?? "unknown")")
                }
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: persistenceAccepted ? "media_video_persistence_completed" : "media_video_persistence_failed",
                    entityID: url.lastPathComponent,
                    previous: ["photosAsset": "pending"],
                    next: [
                        "photosAsset": verifiedAssetIdentifier ?? "none",
                        "success": String(persistenceAccepted),
                        "localSource": localSourceReleased ? "released" : "retained",
                        "error": error?.localizedDescription ?? "none"
                    ],
                    source: "MediaRepository.photosWorkQueue",
                    reason: persistenceAccepted
                        ? "Background Photos persistence, physical asset verification, registry update and local-source ownership release completed"
                        : "Photos persistence was not physically verified; local file retained",
                    authoritativeOwner: "MediaRepository"
                )
                if persistenceAccepted {
                    self.runConfirmedDuplicateMigrationOnce(reason: "first physically acknowledged Photos persistence")
                }
                self.publishOnMain {
                    self.photoPersistenceActivityText = persistenceAccepted
                        ? "Saved to Photos — local source released"
                        : "Photos save unconfirmed — local recovery file retained"
                }
                self.finishPhotosPersistenceRequest(
                    key: persistenceKey,
                    success: persistenceAccepted,
                    error: error
                )
                finish()
            }
        }
    }

    func openPhotosApp() {
        publishOnMain {
            self.photosOpenHelpText = "Photos opened. iOS cannot reliably deep-link to a specific album; use the Media Summary tiles for exact in-app RinkLens album access."
            if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        }
    }

    func openAppSettings() {
        publishOnMain {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    private func markPhotosIntegrationUnavailable(mediaKind: String? = nil) {
        publishOnMain {
            self.photoLibraryStatusText = "Photos integration unavailable"
            self.photoLibraryAccessDetailText = RinkLensPhotoLibraryPrivacyGuard.missingUsageMessage
            if let mediaKind {
                MainThreadStallMonitor.shared.trace("\(mediaKind) retained in app Files only; Photos usage description missing")
            }
        }
    }

    private func publishStatus(_ status: PHAuthorizationStatus) {
        publishOnMain {
            switch status {
            case .authorized:
                self.photoLibraryStatusText = "Full Photos access"
                self.photoLibraryAccessDetailText = "Recordings can be saved into RinkLens Photos albums."
            case .limited:
                self.photoLibraryStatusText = "Limited Photos access"
                self.photoLibraryAccessDetailText = "Full Photos access is needed to check/reuse existing albums. Media stays in app Files to avoid creating duplicate albums."
            case .notDetermined:
                self.photoLibraryStatusText = "Photos access not requested"
                self.photoLibraryAccessDetailText = "Tap Request Photos Access before saving recordings or clips."
            case .denied:
                self.photoLibraryStatusText = "Photos access denied"
                self.photoLibraryAccessDetailText = "Open iPad Settings and allow Photos access for this app."
            case .restricted:
                self.photoLibraryStatusText = "Photos access restricted"
                self.photoLibraryAccessDetailText = "Photos access is blocked by iPad restrictions or device management."
            @unknown default:
                self.photoLibraryStatusText = "Photos access status unknown"
                self.photoLibraryAccessDetailText = "iOS returned an unknown Photos permission state."
            }
        }
    }

    private func incrementSavedCount(albumName: String) {
        switch albumName {
        case Self.recordingsAlbumName:
            savedRecordingsCount += 1
        case Self.manualHighlightsAlbumName:
            savedManualHighlightsCount += 1
        case Self.autoHighlightsAlbumName:
            savedAutoHighlightsCount += 1
        default:
            break
        }
    }

    private func publishOnMain(_ update: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private nonisolated static func performEnsurePhotoAlbumsExist(albumNames: [String], completion: @escaping (Bool, Error?) -> Void) {
        photosWorkQueue.async {
            let missing = albumNames.filter { fetchAlbum(named: $0) == nil }
            guard !missing.isEmpty else {
                DispatchQueue.main.async { completion(true, nil) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for name in missing { PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name) }
            }, completionHandler: { success, error in
                DispatchQueue.main.async { completion(success, error) }
            })
        }
    }

    private nonisolated static func performVideoSaveToPhotosAlbum(
        url: URL,
        albumName: String,
        mediaKind: String,
        completion: @escaping (Bool, String?, Error?) -> Void
    ) {
        photosWorkQueue.async {
            var placeholderIdentifier: String?
            PHPhotoLibrary.shared().performChanges({
                let creation = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                placeholderIdentifier = creation?.placeholderForCreatedAsset?.localIdentifier
                if let placeholder = creation?.placeholderForCreatedAsset,
                   let albumRequest = albumChangeRequest(named: albumName) {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            }, completionHandler: { success, error in
                completion(success, placeholderIdentifier, error)
            })
        }
    }

    private nonisolated static func verifiedPhotosAssetIdentifier(_ identifier: String) -> String? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return result.firstObject == nil ? nil : identifier
    }

    private nonisolated static func isOwnedRuntimeMediaURL(_ url: URL) -> Bool {
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()),
              let documents = try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
              ) else { return false }
        let ownedRoot = documents
            .appendingPathComponent("LiveRinkLensLive", isDirectory: true)
            .standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(ownedRoot)
    }

    /// Removes only legacy app-owned copies whose exact registry entry is backed
    /// by a PHAsset that still physically exists. Unknown, partial and failed
    /// recordings are deliberately retained as recovery media.
    private func runConfirmedDuplicateMigrationOnce(reason: String) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        duplicateMigrationLock.lock()
        guard !duplicateMigrationStarted else {
            duplicateMigrationLock.unlock()
            return
        }
        duplicateMigrationStarted = true
        duplicateMigrationSummary = "Queued — \(reason)"
        duplicateMigrationLock.unlock()

        enqueuePostCaptureOperation(label: "Verified media duplicate migration") { [weak self] finish in
            guard let self else { finish(); return }
            Self.photosWorkQueue.async { [weak self] in
                guard let self else { finish(); return }
                let registry = self.registeredEntriesSnapshot()
                let identifiers = registry.map(\.photosAssetIdentifier)
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                var existingPhotosIdentifiers = Set<String>()
                fetched.enumerateObjects { asset, _, _ in
                    existingPhotosIdentifiers.insert(asset.localIdentifier)
                }

                var entriesByFilename: [String: [Entry]] = [:]
                for entry in registry where existingPhotosIdentifiers.contains(entry.photosAssetIdentifier) {
                    entriesByFilename[entry.localFilename, default: []].append(entry)
                }

                var releasedFiles = 0
                var releasedBytes: Int64 = 0
                var retainedFiles = 0
                if let documents = try? FileManager.default.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                ) {
                    let root = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
                    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                    if let enumerator = FileManager.default.enumerator(
                        at: root,
                        includingPropertiesForKeys: keys,
                        options: [.skipsHiddenFiles]
                    ) {
                        for case let url as URL in enumerator {
                            guard Self.isOwnedRuntimeMediaURL(url),
                                  !url.lastPathComponent.localizedCaseInsensitiveContains("_partial") else { continue }
                            guard let exactMatches = entriesByFilename[url.lastPathComponent], exactMatches.count == 1,
                                  let entry = exactMatches.first else {
                                retainedFiles += 1
                                continue
                            }
                            guard !RinkLensRecordingCaptureLease.shared.isWriterContractOpen(),
                                  RinkLensExecutionCoordinator.shared.admitsDeferredMediaWork() else {
                                retainedFiles += 1
                                continue
                            }
                            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            if self.releaseConfirmedLocalSource(
                                at: url,
                                albumName: entry.albumName,
                                photosAssetIdentifier: entry.photosAssetIdentifier,
                                reason: "One-time migration proved exact registry identity and existing Photos asset",
                                refreshCounts: false
                            ) {
                                releasedFiles += 1
                                releasedBytes += bytes
                            } else {
                                retainedFiles += 1
                            }
                        }
                    }
                }
                let summary = "Released \(releasedFiles) verified duplicate(s), \(releasedBytes) bytes; retained \(retainedFiles) unproven/recovery file(s)"
                self.duplicateMigrationLock.lock()
                self.duplicateMigrationSummary = summary
                self.duplicateMigrationLock.unlock()
                RinkLensStructuredEventLogger.shared.record(
                    domain: .recording,
                    event: "media_confirmed_duplicate_migration_completed",
                    entityID: "LiveRinkLensLive",
                    previous: ["registeredEntries": String(registry.count)],
                    next: [
                        "releasedFiles": String(releasedFiles),
                        "releasedBytes": String(releasedBytes),
                        "retainedFiles": String(retainedFiles)
                    ],
                    source: "MediaRepository.runConfirmedDuplicateMigrationOnce",
                    reason: reason,
                    authoritativeOwner: "MediaRepository"
                )
                self.refreshSavedCountsFromDisk()
                finish()
            }
        }
    }

    @discardableResult
    private func releaseConfirmedLocalSource(
        at url: URL,
        albumName: String,
        photosAssetIdentifier: String,
        reason: String,
        refreshCounts: Bool = true
    ) -> Bool {
        guard Self.isOwnedRuntimeMediaURL(url),
              !url.lastPathComponent.localizedCaseInsensitiveContains("_partial"),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        let sizeBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        do {
            try FileManager.default.removeItem(at: url)
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "media_local_source_released",
                entityID: url.lastPathComponent,
                previous: [
                    "path": url.path,
                    "sizeBytes": String(sizeBytes),
                    "owner": "MediaRepository"
                ],
                next: [
                    "localSource": "removed",
                    "photosAsset": photosAssetIdentifier,
                    "album": albumName,
                    "permanentAuthority": "Photos"
                ],
                source: "MediaRepository.releaseConfirmedLocalSource",
                reason: reason,
                authoritativeOwner: "MediaRepository"
            )
            MainThreadStallMonitor.traceFromAnyQueue(
                "media local source released file=\(url.lastPathComponent) bytes=\(sizeBytes) photosAsset=\(photosAssetIdentifier)"
            )
            if refreshCounts { refreshSavedCountsFromDisk() }
            return true
        } catch {
            RinkLensStructuredEventLogger.shared.record(
                domain: .recording,
                event: "media_local_source_release_failed",
                entityID: url.lastPathComponent,
                previous: ["path": url.path, "sizeBytes": String(sizeBytes)],
                next: ["localSource": "retained", "photosAsset": photosAssetIdentifier, "error": error.localizedDescription],
                source: "MediaRepository.releaseConfirmedLocalSource",
                reason: "Photos is verified but the app-owned transient source could not be removed",
                authoritativeOwner: "MediaRepository"
            )
            return false
        }
    }

    private nonisolated static func albumChangeRequest(named albumName: String) -> PHAssetCollectionChangeRequest? {
        if let album = fetchAlbum(named: albumName) {
            return PHAssetCollectionChangeRequest(for: album)
        }
        return PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
    }

    private nonisolated static func fetchAlbum(named albumName: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumName)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }

    private nonisolated static func loadEntries(from url: URL?) -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func persistLocked() {
        guard let storeURL else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            MainThreadStallMonitor.shared.trace("media repository save failed: \(error.localizedDescription)")
        }
    }
}
/// Temporary source-compatible name for the pre-UX16d3 registry.
typealias LocalRecordingMediaAssetRegistry = MediaRepository

#endif
