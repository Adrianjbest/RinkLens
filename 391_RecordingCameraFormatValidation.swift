// BUILD 707 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreGraphics

// MARK: - Build 707 Camera-Source Recording Authority

/// Immutable snapshot of the authoritative Broadcast camera source used to
/// configure one recording session. It is evidence/projection, not a second
/// writable camera-format owner.
nonisolated struct RecordingCameraSourceProfile: Equatable, Sendable {
    let width: Int
    let height: Int
    let cadence: RinkLensCaptureCadence
    let formatText: String
    let physicalDeviceID: String?
    let captureGeneration: Int

    init(
        width: Int,
        height: Int,
        cadence: RinkLensCaptureCadence,
        formatText: String,
        physicalDeviceID: String?,
        captureGeneration: Int
    ) {
        self.width = width
        self.height = height
        self.cadence = cadence
        self.formatText = formatText
        self.physicalDeviceID = physicalDeviceID
        self.captureGeneration = captureGeneration
    }

    init(
        activeFormat: RinkLensCaptureFormatPreference,
        frameWidth: Int,
        frameHeight: Int,
        physicalDeviceID: String?,
        captureGeneration: Int
    ) {
        self.init(
            width: frameWidth,
            height: frameHeight,
            cadence: activeFormat.cadence,
            formatText: activeFormat.diagnosticText,
            physicalDeviceID: physicalDeviceID,
            captureGeneration: captureGeneration
        )
    }

    var outputSize: CGSize { CGSize(width: width, height: height) }
    var framesPerSecond: Int { cadence.nominalFPS }
    var exactFramesPerSecond: Double { cadence.framesPerSecond }
    var displayText: String { "\(width)x\(height) @ \(cadence.displayText)fps" }

    var resolutionProjection: BroadcastRecordingProfile.Resolution {
        // Recovery CY / RL-163: the recording programme is capped at 1080p.
        if width >= 1900 || height >= 1000 { return .fullHD1080 }
        return .hd720
    }

    var frameRateProjection: BroadcastRecordingProfile.FrameRate {
        BroadcastRecordingProfile.FrameRate.allCases
            .min(by: { abs($0.rawValue - framesPerSecond) < abs($1.rawValue - framesPerSecond) }) ?? .fps30
    }

    /// Rollback-only parser retained so a disabled feature flag can compare the
    /// former string-derived behaviour. The enabled Build 707 start path uses
    /// `RinkLensCaptureEngineSnapshot.liveFormat` and never treats logs/UI text
    /// as camera configuration.
    static func parseLegacyText(
        formatText: String,
        physicalDeviceID: String?,
        captureGeneration: Int
    ) -> RecordingCameraSourceProfile? {
        let lower = formatText.lowercased()
        guard let x = lower.firstIndex(of: "x") else { return nil }
        let leftDigits = lower[..<x].reversed().drop { !$0.isNumber }.prefix { $0.isNumber }
        let rightDigits = lower[lower.index(after: x)...].prefix { $0.isNumber }
        guard let width = Int(String(leftDigits.reversed())),
              let height = Int(String(rightDigits)),
              width > 0, height > 0 else { return nil }

        let fps: Int?
        if let marker = lower.range(of: "activefps=") {
            let digits = lower[marker.upperBound...].prefix { $0.isNumber }
            fps = Int(String(digits))
        } else if let marker = lower.range(of: "fps") {
            let digits = lower[..<marker.lowerBound].reversed().drop { !$0.isNumber }.prefix { $0.isNumber }
            fps = Int(String(digits.reversed()))
        } else {
            fps = nil
        }
        guard let fps, fps > 0 else { return nil }
        return RecordingCameraSourceProfile(
            width: width,
            height: height,
            cadence: .init(integerFPS: fps),
            formatText: formatText,
            physicalDeviceID: physicalDeviceID,
            captureGeneration: captureGeneration
        )
    }
}


/// Result returned by the camera preflight before recording is allowed to start.
/// This is intentionally small and value-based so the guard can be used by the
/// camera service, recording controls and diagnostics without coupling those files.
nonisolated struct RecordingCameraFormatValidationResult: Equatable, Sendable {
    let isValid: Bool
    let requestedFormatText: String
    let activeFormatText: String
    let failureReason: String?
    let sourceProfile: RecordingCameraSourceProfile?

    var operatorMessage: String {
        if isValid {
            return "Recording camera format verified: \(activeFormatText) for \(requestedFormatText)."
        }
        return failureReason ?? "Recording camera format is not compatible with \(requestedFormatText). Active format: \(activeFormatText)."
    }

    static func valid(requested: String, active: String, sourceProfile: RecordingCameraSourceProfile) -> RecordingCameraFormatValidationResult {
        RecordingCameraFormatValidationResult(
            isValid: true,
            requestedFormatText: requested,
            activeFormatText: active,
            failureReason: nil,
            sourceProfile: sourceProfile
        )
    }

    static func invalid(requested: String, active: String, reason: String) -> RecordingCameraFormatValidationResult {
        RecordingCameraFormatValidationResult(
            isValid: false,
            requestedFormatText: requested,
            activeFormatText: active,
            failureReason: reason,
            sourceProfile: nil
        )
    }
}

@MainActor
final class RecordingCameraFormatValidationDiagnostics: ObservableObject {
    static let shared = RecordingCameraFormatValidationDiagnostics()

    /// Build 711: camera/AVFoundation queues submit immutable validation
    /// evidence through this bridge. Only the MainActor diagnostics owner
    /// mutates the published projection.
    nonisolated static func noteFromAnyQueue(
        _ validation: RecordingCameraFormatValidationResult,
        checkedAt: Date = Date()
    ) {
        Task { @MainActor in
            RecordingCameraFormatValidationDiagnostics.shared.note(validation, checkedAt: checkedAt)
        }
    }

    @Published private(set) var requestedRecordingProfileText: String = "not checked"
    @Published private(set) var activeCameraFormatText: String = "not checked"
    @Published private(set) var is60FPSCapableText: String = "Unknown"
    @Published private(set) var preflightResultText: String = "Not run"
    @Published private(set) var blockReasonText: String = "none"
    @Published private(set) var lastCheckedText: String = "never"

    private init() {}

    func note(_ validation: RecordingCameraFormatValidationResult, checkedAt: Date = Date()) {
        requestedRecordingProfileText = validation.requestedFormatText
        activeCameraFormatText = validation.activeFormatText
        let activeFPS = validation.sourceProfile?.framesPerSecond ?? Self.parseFPS(from: validation.activeFormatText)
        if let activeFPS {
            is60FPSCapableText = activeFPS >= 55 ? "Yes" : "No — native source \(activeFPS)fps"
        } else {
            is60FPSCapableText = validation.isValid ? "Unknown" : "No"
        }
        preflightResultText = validation.isValid ? "Passed with native-source enforcement" : "Blocked"
        blockReasonText = validation.failureReason ?? "none"
        lastCheckedText = Self.formatter.string(from: checkedAt)
    }

    private static func parseFPS(from text: String) -> Int? {
        let lower = text.lowercased()
        guard let range = lower.range(of: "fps") else { return nil }
        let prefix = lower[..<range.lowerBound]
        let digits = prefix.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

#endif
