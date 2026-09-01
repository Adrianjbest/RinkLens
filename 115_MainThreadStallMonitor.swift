// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import Combine

nonisolated enum RuntimeDiagnosticsMode: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case rinkTest = "Rink Test"
    case engineering = "Engineering"
    case matchDaySafe = "Match Day Safe"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .production: return "Production"
        case .rinkTest: return "Rink Test"
        case .engineering: return "Engineering"
        case .matchDaySafe: return "Match Day Safe"
        }
    }
}

nonisolated enum DiagnosticTraceChannel: String, CaseIterable, Identifiable, Sendable {
    case cameraStartup = "camera-startup"
    case zoomMovement = "zoom-movement"
    case ocrPhase = "ocr-phase"
    case intermissionTrigger = "intermission-trigger"
    case sponsorOverlay = "sponsor-overlay"
    case recordingWriter = "recording-writer"
    case mainThreadStall = "main-thread-stall"

    var id: String { rawValue }
    var prefix: String { "[\(rawValue)]" }

    var displayName: String {
        switch self {
        case .cameraStartup: return "Camera startup timeline"
        case .zoomMovement: return "Zoom movement trace"
        case .ocrPhase: return "OCR phase trace"
        case .intermissionTrigger: return "Intermission trigger trace"
        case .sponsorOverlay: return "Sponsor overlay trace"
        case .recordingWriter: return "Recording writer trace"
        case .mainThreadStall: return "Main-thread stall trace"
        }
    }

    var defaultRenderTimeline: Bool {
        switch self {
        case .zoomMovement, .sponsorOverlay, .recordingWriter, .mainThreadStall:
            return true
        case .cameraStartup, .ocrPhase, .intermissionTrigger:
            return false
        }
    }

    var isMatchDayImportant: Bool {
        switch self {
        case .cameraStartup, .intermissionTrigger, .sponsorOverlay, .recordingWriter, .mainThreadStall:
            return true
        case .zoomMovement, .ocrPhase:
            return false
        }
    }

    static func channel(forPrefixedEvent event: String) -> DiagnosticTraceChannel? {
        let lower = event.lowercased()
        return allCases.first { lower.hasPrefix($0.prefix) }
    }
}

// MARK: - DIAG3 actor-backed diagnostic store with startup stall tracing

/// DIAG3: Immutable snapshot returned by the actor-backed diagnostics store.
/// The SwiftUI/Combine-facing monitor publishes these values on the main queue.
private struct MainThreadDiagnosticSnapshot: Sendable {
    let currentContext: String
    let recentEvents: [String]
    let renderPreviewToggleEvents: [String]
    let lastTimedOperationText: String
    let longestTimedOperationText: String
    let publishPressureText: String
    let largestPublishBurstText: String
    let topPublishSourceText: String
    let diagnosticsMode: RuntimeDiagnosticsMode
    let diagnosticsModeText: String
    let recordingDiagnosticsActive: Bool
}

/// DIAG3: Owns all mutable diagnostic collections behind actor isolation.
///
/// Previous builds protected the known crash path with a serial dispatch queue,
/// but dictionaries/arrays were still conceptually owned by the ObservableObject.
/// This actor is the single owner for breadcrumb buffers, render-trace buffers,
/// throttle dictionaries, publish-pressure dictionaries and timed-operation state.
/// Callers submit fire-and-forget diagnostics from any thread; only immutable
/// snapshots cross back to the UI/main queue.
private actor DiagnosticsEventStore {
    private var diagnosticsMode: RuntimeDiagnosticsMode = .production
    private var recordingDiagnosticsActive = false

    private var bufferedCurrentContext: String = "app running"
    private var bufferedRecentEvents: [String] = []
    private var bufferedRenderEvents: [String] = []
    private var lastEventAtByKey: [String: Date] = [:]
    private var lastFlushAt: Date = .distantPast

    private var longestTimedOperationSeconds: TimeInterval = 0
    private var lastTimedOperationText: String = "none"
    private var longestTimedOperationText: String = "none"

    private var publishCountsBySource: [String: Int] = [:]
    private var publishWindowStartedAt: Date = Date()
    private var publishPressureText: String = "no publish pressure samples yet"
    private var largestPublishBurstCount: Int = 0
    private var largestPublishBurstText: String = "none"
    private var topPublishSourceText: String = "none"

    private let maxTraceEventCharacters = 280
    private let engineeringFlushInterval: TimeInterval = 1.0
    private let rinkTestFlushInterval: TimeInterval = 1.25
    private let productionFlushInterval: TimeInterval = 1.5
    private let productionRecordingFlushInterval: TimeInterval = 2.0
    private let matchDaySafeFlushInterval: TimeInterval = 2.5
    private let engineeringRecentEventRows = 24
    private let rinkTestRecentEventRows = 14
    private let productionRecentEventRows = 10
    private let productionRecordingRecentEventRows = 8
    private let matchDaySafeRecentEventRows = 6
    private let engineeringRenderEventRows = 20
    private let rinkTestRenderEventRows = 10
    private let productionRenderEventRows = 6
    private let productionRecordingRenderEventRows = 6
    private let matchDaySafeRenderEventRows = 4

    func markContext(_ context: String) -> MainThreadDiagnosticSnapshot? {
        let safeContext = sanitizeTraceEvent(context)
        guard !safeContext.isEmpty else { return nil }
        bufferedCurrentContext = safeContext
        appendEvent(safeContext, toRenderTimeline: false)
        return snapshotIfNeeded(force: false)
    }

    func trace(_ event: String, toRenderTimeline: Bool = false) -> MainThreadDiagnosticSnapshot? {
        appendEvent(event, toRenderTimeline: toRenderTimeline)
        return snapshotIfNeeded(force: false)
    }

    func setDiagnosticsMode(_ mode: RuntimeDiagnosticsMode, reason: String) -> MainThreadDiagnosticSnapshot? {
        guard diagnosticsMode != mode else { return snapshotIfNeeded(force: true) }
        diagnosticsMode = mode
        appendEvent("diagnostics mode changed: \(mode.rawValue) reason=\(reason)", toRenderTimeline: false)
        return snapshotIfNeeded(force: true)
    }

    func setRecordingDiagnosticsActive(_ active: Bool, reason: String) -> MainThreadDiagnosticSnapshot? {
        guard recordingDiagnosticsActive != active else { return snapshotIfNeeded(force: true) }
        recordingDiagnosticsActive = active
        appendEvent("diagnostics recording mode \(active ? "enabled" : "disabled"): \(reason)", toRenderTimeline: false)
        return snapshotIfNeeded(force: true)
    }

    func notePublish(source: String, count: Int) -> MainThreadDiagnosticSnapshot? {
        let safeSource = sanitizeTraceEvent(source)
        guard !safeSource.isEmpty else { return nil }
        let safeCount = max(1, count)
        let now = Date()
        let publishWindow: TimeInterval = recordingDiagnosticsActive && diagnosticsMode == .production ? 2.0 : 1.0

        if now.timeIntervalSince(publishWindowStartedAt) >= publishWindow {
            let total = publishCountsBySource.values.reduce(0, +)
            let top = publishCountsBySource.max { $0.value < $1.value }
            publishPressureText = publishWindow == 1.0 ? "\(total)/sec" : "\(total)/\(Int(publishWindow))sec"

            if let top {
                let suffix = publishWindow == 1.0 ? "sec" : "\(Int(publishWindow))sec"
                let nextTop = "\(top.key) \(top.value)/\(suffix)"
                topPublishSourceText = nextTop
                if top.value > largestPublishBurstCount {
                    largestPublishBurstCount = top.value
                    largestPublishBurstText = nextTop
                }
            }

            publishCountsBySource.removeAll()
            publishWindowStartedAt = now
            publishCountsBySource[safeSource, default: 0] += safeCount
            return snapshotIfNeeded(force: true)
        }

        publishCountsBySource[safeSource, default: 0] += safeCount
        return snapshotIfNeeded(force: false)
    }

    func endTimedOperation(name: String, elapsed: TimeInterval) -> MainThreadDiagnosticSnapshot? {
        let safeElapsed = max(0, elapsed)
        let safeName = sanitizeTraceEvent(name)
        let text = String(format: "%.3fs  %@", safeElapsed, safeName)
        lastTimedOperationText = text
        if safeElapsed > longestTimedOperationSeconds {
            longestTimedOperationSeconds = safeElapsed
            longestTimedOperationText = text
        }
        appendEvent("END \(text)", toRenderTimeline: false)
        return snapshotIfNeeded(force: false)
    }

    func flush(force: Bool) -> MainThreadDiagnosticSnapshot? {
        snapshotIfNeeded(force: force)
    }

    private var currentFlushInterval: TimeInterval {
        switch diagnosticsMode {
        case .production:
            return recordingDiagnosticsActive ? productionRecordingFlushInterval : productionFlushInterval
        case .rinkTest:
            return rinkTestFlushInterval
        case .engineering:
            return recordingDiagnosticsActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22)
                ? matchDaySafeFlushInterval
                : engineeringFlushInterval
        case .matchDaySafe:
            return matchDaySafeFlushInterval
        }
    }

    private var currentRecentEventLimit: Int {
        switch diagnosticsMode {
        case .production:
            return recordingDiagnosticsActive ? productionRecordingRecentEventRows : productionRecentEventRows
        case .rinkTest:
            return rinkTestRecentEventRows
        case .engineering:
            return recordingDiagnosticsActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22)
                ? matchDaySafeRecentEventRows
                : engineeringRecentEventRows
        case .matchDaySafe:
            return matchDaySafeRecentEventRows
        }
    }

    private var currentRenderEventLimit: Int {
        switch diagnosticsMode {
        case .production:
            return recordingDiagnosticsActive ? productionRecordingRenderEventRows : productionRenderEventRows
        case .rinkTest:
            return rinkTestRenderEventRows
        case .engineering:
            return recordingDiagnosticsActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22)
                ? matchDaySafeRenderEventRows
                : engineeringRenderEventRows
        case .matchDaySafe:
            return matchDaySafeRenderEventRows
        }
    }

    private var diagnosticsModeText: String {
        let suffix = "typed channels / SAFE1 actor-backed"
        switch diagnosticsMode {
        case .production:
            if recordingDiagnosticsActive {
                return "Production recording - critical only / 2s batch / \(suffix)"
            }
            return "Production - critical traces / \(suffix)"
        case .rinkTest:
            return "Rink Test - operational traces / 1.25s batch / \(suffix)"
        case .engineering:
            if recordingDiagnosticsActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22) {
                return "Engineering recording-safe - essential transitions / 2.5s batch / \(suffix)"
            }
            return "Engineering - verbose traces / \(suffix)"
        case .matchDaySafe:
            return "Match Day Safe - critical only / 2.5s batch / \(suffix)"
        }
    }

    private func sanitizeTraceEvent(_ event: String) -> String {
        let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTraceEventCharacters else { return trimmed }
        return String(trimmed.prefix(maxTraceEventCharacters)) + "…"
    }

    private func throttleKey(for event: String) -> String {
        if let channel = DiagnosticTraceChannel.channel(forPrefixedEvent: event) {
            return "typed-channel:\(channel.rawValue)"
        }

        if event.contains("CalibrationScreen body render") { return "render:CalibrationScreen" }
        if event.contains("BroadcastView body render") { return "render:BroadcastView" }
        if event.localizedCaseInsensitiveContains("broadcast zoom") { return "broadcast:zoom" }
        if event.localizedCaseInsensitiveContains("zoom") { return "camera:zoom" }
        if event.localizedCaseInsensitiveContains("focus") { return "camera:focus" }
        if event.localizedCaseInsensitiveContains("exposure") { return "camera:exposure" }
        if event.contains("Frame policy set") { return "camera:framePolicy" }
        if event.contains("Preview layer attached") { return "preview:attached" }
        if event.contains("Preview layer detached") { return "preview:detached" }
        if event.contains("swiftui invalidation suppressed") { return "swiftui:invalidationSuppressed" }
        return event
    }

    private func throttleInterval(for event: String) -> TimeInterval {
        if let channel = DiagnosticTraceChannel.channel(forPrefixedEvent: event) {
            return throttleInterval(for: channel)
        }

        if event.contains("body render") { return diagnosticsMode == .engineering ? 5.0 : 8.0 }
        if event.localizedCaseInsensitiveContains("broadcast zoom") { return 0.75 }
        if event.localizedCaseInsensitiveContains("zoom") { return 0.75 }
        if event.localizedCaseInsensitiveContains("focus") { return 1.0 }
        if event.localizedCaseInsensitiveContains("exposure") { return 1.0 }
        if event.contains("Frame policy set") { return 2.0 }
        if event.contains("Preview layer attached") || event.contains("Preview layer detached") { return 1.0 }
        if event.contains("swiftui invalidation suppressed") { return 3.0 }
        return 0.35
    }


    private func throttleInterval(for channel: DiagnosticTraceChannel) -> TimeInterval {
        switch diagnosticsMode {
        case .production:
            switch channel {
            case .mainThreadStall, .intermissionTrigger:
                return 0.20
            case .cameraStartup, .sponsorOverlay:
                return 0.75
            case .recordingWriter:
                return recordingDiagnosticsActive ? 2.0 : 1.25
            case .zoomMovement, .ocrPhase:
                return recordingDiagnosticsActive ? 3.0 : 1.5
            }
        case .rinkTest:
            switch channel {
            case .mainThreadStall, .intermissionTrigger:
                return 0.15
            case .cameraStartup, .sponsorOverlay:
                return 0.35
            case .zoomMovement:
                return 0.65
            case .ocrPhase:
                return 1.0
            case .recordingWriter:
                return 1.0
            }
        case .engineering:
            if recordingDiagnosticsActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22) {
                switch channel {
                case .mainThreadStall, .intermissionTrigger: return 0.50
                case .cameraStartup, .sponsorOverlay: return 2.0
                case .recordingWriter: return 3.0
                case .zoomMovement, .ocrPhase: return 4.0
                }
            }
            switch channel {
            case .mainThreadStall, .intermissionTrigger:
                return 0.10
            case .cameraStartup, .sponsorOverlay:
                return 0.35
            case .zoomMovement:
                return 0.45
            case .ocrPhase:
                return 0.75
            case .recordingWriter:
                return 0.75
            }
        case .matchDaySafe:
            switch channel {
            case .mainThreadStall, .intermissionTrigger:
                return 0.50
            case .cameraStartup, .sponsorOverlay:
                return 2.0
            case .recordingWriter:
                return 3.0
            case .zoomMovement, .ocrPhase:
                return 4.0
            }
        }
    }

    private func appendEvent(_ event: String, toRenderTimeline: Bool) {
        let sanitizedEvent = sanitizeTraceEvent(event)
        guard !sanitizedEvent.isEmpty else { return }
        guard shouldStoreEvent(sanitizedEvent) else { return }

        let now = Date()
        let key = throttleKey(for: sanitizedEvent)
        let interval = throttleInterval(for: sanitizedEvent)
        if let last = lastEventAtByKey[key], now.timeIntervalSince(last) < interval {
            return
        }
        lastEventAtByKey[key] = now

        let stamp = now.formatted(date: .omitted, time: .standard)
        let row = "\(stamp)  \(sanitizedEvent)"

        bufferedRecentEvents.insert(row, at: 0)
        if bufferedRecentEvents.count > currentRecentEventLimit {
            bufferedRecentEvents.removeLast(bufferedRecentEvents.count - currentRecentEventLimit)
        }

        if toRenderTimeline {
            bufferedRenderEvents.insert(row, at: 0)
            if bufferedRenderEvents.count > currentRenderEventLimit {
                bufferedRenderEvents.removeLast(bufferedRenderEvents.count - currentRenderEventLimit)
            }
        }
    }

    private func shouldStoreEvent(_ event: String) -> Bool {
        let lower = event.lowercased()
        let criticalFragments = [
            "warning",
            "failed",
            "blocked",
            "deferred",
            "protection",
            "fps",
            "preview delivery",
            "preview layer detached",
            "persistent preview reset",
            "frame policy change blocked",
            "white-screen",
            "stale",
            "dropped",
            "clip export",
            "short clip",
            "segment rollover warning",
            DiagnosticTraceChannel.mainThreadStall.prefix
        ]
        if criticalFragments.contains(where: { lower.contains($0.lowercased()) }) {
            return true
        }

        if let channel = DiagnosticTraceChannel.channel(forPrefixedEvent: event) {
            switch diagnosticsMode {
            case .engineering:
                return true
            case .rinkTest:
                return true
            case .production:
                return !recordingDiagnosticsActive || channel.isMatchDayImportant
            case .matchDaySafe:
                return channel.isMatchDayImportant
            }
        }

        let noisyFragments = [
            "body render",
            "camera diagnostics publishing",
            "diagnostics hub page active",
            "clipbuffer retained",
            "segment completed",
            "segment writing started",
            "segment discarded due to age",
            "preview heartbeat",
            "zone nudge",
            "focus snapshot"
        ]

        switch diagnosticsMode {
        case .engineering:
            return true
        case .rinkTest:
            return !noisyFragments.contains(where: { lower.contains($0) })
        case .production:
            if recordingDiagnosticsActive {
                return false
            }
            return !noisyFragments.contains(where: { lower.contains($0) })
        case .matchDaySafe:
            return false
        }
    }

    private func snapshotIfNeeded(force: Bool) -> MainThreadDiagnosticSnapshot? {
        let now = Date()
        guard force || now.timeIntervalSince(lastFlushAt) >= currentFlushInterval else { return nil }
        lastFlushAt = now
        return MainThreadDiagnosticSnapshot(
            currentContext: bufferedCurrentContext,
            recentEvents: bufferedRecentEvents,
            renderPreviewToggleEvents: bufferedRenderEvents,
            lastTimedOperationText: lastTimedOperationText,
            longestTimedOperationText: longestTimedOperationText,
            publishPressureText: publishPressureText,
            largestPublishBurstText: largestPublishBurstText,
            topPublishSourceText: topPublishSourceText,
            diagnosticsMode: diagnosticsMode,
            diagnosticsModeText: diagnosticsModeText,
            recordingDiagnosticsActive: recordingDiagnosticsActive
        )
    }
}

/// v0.8.4s: Low-impact main-thread and render diagnostics.
///
/// DIAG3 keeps the public API unchanged for existing callers, but moves mutable
/// diagnostic collections into `DiagnosticsEventStore`, an actor. SwiftUI-facing
/// values are still published only on the main queue. DIAG3 also records a
/// dedicated stall breadcrumb so startup stalls are not attributed only to the
/// last context string.
final class MainThreadStallMonitor: ObservableObject, RinkLensTelemetryClient, @unchecked Sendable {
    static let shared = MainThreadStallMonitor()

    /// Build 711: queue-owned camera code must not synchronously enter the
    /// MainActor diagnostics owner. This bridge preserves one logging owner
    /// while making the actor hop explicit and non-blocking.
    nonisolated static func traceFromAnyQueue(_ event: String) {
        guard !event.isEmpty else { return }
        Task { @MainActor in
            MainThreadStallMonitor.shared.trace(event)
        }
    }

    @Published private(set) var lastHeartbeatAt: Date = Date()
    @Published private(set) var stallCount: Int = 0
    @Published private(set) var longestStallSeconds: TimeInterval = 0
    @Published private(set) var lastStallAt: Date?
    @Published private(set) var lastStallText: String = "none"
    @Published private(set) var currentContext: String = "app running"
    @Published private(set) var lastStallContext: String = "none"
    @Published private(set) var recentEvents: [String] = []
    @Published private(set) var lastTimedOperationText: String = "none"
    @Published private(set) var longestTimedOperationText: String = "none"
    @Published private(set) var renderPreviewToggleEvents: [String] = []
    @Published private(set) var publishPressureText: String = "no publish pressure samples yet"
    @Published private(set) var largestPublishBurstText: String = "none"
    @Published private(set) var topPublishSourceText: String = "none"
    @Published private(set) var diagnosticsMode: RuntimeDiagnosticsMode = .production
    @Published private(set) var diagnosticsModeText: String = "Production - critical traces / typed channels / SAFE1 actor-backed"

    private let eventStore = DiagnosticsEventStore()
    private let configurationLock = NSLock()
    private var cachedDiagnosticsMode: RuntimeDiagnosticsMode = .production
    private var cachedRecordingDiagnosticsActive = false
    private var pendingDiagnosticsModeConfirmation: RuntimeDiagnosticsMode?

    private var timer: Timer?
    private var previousTickAt: Date = Date()
    private var lastHeartbeatPublishedAt: Date = .distantPast
    private var lastStoreFlushRequestedAt: Date = .distantPast
    private let expectedInterval: TimeInterval = 0.25
    private let heartbeatPublishInterval: TimeInterval = 1.0
    private let diagnosticsFlushRequestInterval: TimeInterval = 1.0
    private let recordingDiagnosticsFlushRequestInterval: TimeInterval = 2.0
    private let stallThreshold: TimeInterval = 0.85
    private let sleepWakeGapThreshold: TimeInterval = 20.0
    private var appSuspendedAt: Date?

    private init() {
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
            return
        }

        guard timer == nil else { return }
        previousTickAt = Date()
        lastHeartbeatAt = previousTickAt
        lastHeartbeatPublishedAt = previousTickAt
        lastStoreFlushRequestedAt = previousTickAt

        let newTimer = Timer(timeInterval: expectedInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = 0.05
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        let now = Date()
        let delta = now.timeIntervalSince(previousTickAt)
        previousTickAt = now

        // Build 681 keeps the 250ms private watchdog cadence but no longer
        // publishes an ObservableObject heartbeat four times per second. The
        // published value is diagnostic-only; reducing it to 1Hz avoids needless
        // SwiftUI invalidation while Broadcast, OCR and recording are active.
        if now.timeIntervalSince(lastHeartbeatPublishedAt) >= heartbeatPublishInterval {
            lastHeartbeatPublishedAt = now
            lastHeartbeatAt = now
        }

        if delta > sleepWakeGapThreshold {
            let contextAtWake = currentContext
            lastHeartbeatAt = now
            lastHeartbeatPublishedAt = now
            previousTickAt = now
            lastStallText = String(format: "sleep/wake gap ignored %.1fs at %@", delta, now.formatted(date: .omitted, time: .standard))
            submit { store in
                await store.trace(String(format: "[main-thread-stall] sleep/wake gap ignored %.1fs context=%@", delta, contextAtWake), toRenderTimeline: true)
            }
            return
        }

        if delta > stallThreshold {
            let contextAtStall = currentContext
            stallCount += 1
            longestStallSeconds = max(longestStallSeconds, delta)
            lastStallAt = now
            lastStallContext = contextAtStall
            lastStallText = String(format: "%.2fs gap at %@", delta, now.formatted(date: .omitted, time: .standard))
            let stallRow = String(format: "[main-thread-stall] gap=%.2fs context=%@", delta, contextAtStall)
            RinkLensStructuredEventLogger.shared.record(
                domain: .navigation,
                event: "main_thread_stall_observed",
                entityID: "main-actor-heartbeat",
                previous: ["expectedIntervalMs": String(Int(expectedInterval * 1000.0))],
                next: [
                    "gapMs": String(Int((delta * 1000.0).rounded())),
                    "stallCount": String(stallCount),
                    "longestStallMs": String(Int((longestStallSeconds * 1000.0).rounded())),
                    "context": contextAtStall
                ],
                source: "MainThreadStallMonitor.tick",
                reason: "R22 persists every >850ms main-thread heartbeat gap into the structured JSONL before capped diagnostic rings can overwrite it",
                authoritativeOwner: "MainThreadStallMonitor.telemetry"
            )
            submit { store in
                await store.trace(stallRow, toRenderTimeline: true)
            }
        }

        configurationLock.lock()
        let recordingDiagnosticsActive = cachedRecordingDiagnosticsActive
        configurationLock.unlock()
        let flushInterval = recordingDiagnosticsActive
            ? recordingDiagnosticsFlushRequestInterval
            : diagnosticsFlushRequestInterval
        if now.timeIntervalSince(lastStoreFlushRequestedAt) >= flushInterval {
            lastStoreFlushRequestedAt = now
            submit { store in
                await store.flush(force: false)
            }
        }
    }

    private func submit(_ operation: @escaping (DiagnosticsEventStore) async -> MainThreadDiagnosticSnapshot?) {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let snapshot = await operation(self.eventStore) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: MainThreadDiagnosticSnapshot) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
            return
        }

        if recentEvents != snapshot.recentEvents {
            recentEvents = snapshot.recentEvents
        }
        if renderPreviewToggleEvents != snapshot.renderPreviewToggleEvents {
            renderPreviewToggleEvents = snapshot.renderPreviewToggleEvents
        }
        if currentContext != snapshot.currentContext {
            currentContext = snapshot.currentContext
        }
        if lastTimedOperationText != snapshot.lastTimedOperationText {
            lastTimedOperationText = snapshot.lastTimedOperationText
        }
        if longestTimedOperationText != snapshot.longestTimedOperationText {
            longestTimedOperationText = snapshot.longestTimedOperationText
        }
        if publishPressureText != snapshot.publishPressureText {
            publishPressureText = snapshot.publishPressureText
        }
        if largestPublishBurstText != snapshot.largestPublishBurstText {
            largestPublishBurstText = snapshot.largestPublishBurstText
        }
        if topPublishSourceText != snapshot.topPublishSourceText {
            topPublishSourceText = snapshot.topPublishSourceText
        }
        let hasPendingModeSelection = pendingDiagnosticsModeConfirmation != nil
        let snapshotConfirmsPendingMode = pendingDiagnosticsModeConfirmation == snapshot.diagnosticsMode

        if !hasPendingModeSelection || snapshotConfirmsPendingMode {
            if diagnosticsMode != snapshot.diagnosticsMode {
                diagnosticsMode = snapshot.diagnosticsMode
            }
            if diagnosticsModeText != snapshot.diagnosticsModeText {
                diagnosticsModeText = snapshot.diagnosticsModeText
            }
            if snapshotConfirmsPendingMode {
                pendingDiagnosticsModeConfirmation = nil
            }
        }

        updateCachedConfiguration(
            mode: hasPendingModeSelection && !snapshotConfirmsPendingMode ? nil : snapshot.diagnosticsMode,
            recordingActive: snapshot.recordingDiagnosticsActive
        )
    }

    private func updateCachedConfiguration(mode: RuntimeDiagnosticsMode? = nil, recordingActive: Bool? = nil) {
        configurationLock.lock()
        if let mode { cachedDiagnosticsMode = mode }
        if let recordingActive { cachedRecordingDiagnosticsActive = recordingActive }
        configurationLock.unlock()
    }

    private func cachedConfiguration() -> (mode: RuntimeDiagnosticsMode, recordingActive: Bool) {
        configurationLock.lock()
        let result = (mode: cachedDiagnosticsMode, recordingActive: cachedRecordingDiagnosticsActive)
        configurationLock.unlock()
        return result
    }


    func noteAppWillSuspend(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.noteAppWillSuspend(reason: reason)
            }
            return
        }
        let now = Date()
        appSuspendedAt = now
        previousTickAt = now
        lastHeartbeatAt = now
        markContext("app lifecycle suspending: \(reason)")
    }

    func noteAppDidResume(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.noteAppDidResume(reason: reason)
            }
            return
        }
        let now = Date()
        let sleptFor = appSuspendedAt.map { now.timeIntervalSince($0) }
        appSuspendedAt = nil
        previousTickAt = now
        lastHeartbeatAt = now
        if let sleptFor {
            lastStallText = String(format: "sleep/wake gap ignored %.1fs at %@", sleptFor, now.formatted(date: .omitted, time: .standard))
            trace(String(format: "app lifecycle resumed: %@ after %.1fs sleep/wake gap ignored", reason, sleptFor))
        } else {
            trace("app lifecycle resumed: \(reason); stall monitor reset")
        }
    }

    func markContext(_ context: String) {
        guard !context.isEmpty else { return }
        submit { store in
            await store.markContext(context)
        }
    }

    func trace(_ event: String) {
        guard !event.isEmpty else { return }
        submit { store in
            await store.trace(event, toRenderTimeline: false)
        }
    }

    func trace(_ channel: DiagnosticTraceChannel, _ event: String, toRenderTimeline: Bool? = nil) {
        guard !event.isEmpty else { return }
        let row = "\(channel.prefix) \(event)"
        let renderTimeline = toRenderTimeline ?? channel.defaultRenderTimeline
        submit { store in
            await store.trace(row, toRenderTimeline: renderTimeline)
        }
    }

    private func traceDiagnosticChannel(_ channel: DiagnosticTraceChannel, event: String, toRenderTimeline: Bool? = nil) {
        trace(channel, event, toRenderTimeline: toRenderTimeline)
    }

    func traceCameraStartupTimeline(_ event: String) {
        traceDiagnosticChannel(.cameraStartup, event: event)
    }

    func traceZoomMovement(_ event: String) {
        traceDiagnosticChannel(.zoomMovement, event: event)
    }

    func traceOCRPhase(_ event: String) {
        traceDiagnosticChannel(.ocrPhase, event: event)
    }

    func traceIntermissionTrigger(_ event: String) {
        traceDiagnosticChannel(.intermissionTrigger, event: event)
    }

    func traceSponsorOverlay(_ event: String) {
        traceDiagnosticChannel(.sponsorOverlay, event: event)
    }

    func traceRecordingWriterEvent(_ event: String) {
        traceDiagnosticChannel(.recordingWriter, event: event)
    }

    func traceRenderPreviewToggle(_ event: String) {
        guard !event.isEmpty else { return }
        submit { store in
            await store.trace(event, toRenderTimeline: true)
        }
    }

    func traceRenderPass(_ event: String) {
        // Never publish from inside a SwiftUI body render. DIAG2 stores the trace
        // in the actor and only publishes a capped snapshot when the flush window opens.
        guard !event.isEmpty else { return }
        submit { store in
            await store.trace(event, toRenderTimeline: true)
        }
    }

    func setDiagnosticsMode(_ mode: RuntimeDiagnosticsMode, reason: String) {
        if diagnosticsMode == mode && pendingDiagnosticsModeConfirmation == nil { return }

        RinkLensOCREvidenceJournal.shared.setEngineeringEnabled(
            mode == .engineering,
            reason: "diagnostics mode -> \(mode.rawValue): \(reason)"
        )

        // Reflect the segmented-picker selection immediately. The actor-backed
        // store remains authoritative and confirms the same value asynchronously.
        pendingDiagnosticsModeConfirmation = mode
        diagnosticsMode = mode
        diagnosticsModeText = immediateDiagnosticsModeText(
            for: mode,
            recordingActive: cachedConfiguration().recordingActive
        )
        updateCachedConfiguration(mode: mode)

        submit { store in
            await store.setDiagnosticsMode(mode, reason: reason)
        }
    }

    private func immediateDiagnosticsModeText(
        for mode: RuntimeDiagnosticsMode,
        recordingActive: Bool
    ) -> String {
        let suffix = "typed channels / SAFE1 actor-backed"
        switch mode {
        case .production:
            if recordingActive {
                return "Production recording - critical only / 2s batch / \(suffix)"
            }
            return "Production - critical traces / \(suffix)"
        case .rinkTest:
            return "Rink Test - operational traces / 1.25s batch / \(suffix)"
        case .engineering:
            if recordingActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22) {
                return "Engineering recording-safe - essential transitions / 2.5s batch / \(suffix)"
            }
            return "Engineering - verbose traces / \(suffix)"
        case .matchDaySafe:
            return "Match Day Safe - critical only / 2.5s batch / \(suffix)"
        }
    }

    func setRecordingDiagnosticsActive(_ active: Bool, reason: String) {
        updateCachedConfiguration(recordingActive: active)
        let mode = cachedConfiguration().mode
        RinkLensOCREvidenceJournal.shared.setEngineeringEnabled(
            mode == .engineering && !(active && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22)),
            reason: "Build 741 recording-safe diagnostics active=\(active): \(reason)"
        )
        submit { store in
            await store.setRecordingDiagnosticsActive(active, reason: reason)
        }
    }

    var isEngineeringDiagnosticsActive: Bool {
        cachedConfiguration().mode == .engineering
    }

    var shouldShowVerboseDiagnosticLists: Bool {
        let config = cachedConfiguration()
        switch config.mode {
        case .engineering, .rinkTest:
            return true
        case .production:
            return !config.recordingActive
        case .matchDaySafe:
            return false
        }
    }

    var diagnosticsDetailText: String {
        let config = cachedConfiguration()
        switch config.mode {
        case .production:
            return config.recordingActive ? "Production critical only while recording" : "Production critical, capped"
        case .rinkTest:
            return "Rink Test operational channels, capped"
        case .engineering:
            return "Engineering verbose, typed channels"
        case .matchDaySafe:
            return "Match Day Safe critical only"
        }
    }

    var renderLoggingText: String {
        let config = cachedConfiguration()
        switch config.mode {
        case .production:
            return "Production throttled"
        case .rinkTest:
            return "Rink Test operational throttled"
        case .engineering:
            return "Verbose throttled"
        case .matchDaySafe:
            return "Match Day Safe minimal"
        }
    }

    func broadcastOverlayRefreshNanoseconds() -> UInt64 {
        let config = cachedConfiguration()
        switch config.mode {
        case .production:
            return config.recordingActive ? 250_000_000 : 175_000_000
        case .rinkTest:
            return 150_000_000
        case .engineering:
            return config.recordingActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22)
                ? 300_000_000
                : 125_000_000
        case .matchDaySafe:
            return 300_000_000
        }
    }

    func rendererDiagnosticsPublishInterval() -> TimeInterval {
        let config = cachedConfiguration()
        switch config.mode {
        case .production:
            return config.recordingActive ? 1.0 : 0.75
        case .rinkTest:
            return 0.75
        case .engineering:
            return config.recordingActive && RinkLensRiskFeaturePolicy.isEnabled(.recordingSafeDiagnosticsV22)
                ? 1.5
                : 0.5
        case .matchDaySafe:
            return 1.5
        }
    }

    func notePublish(source: String, count: Int = 1) {
        guard !source.isEmpty else { return }
        submit { store in
            await store.notePublish(source: source, count: count)
        }
    }

    func beginTimedOperation(_ name: String) -> Date {
        trace("BEGIN \(name)")
        return Date()
    }

    func endTimedOperation(_ name: String, startedAt: Date) {
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        submit { store in
            await store.endTimedOperation(name: name, elapsed: elapsed)
        }
    }

    func heartbeatAgeText(now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(lastHeartbeatAt))
        return String(format: "%.1fs ago", age)
    }

    func longestStallText() -> String {
        if longestStallSeconds <= 0 { return "none" }
        return String(format: "%.2fs", longestStallSeconds)
    }
}
#endif
