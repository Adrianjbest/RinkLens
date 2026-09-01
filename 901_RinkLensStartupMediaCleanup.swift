// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation

// MARK: - v9.2 Stage 8a Crash Orphan Clip Cleanup

/// Launch-time media housekeeping for temporary rolling clip files.
///
/// Saved clips and recordings are deliberately outside this cleanup. This only
/// removes orphan rolling-buffer media that may be left behind if the app is
/// force-quit or crashes while the rolling clip buffer is active.
final class RinkLensStartupMediaCleanup {
    static let shared = RinkLensStartupMediaCleanup()

    struct Snapshot {
        var ranAt: Date?
        var reason: String
        var scannedFiles: Int
        var deletedFiles: Int
        var retainedFiles: Int
        var deletedRollingSegments: Int
        var deletedWorkingExports: Int
        var deletedFailedExports: Int
        var removedManifestSegments: Int
        var retainedManifestExports: Int
        var skippedReason: String?

        static let notRun = Snapshot(
            ranAt: nil,
            reason: "not run",
            scannedFiles: 0,
            deletedFiles: 0,
            retainedFiles: 0,
            deletedRollingSegments: 0,
            deletedWorkingExports: 0,
            deletedFailedExports: 0,
            removedManifestSegments: 0,
            retainedManifestExports: 0,
            skippedReason: nil
        )

        var summaryText: String {
            if let skippedReason { return "Skipped — \(skippedReason)" }
            guard ranAt != nil else { return "Not run" }
            return "scanned=\(scannedFiles) deleted=\(deletedFiles) retained=\(retainedFiles)"
        }

        var detailText: String {
            if let skippedReason { return "Skipped: \(skippedReason)" }
            guard ranAt != nil else { return "Startup media cleanup has not run yet" }
            return "rolling=\(deletedRollingSegments) working=\(deletedWorkingExports) failed=\(deletedFailedExports) manifestSegments=\(removedManifestSegments) retainedExports=\(retainedManifestExports)"
        }
    }

    private struct ClipManifest: Codable {
        var segments: [ClipManifestSegment]
        var exportedClips: [HighlightClipMetadata]
    }

    private struct ClipManifestSegment: Codable {
        var id: UUID
        var filename: String
        var startTime: Date
        var endTime: Date
        var duration: TimeInterval
        var status: String
    }

    private let queue = DispatchQueue(label: "rinklens.startup.media.cleanup", qos: .utility)
    private let lock = NSLock()
    private var hasRun = false
    private var snapshot: Snapshot = .notRun

    private init() {}

    var summaryText: String {
        lock.lock()
        let value = snapshot.summaryText
        lock.unlock()
        return value
    }

    var detailText: String {
        lock.lock()
        let value = snapshot.detailText
        lock.unlock()
        return value
    }

    func runOnceAtLaunch(reason: String = "app launch") {
        lock.lock()
        guard !hasRun else {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        queue.async { [weak self] in
            self?.run(reason: reason)
        }
    }

    private func run(reason: String) {
        if RinkLensRecordingCaptureLease.shared.isRecordingActive() {
            publish(
                Snapshot(
                    ranAt: Date(),
                    reason: reason,
                    scannedFiles: 0,
                    deletedFiles: 0,
                    retainedFiles: 0,
                    deletedRollingSegments: 0,
                    deletedWorkingExports: 0,
                    deletedFailedExports: 0,
                    removedManifestSegments: 0,
                    retainedManifestExports: 0,
                    skippedReason: "recording active"
                )
            )
            return
        }

        do {
            let folders = try resolveFolders()
            try FileManager.default.createDirectory(at: folders.root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folders.clipBuffer, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folders.segments, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folders.working, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folders.failed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folders.complete, withIntermediateDirectories: true)

            var scanned = 0
            var deleted = 0
            var retained = 0

            let deletedSegments = deleteContents(of: folders.segments, scanned: &scanned, deleted: &deleted)
            let deletedWorking = deleteContents(of: folders.working, scanned: &scanned, deleted: &deleted)
            let deletedFailed = deleteContents(of: folders.failed, scanned: &scanned, deleted: &deleted)
            retained += countContents(of: folders.complete)

            let manifestResult = resetClipManifestSegments(at: folders.manifest)
            let result = Snapshot(
                ranAt: Date(),
                reason: reason,
                scannedFiles: scanned,
                deletedFiles: deleted,
                retainedFiles: retained,
                deletedRollingSegments: deletedSegments,
                deletedWorkingExports: deletedWorking,
                deletedFailedExports: deletedFailed,
                removedManifestSegments: manifestResult.removedSegments,
                retainedManifestExports: manifestResult.retainedExports,
                skippedReason: nil
            )
            publish(result)
        } catch {
            publish(
                Snapshot(
                    ranAt: Date(),
                    reason: reason,
                    scannedFiles: 0,
                    deletedFiles: 0,
                    retainedFiles: 0,
                    deletedRollingSegments: 0,
                    deletedWorkingExports: 0,
                    deletedFailedExports: 0,
                    removedManifestSegments: 0,
                    retainedManifestExports: 0,
                    skippedReason: "failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func publish(_ value: Snapshot) {
        lock.lock()
        snapshot = value
        lock.unlock()
        MainThreadStallMonitor.shared.trace("startup media cleanup \(value.summaryText)")
        MainThreadStallMonitor.shared.trace("startup clip cleanup \(value.detailText)")
    }

    private struct FolderSet {
        var root: URL
        var clipBuffer: URL
        var segments: URL
        var manifest: URL
        var working: URL
        var complete: URL
        var failed: URL
    }

    private func resolveFolders() throws -> FolderSet {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents.appendingPathComponent("LiveRinkLensLive", isDirectory: true)
        let clipBuffer = root.appendingPathComponent("ClipBuffer", isDirectory: true)
        let exports = root.appendingPathComponent("ClipExports", isDirectory: true)
        return FolderSet(
            root: root,
            clipBuffer: clipBuffer,
            segments: clipBuffer.appendingPathComponent("segments", isDirectory: true),
            manifest: clipBuffer.appendingPathComponent("manifest.json"),
            working: exports.appendingPathComponent("working", isDirectory: true),
            complete: exports.appendingPathComponent("complete", isDirectory: true),
            failed: exports.appendingPathComponent("failed", isDirectory: true)
        )
    }

    @discardableResult
    private func deleteContents(of folder: URL, scanned: inout Int, deleted: inout Int) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files {
            scanned += 1
            if (try? FileManager.default.removeItem(at: file)) != nil {
                deleted += 1
                removed += 1
            }
        }
        return removed
    }

    private func countContents(of folder: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).count
    }

    private func resetClipManifestSegments(at url: URL) -> (removedSegments: Int, retainedExports: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, 0) }
        guard let data = try? Data(contentsOf: url) else { return (0, 0) }
        let decoder = JSONDecoder()
        guard var manifest = try? decoder.decode(ClipManifest.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return (0, 0)
        }
        let removed = manifest.segments.count
        let retained = manifest.exportedClips.count
        manifest.segments.removeAll()
        if let encoded = try? JSONEncoder().encode(manifest) {
            try? encoded.write(to: url, options: [.atomic])
        }
        return (removed, retained)
    }
}
#endif
