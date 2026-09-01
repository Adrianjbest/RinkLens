// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

// MARK: - v0.8.8 Camera Ownership Trace
// Safe diagnostic layer. It does not mutate the camera; it only records who touched session/preview/recording paths.

enum CameraTraceOwner: String, CaseIterable, Identifiable {
    case broadcast = "Broadcast"
    case calibration = "Calibration"
    case recording = "Recording"
    case diagnostics = "Diagnostics"
    case liveCamera = "Live Camera"
    case ocrCamera = "OCR Camera"
    case unknown = "Unknown"
    var id: String { rawValue }
}

enum CameraTraceAction: String {
    case lifecycle = "lifecycle"
    case route = "route"
    case picker = "picker"
    case selection = "selection"
    case discovery = "discovery"
    case permission = "permission"
    case configure = "configure"
    case graph = "graph"
    case startRunning = "startRunning"
    case stopRunning = "stopRunning"
    case sessionNotification = "sessionNotification"
    case release = "release"
    case recovery = "recovery"
    case attachPreview = "attachPreview"
    case detachPreview = "detachPreview"
    case previewConfigure = "previewConfigure"
    case previewHeartbeat = "previewHeartbeat"
    case previewReady = "previewReady"
    case firstFrame = "firstFrame"
    case frameDelivery = "frameDelivery"
    case frameTapOn = "recordingFrameTapOn"
    case frameTapOff = "recordingFrameTapOff"
    case recordingStarted = "recordingStarted"
    case recordingStopped = "recordingStopped"
    case clipQueued = "clipQueued"
    case clipExported = "clipExported"
    case clipFailed = "clipFailed"
}

struct CameraOwnershipTraceEvent: Identifiable {
    let id = UUID()
    let date: Date
    let owner: CameraTraceOwner
    let action: CameraTraceAction
    let reason: String
    let isMainThread: Bool

    var line: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let thread = isMainThread ? "main" : "bg"
        return "\(formatter.string(from: date))  \(owner.rawValue)  \(action.rawValue)  [\(thread)]  \(reason)"
    }
}

@MainActor
final class CameraOwnershipTraceStore: ObservableObject {
    static let shared = CameraOwnershipTraceStore()

    @Published private(set) var events: [CameraOwnershipTraceEvent] = []
    @Published private(set) var currentOwner: CameraTraceOwner = .unknown
    @Published private(set) var lastSessionMutation: String = "none"
    @Published private(set) var lastPreviewMutation: String = "none"
    @Published private(set) var lastRecordingMutation: String = "none"
    @Published private(set) var currentRecordingOwnerText: String = "none"
    @Published private(set) var currentPreviewOwnerText: String = "none"
    @Published private(set) var currentOCROwnerText: String = "none"
    @Published private(set) var displayedOwnerSourceText: String = "No active owner"
    @Published private(set) var staleOCROwnershipIgnoredText: String = "No"
    @Published private(set) var lastForensicEvent: String = "none"

    // UX16c46: bounded forensic history and duplicate suppression prevent
    // heartbeat/lifecycle loops from becoming a second publication storm.
    private let maxEvents = 240
    private var lastEventFingerprint = ""
    private var lastEventDate = Date.distantPast
    private(set) var repeatedBreadcrumbSuppressionCount = 0
    private init() {}

    private func refreshOwnerSummary(recordingActive: Bool) {
        if recordingActive {
            currentRecordingOwnerText = CameraTraceOwner.recording.rawValue
            displayedOwnerSourceText = "Recording owner is authoritative while recording"
        } else {
            currentRecordingOwnerText = "none"
            displayedOwnerSourceText = "Latest accepted camera/session owner"
        }
    }

    nonisolated static func record(_ action: CameraTraceAction, owner: CameraTraceOwner, reason: String) {
        let boundedReason = String(reason.prefix(320))
        let event = CameraOwnershipTraceEvent(date: Date(), owner: owner, action: action, reason: boundedReason, isMainThread: Thread.isMainThread)
        Task { @MainActor in
            CameraOwnershipTraceStore.shared.append(event)
        }
    }

    private func append(_ event: CameraOwnershipTraceEvent) {
        let fingerprint = "\(event.owner.rawValue)|\(event.action.rawValue)|\(event.reason)"
        if fingerprint == lastEventFingerprint,
           event.date.timeIntervalSince(lastEventDate) < 1.0 {
            repeatedBreadcrumbSuppressionCount &+= 1
            return
        }
        lastEventFingerprint = fingerprint
        lastEventDate = event.date
        events.insert(event, at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }

        let recordingActive = RinkLensRecordingCaptureLease.shared.isRecordingActive()

        lastForensicEvent = event.line

        switch event.action {
        case .startRunning, .stopRunning, .configure, .graph, .permission, .sessionNotification, .release, .recovery, .selection, .discovery, .route, .picker, .lifecycle:
            if !recordingActive {
                currentOwner = event.owner
            }
            if event.owner == .ocrCamera { currentOCROwnerText = event.owner.rawValue }
            lastSessionMutation = event.line
        case .attachPreview, .detachPreview, .previewConfigure, .previewHeartbeat, .previewReady:
            // v0.9.1t: while recording, passive preview heartbeat/detach events
            // must not make the global trace claim "Current owner: OCR Camera".
            // Recording ownership remains the effective owner until recording ends.
            if !recordingActive {
                currentOwner = event.owner
                currentPreviewOwnerText = event.owner.rawValue
                staleOCROwnershipIgnoredText = "No"
            } else if event.owner == .ocrCamera {
                staleOCROwnershipIgnoredText = "Yes"
            }
            if event.owner == .ocrCamera { currentOCROwnerText = event.owner.rawValue }
            lastPreviewMutation = event.line
        case .firstFrame, .frameDelivery:
            if !recordingActive {
                currentOwner = event.owner
            }
            if event.owner == .ocrCamera { currentOCROwnerText = event.owner.rawValue }
            lastSessionMutation = event.line
        case .frameTapOn, .recordingStarted, .clipQueued, .clipExported, .clipFailed:
            currentOwner = .recording
            currentRecordingOwnerText = CameraTraceOwner.recording.rawValue
            displayedOwnerSourceText = "Recording owner is authoritative while recording"
            lastRecordingMutation = event.line
        case .frameTapOff:
            lastRecordingMutation = event.line
        case .recordingStopped:
            currentOwner = event.owner == .recording ? .unknown : event.owner
            currentRecordingOwnerText = "none"
            displayedOwnerSourceText = "Recording stopped; latest accepted owner will apply"
            lastRecordingMutation = event.line
        }

        refreshOwnerSummary(recordingActive: recordingActive)
    }

    func clear() {
        events.removeAll()
        currentOwner = .unknown
        lastSessionMutation = "none"
        lastPreviewMutation = "none"
        lastRecordingMutation = "none"
        currentRecordingOwnerText = "none"
        currentPreviewOwnerText = "none"
        currentOCROwnerText = "none"
        displayedOwnerSourceText = "No active owner"
        staleOCROwnershipIgnoredText = "No"
        lastForensicEvent = "none"
        lastEventFingerprint = ""
        lastEventDate = .distantPast
        repeatedBreadcrumbSuppressionCount = 0
    }
}

struct CameraOwnershipTracePanel: View {
    @ObservedObject private var trace = CameraOwnershipTraceStore.shared

    var body: some View {
        DiagnosticsCard(title: "Camera Ownership Trace", systemImage: "point.3.connected.trianglepath.dotted") {
            DiagnosticsRow(title: "Current owner", value: trace.currentOwner.rawValue)
            DiagnosticsRow(title: "Displayed owner source", value: trace.displayedOwnerSourceText)
            DiagnosticsRow(title: "Recording owner", value: trace.currentRecordingOwnerText)
            DiagnosticsRow(title: "Preview owner", value: trace.currentPreviewOwnerText)
            DiagnosticsRow(title: "OCR owner", value: trace.currentOCROwnerText)
            DiagnosticsRow(title: "Stale OCR ownership ignored", value: trace.staleOCROwnershipIgnoredText)
            DiagnosticsRow(title: "Last session mutation", value: trace.lastSessionMutation)
            DiagnosticsRow(title: "Last preview mutation", value: trace.lastPreviewMutation)
            DiagnosticsRow(title: "Last recording mutation", value: trace.lastRecordingMutation)
            DiagnosticsRow(title: "Last forensic event", value: trace.lastForensicEvent)
            DiagnosticsRow(title: "Repeated breadcrumbs suppressed", value: "\(trace.repeatedBreadcrumbSuppressionCount)")

            Button("Clear ownership trace") {
                trace.clear()
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 4) {
                Text("Recent ownership events")
                    .font(.caption.weight(.semibold))
                ForEach(trace.events.prefix(40)) { event in
                    Text(event.line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
#endif
