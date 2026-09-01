// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import Foundation

// MARK: - UX16c44 OCR publication diagnostics

/// Identifies the three deliberately separate OCR publication paths.
/// Only `continuousBroadcast` is allowed to commit automatically to MatchState.
enum RinkLensOCRPublicationFlow: String, Sendable, CaseIterable {
    case continuousBroadcast = "continuous-broadcast"
    case calibrationSelectedZone = "calibration-selected-zone"
    case testOCR = "test-ocr"

    var title: String {
        switch self {
        case .continuousBroadcast: return "Continuous Broadcast OCR"
        case .calibrationSelectedZone: return "Calibration Selected-Zone OCR"
        case .testOCR: return "Test OCR"
        }
    }

    var automaticallyCommitsMatchState: Bool {
        self == .continuousBroadcast
    }
}

/// One auditable field decision from recogniser input through the reducer boundary
/// to the value currently visible on the public scorebug.
struct RinkLensOCRFieldPublicationDiagnostic: Identifiable, Equatable {
    var id: String { key.rawValue }

    let key: OCRRegionKey
    let flow: RinkLensOCRPublicationFlow
    let rawCandidate: String
    let cleanedCandidate: String
    let confidence: Float
    let acceptanceReason: String
    let reducerOutcome: String
    let visibleScorebugValue: String
    let updatedAt: Date

    var compactText: String {
        let raw = rawCandidate.isEmpty ? "--" : rawCandidate
        let cleaned = cleanedCandidate.isEmpty ? "--" : cleanedCandidate
        return "flow=\(flow.rawValue) raw=\(raw) cleaned=\(cleaned) conf=\(String(format: "%.2f", confidence)) decision={\(acceptanceReason)} reducer={\(reducerOutcome)} visible=\(visibleScorebugValue)"
    }
}


// MARK: - UX16d15b Engineering OCR evidence and geometry audit journal

/// Append-only OCR evidence retained for the complete Engineering diagnostics
/// session. This journal is intentionally independent of SwiftUI publication and
/// the bounded on-screen diagnostics dictionaries: every processed dynamic-token
/// attempt and every publication/reducer decision is written to rotating JSONL
/// files on a private utility queue. Production, Rink Test and Match Day Safe do
/// not create journal rows.
nonisolated final class RinkLensOCREvidenceJournal: @unchecked Sendable {
    static let shared = RinkLensOCREvidenceJournal()

    struct TokenAttempt: Sendable {
        let field: String
        let outcome: String
        let rawText: String
        let acceptedValue: String?
        let confidence: Float
        let sourceFrameID: Int?
        let captureGeneration: Int
        let cropWidth: Int
        let cropHeight: Int
        let colourProfile: String
        let resolvedPipeline: String
        let scoreReacquisition: Bool
        let timerRecoveryReserved: Bool
        let elapsedMilliseconds: Double
        let masksProcessed: String
        let masksNotProcessedReason: String
        let maskSummary: String
        let tokenEvidence: String
        let decisionDetail: String
        let fullDiagnostic: String
    }

    /// Immutable geometry captured at the moment an operator commits a zone edit.
    /// Double values keep the journal payload Sendable and independent of SwiftUI.
    struct ZoneSnapshot: Sendable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let rotationDegrees: Double

        init(_ region: OCRRegion) {
            x = Double(region.x)
            y = Double(region.y)
            width = Double(region.width)
            height = Double(region.height)
            rotationDegrees = Double(region.rotationDegrees)
        }

        var centreX: Double { x + width / 2.0 }

        var physicalSide: String {
            if centreX < 0.40 { return "left" }
            if centreX > 0.60 { return "right" }
            return "centre"
        }

        var jsonObject: [String: Double] {
            [
                "x": x,
                "y": y,
                "width": width,
                "height": height,
                "rotationDegrees": rotationDegrees,
                "centreX": centreX
            ]
        }
    }

    private let queue = DispatchQueue(label: "rinklens.ocr.evidence.journal", qos: .utility)
    private let enablementLock = NSLock()
    private let maximumPartBytes: Int64 = 25 * 1_024 * 1_024
    private var cachedEnabled = false
    private var enabled = false
    private var sessionIdentifier = "none"
    private var sessionFiles: [URL] = []
    private var currentHandle: FileHandle?
    private var currentPartBytes: Int64 = 0
    private var partIndex = 0
    private var sequence = 0
    private var tokenAttemptCount = 0
    private var acceptedTokenAttemptCount = 0
    private var rejectedTokenAttemptCount = 0
    private var publicationCount = 0
    private var zoneEditCount = 0
    private var scoreTransitionCount = 0
    private var eventAuditCount = 0
    private var zoneRevisionByField: [String: Int] = [:]
    private var recentRows: [String] = []
    private var lastError = "none"

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private init() {}

    func setEngineeringEnabled(_ nextEnabled: Bool, reason: String) {
        setCachedEnabled(nextEnabled)
        queue.async { [self] in
            if nextEnabled {
                if !enabled {
                    startSession(reason: reason)
                } else {
                    appendRecord(type: "mode_marker", fields: ["enabled": true, "reason": reason])
                }
            } else if enabled {
                appendRecord(type: "session_end", fields: ["reason": reason])
                closeCurrentHandle()
                enabled = false
            }
        }
    }

    /// Clears only OCR evidence owned by this journal. Closing and reopening the
    /// handle on the journal queue prevents an active FileHandle from pointing at
    /// an unlinked file after an operator storage purge.
    func clearStoredEvidence() async -> RinkLensStorageClearResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let resumeEngineeringJournal = enabled
                closeCurrentHandle()
                let folder = journalFolderURL()
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                var files = 0
                var bytes: Int64 = 0
                var failure: String?
                for url in urls {
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    do {
                        try FileManager.default.removeItem(at: url)
                        files += 1
                        bytes += size
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                sessionFiles.removeAll()
                recentRows.removeAll()
                enabled = false
                if resumeEngineeringJournal {
                    startSession(reason: "operator cleared stored OCR evidence")
                }
                continuation.resume(returning: .init(files: files, bytes: bytes, blockedReason: failure))
            }
        }
    }

    func recordTokenAttempt(_ attempt: TokenAttempt) {
        guard isCachedEnabled() else { return }
        queue.async { [self] in
            if !enabled { startSession(reason: "lazy Engineering token evidence activation") }
            guard enabled else { return }
            tokenAttemptCount += 1
            if attempt.outcome == "accepted" {
                acceptedTokenAttemptCount += 1
            } else {
                rejectedTokenAttemptCount += 1
            }

            var fields: [String: Any] = [
                "field": attempt.field,
                "outcome": attempt.outcome,
                "rawText": attempt.rawText,
                "acceptedValue": attempt.acceptedValue ?? NSNull(),
                "confidence": Double(attempt.confidence),
                "sourceFrameID": attempt.sourceFrameID ?? NSNull(),
                "captureGeneration": attempt.captureGeneration,
                "cropWidth": attempt.cropWidth,
                "cropHeight": attempt.cropHeight,
                "colourProfile": attempt.colourProfile,
                "resolvedPipeline": attempt.resolvedPipeline,
                "scoreReacquisition": attempt.scoreReacquisition,
                "timerRecoveryReserved": attempt.timerRecoveryReserved,
                "elapsedMilliseconds": attempt.elapsedMilliseconds,
                "masksProcessed": attempt.masksProcessed,
                "masksNotProcessedReason": attempt.masksNotProcessedReason,
                "maskSummary": attempt.maskSummary,
                "tokenEvidence": attempt.tokenEvidence,
                "decisionDetail": attempt.decisionDetail,
                "fullDiagnostic": attempt.fullDiagnostic
            ]
            fields["tokenAttemptNumber"] = tokenAttemptCount
            fields["zoneRevision"] = zoneRevisionByField[attempt.field] ?? 0
            appendRecord(type: "token_attempt", fields: fields)
        }
    }

    func recordPublication(_ diagnostic: RinkLensOCRFieldPublicationDiagnostic) {
        guard isCachedEnabled() else { return }
        let field = diagnostic.key.rawValue
        let flow = diagnostic.flow.rawValue
        let rawCandidate = diagnostic.rawCandidate
        let cleanedCandidate = diagnostic.cleanedCandidate
        let confidence = diagnostic.confidence
        let acceptanceReason = diagnostic.acceptanceReason
        let reducerOutcome = diagnostic.reducerOutcome
        let visibleScorebugValue = diagnostic.visibleScorebugValue
        let updatedAt = diagnostic.updatedAt
        queue.async { [self] in
            if !enabled { startSession(reason: "lazy Engineering publication evidence activation") }
            guard enabled else { return }
            publicationCount += 1
            appendRecord(
                type: "publication_decision",
                fields: [
                    "publicationNumber": publicationCount,
                    "field": field,
                    "flow": flow,
                    "rawCandidate": rawCandidate,
                    "cleanedCandidate": cleanedCandidate,
                    "confidence": Double(confidence),
                    "acceptanceReason": acceptanceReason,
                    "reducerOutcome": reducerOutcome,
                    "visibleScorebugValue": visibleScorebugValue,
                    "decisionTimestamp": Self.timestamp(updatedAt),
                    "zoneRevision": zoneRevisionByField[field] ?? 0
                ]
            )
        }
    }

    func recordPublicationSummary(flow: RinkLensOCRPublicationFlow, summary: String) {
        guard isCachedEnabled() else { return }
        queue.async { [self] in
            if !enabled { startSession(reason: "lazy Engineering publication-summary activation") }
            guard enabled else { return }
            appendRecord(
                type: "publication_summary",
                fields: ["flow": flow.rawValue, "summary": summary]
            )
        }
    }

    /// Records a committed zone move/resize/rotation. Intermediate drag updates
    /// are intentionally excluded so the audit is readable and correlates one row
    /// with the subsequent OCR token/publication rows through `zoneRevision`.
    func recordZoneEdit(
        field: String,
        operation: String,
        before: ZoneSnapshot,
        after: ZoneSnapshot,
        correlationID: String? = nil,
        detail: String
    ) {
        guard isCachedEnabled(), before != after else { return }
        queue.async { [self] in
            if !enabled { startSession(reason: "lazy Engineering zone-edit audit activation") }
            guard enabled else { return }
            zoneEditCount += 1
            let nextRevision = (zoneRevisionByField[field] ?? 0) + 1
            zoneRevisionByField[field] = nextRevision
            appendRecord(
                type: "zone_edit",
                fields: [
                    "zoneEditNumber": zoneEditCount,
                    "field": field,
                    "operation": operation,
                    "zoneRevision": nextRevision,
                    "correlationID": correlationID ?? NSNull(),
                    "before": before.jsonObject,
                    "after": after.jsonObject,
                    "delta": [
                        "x": after.x - before.x,
                        "y": after.y - before.y,
                        "width": after.width - before.width,
                        "height": after.height - before.height,
                        "rotationDegrees": after.rotationDegrees - before.rotationDegrees
                    ],
                    "beforePhysicalSide": before.physicalSide,
                    "afterPhysicalSide": after.physicalSide,
                    "detail": detail
                ]
            )
        }
    }

    /// Records an explicit logical zone swap as one correlated audit event while
    /// advancing the independent revision of each affected field.
    func recordZoneSwap(
        firstField: String,
        firstBefore: ZoneSnapshot,
        firstAfter: ZoneSnapshot,
        secondField: String,
        secondBefore: ZoneSnapshot,
        secondAfter: ZoneSnapshot,
        detail: String
    ) {
        guard isCachedEnabled() else { return }
        let correlationID = UUID().uuidString
        recordZoneEdit(
            field: firstField,
            operation: "swap",
            before: firstBefore,
            after: firstAfter,
            correlationID: correlationID,
            detail: detail
        )
        recordZoneEdit(
            field: secondField,
            operation: "swap",
            before: secondBefore,
            after: secondAfter,
            correlationID: correlationID,
            detail: detail
        )
    }

    /// Every score-relevant reducer attempt is retained, including no-change,
    /// held and diagnostics-only attempts. This makes the history show both what
    /// OCR proposed and what the public MatchState actually committed.
    func recordScoreTransition(
        actionName: String,
        origin: String,
        diagnosticsOnly: Bool,
        reason: String,
        previousHome: Int?,
        previousAway: Int?,
        nextHome: Int?,
        nextAway: Int?,
        changedFields: [String],
        reductionChanged: Bool,
        committed: Bool,
        revisionBefore: UInt64,
        revisionAfter: UInt64
    ) {
        guard isCachedEnabled() else { return }
        queue.async { [self] in
            if !enabled { startSession(reason: "lazy Engineering score-transition history activation") }
            guard enabled else { return }
            scoreTransitionCount += 1
            appendRecord(
                type: "score_transition",
                fields: [
                    "scoreTransitionNumber": scoreTransitionCount,
                    "actionName": actionName,
                    "origin": origin,
                    "diagnosticsOnly": diagnosticsOnly,
                    "reason": reason,
                    "previousHome": previousHome ?? NSNull(),
                    "previousAway": previousAway ?? NSNull(),
                    "nextHome": nextHome ?? NSNull(),
                    "nextAway": nextAway ?? NSNull(),
                    "changedFields": changedFields,
                    "reductionChanged": reductionChanged,
                    "committed": committed,
                    "revisionBefore": revisionBefore,
                    "revisionAfter": revisionAfter,
                    "homeScoreZoneRevision": zoneRevisionByField[OCRRegionKey.homeScore.rawValue] ?? 0,
                    "awayScoreZoneRevision": zoneRevisionByField[OCRRegionKey.awayScore.rawValue] ?? 0
                ]
            )
        }
    }

    /// UX16d15e Build 520: end-to-end event and overlay lifecycle evidence.
    /// Records eligibility, creation/suppression, queue admission, display start
    /// and completion so a committed score/penalty can be traced to the popup.
    func recordEventAudit(
        stage: String,
        eventKind: String,
        source: String,
        queueItemID: String? = nil,
        detail: String
    ) {
        guard isCachedEnabled() else { return }
        queue.async { [self] in
            if !enabled { startSession(reason: "lazy Engineering event-audit activation") }
            guard enabled else { return }
            eventAuditCount += 1
            appendRecord(
                type: "event_audit",
                fields: [
                    "eventAuditNumber": eventAuditCount,
                    "stage": stage,
                    "eventKind": eventKind,
                    "source": source,
                    "queueItemID": queueItemID ?? NSNull(),
                    "detail": detail
                ]
            )
        }
    }

    func recordMarker(_ marker: String, detail: String) {
        guard isCachedEnabled() else { return }
        queue.async { [self] in
            if !enabled { startSession(reason: "lazy Engineering marker activation") }
            guard enabled else { return }
            appendRecord(type: marker, fields: ["detail": detail])
        }
    }


    private func setCachedEnabled(_ value: Bool) {
        enablementLock.lock()
        cachedEnabled = value
        enablementLock.unlock()
    }

    private func isCachedEnabled() -> Bool {
        enablementLock.lock()
        let value = cachedEnabled
        enablementLock.unlock()
        return value
    }

    func exportLines() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let rows = readAllRows()
                let status = enabled ? "Engineering journal active" : "Engineering journal inactive"
                let fileNames = sessionFiles.isEmpty
                    ? "none"
                    : sessionFiles.map(\.lastPathComponent).joined(separator: ", ")
                let summary = [
                    "Status: \(status)",
                    "Session: \(sessionIdentifier)",
                    "Token attempts: \(tokenAttemptCount) total / \(acceptedTokenAttemptCount) accepted / \(rejectedTokenAttemptCount) rejected",
                    "Publication decisions: \(publicationCount)",
                    "Zone edit commits: \(zoneEditCount)",
                    "Score transition attempts: \(scoreTransitionCount)",
                    "Event/overlay audit rows: \(eventAuditCount)",
                    "Parts: \(sessionFiles.count)",
                    "Part limit: \(maximumPartBytes / 1_024 / 1_024) MB; parts rotate without discarding the current session",
                    "Last journal error: \(lastError)",
                    "Files: \(fileNames)",
                    "Rows below are append-only JSONL from the current/most-recent Engineering session."
                ]
                continuation.resume(returning: summary + (rows.isEmpty ? ["No Engineering OCR evidence has been recorded."] : rows))
            }
        }
    }

    func exportZoneEditLines() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let rows = readAllRows().filter { row in
                    row.contains("\"type\":\"zone_edit\"")
                }
                let summary = [
                    "Committed zone edits: \(zoneEditCount)",
                    "Each row includes before/after geometry, physical side, correlation ID and the new per-field zone revision."
                ]
                continuation.resume(
                    returning: summary + (rows.isEmpty
                        ? ["No committed Engineering zone edits have been recorded."]
                        : rows)
                )
            }
        }
    }

    func exportScoreTransitionLines() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let rows = readAllRows().filter { row in
                    if row.contains("\"type\":\"score_transition\"") { return true }
                    guard row.contains("\"type\":\"publication_decision\"") else { return false }
                    return row.contains("\"field\":\"homeScore\"")
                        || row.contains("\"field\":\"awayScore\"")
                }
                let summary = [
                    "Score-relevant reducer attempts: \(scoreTransitionCount)",
                    "Rows include Home/Away OCR publication decisions plus committed, held, unchanged and diagnostics-only reducer attempts with zone revisions."
                ]
                continuation.resume(
                    returning: summary + (rows.isEmpty
                        ? ["No Engineering score-field transition history has been recorded."]
                        : rows)
                )
            }
        }
    }

    func exportEventAuditLines() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let rows = readAllRows().filter { $0.contains("\"type\":\"event_audit\"") }
                let summary = [
                    "Event/overlay lifecycle rows: \(eventAuditCount)",
                    "Stages include MatchState eligibility, event creation/suppression, queue enqueue, display start and display completion."
                ]
                continuation.resume(
                    returning: summary + (rows.isEmpty
                        ? ["No Engineering event/overlay lifecycle evidence has been recorded."]
                        : rows)
                )
            }
        }
    }

    private func readAllRows() -> [String] {
        try? currentHandle?.synchronize()
        var rows: [String] = []
        for file in sessionFiles {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                rows.append(contentsOf: text.split(whereSeparator: \.isNewline).map { String($0) })
            } catch {
                rows.append("journal-read-error file=\(file.lastPathComponent) error=\(error.localizedDescription)")
            }
        }
        if rows.isEmpty, !recentRows.isEmpty {
            rows = recentRows
        }
        return rows
    }

    private func startSession(reason: String) {
        closeCurrentHandle()
        let stamp = Self.timestamp(Date())
            .replacingOccurrences(of: ":", with: "-")
        sessionIdentifier = "\(stamp)_\(UUID().uuidString.prefix(8))"
        sessionFiles = []
        partIndex = 0
        sequence = 0
        tokenAttemptCount = 0
        acceptedTokenAttemptCount = 0
        rejectedTokenAttemptCount = 0
        publicationCount = 0
        zoneEditCount = 0
        scoreTransitionCount = 0
        eventAuditCount = 0
        zoneRevisionByField = [:]
        recentRows = []
        lastError = "none"
        enabled = true
        openNextPart()
        appendRecord(
            type: "session_start",
            fields: [
                "reason": reason,
                "build": RinkLensBuildInfo.version,
                "buildNumber": RinkLensBuildInfo.buildNumber,
                "journalContract": "all processed dynamic-token attempts, publication/reducer decisions, committed zone edits, score-field transitions and event/overlay lifecycle stages"
            ]
        )
    }

    private func journalFolderURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("RinkLens Logs", isDirectory: true)
            .appendingPathComponent("OCR Evidence", isDirectory: true)
    }

    private func openNextPart() {
        do {
            let folder = journalFolderURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            partIndex += 1
            let name = String(format: "OCR_Evidence_%@_part%03d.jsonl", sessionIdentifier, partIndex)
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            currentHandle = handle
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            currentPartBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            sessionFiles.append(url)
        } catch {
            currentHandle = nil
            currentPartBytes = 0
            lastError = error.localizedDescription
        }
    }

    private func closeCurrentHandle() {
        try? currentHandle?.synchronize()
        try? currentHandle?.close()
        currentHandle = nil
        currentPartBytes = 0
    }

    private func appendRecord(type: String, fields: [String: Any]) {
        guard enabled || type == "session_end" else { return }
        sequence += 1
        var object = fields
        object["sequence"] = sequence
        object["type"] = type
        object["timestamp"] = Self.timestamp(Date())
        object["session"] = sessionIdentifier

        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            if currentHandle == nil || currentPartBytes + Int64(data.count) > maximumPartBytes {
                closeCurrentHandle()
                openNextPart()
            }
            guard let currentHandle else {
                lastError = lastError == "none" ? "Journal file handle unavailable" : lastError
                return
            }
            try currentHandle.write(contentsOf: data)
            currentPartBytes += Int64(data.count)
            let row = String(decoding: data.dropLast(), as: UTF8.self)
            recentRows.append(row)
            if recentRows.count > 40 {
                recentRows.removeFirst(recentRows.count - 40)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

@MainActor
final class OCRDiagnosticsStore: ObservableObject {
    @Published var regionOCRPreview: [OCRRegionKey: String] = [:]
    @Published var regionOCRRecognizer: [OCRRegionKey: RecognitionStrategy] = [:]
    @Published var ocrDiagnosticDisplayOptions = OCRDiagnosticDisplayOptions()
    @Published var selectedRegionRawPreviewImage: UIImage?
    @Published var selectedRegionProcessedPreviewImage: UIImage?
    @Published var selectedRegionThresholdedPreviewImage: UIImage?
    @Published var selectedRegionSegmentPreviewImage: UIImage?
    @Published var selectedRegionPreviewStatus = "No OCR crop yet"
    @Published var regionLikelyLabels: [OCRRegionKey: String] = [:]
    @Published var ocrFieldConfidence: [OCRRegionKey: OCRFieldConfidence] = [:]
    @Published var ocrTrustSummary = OCRTrustSummary()
    @Published var latestOCRCandidateState = ScoreboardState()
    @Published var isPixelHashingActive = false
    @Published var ocrPixelHashingStatusText = "Pixel hashing inactive"
    @Published var ocrPixelHashingDetailText = "Perspective-corrected whole-zone block-average hashing watches score, clock, period and penalty changes before bounded OCR is opened."
    @Published var regionDetectionStates: [OCRRegionKey: OCRRegionDetectionState] = Dictionary(uniqueKeysWithValues: OCRRegionKey.calibrationCases.map { ($0, .none) })
    @Published var smartChangeSkippedOCRFrames: Int = 0
    @Published var smartChangeLastDecisionText: String = "Smart Change Detection ready"

    @Published private(set) var fieldPublicationDiagnostics: [OCRRegionKey: RinkLensOCRFieldPublicationDiagnostic] = [:]
    @Published private(set) var lastPublicationFlowText = "No OCR publication flow has completed."
    @Published private(set) var lastPublicationSummary = "No OCR field decision has been recorded."

    private var lastPreviewPublishAt: CFTimeInterval = 0
    private let previewPublishInterval: CFTimeInterval = 0.35

    var orderedFieldPublicationDiagnostics: [RinkLensOCRFieldPublicationDiagnostic] {
        OCRRegionKey.productionOCRCases.compactMap { fieldPublicationDiagnostics[$0] }
    }

    func recordFieldPublication(_ diagnostic: RinkLensOCRFieldPublicationDiagnostic) {
        RinkLensOCREvidenceJournal.shared.recordPublication(diagnostic)
        fieldPublicationDiagnostics[diagnostic.key] = diagnostic
        lastPublicationFlowText = diagnostic.flow.title
        lastPublicationSummary = "\(diagnostic.key.likelyTitle): \(diagnostic.compactText)"
    }

    func recordPublicationSummary(flow: RinkLensOCRPublicationFlow, summary: String) {
        RinkLensOCREvidenceJournal.shared.recordPublicationSummary(flow: flow, summary: summary)
        lastPublicationFlowText = flow.title
        lastPublicationSummary = summary
    }

    func resetPublicationDiagnostics(reason: String) {
        fieldPublicationDiagnostics.removeAll()
        lastPublicationFlowText = "OCR publication diagnostics reset"
        lastPublicationSummary = reason
    }

    func resetLiveDiagnostics(reason: String) {
        latestOCRCandidateState = ScoreboardState()
        regionOCRPreview = Dictionary(uniqueKeysWithValues: OCRRegionKey.allCases.map { ($0, "--") })
        regionOCRRecognizer.removeAll()
        ocrFieldConfidence.removeAll()
        ocrTrustSummary = OCRTrustSummary()
        selectedRegionRawPreviewImage = nil
        selectedRegionProcessedPreviewImage = nil
        selectedRegionThresholdedPreviewImage = nil
        selectedRegionSegmentPreviewImage = nil
        selectedRegionPreviewStatus = reason
        isPixelHashingActive = false
        ocrPixelHashingStatusText = "Pixel hashing inactive"
        smartChangeLastDecisionText = reason
        regionDetectionStates = Dictionary(uniqueKeysWithValues: OCRRegionKey.calibrationCases.map { ($0, .none) })
        resetPublicationDiagnostics(reason: reason)
    }

    func clearCropPreview(status: String) {
        selectedRegionRawPreviewImage = nil
        selectedRegionProcessedPreviewImage = nil
        selectedRegionThresholdedPreviewImage = nil
        selectedRegionSegmentPreviewImage = nil
        selectedRegionPreviewStatus = status
    }

    func publishCropPreview(
        rawImage: UIImage?,
        processedImage: UIImage?,
        thresholdedImage: UIImage?,
        segmentImage: UIImage? = nil,
        status: String,
        now: CFTimeInterval = CACurrentMediaTime(),
        force: Bool = false
    ) {
        guard force || now - lastPreviewPublishAt >= previewPublishInterval else { return }
        lastPreviewPublishAt = now
        selectedRegionRawPreviewImage = rawImage
        selectedRegionProcessedPreviewImage = processedImage
        selectedRegionThresholdedPreviewImage = thresholdedImage
        selectedRegionSegmentPreviewImage = segmentImage
        selectedRegionPreviewStatus = status
    }

    func updateSmartChange(skippedFrames: Int? = nil, decisionText: String? = nil) {
        if let skippedFrames { smartChangeSkippedOCRFrames = skippedFrames }
        if let decisionText { smartChangeLastDecisionText = decisionText }
    }
}
#endif
