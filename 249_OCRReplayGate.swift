// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation
import CoreFoundation
import CoreGraphics
import UIKit

// MARK: - UX16d20 Build 542 deterministic OCR replay and transaction gate

/// A compact append-only event written during physical OCR sessions. The record
/// intentionally stores strings and primitive values only so older replay bundles
/// remain readable after production model types evolve.
nonisolated struct RinkLensOCRReplayRecord: Codable, Sendable {
    let sequence: UInt64
    let timestamp: Date
    let monotonicSeconds: Double
    let stage: String
    let transactionID: String?
    let frameID: Int?
    let captureGeneration: Int?
    let workUnit: String?
    let keys: [String]
    let detail: String
    let stateSummary: String?
}

enum RinkLensOCRReplayTerminalState: String, Codable, Sendable {
    case completed
    case confirmedBlank
    case retryScheduled
    case expiredWithFault
}

private struct RinkLensOCRReplayPendingTransaction: Sendable {
    let id: String
    let workUnit: String
    let startedAt: CFAbsoluteTime
    var lastProgressAt: CFAbsoluteTime
    var deadlineAt: CFAbsoluteTime
    var terminalState: RinkLensOCRReplayTerminalState?
    var detail: String
}

struct RinkLensOCRReplayGateResult: Identifiable, Sendable {
    let id = UUID()
    let scenario: String
    let passed: Bool
    let summary: String
    let failures: [String]
    let finalState: String
    let goalPopupCount: Int
    let penaltyPopupCount: Int
    let maximumServiceGaps: [String: Double]
}

/// Queue-safe writer used by both the MainActor controller and the OCR executor.
/// Exact field crops are emitted from the production dynamic-token path, avoiding
/// a second crop implementation that could silently differ from live OCR.
nonisolated final class RinkLensOCRReplayFileSink: @unchecked Sendable {
    static let shared = RinkLensOCRReplayFileSink()

    private let queue = DispatchQueue(label: "RinkLens.OCRReplayFileSink", qos: .utility)
    private let lock = NSLock()
    private var sessionDirectory: URL?
    private var eventURL: URL?
    private var cropIndexURL: URL?

    private init() {}

    func configure(sessionDirectory: URL?) {
        lock.lock()
        self.sessionDirectory = sessionDirectory
        self.eventURL = sessionDirectory?.appendingPathComponent("events.jsonl")
        self.cropIndexURL = sessionDirectory?.appendingPathComponent("crops.jsonl")
        lock.unlock()
    }

    func append(_ record: RinkLensOCRReplayRecord) {
        lock.lock()
        let url = eventURL
        lock.unlock()
        guard let url else { return }
        queue.async {
            guard let data = try? JSONEncoder.rinkLensReplay.encode(record) else { return }
            Self.appendLine(data, to: url)
        }
    }

    func captureCrop(
        key: OCRRegionKey,
        image: CGImage,
        frameID: Int?,
        captureGeneration: Int,
        diagnostic: String
    ) {
        lock.lock()
        let directory = sessionDirectory
        let indexURL = cropIndexURL
        lock.unlock()
        guard let directory, let indexURL else { return }

        let safeFrame = frameID ?? -1
        let filename = String(
            format: "crop_g%03d_f%08d_%@_%lld.jpg",
            captureGeneration,
            safeFrame,
            key.rawValue,
            Int64(DispatchTime.now().uptimeNanoseconds)
        )
        let destination = directory.appendingPathComponent("crops", isDirectory: true)
            .appendingPathComponent(filename)

        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.72) else { return }
                try data.write(to: destination, options: .atomic)
                let row: [String: Any] = [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "generation": captureGeneration,
                    "frameID": safeFrame,
                    "key": key.rawValue,
                    "filename": "crops/\(filename)",
                    "width": image.width,
                    "height": image.height,
                    "diagnostic": diagnostic
                ]
                guard JSONSerialization.isValidJSONObject(row),
                      let rowData = try? JSONSerialization.data(withJSONObject: row) else { return }
                Self.appendLine(rowData, to: indexURL)
            } catch {
                // Replay capture is diagnostic-only and must never affect OCR.
            }
        }
    }

    private static func appendLine(_ data: Data, to url: URL) {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
            try handle.close()
        } catch {
            // The production pipeline must remain unaffected by diagnostic I/O.
        }
    }
}

private extension JSONEncoder {
    static var rinkLensReplay: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

@MainActor
final class RinkLensOCRReplayGateController: ObservableObject {
    static let shared = RinkLensOCRReplayGateController()

    @Published private(set) var captureEnabled = false
    @Published private(set) var statusText = "Replay capture is off"
    @Published private(set) var lastSessionURL: URL?
    @Published private(set) var gateResults: [RinkLensOCRReplayGateResult] = []
    @Published private(set) var recentFaults: [String] = []
    @Published private(set) var activeTransactionCount = 0

    private var sequence: UInt64 = 0
    private var sessionStartedUptime = CFAbsoluteTimeGetCurrent()
    private var pendingTransactions: [String: RinkLensOCRReplayPendingTransaction] = [:]
    private var planTransactionBySequence: [UInt64: String] = [:]

    private init() {}

    func startCapture(reason: String = "operator requested") {
        guard !captureEnabled else { return }
        do {
            let root = try replayRootDirectory()
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let directory = root.appendingPathComponent(
                "Replay_\(stamp)_Build\(RinkLensBuildInfo.buildNumber)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "schema": 1,
                "build": RinkLensBuildInfo.version,
                "buildNumber": RinkLensBuildInfo.buildNumber,
                "created": ISO8601DateFormatter().string(from: Date()),
                "reason": reason,
                "contract": "exact dynamic-token crops + control plan + recognition + reducer + event + overlay transaction stages"
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)

            sequence = 0
            sessionStartedUptime = CFAbsoluteTimeGetCurrent()
            pendingTransactions.removeAll()
            planTransactionBySequence.removeAll()
            recentFaults.removeAll()
            lastSessionURL = directory
            RinkLensOCRReplayFileSink.shared.configure(sessionDirectory: directory)
            captureEnabled = true
            statusText = "Capturing deterministic OCR replay evidence"
            appendRecord(
                stage: "session_started",
                detail: "reason=\(reason)",
                stateSummary: nil
            )
        } catch {
            statusText = "Replay capture could not start: \(error.localizedDescription)"
        }
    }

    func stopCapture(reason: String = "operator stopped") {
        guard captureEnabled else { return }
        expirePendingTransactions(now: CFAbsoluteTimeGetCurrent(), force: true)
        appendRecord(
            stage: "session_stopped",
            detail: "reason=\(reason) unresolved=\(pendingTransactions.values.filter { $0.terminalState == nil }.count)",
            stateSummary: nil
        )
        captureEnabled = false
        RinkLensOCRReplayFileSink.shared.configure(sessionDirectory: nil)
        statusText = "Replay capture stopped"
    }

    func recordPlan(
        _ plan: OCRWorkScheduler.Plan,
        frameID: Int?,
        captureGeneration: Int,
        pendingBaseline: Set<OCRRegionKey>,
        pendingPenaltyBaseline: Set<OCRRegionKey>,
        visualChanges: Set<OCRRegionKey>,
        publicationPriority: Set<OCRRegionKey>,
        resetRecovery: Set<OCRRegionKey>,
        activePenalty: Set<OCRRegionKey>,
        visibleState: ScoreboardState
    ) {
        guard captureEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        expirePendingTransactions(now: now)
        let transactionID = "plan-\(plan.sequence)-\(plan.unit.diagnosticName)"
        planTransactionBySequence[plan.sequence] = transactionID
        let maximum = maximumResolutionSeconds(for: plan.unit)
        pendingTransactions[transactionID] = RinkLensOCRReplayPendingTransaction(
            id: transactionID,
            workUnit: plan.unit.diagnosticName,
            startedAt: now,
            lastProgressAt: now,
            deadlineAt: now + maximum,
            terminalState: nil,
            detail: plan.reason
        )
        activeTransactionCount = pendingTransactions.values.filter { $0.terminalState == nil }.count
        appendRecord(
            stage: "control_plan",
            transactionID: transactionID,
            frameID: frameID,
            captureGeneration: captureGeneration,
            workUnit: plan.unit.diagnosticName,
            keys: plan.keys,
            detail: "priority=\(plan.priority.rawValue) reason=\(plan.reason) hardDeadline=\(plan.hardDeadlineAt) pendingBaseline=[\(keyText(pendingBaseline))] pendingPenaltyBaseline=[\(keyText(pendingPenaltyBaseline))] visual=[\(keyText(visualChanges))] publication=[\(keyText(publicationPriority))] reset=[\(keyText(resetRecovery))] activePenalty=[\(keyText(activePenalty))]",
            stateSummary: stateSummary(visibleState)
        )
    }

    func recordRecognition(
        plan: OCRWorkScheduler.Plan?,
        passID: UInt64,
        fields: [ScoreboardOCRProcessor.OCRFieldDebug],
        visibleState: ScoreboardState
    ) {
        guard captureEnabled else { return }
        let transactionID = plan.flatMap { planTransactionBySequence[$0.sequence] }
        let detail = fields.map { field in
            "\(field.key.rawValue){raw=\(field.raw) accepted=\(field.accepted) confidence=\(String(format: "%.2f", field.confidence)) validation=\(field.validation)}"
        }.joined(separator: " | ")
        appendRecord(
            stage: "recognition_completed",
            transactionID: transactionID,
            workUnit: plan?.unit.diagnosticName,
            keys: Set(fields.map(\.key)),
            detail: "passID=\(passID) \(detail)",
            stateSummary: stateSummary(visibleState)
        )
    }

    func recordControlPlaneCompletion(
        plan: OCRWorkScheduler.Plan?,
        usableKeys: Set<OCRRegionKey>,
        completedKeys: Set<OCRRegionKey>,
        confirmedBlankKeys: Set<OCRRegionKey>,
        reason: String
    ) {
        guard captureEnabled, let plan else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let transactionID = planTransactionBySequence[plan.sequence]
        let terminal: RinkLensOCRReplayTerminalState
        if !confirmedBlankKeys.isEmpty {
            terminal = .confirmedBlank
        } else if !usableKeys.isEmpty {
            terminal = .completed
        } else {
            terminal = .retryScheduled
        }
        if let transactionID, var transaction = pendingTransactions[transactionID] {
            transaction.lastProgressAt = now
            transaction.terminalState = terminal
            transaction.detail = reason
            pendingTransactions[transactionID] = transaction
        }
        activeTransactionCount = pendingTransactions.values.filter { $0.terminalState == nil }.count
        appendRecord(
            stage: "control_completion",
            transactionID: transactionID,
            workUnit: plan.unit.diagnosticName,
            keys: completedKeys,
            detail: "terminal=\(terminal.rawValue) usable=[\(keyText(usableKeys))] blank=[\(keyText(confirmedBlankKeys))] reason=\(reason)",
            stateSummary: nil
        )
    }

    func recordReduction(_ reduction: RinkLensMatchStateReduction, revision: UInt64) {
        guard captureEnabled else { return }
        appendRecord(
            stage: "matchstate_reduction",
            keys: [],
            detail: "revision=\(revision) \(reduction.diagnosticSummary)",
            stateSummary: stateSummary(reduction.next)
        )
    }

    func recordEvent(stage: String, event: BroadcastEvent, detail: String) {
        guard captureEnabled else { return }
        appendRecord(
            stage: stage,
            transactionID: event.id.uuidString,
            workUnit: event.type.title,
            keys: [],
            detail: "team=\(event.team?.displayName ?? "none") source=\(event.source.rawValue) \(detail)",
            stateSummary: "score=\(event.homeScoreAfter.map { String($0) } ?? "--")-\(event.awayScoreAfter.map { String($0) } ?? "--") clock=\(event.gameClock ?? "--")"
        )
    }

    func runStandingRegressionGate() {
        let results = RinkLensOCRReplayScenarioLibrary.all.map { scenario in
            RinkLensOCRSyntheticReplayPipeline().run(scenario)
        }
        gateResults = results
        let passed = results.filter(\.passed).count
        statusText = "Replay gate: \(passed)/\(results.count) scenarios passed"
        if passed != results.count {
            recentFaults = results.flatMap { result in
                result.failures.map { "\(result.scenario): \($0)" }
            }
        }
    }

    private func expirePendingTransactions(now: CFAbsoluteTime, force: Bool = false) {
        var faults: [String] = []
        for (id, var transaction) in pendingTransactions where transaction.terminalState == nil {
            if force || now > transaction.deadlineAt {
                transaction.terminalState = .expiredWithFault
                transaction.detail = force
                    ? "session ended before bounded resolution"
                    : "no terminal resolution before deadline"
                pendingTransactions[id] = transaction
                faults.append("\(transaction.workUnit) expired after \(String(format: "%.1f", now - transaction.startedAt))s")
                appendRecord(
                    stage: "transaction_fault",
                    transactionID: id,
                    workUnit: transaction.workUnit,
                    keys: [],
                    detail: "terminal=expiredWithFault deadline=\(transaction.deadlineAt) lastProgress=\(transaction.lastProgressAt)",
                    stateSummary: nil
                )
            }
        }
        if !faults.isEmpty {
            recentFaults = Array((faults + recentFaults).prefix(20))
        }
        activeTransactionCount = pendingTransactions.values.filter { $0.terminalState == nil }.count
    }

    private func appendRecord(
        stage: String,
        transactionID: String? = nil,
        frameID: Int? = nil,
        captureGeneration: Int? = nil,
        workUnit: String? = nil,
        keys: Set<OCRRegionKey> = [],
        detail: String,
        stateSummary: String?
    ) {
        guard captureEnabled || stage == "session_stopped" else { return }
        sequence &+= 1
        let record = RinkLensOCRReplayRecord(
            sequence: sequence,
            timestamp: Date(),
            monotonicSeconds: CFAbsoluteTimeGetCurrent() - sessionStartedUptime,
            stage: stage,
            transactionID: transactionID,
            frameID: frameID,
            captureGeneration: captureGeneration,
            workUnit: workUnit,
            keys: keys.map(\.rawValue).sorted(),
            detail: detail,
            stateSummary: stateSummary
        )
        RinkLensOCRReplayFileSink.shared.append(record)
    }

    private func maximumResolutionSeconds(for unit: OCRWorkScheduler.WorkUnit) -> TimeInterval {
        switch unit {
        case .clock: return 3.0
        case .staticField(.homeScore), .staticField(.awayScore): return 6.0
        case .staticField(.period): return 10.0
        case .staticField: return 10.0
        case .penaltyPlayer: return 4.0
        case .penaltyPair: return 6.0
        }
    }

    private func replayRootDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("RinkLens/OCRReplay", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func keyText(_ keys: Set<OCRRegionKey>) -> String {
        keys.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func stateSummary(_ state: ScoreboardState) -> String {
        let penalties = StrengthStateCalculator.activePenaltyClocks(from: state)
            .map { "\($0.id)=\($0.playerNumber.map { String($0) } ?? "--")/\($0.rawClock ?? "--")" }
            .joined(separator: ",")
        return "clock=\(state.clock ?? "--") period=\(state.periodLabel ?? state.period.map { String($0) } ?? "--") score=\(state.homeScore.map { String($0) } ?? "--")-\(state.awayScore.map { String($0) } ?? "--") penalties=[\(penalties)]"
    }
}

// MARK: - Synthetic standing regression and chaos gate

private struct RinkLensOCRReplayPhysicalState {
    var clock = "20:00"
    var clockRunning = false
    var homeScore = 0
    var awayScore = 0
    var period = 1
    var home1Player: Int?
    var home1Clock: String?
    var home2Player: Int?
    var home2Clock: String?
    var away1Player: Int?
    var away1Clock: String?
    var away2Player: Int?
    var away2Clock: String?
}

private enum RinkLensOCRReplayMutation {
    case clock(String, running: Bool)
    case score(home: Int, away: Int)
    case penalty(slot: RinkLensMatchPenaltySlot, player: Int?, clock: String?)
}

private struct RinkLensOCRReplayMutationAt {
    let at: Double
    let mutation: RinkLensOCRReplayMutation
}

private struct RinkLensOCRReplayScenario {
    let name: String
    let duration: Double
    let mutations: [RinkLensOCRReplayMutationAt]
    let expectedHome: Int
    let expectedAway: Int
    let expectedActivePenalties: Int
    let expectedGoalPopups: Int
    let expectedPenaltyPopups: Int
    let injectUnusableAttempts: [String: Set<Int>]
}

private enum RinkLensOCRReplayScenarioLibrary {
    static let knownThreePenaltyGame = RinkLensOCRReplayScenario(
        name: "Known session: two goals and three rapid penalties",
        duration: 48,
        mutations: [
            .init(at: 2, mutation: .clock("19:58", running: true)),
            .init(at: 9, mutation: .clock("19:51", running: false)),
            .init(at: 10, mutation: .score(home: 1, away: 0)),
            .init(at: 14, mutation: .score(home: 1, away: 1)),
            .init(at: 18, mutation: .penalty(slot: .home1, player: 45, clock: "2:00")),
            .init(at: 20, mutation: .penalty(slot: .away1, player: 77, clock: "1:58")),
            .init(at: 22, mutation: .penalty(slot: .away2, player: 55, clock: "1:56")),
            .init(at: 27, mutation: .clock("19:50", running: true)),
            .init(at: 28, mutation: .penalty(slot: .home1, player: 45, clock: "1:59")),
            .init(at: 28, mutation: .penalty(slot: .away1, player: 77, clock: "1:57")),
            .init(at: 28, mutation: .penalty(slot: .away2, player: 55, clock: "1:55"))
        ],
        expectedHome: 1,
        expectedAway: 1,
        expectedActivePenalties: 3,
        expectedGoalPopups: 2,
        expectedPenaltyPopups: 1,
        injectUnusableAttempts: [:]
    )

    static let adversarialChaos = RinkLensOCRReplayScenario(
        name: "Chaos: corrections, Clock stop and overlapping penalties",
        duration: 58,
        mutations: [
            .init(at: 3, mutation: .clock("19:57", running: true)),
            .init(at: 8, mutation: .clock("19:52", running: false)),
            .init(at: 9, mutation: .score(home: 1, away: 0)),
            .init(at: 11, mutation: .penalty(slot: .home1, player: 45, clock: "2:00")),
            .init(at: 12, mutation: .penalty(slot: .away1, player: 77, clock: "2:00")),
            .init(at: 13, mutation: .penalty(slot: .away2, player: 55, clock: "2:00")),
            .init(at: 14, mutation: .score(home: 0, away: 0)),
            .init(at: 16, mutation: .score(home: 0, away: 1)),
            .init(at: 22, mutation: .penalty(slot: .home1, player: 45, clock: "1:59")),
            .init(at: 22, mutation: .penalty(slot: .away1, player: 77, clock: "1:59")),
            .init(at: 22, mutation: .penalty(slot: .away2, player: 55, clock: "1:59")),
            .init(at: 27, mutation: .clock("19:51", running: true)),
            .init(at: 31, mutation: .clock("19:47", running: false)),
            .init(at: 34, mutation: .clock("19:46", running: true))
        ],
        expectedHome: 0,
        expectedAway: 1,
        expectedActivePenalties: 3,
        expectedGoalPopups: 1,
        expectedPenaltyPopups: 1,
        injectUnusableAttempts: [
            "homeScore": [1],
            "penaltyPair(homePenalty1Player+homePenalty1Time)": [1],
            "penaltyPair(awayPenalty1Player+awayPenalty1Time)": [1]
        ]
    )

    static let activePenaltyThenLaterGoal = RinkLensOCRReplayScenario(
        name: "Active penalty noise cannot suppress later goal or Clock",
        duration: 68,
        mutations: [
            .init(at: 2, mutation: .clock("19:58", running: true)),
            .init(at: 6, mutation: .clock("19:54", running: false)),
            .init(at: 8, mutation: .score(home: 1, away: 0)),
            .init(at: 14, mutation: .score(home: 1, away: 1)),
            .init(at: 20, mutation: .penalty(slot: .home1, player: 45, clock: "2:00")),
            .init(at: 24, mutation: .clock("19:53", running: true)),
            .init(at: 25, mutation: .penalty(slot: .home1, player: 45, clock: "1:59")),
            .init(at: 30, mutation: .clock("19:30", running: false)),
            .init(at: 34, mutation: .clock("19:29", running: true)),
            .init(at: 38, mutation: .clock("19:25", running: false)),
            .init(at: 40, mutation: .score(home: 1, away: 2)),
            .init(at: 44, mutation: .clock("19:24", running: true))
        ],
        expectedHome: 1,
        expectedAway: 2,
        expectedActivePenalties: 1,
        expectedGoalPopups: 3,
        expectedPenaltyPopups: 1,
        injectUnusableAttempts: [
            "penaltyPair(homePenalty1Player+homePenalty1Time)": [5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
        ]
    )

    static let noisyUnresolvedSlotThenRealPenalties = RinkLensOCRReplayScenario(
        name: "Noisy unresolved slot cannot starve later Home and Away penalties",
        duration: 84,
        mutations: [
            .init(at: 2, mutation: .clock("19:58", running: true)),
            .init(at: 6, mutation: .clock("19:54", running: false)),
            .init(at: 8, mutation: .score(home: 1, away: 0)),
            .init(at: 14, mutation: .score(home: 1, away: 1)),
            .init(at: 22, mutation: .penalty(slot: .home1, player: 45, clock: "2:00")),
            .init(at: 26, mutation: .clock("19:53", running: true)),
            .init(at: 27, mutation: .penalty(slot: .home1, player: 45, clock: "1:59")),
            .init(at: 32, mutation: .clock("19:48", running: false)),
            .init(at: 34, mutation: .score(home: 1, away: 2)),
            .init(at: 37, mutation: .clock("19:47", running: true)),
            .init(at: 40, mutation: .clock("19:44", running: false)),
            .init(at: 42, mutation: .penalty(slot: .away1, player: 45, clock: "2:00")),
            .init(at: 46, mutation: .clock("19:43", running: true)),
            .init(at: 47, mutation: .penalty(slot: .away1, player: 45, clock: "1:59")),
            .init(at: 55, mutation: .clock("19:03", running: false)),
            .init(at: 60, mutation: .clock("19:02", running: true))
        ],
        expectedHome: 1,
        expectedAway: 2,
        expectedActivePenalties: 2,
        expectedGoalPopups: 3,
        expectedPenaltyPopups: 2,
        injectUnusableAttempts: [
            // Recreate the physical Build 540 shape: Home 2 owns a persistent
            // changed hash while the other three penalty slots have not yet
            // obtained any usable baseline evidence.
            "penaltyPair(homePenalty1Player+homePenalty1Time)": [1, 2, 3],
            "penaltyPair(homePenalty2Player+homePenalty2Time)": Set(1...80),
            "penaltyPair(awayPenalty1Player+awayPenalty1Time)": [1, 2, 3],
            "penaltyPair(awayPenalty2Player+awayPenalty2Time)": [1, 2, 3]
        ]
    )

    static let build541PhysicalRegression = RinkLensOCRReplayScenario(
        name: "Build 541 physical regression: goals, one penalty and sustained Clock",
        duration: 78,
        mutations: [
            .init(at: 2, mutation: .clock("19:58", running: true)),
            .init(at: 10, mutation: .clock("19:32", running: false)),
            .init(at: 11, mutation: .score(home: 1, away: 0)),
            .init(at: 18, mutation: .clock("19:31", running: true)),
            .init(at: 24, mutation: .clock("19:15", running: false)),
            .init(at: 25, mutation: .score(home: 2, away: 0)),
            .init(at: 31, mutation: .penalty(slot: .home1, player: 45, clock: "2:00")),
            .init(at: 35, mutation: .clock("18:52", running: true)),
            .init(at: 39, mutation: .penalty(slot: .home1, player: 45, clock: "1:56")),
            .init(at: 45, mutation: .clock("18:33", running: false)),
            .init(at: 46, mutation: .score(home: 2, away: 1)),
            .init(at: 53, mutation: .clock("18:32", running: true)),
            .init(at: 62, mutation: .clock("17:48", running: false)),
            .init(at: 63, mutation: .score(home: 3, away: 1)),
            .init(at: 69, mutation: .clock("17:47", running: true))
        ],
        expectedHome: 3,
        expectedAway: 1,
        expectedActivePenalties: 1,
        expectedGoalPopups: 4,
        expectedPenaltyPopups: 1,
        injectUnusableAttempts: [
            "penaltyPair(homePenalty2Player+homePenalty2Time)": Set(1...80),
            "penaltyPair(awayPenalty1Player+awayPenalty1Time)": Set(1...80),
            "penaltyPair(awayPenalty2Player+awayPenalty2Time)": Set(1...80)
        ]
    )

    static let pendingTermination = RinkLensOCRReplayScenario(
        name: "Bounded termination: persistent malformed pair cannot wedge queue",
        duration: 42,
        mutations: [
            .init(at: 2, mutation: .clock("19:58", running: true)),
            .init(at: 6, mutation: .clock("19:54", running: false)),
            .init(at: 8, mutation: .score(home: 1, away: 0)),
            .init(at: 10, mutation: .penalty(slot: .home1, player: 45, clock: "2:80")),
            .init(at: 18, mutation: .penalty(slot: .home1, player: 45, clock: "1:51")),
            .init(at: 20, mutation: .score(home: 1, away: 1)),
            .init(at: 22, mutation: .clock("19:53", running: true)),
            .init(at: 25, mutation: .clock("19:40", running: false)),
            .init(at: 30, mutation: .clock("19:39", running: true))
        ],
        expectedHome: 1,
        expectedAway: 1,
        expectedActivePenalties: 1,
        expectedGoalPopups: 2,
        expectedPenaltyPopups: 1,
        injectUnusableAttempts: [
            "penaltyPair(homePenalty2Player+homePenalty2Time)": [1, 2, 3, 4, 5, 6]
        ]
    )

    static let all = [
        knownThreePenaltyGame,
        adversarialChaos,
        activePenaltyThenLaterGoal,
        noisyUnresolvedSlotThenRealPenalties,
        build541PhysicalRegression,
        pendingTermination
    ]
}

@MainActor
private final class RinkLensOCRSyntheticReplayPipeline {
    private var physical = RinkLensOCRReplayPhysicalState()
    private var visible = ScoreboardState()
    private var publicationMemory = OCREvidenceStore()
    private let controlPlane = OCRWorkScheduler()
    private let detector = RinkLensGameEventCoordinator()
    private var pendingVisual = Set<OCRRegionKey>()
    private var appliedMutationCount = 0
    private var attemptsByUnit: [String: Int] = [:]
    private var lastServiceAt: [String: Double] = [:]
    private var maximumServiceGap: [String: Double] = [:]
    private var pendingConfirmationAt: [String: Double] = [:]
    private var maximumConfirmationGap: [String: Double] = [:]
    private var replayBaseDate = Date()
    private var goalPopups: [BroadcastEvent] = []
    private var penaltyPopups: [BroadcastEvent] = []

    func run(_ scenario: RinkLensOCRReplayScenario) -> RinkLensOCRReplayGateResult {
        reset()
        let step = 0.75
        var now = 0.0
        while now <= scenario.duration {
            applyMutations(scenario.mutations, through: now)
            runPass(now: now, scenario: scenario)
            releaseHeldEvents(now: now)
            now += step
        }

        let activePenalties = StrengthStateCalculator.activePenaltyClocks(from: visible).filter(\.isActive).count
        var failures: [String] = []
        if visible.homeScore != scenario.expectedHome {
            failures.append("Home score expected \(scenario.expectedHome), got \(visible.homeScore.map { String($0) } ?? "nil")")
        }
        if visible.awayScore != scenario.expectedAway {
            failures.append("Away score expected \(scenario.expectedAway), got \(visible.awayScore.map { String($0) } ?? "nil")")
        }
        if activePenalties != scenario.expectedActivePenalties {
            failures.append("Active penalties expected \(scenario.expectedActivePenalties), got \(activePenalties)")
        }
        if goalPopups.count != scenario.expectedGoalPopups {
            failures.append("Goal popups expected \(scenario.expectedGoalPopups), got \(goalPopups.count)")
        }
        if penaltyPopups.count != scenario.expectedPenaltyPopups {
            failures.append("Penalty popups expected \(scenario.expectedPenaltyPopups), got \(penaltyPopups.count)")
        }
        for key in ["homeScore", "awayScore"] {
            if (maximumServiceGap[key] ?? 0) > 10.0 {
                failures.append("\(key) routine service gap exceeded loaded-lane 10s contract: \(String(format: "%.2f", maximumServiceGap[key] ?? 0))s")
            }
        }
        if (maximumServiceGap["clock"] ?? 0) > 5.5 {
            failures.append("Clock service gap exceeded 5.5s authority contract: \(String(format: "%.2f", maximumServiceGap["clock"] ?? 0))s")
        }
        // Inactive unresolved penalty slots are deliberately hash-driven after
        // one initial sample and may have a 20-second safety-audit gap. Only a
        // real pending confirmation is required to revisit inside five seconds.
        for (unit, gap) in maximumConfirmationGap where gap > 5.0 {
            failures.append("\(unit) confirmation revisit exceeded 5s evidence window: \(String(format: "%.2f", gap))s")
        }
        for (unit, startedAt) in pendingConfirmationAt {
            failures.append("\(unit) remained pending at replay end for \(String(format: "%.2f", scenario.duration - startedAt))s")
        }

        return RinkLensOCRReplayGateResult(
            scenario: scenario.name,
            passed: failures.isEmpty,
            summary: failures.isEmpty ? "End-to-end contracts satisfied" : "\(failures.count) contract failures",
            failures: failures,
            finalState: stateSummary(visible),
            goalPopupCount: goalPopups.count,
            penaltyPopupCount: penaltyPopups.count,
            maximumServiceGaps: maximumServiceGap
        )
    }

    private func reset() {
        physical = RinkLensOCRReplayPhysicalState()
        visible = ScoreboardState()
        visible.clock = "20:00"
        visible.period = 1
        visible.periodLabel = "1"
        visible.homeScore = 0
        visible.awayScore = 0
        publicationMemory.reset()
        controlPlane.reset(generation: 1, now: 0, reason: "synthetic replay")
        detector.reset()
        // Initial score/period baselines are explicit. Penalty baselines are
        // player-number led; inactive timer zones have no independent lifecycle.
        pendingVisual = [.homeScore, .awayScore, .period,
                         .homePenalty1Player,
                         .homePenalty2Player,
                         .awayPenalty1Player,
                         .awayPenalty2Player]
        appliedMutationCount = 0
        attemptsByUnit.removeAll()
        lastServiceAt.removeAll()
        maximumServiceGap.removeAll()
        pendingConfirmationAt.removeAll()
        maximumConfirmationGap.removeAll()
        replayBaseDate = Date()
        goalPopups.removeAll()
        penaltyPopups.removeAll()
    }

    private func applyMutations(_ mutations: [RinkLensOCRReplayMutationAt], through now: Double) {
        while appliedMutationCount < mutations.count,
              mutations[appliedMutationCount].at <= now {
            let mutation = mutations[appliedMutationCount].mutation
            switch mutation {
            case .clock(let value, let running):
                physical.clock = value
                physical.clockRunning = running
            case .score(let home, let away):
                if physical.homeScore != home {
                    pendingVisual.insert(.homeScore)
                    lastServiceAt["homeScore"] = now
                }
                if physical.awayScore != away {
                    pendingVisual.insert(.awayScore)
                    lastServiceAt["awayScore"] = now
                }
                physical.homeScore = home
                physical.awayScore = away
            case .penalty(let slot, let player, let clock):
                let ordered = penaltyKeyPair(slot)
                let previous = physicalPenalty(playerKey: ordered.player)
                if previous.player != player {
                    // Player-zone hashing creates, replaces and clears a slot.
                    // A timer change cannot create a penalty independently.
                    pendingVisual.insert(ordered.player)
                    let unitName = OCRWorkScheduler.WorkUnit.penaltyPlayer(ordered.player).diagnosticName
                    lastServiceAt[unitName] = now
                } else if player != nil, previous.clock != clock {
                    // Once a player owns the slot, timer hashing can wake the
                    // paired update transaction.
                    pendingVisual.insert(ordered.time)
                    let unitName = OCRWorkScheduler.WorkUnit.penaltyPair(player: ordered.player, time: ordered.time).diagnosticName
                    lastServiceAt[unitName] = now
                }
                setPhysicalPenalty(slot: slot, player: player, clock: clock)
            }
            appliedMutationCount += 1
        }
    }

    private func runPass(now: Double, scenario: RinkLensOCRReplayScenario) {
        let activeKeys = activePhysicalPenaltyKeys()
        let plan = controlPlane.nextPlan(
            signals: OCRWorkScheduler.Signals(
                generation: 1,
                now: now,
                performanceSafeMode: false,
                startupClockBootstrap: false,
                clockConfirmationRequired: false,
                trustedClockRunning: physical.clockRunning,
                confirmedStoppedClock: !physical.clockRunning,
                pendingBaselineKeys: publicationMemory.pendingBaselineKeys,
                pendingPenaltyBaselineKeys: publicationMemory.pendingPenaltyBaselineKeys,
                publicationPriorityKeys: publicationMemory.pendingPriorityVerificationKeys,
                resetRecoveryKeys: [],
                visualChangeKeys: pendingVisual,
                activePenaltyKeys: activeKeys
            )
        )

        let name = plan.unit.diagnosticName
        let attempt = attemptsByUnit[name, default: 0] + 1
        attemptsByUnit[name] = attempt
        let shouldTrackService: Bool
        switch plan.unit {
        case .penaltyPlayer(let playerKey), .penaltyPair(let playerKey, _):
            shouldTrackService = physicalPenalty(playerKey: playerKey).player != nil
                || pendingVisual.contains(playerKey)
        default:
            shouldTrackService = true
        }
        if shouldTrackService {
            if let previous = lastServiceAt[name] {
                maximumServiceGap[name] = max(maximumServiceGap[name] ?? 0, now - previous)
            }
            lastServiceAt[name] = now
        }

        if scenario.injectUnusableAttempts[name]?.contains(attempt) == true {
            controlPlane.complete(
                .init(usableKeys: [], completedKeys: plan.keys, confirmedBlankKeys: [], now: now, reason: "synthetic unusable observation")
            )
            return
        }

        let observation = observation(for: plan.unit)
        let previousVisible = visible
        var candidate = visible
        apply(observation: observation.values, blanks: observation.blanks, to: &candidate)
        var evidence = RinkLensOCRPublicationEvidence()
        for (key, value) in observation.values {
            evidence.fields[key] = RinkLensOCRFieldEvidence(
                acceptedText: value,
                rawText: value,
                confidence: 0.96,
                segmentationBacked: true,
                deterministicAgreement: true
            )
        }
        for key in observation.blanks {
            evidence.fields[key] = RinkLensOCRFieldEvidence(
                acceptedText: "",
                rawText: "",
                confidence: 0,
                segmentationBacked: true,
                deterministicAgreement: true,
                confirmedBlank: true
            )
        }

        let wasConfirmationPending = !publicationMemory.pendingPriorityVerificationKeys.intersection(plan.keys).isEmpty
        // The event coordinator records the physical Clock state before
        // publication so a field first observed immediately after restart can
        // complete the transaction opened during the preceding stoppage.
        let replayDate = replayBaseDate.addingTimeInterval(now)
        if physical.clockRunning {
            detector.notePhysicalClockRunning(now: replayDate)
        } else {
            detector.notePhysicalClockStopped(clockText: physical.clock)
        }

        let safety = RinkLensOCRPublicationSafetyPolicy.evaluateContinuous(
            previous: visible,
            candidate: candidate,
            evidence: evidence,
            confirmedStoppedClock: !physical.clockRunning,
            hashTriggeredKeys: pendingVisual,
            localClockIsRunning: physical.clockRunning,
            memory: &publicationMemory,
            now: now
        )
        let isConfirmationPending = !publicationMemory.pendingPriorityVerificationKeys.intersection(plan.keys).isEmpty
        if !wasConfirmationPending && isConfirmationPending {
            pendingConfirmationAt[name] = now
        } else if wasConfirmationPending && !isConfirmationPending,
                  let startedAt = pendingConfirmationAt.removeValue(forKey: name) {
            maximumConfirmationGap[name] = max(maximumConfirmationGap[name] ?? 0, now - startedAt)
        }

        let reduction = RinkLensMatchStateReducer.reduce(
            current: visible,
            action: .applyAcceptedOCR(
                safety.state,
                manualProtection: ManualScoreState(),
                context: .init(
                    origin: .ocr,
                    eventPolicy: safety.eventPolicy,
                    reason: "synthetic production replay"
                )
            )
        )
        visible = reduction.next

        let scoreTeams = Set(observation.values.compactMap { key, value -> Team? in
            guard Int(value) != nil else { return nil }
            if key == .homeScore, visible.homeScore == Int(value) { return .home }
            if key == .awayScore, visible.awayScore == Int(value) { return .away }
            return nil
        })
        detector.noteConfirmedGoalScoreObservation(
            currentState: visible,
            observedScoreTeams: scoreTeams,
            observationID: plan.sequence
        )

        if reduction.shouldEvaluateScoreEvents,
           let event = detector.makeGoalEvent(
                from: previousVisible,
                to: visible,
                source: .ocr,
                operatorConfirmed: false,
                eventClock: visible.clock,
                currentStrengthState: StrengthStateCalculator.strengthState(
                    from: StrengthStateCalculator.activePenaltyClocks(from: visible)
                ),
                activePenaltyClocks: StrengthStateCalculator.activePenaltyClocks(from: visible)
           ) {
            detector.upsertPendingStoppedClockBroadcastEvent(event)
        }

        if reduction.shouldEvaluatePenaltyEvents {
            let update = detector.makePenaltyBroadcastEventUpdate(
                from: previousVisible,
                to: visible,
                source: .ocr,
                operatorConfirmed: false,
                eventClock: visible.clock
            )
            if let event = update.event {
                detector.upsertPendingStoppedClockBroadcastEvent(event)
            }
        }

        let usable = Set(observation.values.keys).union(observation.blanks)
        commitResolvedVisualTransactions(observation: observation, plan: plan)
        controlPlane.complete(
            .init(usableKeys: usable, completedKeys: plan.keys, confirmedBlankKeys: observation.blanks, now: now, reason: "synthetic usable observation")
        )
    }

    private func releaseHeldEvents(now: Double) {
        let date = replayBaseDate.addingTimeInterval(now)
        let events = detector.flushNormalizedStoppedClockBroadcastEvents(now: date, currentState: visible)
            + detector.flushStableGoalFallbackEvents(now: date, currentState: visible)
        for event in events {
            switch event.type {
            case .goal, .powerPlayGoal, .shortHandedGoal:
                goalPopups.append(event)
            case .penalty, .penalties, .powerPlayStart, .penaltyEnd, .timeoutStart, .timeoutEnd:
                penaltyPopups.append(event)
            default:
                break
            }
        }
    }

    private func commitResolvedVisualTransactions(
        observation: (values: [OCRRegionKey: String], blanks: Set<OCRRegionKey>),
        plan: OCRWorkScheduler.Plan
    ) {
        let stillPending = publicationMemory.pendingPriorityVerificationKeys

        for key in plan.keys where !stillPending.contains(key) {
            switch key {
            case .homeScore:
                if visible.homeScore == physical.homeScore { pendingVisual.remove(key) }
            case .awayScore:
                if visible.awayScore == physical.awayScore { pendingVisual.remove(key) }
            case .period:
                if visible.period == physical.period { pendingVisual.remove(key) }
            case .homePenalty1Player, .homePenalty2Player,
                 .awayPenalty1Player, .awayPenalty2Player:
                let physicalPair = physicalPenalty(playerKey: key)
                let visiblePair = visiblePenalty(playerKey: key)
                if physicalPair.player == visiblePair.player,
                   physicalPair.player == nil || physicalPair.clock == visiblePair.clock {
                    pendingVisual.remove(key)
                    pendingVisual.remove(PenaltyStateMachine.penaltyTimeKey(forPlayerKey: key))
                }
            case .homePenalty1Time, .homePenalty2Time,
                 .awayPenalty1Time, .awayPenalty2Time:
                let playerKey = PenaltyStateMachine.penaltyPlayerKey(forTimeKey: key)
                let physicalPair = physicalPenalty(playerKey: playerKey)
                let visiblePair = visiblePenalty(playerKey: playerKey)
                if physicalPair.player == visiblePair.player,
                   physicalPair.clock == visiblePair.clock {
                    pendingVisual.remove(key)
                    pendingVisual.remove(playerKey)
                }
            default:
                break
            }
        }
    }

    private func visiblePenalty(playerKey: OCRRegionKey) -> (player: Int?, clock: String?) {
        switch playerKey {
        case .homePenalty1Player: return (visible.homePenalty1Player, visible.homePenalty1Clock)
        case .homePenalty2Player: return (visible.homePenalty2Player, visible.homePenalty2Clock)
        case .awayPenalty1Player: return (visible.awayPenalty1Player, visible.awayPenalty1Clock)
        case .awayPenalty2Player: return (visible.awayPenalty2Player, visible.awayPenalty2Clock)
        default: return (nil, nil)
        }
    }

    private func observation(for unit: OCRWorkScheduler.WorkUnit) -> (values: [OCRRegionKey: String], blanks: Set<OCRRegionKey>) {
        switch unit {
        case .clock:
            return ([.clock: physical.clock], [])
        case .staticField(.homeScore):
            return ([.homeScore: String(physical.homeScore)], [])
        case .staticField(.awayScore):
            return ([.awayScore: String(physical.awayScore)], [])
        case .staticField(.period):
            return ([.period: String(physical.period)], [])
        case .staticField(let key):
            return ([:], [key])
        case .penaltyPlayer(let playerKey):
            let pair = physicalPenalty(playerKey: playerKey)
            if let player = pair.player {
                return ([playerKey: String(player)], [])
            }
            return ([:], [playerKey])
        case .penaltyPair(let playerKey, let timeKey):
            let pair = physicalPenalty(playerKey: playerKey)
            guard let player = pair.player else {
                // A blank player clears the slot. The timer has no independent
                // blank/value publication when the player does not exist.
                return ([:], [playerKey])
            }
            guard let clock = pair.clock else {
                return ([playerKey: String(player)], [])
            }
            let parts = clock.split(separator: ":")
            let structurallyValid = parts.count == 2
                && Int(parts[0]) != nil
                && Int(parts[1]).map { (0...59).contains($0) } == true
            guard structurallyValid else {
                // Preserve the valid player observation, but malformed timer
                // evidence cannot complete or sustain a published penalty.
                return ([playerKey: String(player)], [])
            }
            return ([playerKey: String(player), timeKey: clock], [])
        }
    }

    private func apply(observation: [OCRRegionKey: String], blanks: Set<OCRRegionKey>, to state: inout ScoreboardState) {
        for (key, value) in observation {
            switch key {
            case .clock: state.clock = value
            case .homeScore: state.homeScore = Int(value)
            case .awayScore: state.awayScore = Int(value)
            case .period:
                state.period = Int(value)
                state.periodLabel = value
            case .homePenalty1Player: state.homePenalty1Player = Int(value)
            case .homePenalty1Time: state.homePenalty1Clock = value
            case .homePenalty2Player: state.homePenalty2Player = Int(value)
            case .homePenalty2Time: state.homePenalty2Clock = value
            case .awayPenalty1Player: state.awayPenalty1Player = Int(value)
            case .awayPenalty1Time: state.awayPenalty1Clock = value
            case .awayPenalty2Player: state.awayPenalty2Player = Int(value)
            case .awayPenalty2Time: state.awayPenalty2Clock = value
            case .homeShots, .awayShots: break
            }
        }
        for key in blanks {
            switch key {
            case .homePenalty1Player: state.homePenalty1Player = nil
            case .homePenalty1Time: state.homePenalty1Clock = nil
            case .homePenalty2Player: state.homePenalty2Player = nil
            case .homePenalty2Time: state.homePenalty2Clock = nil
            case .awayPenalty1Player: state.awayPenalty1Player = nil
            case .awayPenalty1Time: state.awayPenalty1Clock = nil
            case .awayPenalty2Player: state.awayPenalty2Player = nil
            case .awayPenalty2Time: state.awayPenalty2Clock = nil
            default: break
            }
        }
    }

    private func penaltyKeyPair(_ slot: RinkLensMatchPenaltySlot) -> (player: OCRRegionKey, time: OCRRegionKey) {
        switch slot {
        case .home1: return (.homePenalty1Player, .homePenalty1Time)
        case .home2: return (.homePenalty2Player, .homePenalty2Time)
        case .away1: return (.awayPenalty1Player, .awayPenalty1Time)
        case .away2: return (.awayPenalty2Player, .awayPenalty2Time)
        }
    }

    private func penaltyKeys(_ slot: RinkLensMatchPenaltySlot) -> Set<OCRRegionKey> {
        switch slot {
        case .home1: return [.homePenalty1Player, .homePenalty1Time]
        case .home2: return [.homePenalty2Player, .homePenalty2Time]
        case .away1: return [.awayPenalty1Player, .awayPenalty1Time]
        case .away2: return [.awayPenalty2Player, .awayPenalty2Time]
        }
    }

    private func activePhysicalPenaltyKeys() -> Set<OCRRegionKey> {
        var keys = Set<OCRRegionKey>()
        if physical.home1Player != nil || physical.home1Clock != nil { keys.formUnion(penaltyKeys(.home1)) }
        if physical.home2Player != nil || physical.home2Clock != nil { keys.formUnion(penaltyKeys(.home2)) }
        if physical.away1Player != nil || physical.away1Clock != nil { keys.formUnion(penaltyKeys(.away1)) }
        if physical.away2Player != nil || physical.away2Clock != nil { keys.formUnion(penaltyKeys(.away2)) }
        return keys
    }

    private func setPhysicalPenalty(slot: RinkLensMatchPenaltySlot, player: Int?, clock: String?) {
        switch slot {
        case .home1: physical.home1Player = player; physical.home1Clock = clock
        case .home2: physical.home2Player = player; physical.home2Clock = clock
        case .away1: physical.away1Player = player; physical.away1Clock = clock
        case .away2: physical.away2Player = player; physical.away2Clock = clock
        }
    }

    private func physicalPenalty(playerKey: OCRRegionKey) -> (player: Int?, clock: String?) {
        switch playerKey {
        case .homePenalty1Player: return (physical.home1Player, physical.home1Clock)
        case .homePenalty2Player: return (physical.home2Player, physical.home2Clock)
        case .awayPenalty1Player: return (physical.away1Player, physical.away1Clock)
        case .awayPenalty2Player: return (physical.away2Player, physical.away2Clock)
        default: return (nil, nil)
        }
    }

    private func stateSummary(_ state: ScoreboardState) -> String {
        let penaltyCount = StrengthStateCalculator.activePenaltyClocks(from: state).filter(\.isActive).count
        return "clock=\(state.clock ?? "--") period=\(state.period ?? 0) score=\(state.homeScore ?? -1)-\(state.awayScore ?? -1) activePenalties=\(penaltyCount)"
    }
}
#endif
