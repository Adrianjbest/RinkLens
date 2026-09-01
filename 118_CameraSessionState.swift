// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreGraphics

/// v0.8.8m8 — Camera Stability / Ownership Pass
///
/// Lightweight camera lifecycle/preview metadata used for diagnostics and
/// idempotency. This file intentionally contains no AVCapture code and makes no
/// camera, OCR, recording, media-browser or UI-layout changes by itself.
nonisolated enum CameraSessionState: Equatable, CustomStringConvertible {
    case idle
    case configuring
    case starting
    case running
    case stopping
    case failed(String)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .configuring: return "configuring"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

nonisolated enum CameraDisplayOrientation: String, CaseIterable, Identifiable, CustomStringConvertible {
    case landscapeLeft
    case landscapeRight
    case portrait
    case portraitUpsideDown
    case unknown

    var id: String { rawValue }
    var description: String { rawValue }
}

nonisolated struct CameraPreviewAttachmentSignature: Equatable, CustomStringConvertible {
    let hostID: String
    let frameDescription: String
    let sessionAssigned: Bool

    var description: String {
        "host=\(hostID) \(frameDescription) \(sessionAssigned ? "session assigned" : "session missing")"
    }
}

nonisolated struct CameraOwnershipDiagnosticSnapshot: Equatable {
    let owner: String
    let previewHost: String
    let sessionState: CameraSessionState
    let displayOrientation: CameraDisplayOrientation
    let previewMirrored: Bool
    let lastAttachReason: String
    let sessionRunning: Bool
}
#endif
