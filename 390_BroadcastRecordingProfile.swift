// BUILD 707 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import AVFoundation
import CoreGraphics

// MARK: - v0.8.7 Persistent Broadcast Renderer + 60fps Recording Foundation

/// Recording profile used by the Phase 2/3 recording pipeline.
/// Build 728 ownership contract:
/// - CaptureEngine/HockeyCameraService owns the verified physical camera source.
/// - RecordingEngine owns the encoded output mode, codec and exact bitrate.
/// - `recordingProfile` remains a compatibility projection for rollback callers;
///   enabled Build 728 code reads `activeRecordingOutputMode` and related policy.
/// - Broadcast stabilisation is owned by RinkLensCameraControlStore.
nonisolated struct BroadcastRecordingProfile: Codable, Equatable {
    enum Resolution: String, CaseIterable, Codable, Identifiable {
        case hd720 = "720p"
        case fullHD1080 = "1080p"

        var id: String { rawValue }

        var size: CGSize {
            switch self {
            case .hd720: return CGSize(width: 1280, height: 720)
            case .fullHD1080: return CGSize(width: 1920, height: 1080)
            }
        }
    }

    enum FrameRate: Int, CaseIterable, Codable, Identifiable {
        case fps15 = 15
        case fps24 = 24
        case fps25 = 25
        case fps30 = 30
        case fps50 = 50
        case fps60 = 60

        var id: Int { rawValue }
        var label: String { "\(rawValue)fps" }
    }

    enum OutputMode: String, CaseIterable, Codable, Identifiable {
        case hd720p30 = "720p at 30 fps"
        case hd720p60 = "720p at 60 fps"
        case fullHD1080p30 = "1080p at 30 fps"
        case fullHD1080p60 = "1080p at 60 fps"

        var id: String { rawValue }

        var resolution: Resolution {
            switch self {
            case .hd720p30, .hd720p60: return .hd720
            case .fullHD1080p30, .fullHD1080p60: return .fullHD1080
            }
        }

        var frameRate: FrameRate {
            switch self {
            case .hd720p30, .fullHD1080p30: return .fps30
            case .hd720p60, .fullHD1080p60: return .fps60
            }
        }

        var compactLabel: String {
            "\(resolution.rawValue) / \(frameRate.label)"
        }

        var purposeText: String {
            switch self {
            case .hd720p30: return "Smallest practical sports file"
            case .hd720p60: return "Smooth motion with a lighter HD frame"
            case .fullHD1080p30: return "Balanced Full HD recording"
            case .fullHD1080p60: return "Smooth Full HD for fast play"
            }
        }

        var recommendedMinimumBitrateMbps: Int {
            switch self {
            case .hd720p30: return 4
            case .hd720p60: return 8
            case .fullHD1080p30: return 8
            case .fullHD1080p60: return 16
            }
        }
    }

    enum Codec: String, CaseIterable, Codable, Identifiable {
        case h264 = "H.264"
        case h265 = "H.265"

        var id: String { rawValue }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .h265: return .hevc
            }
        }

        var settingsTitle: String {
            switch self {
            case .h264: return "H.264"
            case .h265: return "HEVC (H.265)"
            }
        }

        var settingsDetail: String {
            switch self {
            case .h264: return "Broad playback support across Apple, Windows and web tools."
            case .h265: return "Keeps similar detail in a smaller file when the iPad supports hardware HEVC encoding."
            }
        }
    }

    enum Bitrate: String, CaseIterable, Codable, Identifiable {
        case safe = "Safe"
        case medium = "Medium"
        case high = "High"

        var id: String { rawValue }

        func bitsPerSecond(resolution: Resolution, fps: FrameRate) -> Int {
            bitsPerSecond(resolution: resolution, framesPerSecond: fps.rawValue)
        }

        func bitsPerSecond(resolution: Resolution, framesPerSecond: Int) -> Int {
            bitsPerSecond(outputSize: resolution.size, framesPerSecond: Double(framesPerSecond))
        }

        func bitsPerSecond(outputSize: CGSize, framesPerSecond: Double) -> Int {
            let base: Int
            switch self {
            case .safe: base = 4_000_000
            case .medium: base = 8_000_000
            case .high: base = 14_000_000
            }
            let referencePixels = 1280.0 * 720.0
            let sourcePixels = max(1.0, Double(outputSize.width) * Double(outputSize.height))
            let resolutionMultiplier = sourcePixels / referencePixels
            let fpsMultiplier = max(1.0, framesPerSecond) / 30.0
            return Int(Double(base) * resolutionMultiplier * fpsMultiplier)
        }
    }

    enum Stabilisation: String, CaseIterable, Codable, Identifiable {
        case off = "Off"
        case standard = "Standard"

        var id: String { rawValue }
    }

    var resolution: Resolution = .fullHD1080
    var frameRate: FrameRate = .fps30
    var codec: Codec = .h265
    var bitrate: Bitrate = .medium
    var stabilisation: Stabilisation = .off

    var label: String {
        "\(resolution.rawValue) / \(frameRate.label) / \(codec.rawValue) / \(bitrate.rawValue)"
    }
}

/// Lightweight diagnostics for the persistent broadcast render foundation.
@MainActor
final class PersistentBroadcastRendererDiagnostics: ObservableObject {
    static let shared = PersistentBroadcastRendererDiagnostics()

    @Published private(set) var targetFPS: Int = 30
    @Published private(set) var actualFPS: String = "--"
    @Published private(set) var renderMode: String = "persistent renderer idle"
    @Published private(set) var lastRenderTimeMs: String = "--"
    private(set) var renderDrops: Int = 0
    private(set) var encoderBacklog: Int = 0
    @Published private(set) var lastFrameSource: String = "--"
    @Published private(set) var lastFrameSize: String = "--"

    private var lastFPSWindowStarted = Date()
    private var lastDiagnosticsPublishAt = Date.distantPast
    private var pendingLastRenderTimeMs: String = "--"
    private var pendingLastFrameSource: String = "--"
    private var pendingLastFrameSize: String = "--"
    private var framesInWindow = 0

    private init() {}

    func configure(targetFPS: Int, mode: String) {
        if self.targetFPS != targetFPS { self.targetFPS = targetFPS }
        if self.renderMode != mode { self.renderMode = mode }
        framesInWindow = 0
        lastFPSWindowStarted = Date()
        lastDiagnosticsPublishAt = .distantPast
    }

    func noteFrameRendered(durationMs: Double, source: String, size: CGSize) {
        framesInWindow += 1
        pendingLastRenderTimeMs = String(format: "%.1fms", durationMs)
        pendingLastFrameSource = source
        pendingLastFrameSize = "\(Int(size.width))x\(Int(size.height))"
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSWindowStarted)
        if elapsed >= 1.0 {
            let nextFPS = String(format: "%.1ffps", Double(framesInWindow) / elapsed)
            if actualFPS != nextFPS { actualFPS = nextFPS }
            framesInWindow = 0
            lastFPSWindowStarted = now
        }
        guard now.timeIntervalSince(lastDiagnosticsPublishAt) >= MainThreadStallMonitor.shared.rendererDiagnosticsPublishInterval() else { return }
        lastDiagnosticsPublishAt = now
        if lastRenderTimeMs != pendingLastRenderTimeMs { lastRenderTimeMs = pendingLastRenderTimeMs }
        if lastFrameSource != pendingLastFrameSource { lastFrameSource = pendingLastFrameSource }
        if lastFrameSize != pendingLastFrameSize { lastFrameSize = pendingLastFrameSize }
        if renderMode != "persistent render loop running at \(targetFPS)fps" {
            renderMode = "persistent render loop running at \(targetFPS)fps"
        }
    }


    /// UX16c27 receives an immutable, throttled snapshot from the background
    /// writer rather than inferring FPS from MainActor callback frequency.
    func noteBackgroundWorkerProgress(
        actualFPS: Double,
        renderDurationMS: Double,
        source: String,
        size: CGSize,
        backlog: Int,
        decision: String
    ) {
        self.actualFPS = String(format: "%.1ffps", actualFPS)
        self.lastRenderTimeMs = String(format: "%.1fms", renderDurationMS)
        self.lastFrameSource = source
        self.lastFrameSize = "\(Int(size.width))x\(Int(size.height))"
        self.encoderBacklog = backlog
        self.renderMode = "UX16c27 background worker: \(decision)"
    }

    func noteDrop(reason: String) {
        renderDrops += 1
        let nextMode = "drop: \(reason)"
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticsPublishAt) >= MainThreadStallMonitor.shared.rendererDiagnosticsPublishInterval() else { return }
        lastDiagnosticsPublishAt = now
        if renderMode != nextMode { renderMode = nextMode }
    }

    func setBacklog(_ backlog: Int) {
        // Backlog is sampled by the diagnostics UI; avoid publishing every
        // 0→1→0 transition during the 60fps frame loop.
        encoderBacklog = backlog
    }
}
#endif
