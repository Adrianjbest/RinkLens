// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import CoreGraphics
import UIKit
import Foundation

nonisolated struct PenaltyOCRCandidate: Equatable, Sendable {
    let value: String
    let confidence: Float
}

nonisolated enum PenaltyOCRRosterHintSource: Equatable, Sendable {
    case directOCR
    case homeRosterHint
    case unresolved
}

nonisolated struct PenaltyOCRRosterResolution: Equatable, Sendable {
    let value: String?
    let confidence: Float
    let source: PenaltyOCRRosterHintSource
}

/// A roster is bounded reference evidence, never recognition truth. A direct
/// parser winner always wins. Only a rejected Home result with exactly one
/// roster-matching mask candidate may be forwarded to normal multi-read
/// confirmation; Away results and ambiguous roster matches remain unresolved.
nonisolated enum PenaltyOCRRosterHint {
    static func resolve(
        directValue: String?,
        directConfidence: Float = 1,
        candidates: [PenaltyOCRCandidate],
        homeRosterNumbers: Set<Int>,
        isHome: Bool
    ) -> PenaltyOCRRosterResolution {
        if let directValue {
            return .init(value: directValue, confidence: directConfidence, source: .directOCR)
        }
        guard isHome, !homeRosterNumbers.isEmpty else {
            return .init(value: nil, confidence: 0, source: .unresolved)
        }

        var bestByNumber: [Int: PenaltyOCRCandidate] = [:]
        for candidate in candidates {
            guard let number = Int(candidate.value), (1...99).contains(number) else { continue }
            if candidate.confidence > (bestByNumber[number]?.confidence ?? 0) {
                bestByNumber[number] = candidate
            }
        }
        let matches = bestByNumber
            .filter { homeRosterNumbers.contains($0.key) }
            .map(\.value)
        guard matches.count == 1, let match = matches.first else {
            return .init(value: nil, confidence: 0, source: .unresolved)
        }
        return .init(
            value: match.value,
            confidence: min(match.confidence, 0.84),
            source: .homeRosterHint
        )
    }
}

/// UX16c6/UX16d15e: isolated lightweight OCR parser kept outside the main scoreboard view-model
/// so Swift Playgrounds/iPad has less work type-checking the large 180 file.
nonisolated enum RinkLensLightweightOCRParser {
    struct ParsedValue {
        let value: String
        let rawText: String
        let confidence: Float
        let diagnostic: String
    }

    private struct DigitDecode {
        let digit: Int
        let confidence: Double
        let fractions: [Double]
    }

    /// Compatibility entry point retained only for legacy diagnostics that still
    /// provide saved character slots. Live and Test OCR use `parseAgreement`, which
    /// discovers visual tokens dynamically inside the saved field zone and does not
    /// require saved character cells or a fixed colon slot.
    static func parse(
        from image: CGImage,
        key: OCRRegionKey,
        characterSlots: [OCRRegion]
    ) -> ParsedValue? {
        let profile = OCRZoneColourProfile.defaultProfile(for: key)
        guard let raster = rasterise(image), !characterSlots.isEmpty else { return nil }
        let slots = characterSlots.map { slotRect($0, width: raster.width, height: raster.height) }
        let masks = agreementMasks(raster: raster, key: key, colourProfile: profile, slots: slots)
        for mask in masks {
            if let value = decode(
                mask: mask.mask,
                width: raster.width,
                height: raster.height,
                key: key,
                slots: slots,
                variant: mask.label,
                deadlineUptimeNanoseconds: nil
            ) {
                return value
            }
        }
        return nil
    }

    /// UX16d5 authoritative live/Test decoder.
    ///
    /// The saved field zone remains authoritative, but character locations are
    /// discovered dynamically inside that crop. Each visual token is recognised
    /// independently as a digit, colon or unknown. Field meaning is applied only
    /// after the left-to-right raw token sequence has been assembled.
    struct ParseAttempt {
        let value: String?
        let rawText: String
        let confidence: Float
        let diagnostic: String
        let candidates: [PenaltyOCRCandidate]
    }

    static func parseAgreement(
        from image: CGImage,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile,
        deadlineUptimeNanoseconds: UInt64?,
        sourceFrameID: Int? = nil,
        captureGeneration: Int = 0
    ) -> ParsedValue? {
        let attempt = parseDynamicTokens(
            from: image,
            key: key,
            colourProfile: colourProfile,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            sourceFrameID: sourceFrameID,
            captureGeneration: captureGeneration
        )
        guard let value = attempt.value else { return nil }
        return ParsedValue(
            value: value,
            rawText: attempt.rawText,
            confidence: attempt.confidence,
            diagnostic: attempt.diagnostic
        )
    }

    static func parseDynamicTokens(
        from image: CGImage,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile,
        deadlineUptimeNanoseconds: UInt64?,
        sourceFrameID: Int? = nil,
        captureGeneration: Int = 0,
        scoreReacquisition: Bool = false,
        reserveTimerRecovery: Bool = false
    ) -> ParseAttempt {
        let started = DispatchTime.now().uptimeNanoseconds
        guard beforeDeadline(deadlineUptimeNanoseconds), let raster = rasterise(image) else {
            let diagnostic = "dynamic-token raster unavailable or deadline expired"
            RinkLensOCREvidenceJournal.shared.recordTokenAttempt(
                .init(
                    field: key.rawValue,
                    outcome: "rejected",
                    rawText: "",
                    acceptedValue: nil,
                    confidence: 0,
                    sourceFrameID: sourceFrameID,
                    captureGeneration: captureGeneration,
                    cropWidth: image.width,
                    cropHeight: image.height,
                    colourProfile: colourProfile.summaryText,
                    resolvedPipeline: colourProfile.resolvedPipeline(for: key).title,
                    scoreReacquisition: scoreReacquisition,
                    timerRecoveryReserved: reserveTimerRecovery,
                    elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                    masksProcessed: "none",
                    masksNotProcessedReason: "raster unavailable or deadline expired before mask construction",
                    maskSummary: "none",
                    tokenEvidence: "none",
                    decisionDetail: "no parser result",
                    fullDiagnostic: diagnostic
                )
            )
            return ParseAttempt(value: nil, rawText: "", confidence: 0, diagnostic: diagnostic, candidates: [])
        }

        let fullField = CGRect(x: 0, y: 0, width: CGFloat(raster.width), height: CGFloat(raster.height))
        let colourLabel: String
        let contrastLabel: String
        var colour: [Bool]
        if scoreReacquisition && isScoreKey(key) {
            // UX16d11: only an empty score crop enters this second, bounded pass.
            colour = relaxedScoreColourMask(raster: raster, key: key, colourProfile: colourProfile)
            colourLabel = "reacquire-colour"
            contrastLabel = "reacquire-neutral"
        } else {
            colour = colourMask(raster: raster, key: key, colourProfile: colourProfile)
            colourLabel = "colour"
            contrastLabel = "contrast"
        }

        // Build 523: contrast used to be generated and sanitised before colour
        // recognition had even started. That preprocessing consumed the same
        // field deadline and could make a timer exceed its 660ms orchestration
        // budget even when colour was nearly complete. Build colour first; create
        // contrast lazily only when colour evidence is incomplete and enough hard
        // deadline remains for a useful verification pass.
        sanitiseMask(&colour, width: raster.width, height: raster.height)

        var results: [DynamicMaskResult] = []
        var strongColourShortCircuit = false
        var contrastSkipReason: String?

        guard beforeDeadline(deadlineUptimeNanoseconds) else {
            contrastSkipReason = "deadline expired after colour-mask construction"
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let diagnostic = "dynamic-token rejected elapsedMs=\(String(format: "%.2f", elapsedMs)) deadline expired before token discovery"
            RinkLensOCREvidenceJournal.shared.recordTokenAttempt(
                .init(
                    field: key.rawValue,
                    outcome: "rejected",
                    rawText: "",
                    acceptedValue: nil,
                    confidence: 0,
                    sourceFrameID: sourceFrameID,
                    captureGeneration: captureGeneration,
                    cropWidth: raster.width,
                    cropHeight: raster.height,
                    colourProfile: colourProfile.summaryText,
                    resolvedPipeline: colourProfile.resolvedPipeline(for: key).title,
                    scoreReacquisition: scoreReacquisition,
                    timerRecoveryReserved: reserveTimerRecovery,
                    elapsedMilliseconds: elapsedMs,
                    masksProcessed: "none",
                    masksNotProcessedReason: contrastSkipReason ?? "deadline expired",
                    maskSummary: "none",
                    tokenEvidence: "none",
                    decisionDetail: "hard field deadline expired before decoding",
                    fullDiagnostic: diagnostic
                )
            )
            return ParseAttempt(value: nil, rawText: "", confidence: 0, diagnostic: diagnostic, candidates: [])
        }

        let colourResult = decodeDynamicMask(
            NamedMask(label: colourLabel, mask: colour),
            key: key,
            width: raster.width,
            height: raster.height,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            sourceFrameID: sourceFrameID,
            captureGeneration: captureGeneration,
            reserveTimerRecovery: reserveTimerRecovery
        )
        results.append(colourResult)

        if !scoreReacquisition,
           colourLabel == "colour",
           interpretRawSequence(colourResult.rawText, key: key) != nil,
           !colourResult.rawText.contains("?"),
           colourResult.confidence >= strongSingleMaskConfidence(for: key) {
            strongColourShortCircuit = true
            contrastSkipReason = "remaining contrast mask deliberately skipped after complete strong colour evidence"
        } else if beforeDeadline(deadlineUptimeNanoseconds) {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadlineUptimeNanoseconds.map { $0 > now ? $0 - now : 0 } ?? UInt64.max
            let isPenaltyTimer = isTimerKey(key) && key != .clock
            let minimumUsefulContrastBudget: UInt64 = isPenaltyTimer
                ? 120_000_000
                : (isTimerKey(key) ? 180_000_000 : 80_000_000)

            if remaining < minimumUsefulContrastBudget {
                contrastSkipReason = "hard field deadline retained; insufficient budget for useful contrast verification"
            } else {
                var contrast: [Bool]
                if scoreReacquisition && isScoreKey(key) {
                    contrast = neutralScoreContrastMask(raster: raster, colourProfile: colourProfile)
                } else {
                    contrast = adaptiveContrastMask(raster: raster, colourProfile: colourProfile, slots: [fullField])
                }
                sanitiseMask(&contrast, width: raster.width, height: raster.height)

                if beforeDeadline(deadlineUptimeNanoseconds) {
                    let afterMaskNow = DispatchTime.now().uptimeNanoseconds
                    let remainingAfterMask = deadlineUptimeNanoseconds.map { $0 > afterMaskNow ? $0 - afterMaskNow : 0 } ?? UInt64.max
                    let contrastSlice: UInt64
                    if isPenaltyTimer {
                        contrastSlice = min(220_000_000, remainingAfterMask)
                    } else if isTimerKey(key) {
                        contrastSlice = min(180_000_000, remainingAfterMask)
                    } else {
                        contrastSlice = remainingAfterMask
                    }
                    let contrastDeadline = deadlineUptimeNanoseconds.map { min($0, afterMaskNow &+ contrastSlice) }
                    let contrastResult = decodeDynamicMask(
                        NamedMask(label: contrastLabel, mask: contrast),
                        key: key,
                        width: raster.width,
                        height: raster.height,
                        deadlineUptimeNanoseconds: contrastDeadline,
                        sourceFrameID: sourceFrameID,
                        captureGeneration: captureGeneration,
                        reserveTimerRecovery: false
                    )
                    results.append(contrastResult)
                } else {
                    contrastSkipReason = "hard field deadline expired during lazy contrast-mask construction"
                }
            }
        } else {
            contrastSkipReason = "hard field deadline expired after colour decoding"
        }

        let evaluated = results.map { result in
            (result: result, value: interpretRawSequence(result.rawText, key: key))
        }
        let valid = evaluated.compactMap { entry -> (DynamicMaskResult, String)? in
            guard let value = entry.value else { return nil }
            return (entry.result, value)
        }
        var bestCandidateByValue: [String: PenaltyOCRCandidate] = [:]
        for entry in valid {
            let candidate = PenaltyOCRCandidate(value: entry.1, confidence: Float(entry.0.confidence))
            if candidate.confidence > (bestCandidateByValue[entry.1]?.confidence ?? 0) {
                bestCandidateByValue[entry.1] = candidate
            }
        }
        let candidateEvidence = bestCandidateByValue.values.sorted {
            if $0.confidence == $1.confidence { return $0.value < $1.value }
            return $0.confidence > $1.confidence
        }

        let fusedTimer = fusedTimerMaskResult(results, key: key)
        let strongConflictingScoreMasks: Bool = {
            guard isScoreKey(key), valid.count >= 2 else { return false }
            let ranked = valid.sorted { $0.0.confidence > $1.0.confidence }
            guard ranked[0].1 != ranked[1].1 else { return false }
            // Build 533: the Build 532 ground-truth run repeatedly presented a
            // physical score 0 as colour=0 / contrast=8. Choosing the higher
            // confidence mask established a false score baseline. When both score
            // masks produce credible but different digits, reject the frame and
            // let the next scheduled verification decide; a single strong colour
            // short-circuit remains unchanged.
            return ranked[1].0.confidence >= 0.62
        }()

        let selected: (DynamicMaskResult, String)?
        if let fusedTimer {
            selected = fusedTimer
        } else if valid.count >= 2, valid[0].1 == valid[1].1 {
            let combined = DynamicMaskResult(
                label: "colour+contrast",
                rawText: valid[0].0.rawText,
                confidence: min(0.99, (valid[0].0.confidence + valid[1].0.confidence) * 0.5 + 0.08),
                tokenEvidence: valid[0].0.tokenEvidence,
                tokenDiagnostics: valid[0].0.tokenDiagnostics + valid[1].0.tokenDiagnostics,
                summary: "sources agree"
            )
            selected = (combined, valid[0].1)
        } else if strongConflictingScoreMasks {
            selected = nil
        } else if let best = valid.max(by: { $0.0.confidence < $1.0.confidence }),
                  best.0.confidence >= (scoreReacquisition ? 0.78 : 0.56) {
            let runnerUp = valid.filter { $0.0.label != best.0.label }.map { $0.0.confidence }.max() ?? 0
            selected = runnerUp > 0 && best.0.confidence - runnerUp < 0.10 ? nil : best
        } else {
            selected = nil
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let maskSummary = results.map {
            "\($0.label) raw=\($0.rawText.isEmpty ? "<blank>" : $0.rawText) conf=\(String(format: "%.2f", $0.confidence)) \($0.summary)"
        }.joined(separator: " | ")
        let tokenDetails = results.flatMap(\.tokenDiagnostics).joined(separator: " ; ")
        let singleSourceScoreReacquisition = scoreReacquisition
            && valid.count == 1
            && selected != nil
        let shortCircuitDetail: String
        if strongColourShortCircuit {
            shortCircuitDetail = " shortCircuit=strong-colour"
        } else if singleSourceScoreReacquisition {
            shortCircuitDetail = " shortCircuit=score-reacquisition-strong"
        } else {
            shortCircuitDetail = ""
        }
        let modeDetail: String
        if strongConflictingScoreMasks {
            modeDetail = " conflict=credible-score-mask-disagreement"
        } else {
            modeDetail = scoreReacquisition ? " mode=score-reacquisition" : ""
        }

        let masksProcessed = results.map(\.label).joined(separator: ",")
        let masksNotProcessedReason: String
        if let contrastSkipReason {
            masksNotProcessedReason = contrastSkipReason
        } else if strongColourShortCircuit {
            masksNotProcessedReason = "remaining contrast mask deliberately skipped after strong colour evidence"
        } else {
            masksNotProcessedReason = "none"
        }

        guard let selected else {
            let rawText = results.max(by: { $0.confidence < $1.confidence })?.rawText ?? ""
            let confidence = Float(results.map(\.confidence).max() ?? 0)
            let diagnostic = "dynamic-token rejected elapsedMs=\(String(format: "%.2f", elapsedMs)) \(maskSummary)\(shortCircuitDetail)\(modeDetail) tokens=[\(tokenDetails)]"
            RinkLensOCREvidenceJournal.shared.recordTokenAttempt(
                .init(
                    field: key.rawValue,
                    outcome: "rejected",
                    rawText: rawText,
                    acceptedValue: nil,
                    confidence: confidence,
                    sourceFrameID: sourceFrameID,
                    captureGeneration: captureGeneration,
                    cropWidth: raster.width,
                    cropHeight: raster.height,
                    colourProfile: colourProfile.summaryText,
                    resolvedPipeline: colourProfile.resolvedPipeline(for: key).title,
                    scoreReacquisition: scoreReacquisition,
                    timerRecoveryReserved: reserveTimerRecovery,
                    elapsedMilliseconds: elapsedMs,
                    masksProcessed: masksProcessed,
                    masksNotProcessedReason: masksNotProcessedReason,
                    maskSummary: maskSummary,
                    tokenEvidence: tokenDetails,
                    decisionDetail: "no valid agreed/high-margin field value",
                    fullDiagnostic: diagnostic
                )
            )
            return ParseAttempt(value: nil, rawText: rawText, confidence: confidence, diagnostic: diagnostic, candidates: candidateEvidence)
        }

        let diagnostic = "dynamic-token accepted source=\(selected.0.label) elapsedMs=\(String(format: "%.2f", elapsedMs)) \(maskSummary)\(shortCircuitDetail)\(modeDetail) tokens=[\(tokenDetails)]"
        RinkLensOCREvidenceJournal.shared.recordTokenAttempt(
            .init(
                field: key.rawValue,
                outcome: "accepted",
                rawText: selected.0.rawText,
                acceptedValue: selected.1,
                confidence: Float(selected.0.confidence),
                sourceFrameID: sourceFrameID,
                captureGeneration: captureGeneration,
                cropWidth: raster.width,
                cropHeight: raster.height,
                colourProfile: colourProfile.summaryText,
                resolvedPipeline: colourProfile.resolvedPipeline(for: key).title,
                scoreReacquisition: scoreReacquisition,
                timerRecoveryReserved: reserveTimerRecovery,
                elapsedMilliseconds: elapsedMs,
                masksProcessed: masksProcessed,
                masksNotProcessedReason: masksNotProcessedReason,
                maskSummary: maskSummary,
                tokenEvidence: tokenDetails,
                decisionDetail: "selected source=\(selected.0.label) interpreted=\(selected.1)",
                fullDiagnostic: diagnostic
            )
        )
        return ParseAttempt(value: selected.1, rawText: selected.0.rawText, confidence: Float(selected.0.confidence), diagnostic: diagnostic, candidates: candidateEvidence)
    }

    /// Build 524: colour and contrast are independent observations of the
    /// same timer slots. A complete field-level winner is no longer required when
    /// the masks contain complementary evidence. Fusion is deliberately strict:
    /// token geometry/count must align, unknowns may be filled only by credible
    /// evidence, and the only conflicting-digit repair is the observed 0/8 case
    /// where segment topology supports 0 and hole-only topology supports 8.
    private static func fusedTimerMaskResult(
        _ results: [DynamicMaskResult],
        key: OCRRegionKey
    ) -> (DynamicMaskResult, String)? {
        guard isTimerKey(key), results.count >= 2 else { return nil }
        let first = results[0]
        let second = results[1]
        guard !first.tokenEvidence.isEmpty,
              first.tokenEvidence.count == second.tokenEvidence.count,
              first.tokenEvidence.count <= 5 else { return nil }

        var characters: [String] = []
        var confidences: [Double] = []
        var fusedEvidence: [DynamicTokenEvidence] = []
        var fusionDiagnostics: [String] = []

        for (left, right) in zip(first.tokenEvidence, second.tokenEvidence) {
            guard left.index == right.index else { return nil }
            let chosen: DynamicTokenEvidence
            let reason: String

            if left.character == right.character, left.character != "?" {
                let confidence = min(0.99, max(left.confidence, right.confidence) + 0.04)
                chosen = DynamicTokenEvidence(
                    index: left.index,
                    character: left.character,
                    confidence: confidence,
                    method: "slot-agreement",
                    alternatives: Array(Set(left.alternatives + right.alternatives)).sorted(),
                    rect: left.rect.union(right.rect)
                )
                reason = "agree"
            } else if left.character == "?", right.character != "?", right.confidence >= 0.60 {
                chosen = right
                reason = "filled-from-\(second.label)"
            } else if right.character == "?", left.character != "?", left.confidence >= 0.60 {
                chosen = left
                reason = "filled-from-\(first.label)"
            } else if let zero = [left, right].first(where: { $0.character == "0" }),
                      let eight = [left, right].first(where: { $0.character == "8" }),
                      zero.confidence >= 0.64,
                      zero.method.contains("segment"),
                      eight.method.contains("hole-topology-two") {
                chosen = DynamicTokenEvidence(
                    index: zero.index,
                    character: "0",
                    confidence: min(0.92, max(0.72, zero.confidence + 0.04)),
                    method: "slot-fusion-middle-segment-zero",
                    alternatives: [8],
                    rect: zero.rect.union(eight.rect)
                )
                reason = "0-over-hole-only-8"
            } else {
                return nil
            }

            characters.append(chosen.character)
            confidences.append(chosen.confidence)
            fusedEvidence.append(chosen)
            fusionDiagnostics.append(
                "fusion token=\(chosen.index) left=\(left.character)/\(String(format: "%.2f", left.confidence))/\(left.method) right=\(right.character)/\(String(format: "%.2f", right.confidence))/\(right.method) selected=\(chosen.character) reason=\(reason)"
            )
        }

        let raw = characters.joined()
        guard let value = interpretRawSequence(raw, key: key) else { return nil }
        let result = DynamicMaskResult(
            label: "colour+contrast-slot-fusion",
            rawText: raw,
            confidence: min(0.97, confidences.min() ?? 0),
            tokenEvidence: fusedEvidence,
            tokenDiagnostics: first.tokenDiagnostics + second.tokenDiagnostics + fusionDiagnostics,
            summary: "per-position timer fusion"
        )
        return (result, value)
    }

    private static func strongSingleMaskConfidence(for key: OCRRegionKey) -> Double {
        switch key {
        case .clock, .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            // Build 522: a structurally complete timer at this confidence was
            // already eligible as provisional single-source evidence. Stop
            // before a noisy second mask can consume the confirmation cadence;
            // the trusted-clock and paired-penalty policies still require a
            // second bounded observation before public state changes.
            return 0.62
        case .period, .homeScore, .awayScore,
             .homePenalty1Player, .homePenalty2Player,
             .awayPenalty1Player, .awayPenalty2Player:
            return 0.92
        default:
            return 0.94
        }
    }

    private struct DynamicComponent {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let area: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var centreX: Double { Double(minX + maxX) * 0.5 }
        var centreY: Double { Double(minY + maxY) * 0.5 }
        var rect: CGRect { CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(width), height: CGFloat(height)) }
    }

    private struct DynamicTokenCandidate {
        let rect: CGRect
        let components: [DynamicComponent]
    }

    private struct DynamicTokenEvidence {
        let index: Int
        let character: String
        let confidence: Double
        let method: String
        let alternatives: [Int]
        let rect: CGRect
    }

    private struct DynamicMaskResult {
        let label: String
        let rawText: String
        let confidence: Double
        let tokenEvidence: [DynamicTokenEvidence]
        let tokenDiagnostics: [String]
        let summary: String
    }

    private struct DynamicGlyphDecode {
        let digit: Int
        let confidence: Double
        let method: String
        let alternatives: [Int]

        init(digit: Int, confidence: Double, method: String, alternatives: [Int] = []) {
            self.digit = digit
            self.confidence = confidence
            self.method = method
            self.alternatives = Array(Set(alternatives.filter { $0 != digit })).sorted()
        }
    }

    private struct DynamicGlyphRecoveryAttempt {
        let decode: DynamicGlyphDecode?
        let summary: String
    }

    private static func decodeDynamicMask(
        _ namedMask: NamedMask,
        key: OCRRegionKey,
        width: Int,
        height: Int,
        deadlineUptimeNanoseconds: UInt64?,
        sourceFrameID: Int?,
        captureGeneration: Int,
        reserveTimerRecovery: Bool
    ) -> DynamicMaskResult {
        let discovery = discoverDynamicTokens(
            mask: namedMask.mask,
            key: key,
            width: width,
            height: height,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        guard !discovery.tokens.isEmpty else {
            let frameText = sourceFrameID.map { String($0) } ?? "unknown"
            return DynamicMaskResult(
                label: namedMask.label,
                rawText: "",
                confidence: 0,
                tokenEvidence: [],
                tokenDiagnostics: [
                    "source=\(namedMask.label) token=none char=<blank> conf=0.00 bounds=none durationMs=0.00 frame=#\(frameText) generation=\(captureGeneration)"
                ],
                summary: discovery.summary
            )
        }

        var characters: [String] = []
        var confidences: [Double] = []
        var diagnostics: [String] = []
        let frameText = sourceFrameID.map { String($0) } ?? "unknown"
        let timerKey = isTimerKey(key)

        // UX16d15g Build 522: three-stage timer decoding.
        //  1. Every slot receives bounded topology/hole/solid-one evidence.
        //  2. Generic template work is spent only on unresolved/weak slots,
        //     rightmost-first, while preserving the final recovery tail.
        //  3. Morphology recovery is last and also rightmost-first.
        // This removes first-come-first-served starvation without weakening the
        // existing field-level validation or multi-frame publication policy.
        let genericClassificationDeadline: UInt64?
        if reserveTimerRecovery,
           timerKey,
           let deadlineUptimeNanoseconds,
           deadlineUptimeNanoseconds > 80_000_000 {
            genericClassificationDeadline = deadlineUptimeNanoseconds - 80_000_000
        } else {
            genericClassificationDeadline = deadlineUptimeNanoseconds
        }

        struct TokenWorkingResult {
            let index: Int
            let token: DynamicTokenCandidate
            var character: String
            var confidence: Double
            var recognitionMethod: String
            var alternativeDigits: [Int]
            var durationMs: Double
            var pendingGeneric: Bool
            var pendingRecovery: Bool
        }

        var results: [TokenWorkingResult] = []
        results.reserveCapacity(min(discovery.tokens.count, 8))

        // Stage 1: no generic reference scan and no morphology. Timer work is
        // fixed by the maximum eight discovered tokens, so all slots receive a
        // primary opportunity even when earlier preprocessing used most of the
        // shared field budget.
        for (index, token) in discovery.tokens.prefix(8).enumerated() {
            let tokenStarted = DispatchTime.now().uptimeNanoseconds

            if timerKey, let colonConfidence = dynamicColonConfidence(
                mask: namedMask.mask,
                width: width,
                height: height,
                token: token,
                dominantHeight: discovery.dominantHeight
            ) {
                results.append(TokenWorkingResult(
                    index: index,
                    token: token,
                    character: ":",
                    confidence: colonConfidence,
                    recognitionMethod: token.components.count >= 2 ? "stage1-separator-pair" : "stage1-separator-dot",
                    alternativeDigits: [],
                    durationMs: Double(DispatchTime.now().uptimeNanoseconds - tokenStarted) / 1_000_000,
                    pendingGeneric: false,
                    pendingRecovery: false
                ))
                continue
            }

            if timerKey {
                let fast = decodeDynamicGlyphFast(
                    mask: namedMask.mask,
                    width: width,
                    height: height,
                    rect: token.rect,
                    dominantHeight: discovery.dominantHeight,
                    key: key
                )
                let durationMs = Double(DispatchTime.now().uptimeNanoseconds - tokenStarted) / 1_000_000
                if let fast {
                    let needsGeneric = fast.method == "segment-topology-tolerant" || fast.confidence < 0.72
                    results.append(TokenWorkingResult(
                        index: index,
                        token: token,
                        character: String(fast.digit),
                        confidence: fast.confidence,
                        recognitionMethod: "stage1-\(fast.method)",
                        alternativeDigits: fast.alternatives,
                        durationMs: durationMs,
                        pendingGeneric: needsGeneric,
                        pendingRecovery: false
                    ))
                } else {
                    results.append(TokenWorkingResult(
                        index: index,
                        token: token,
                        character: "?",
                        confidence: 0,
                        recognitionMethod: "stage1-unresolved",
                        alternativeDigits: [],
                        durationMs: durationMs,
                        pendingGeneric: true,
                        pendingRecovery: true
                    ))
                }
                continue
            }

            guard beforeDeadline(deadlineUptimeNanoseconds) else {
                results.append(TokenWorkingResult(
                    index: index,
                    token: token,
                    character: "?",
                    confidence: 0,
                    recognitionMethod: "unclassified-deadline",
                    alternativeDigits: [],
                    durationMs: Double(DispatchTime.now().uptimeNanoseconds - tokenStarted) / 1_000_000,
                    pendingGeneric: false,
                    pendingRecovery: false
                ))
                continue
            }

            let digit = decodeDynamicGlyph(
                mask: namedMask.mask,
                width: width,
                height: height,
                rect: token.rect,
                dominantHeight: discovery.dominantHeight,
                key: key,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
            results.append(TokenWorkingResult(
                index: index,
                token: token,
                character: digit.map { String($0.digit) } ?? "?",
                confidence: digit?.confidence ?? 0,
                recognitionMethod: digit?.method ?? "unclassified",
                alternativeDigits: digit?.alternatives ?? [],
                durationMs: Double(DispatchTime.now().uptimeNanoseconds - tokenStarted) / 1_000_000,
                pendingGeneric: false,
                pendingRecovery: false
            ))
        }

        // Stage 2: expensive generic/reference reconciliation only for slots
        // that Stage 1 could not settle strongly. Seconds are prioritised, but
        // an existing Stage 1 result is retained if the generic stage expires.
        if timerKey {
            let genericIndices = results.indices
                .filter { results[$0].pendingGeneric }
                .sorted(by: >)
            for i in genericIndices {
                guard beforeDeadline(genericClassificationDeadline) else {
                    if results[i].character == "?" {
                        results[i].recognitionMethod += "-generic-deadline"
                    }
                    continue
                }
                let genericStarted = DispatchTime.now().uptimeNanoseconds
                if let refined = decodeDynamicGlyph(
                    mask: namedMask.mask,
                    width: width,
                    height: height,
                    rect: results[i].token.rect,
                    dominantHeight: discovery.dominantHeight,
                    key: key,
                    deadlineUptimeNanoseconds: genericClassificationDeadline
                ) {
                    results[i].character = String(refined.digit)
                    results[i].confidence = refined.confidence
                    results[i].recognitionMethod = "stage2-\(refined.method)"
                    results[i].alternativeDigits = refined.alternatives
                    results[i].pendingRecovery = false
                } else if results[i].character == "?" {
                    results[i].recognitionMethod = "stage2-unresolved"
                    results[i].pendingRecovery = true
                }
                results[i].pendingGeneric = false
                results[i].durationMs += Double(DispatchTime.now().uptimeNanoseconds - genericStarted) / 1_000_000
            }
        }

        // Stage 3: the reserved morphology tail is available only to genuinely
        // unresolved timer digits. A weak-but-valid Stage 1 digit is never erased
        // merely because Stage 2 had no time to revisit it.
        if timerKey {
            let recoveryIndices = results.indices
                .filter { results[$0].character == "?" && results[$0].pendingRecovery }
                .sorted(by: >)
            for i in recoveryIndices {
                guard beforeDeadline(deadlineUptimeNanoseconds) else {
                    results[i].recognitionMethod += "-recovery-deadline"
                    continue
                }
                let recoveryStarted = DispatchTime.now().uptimeNanoseconds
                let recovery = recoverUnknownTimerDigit(
                    mask: namedMask.mask,
                    width: width,
                    height: height,
                    rect: results[i].token.rect,
                    key: key,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
                if let recovered = recovery.decode {
                    results[i].character = String(recovered.digit)
                    results[i].confidence = recovered.confidence
                    results[i].recognitionMethod = "stage3-\(recovered.method)-\(recovery.summary)"
                    results[i].alternativeDigits = recovered.alternatives
                    results[i].pendingRecovery = false
                } else {
                    results[i].recognitionMethod = "stage3-unclassified-\(recovery.summary)"
                }
                results[i].durationMs += Double(DispatchTime.now().uptimeNanoseconds - recoveryStarted) / 1_000_000
            }
        }

        var orderedResults = results.sorted(by: { $0.index < $1.index })

        // UX16d15q Build 534: Build 533 repeatedly accepted an empty player zone
        // as a single `1` from a 2-4 px reflection at the extreme right crop edge
        // (for example x=123...126 in a 129 px crop). The earlier multi-token edge
        // filter intentionally preserved every single token, so this artefact could
        // keep penalty verification permanently urgent. A real right-aligned player
        // digit remains character-height and inside the padded crop; reject only a
        // short, very narrow singleton that actually touches the extreme guard.
        if orderedResults.count == 1, isPlayerKey(key), let only = orderedResults.first {
            let rect = only.token.rect
            let extremeOuterEdge = rect.minX <= 3 || rect.maxX >= CGFloat(width - 3)
            let veryNarrow = Double(rect.width) <= max(4.0, discovery.dominantHeight * 0.22)
            let tooShortForPlayerGlyph = Double(rect.height) <= Double(height) * 0.45
            if extremeOuterEdge && veryNarrow && tooShortForPlayerGlyph {
                diagnostics.append(
                    "source=\(namedMask.label) single-player-edge-artifact-filter removedToken=\(only.index) bounds=\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) field=\(key.rawValue)"
                )
                orderedResults.removeAll()
            }
        }

        // Build 531 ground-truth edge filtering. The live controller log proved
        // that isolated bezel/reflection tokens at the extreme crop edge could
        // turn player 45 into 451 and score 2 into 21. Remove only tokens that are
        // both isolated from the dominant digit cluster and located in the outer
        // crop margin. Genuine one- and two-digit values remain close together;
        // a single visible `1` is never removed because filtering requires another
        // substantial token in the same field.
        if orderedResults.count > 1, isPlayerKey(key) || isScoreKey(key) {
            let originalResults = orderedResults
            orderedResults = orderedResults.filter { candidate in
                let rect = candidate.token.rect
                let otherRects = originalResults
                    .filter { $0.index != candidate.index }
                    .map { $0.token.rect }
                guard !otherRects.isEmpty else { return true }
                let nearestGap = otherRects.map { other -> Double in
                    if rect.maxX < other.minX { return Double(other.minX - rect.maxX) }
                    if other.maxX < rect.minX { return Double(rect.minX - other.maxX) }
                    return 0
                }.min() ?? 0

                if isPlayerKey(key) {
                    let nearOuterEdge = rect.minX <= 5 || rect.maxX >= CGFloat(width - 5)
                    let narrow = Double(rect.width) <= discovery.dominantHeight * 0.22
                    let notFullHeight = Double(rect.height) <= discovery.dominantHeight * 1.15
                    let isolated = nearestGap >= discovery.dominantHeight * 0.65
                    return !(nearOuterEdge && narrow && notFullHeight && isolated)
                }

                let centreX = Double(rect.midX)
                let inOuterMargin = centreX <= Double(width) * 0.14
                    || centreX >= Double(width) * 0.86
                let isolated = nearestGap >= discovery.dominantHeight * 1.25
                return !(inOuterMargin && isolated)
            }
            if orderedResults.isEmpty {
                orderedResults = originalResults
            } else if orderedResults.count != originalResults.count {
                let removed = originalResults
                    .filter { candidate in !orderedResults.contains(where: { $0.index == candidate.index }) }
                    .map { String($0.index) }
                    .joined(separator: ",")
                diagnostics.append("source=\(namedMask.label) edge-artifact-filter removedTokens=[\(removed)] field=\(key.rawValue)")
            }
        }

        for result in orderedResults {
            characters.append(result.character)
            if result.character != "?" { confidences.append(result.confidence) }
            let alternativesText = result.alternativeDigits.isEmpty
                ? "none"
                : result.alternativeDigits.map { String($0) }.joined(separator: ",")
            diagnostics.append(
                String(
                    format: "source=%@ token=%d char=%@ conf=%.2f method=%@ alts=%@ bounds=%.0f,%.0f %.0fx%.0f durationMs=%.2f frame=#%@ generation=%d",
                    namedMask.label,
                    result.index,
                    result.character,
                    result.confidence,
                    result.recognitionMethod,
                    alternativesText,
                    Double(result.token.rect.minX),
                    Double(result.token.rect.minY),
                    Double(result.token.rect.width),
                    Double(result.token.rect.height),
                    result.durationMs,
                    frameText,
                    captureGeneration
                )
            )
        }

        let tokenEvidence = orderedResults.map { result in
            DynamicTokenEvidence(
                index: result.index,
                character: result.character,
                confidence: result.confidence,
                method: result.recognitionMethod,
                alternatives: result.alternativeDigits,
                rect: result.token.rect
            )
        }
        let raw = characters.joined()
        let confidence = characters.contains("?") ? 0 : (confidences.min() ?? 0)
        return DynamicMaskResult(
            label: namedMask.label,
            rawText: raw,
            confidence: confidence,
            tokenEvidence: tokenEvidence,
            tokenDiagnostics: diagnostics,
            summary: "components=\(discovery.componentCount) tokens=\(discovery.tokens.count) dominantHeight=\(String(format: "%.1f", discovery.dominantHeight)) stages=fast+generic+recovery recoveryReserveMs=\(reserveTimerRecovery && timerKey ? 80 : 0)"
        )
    }

    private static func discoverDynamicTokens(
        mask: [Bool],
        key: OCRRegionKey,
        width: Int,
        height: Int,
        deadlineUptimeNanoseconds: UInt64?
    ) -> (tokens: [DynamicTokenCandidate], dominantHeight: Double, componentCount: Int, summary: String) {
        guard width > 4, height > 4, mask.count == width * height else {
            return ([], 0, 0, "invalid mask geometry")
        }
        var visited = [Bool](repeating: false, count: mask.count)
        var components: [DynamicComponent] = []
        components.reserveCapacity(32)
        let neighbours = [(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)]
        var scanned = 0

        for start in mask.indices where mask[start] && !visited[start] {
            scanned += 1
            if (scanned & 31) == 0, !beforeDeadline(deadlineUptimeNanoseconds) {
                return ([], 0, components.count, "component discovery deadline")
            }
            var queue = [start]
            visited[start] = true
            var cursor = 0
            var minX = width, minY = height, maxX = -1, maxY = -1, area = 0
            while cursor < queue.count {
                if (cursor & 2047) == 0, !beforeDeadline(deadlineUptimeNanoseconds) {
                    return ([], 0, components.count, "component traversal deadline")
                }
                let point = queue[cursor]
                cursor += 1
                area += 1
                let x = point % width
                let y = point / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in neighbours {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if mask[next] && !visited[next] {
                        visited[next] = true
                        queue.append(next)
                    }
                }
            }
            guard area >= 3 else { continue }
            let component = DynamicComponent(minX: minX, minY: minY, maxX: maxX, maxY: maxY, area: area)
            let touchesEdge = minX <= 1 || minY <= 1 || maxX >= width - 2 || maxY >= height - 2
            let borderLine = (component.width >= Int(Double(width) * 0.72) && component.height <= Int(Double(height) * 0.20))
                || (component.height >= Int(Double(height) * 0.72) && component.width <= Int(Double(width) * 0.15))
                || (touchesEdge && (component.width >= Int(Double(width) * 0.85) || component.height >= Int(Double(height) * 0.85)))
                || (touchesEdge && component.width <= max(5, Int(Double(width) * 0.06)))
            let centredTallScoreOne = isScoreKey(key)
                && component.height >= max(8, Int(Double(height) * 0.30))
                && component.width <= max(8, Int(Double(component.height) * 0.46))
                && component.centreX >= Double(width) * 0.14
                && component.centreX <= Double(width) * 0.86

            // UX16d15e Build 520: player crops can include a thin bezel/reflection
            // a few pixels inside the padded crop rather than exactly on x=0. It
            // was repeatedly classified as a leading `1`, turning physical player
            // 45 into raw 145. Reject only very narrow, tall components in the
            // outer player-zone margins; genuine one-digit/two-digit glyphs remain
            // centred and substantially wider after normalisation.
            let playerEdgeArtefact = isPlayerKey(key)
                && component.width <= max(5, Int(Double(width) * 0.055))
                && component.height >= max(12, Int(Double(height) * 0.48))
                && (component.centreX <= Double(width) * 0.20
                    || component.centreX >= Double(width) * 0.80)

            if (!borderLine && !playerEdgeArtefact) || centredTallScoreOne {
                components.append(component)
            }
            if components.count >= 64 { break }
        }

        let minimumAnchorHeight = max(8, Int(Double(height) * 0.18))
        let anchors = components.filter {
            $0.height >= minimumAnchorHeight && $0.width < Int(Double(width) * 0.55)
        }.sorted { $0.area > $1.area }
        guard !anchors.isEmpty else {
            return ([], 0, components.count, "no character-height components")
        }
        let anchorSample = Array(anchors.prefix(8))
        let sortedHeights = anchorSample.map { Double($0.height) }.sorted()
        let dominantHeight = sortedHeights[sortedHeights.count / 2]
        guard dominantHeight >= Double(minimumAnchorHeight) else {
            return ([], dominantHeight, components.count, "dominant height below character threshold")
        }
        let dominantArea = Double(anchorSample.map(\.area).max() ?? 1)
        let strongAnchors = anchorSample.filter {
            Double($0.height) >= dominantHeight * 0.65 || Double($0.area) >= dominantArea * 0.45
        }
        let centres = strongAnchors.map(\.centreY).sorted()
        let centreY = centres.isEmpty ? Double(height) * 0.5 : centres[centres.count / 2]

        let retained = components.filter { component in
            let substantial = Double(component.height) >= dominantHeight * 0.34
                || Double(component.area) >= dominantArea * 0.09
            let verticallyRelevant = abs(component.centreY - centreY) <= dominantHeight * 0.72
                || Double(component.height) >= dominantHeight * 0.75
            let reasonableWidth = component.width < Int(Double(width) * 0.55)
            return substantial && verticallyRelevant && reasonableWidth
        }.sorted { lhs, rhs in
            lhs.minX == rhs.minX ? lhs.minY < rhs.minY : lhs.minX < rhs.minX
        }
        guard !retained.isEmpty else {
            return ([], dominantHeight, components.count, "all components filtered as noise")
        }

        let gapTolerance = max(1, Int((dominantHeight * 0.08).rounded()))
        var grouped: [[DynamicComponent]] = []
        for component in retained {
            if let last = grouped.last,
               let currentMaxX = last.map(\.maxX).max(),
               component.minX <= currentMaxX + gapTolerance {
                grouped[grouped.count - 1].append(component)
            } else {
                grouped.append([component])
            }
        }

        var tokens: [DynamicTokenCandidate] = []
        for group in grouped {
            guard let minX = group.map(\.minX).min(), let maxX = group.map(\.maxX).max(),
                  let minY = group.map(\.minY).min(), let maxY = group.map(\.maxY).max() else { continue }
            let token = DynamicTokenCandidate(
                rect: CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1)),
                components: group
            )
            tokens.append(contentsOf: splitWideTokenIfNeeded(token, mask: mask, width: width, height: height, dominantHeight: dominantHeight))
        }

        // UX16d6: many physical scoreboards render the timer separator as two
        // compact lamps, while some use one central lamp. These components are
        // intentionally smaller than digit strokes and were previously discarded
        // by the general noise filter. Recover at most one separator token only for
        // timer fields; score, period and player fields never treat specks as ':'.
        if isTimerKey(key), let separator = discoverDynamicSeparator(
            components: components,
            existingTokens: tokens,
            dominantHeight: dominantHeight,
            dominantArea: dominantArea,
            centreY: centreY
        ) {
            tokens.append(separator)
        }

        tokens.sort { $0.rect.minX < $1.rect.minX }
        return (Array(tokens.prefix(8)), dominantHeight, components.count, "ok separator=\(tokens.contains(where: { $0.components.count <= 2 && $0.rect.height < CGFloat(dominantHeight * 0.75) }) ? "candidate" : "none")")
    }

    private static func discoverDynamicSeparator(
        components: [DynamicComponent],
        existingTokens: [DynamicTokenCandidate],
        dominantHeight: Double,
        dominantArea: Double,
        centreY: Double
    ) -> DynamicTokenCandidate? {
        guard dominantHeight > 0, existingTokens.count >= 2 else { return nil }
        let minTokenX = existingTokens.map { Double($0.rect.minX) }.min() ?? 0
        let maxTokenX = existingTokens.map { Double($0.rect.maxX) }.max() ?? 0
        let minimumArea = max(4.0, dominantArea * 0.010)

        let compact = components.filter { component in
            let componentRect = component.rect.insetBy(dx: -1, dy: -1)
            let overlapsDigit = existingTokens.contains { $0.rect.intersects(componentRect) }
            let heightRatio = Double(component.height) / dominantHeight
            let widthRatio = Double(component.width) / dominantHeight
            let betweenDigits = component.centreX > minTokenX && component.centreX < maxTokenX
            return !overlapsDigit
                && betweenDigits
                && Double(component.area) >= minimumArea
                && heightRatio >= 0.045 && heightRatio <= 0.34
                && widthRatio >= 0.025 && widthRatio <= 0.36
                && abs(component.centreY - centreY) <= dominantHeight * 0.56
        }
        guard !compact.isEmpty else { return nil }

        var bestPair: (first: DynamicComponent, second: DynamicComponent, score: Double)?
        for firstIndex in compact.indices {
            for secondIndex in compact.indices where secondIndex > firstIndex {
                let first = compact[firstIndex]
                let second = compact[secondIndex]
                let upper = first.centreY <= second.centreY ? first : second
                let lower = first.centreY <= second.centreY ? second : first
                let verticalSeparation = lower.centreY - upper.centreY
                let horizontalOffset = abs(first.centreX - second.centreX)
                let midpoint = (upper.centreY + lower.centreY) * 0.5
                guard verticalSeparation >= dominantHeight * 0.18,
                      verticalSeparation <= dominantHeight * 0.72,
                      horizontalOffset <= dominantHeight * 0.22,
                      abs(midpoint - centreY) <= dominantHeight * 0.24 else { continue }
                let score = 1.0
                    - min(1.0, horizontalOffset / max(1.0, dominantHeight * 0.22)) * 0.45
                    - min(1.0, abs(midpoint - centreY) / max(1.0, dominantHeight * 0.24)) * 0.35
                    - min(1.0, abs(verticalSeparation - dominantHeight * 0.42) / max(1.0, dominantHeight * 0.42)) * 0.20
                if bestPair == nil || score > (bestPair?.score ?? -1) {
                    bestPair = (upper, lower, score)
                }
            }
        }

        if let pair = bestPair {
            let minX = min(pair.first.minX, pair.second.minX)
            let minY = min(pair.first.minY, pair.second.minY)
            let maxX = max(pair.first.maxX, pair.second.maxX)
            let maxY = max(pair.first.maxY, pair.second.maxY)
            return DynamicTokenCandidate(
                rect: CGRect(
                    x: CGFloat(minX),
                    y: CGFloat(minY),
                    width: CGFloat(maxX - minX + 1),
                    height: CGFloat(maxY - minY + 1)
                ),
                components: [pair.first, pair.second]
            )
        }

        // Some scoreboards use a single central lamp instead of two colon dots.
        // Only accept a compact component close to the digit centre line.
        guard let single = compact
            .filter({ abs($0.centreY - centreY) <= dominantHeight * 0.20 })
            .min(by: { abs($0.centreY - centreY) < abs($1.centreY - centreY) }) else {
            return nil
        }
        return DynamicTokenCandidate(rect: single.rect, components: [single])
    }

    private static func splitWideTokenIfNeeded(
        _ token: DynamicTokenCandidate,
        mask: [Bool],
        width: Int,
        height: Int,
        dominantHeight: Double
    ) -> [DynamicTokenCandidate] {
        guard Double(token.rect.width) > dominantHeight * 1.08 else { return [token] }
        let minX = max(0, Int(token.rect.minX.rounded(.down)))
        let maxX = min(width - 1, Int(token.rect.maxX.rounded(.up)) - 1)
        let minY = max(0, Int(token.rect.minY.rounded(.down)))
        let maxY = min(height - 1, Int(token.rect.maxY.rounded(.up)) - 1)
        guard maxX - minX >= 8, maxY >= minY else { return [token] }
        var projection = [Int](repeating: 0, count: maxX - minX + 1)
        for x in minX...maxX {
            var count = 0
            for y in minY...maxY where mask[y * width + x] { count += 1 }
            projection[x - minX] = count
        }
        let lower = max(2, Int(Double(projection.count) * 0.28))
        let upper = min(projection.count - 3, Int(Double(projection.count) * 0.72))
        guard lower <= upper,
              let relativeSplit = (lower...upper).min(by: { projection[$0] < projection[$1] }) else { return [token] }
        let peak = projection.max() ?? 0
        guard projection[relativeSplit] <= max(1, peak / 4) else { return [token] }
        let splitX = minX + relativeSplit
        let leftRect = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(splitX - minX), height: CGFloat(maxY - minY + 1))
        let rightRect = CGRect(x: CGFloat(splitX + 1), y: CGFloat(minY), width: CGFloat(maxX - splitX), height: CGFloat(maxY - minY + 1))
        guard leftRect.width >= 3, rightRect.width >= 3 else { return [token] }
        return [
            DynamicTokenCandidate(rect: leftRect, components: token.components.filter { $0.centreX <= Double(splitX) }),
            DynamicTokenCandidate(rect: rightRect, components: token.components.filter { $0.centreX > Double(splitX) })
        ]
    }

    private static func dynamicColonConfidence(
        mask: [Bool],
        width: Int,
        height: Int,
        token: DynamicTokenCandidate,
        dominantHeight: Double
    ) -> Double? {
        guard dominantHeight > 0,
              Double(token.rect.width) <= dominantHeight * 0.58,
              Double(token.rect.height) <= dominantHeight * 0.95 else { return nil }

        if token.components.count == 2 {
            let sorted = token.components.sorted { $0.centreY < $1.centreY }
            let separation = sorted[1].centreY - sorted[0].centreY
            let horizontalOffset = abs(sorted[1].centreX - sorted[0].centreX)
            let compact = sorted.allSatisfy {
                Double($0.height) <= dominantHeight * 0.34
                    && Double($0.width) <= dominantHeight * 0.36
            }
            guard compact,
                  separation >= dominantHeight * 0.18,
                  separation <= dominantHeight * 0.72,
                  horizontalOffset <= dominantHeight * 0.22 else { return nil }
            return min(0.97, 0.88 + (1.0 - horizontalOffset / max(1.0, dominantHeight * 0.22)) * 0.08)
        }

        if token.components.count == 1,
           let component = token.components.first,
           Double(component.height) <= dominantHeight * 0.34,
           Double(component.width) <= dominantHeight * 0.36,
           component.area >= 4 {
            return 0.84
        }

        // Retain a raster fallback for anti-aliased separator lamps that were
        // connected by one or two threshold pixels and therefore form one component.
        let minX = max(0, Int(token.rect.minX.rounded(.down)))
        let maxX = min(width - 1, Int(token.rect.maxX.rounded(.up)) - 1)
        let minY = max(0, Int(token.rect.minY.rounded(.down)))
        let maxY = min(height - 1, Int(token.rect.maxY.rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return nil }
        var activeRows: [Bool] = []
        activeRows.reserveCapacity(maxY - minY + 1)
        let rowThreshold = max(1, (maxX - minX + 1) / 8)
        for y in minY...maxY {
            var active = 0
            for x in minX...maxX where mask[y * width + x] { active += 1 }
            activeRows.append(active >= rowThreshold)
        }
        var runs: [(Int, Int)] = []
        var runStart: Int?
        for (index, active) in activeRows.enumerated() {
            if active, runStart == nil { runStart = index }
            if !active, let start = runStart {
                runs.append((start, index - 1))
                runStart = nil
            }
        }
        if let start = runStart { runs.append((start, activeRows.count - 1)) }
        if runs.count == 2 {
            let separation = runs[1].0 - runs[0].1
            guard separation >= max(2, Int(dominantHeight * 0.12)) else { return nil }
            return min(0.94, 0.78 + Double(separation) / max(1, dominantHeight) * 0.22)
        }
        if runs.count == 1,
           Double(token.rect.height) <= dominantHeight * 0.34,
           Double(token.rect.width) <= dominantHeight * 0.36 {
            return 0.80
        }
        return nil
    }

    private static let dynamicSegmentTemplates: [(digit: Int, segments: [Bool])] = [
        (0, [true, true, true, false, true, true, true]),
        (1, [false, false, true, false, false, true, false]),
        (2, [true, false, true, true, true, false, true]),
        (3, [true, false, true, true, false, true, true]),
        (4, [false, true, true, true, false, true, false]),
        (5, [true, true, false, true, false, true, true]),
        (6, [true, true, false, true, true, true, true]),
        (7, [true, false, true, false, false, true, false]),
        (8, [true, true, true, true, true, true, true]),
        (9, [true, true, true, true, false, true, true])
    ]

    /// Build 522 fixed-cost timer primary classifier. It deliberately omits
    /// generic reference scanning and morphology so every discovered timer slot
    /// can be visited before any one ambiguous digit consumes the field budget.
    private static func decodeDynamicGlyphFast(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        dominantHeight: Double,
        key: OCRRegionKey
    ) -> DynamicGlyphDecode? {
        let activeRect = dynamicActiveRect(mask: mask, width: width, height: height, rect: rect)
        if isScoreKey(key), let activeRect {
            let aspect = Double(activeRect.width / max(1, activeRect.height))
            if aspect <= 0.46,
               Double(activeRect.height) >= dominantHeight * 0.58 {
                return DynamicGlyphDecode(digit: 1, confidence: 0.92, method: "score-narrow-one")
            }
        }

        let topology = decodeDynamicSegmentTopology(
            mask: mask,
            width: width,
            height: height,
            rect: rect,
            dominantHeight: dominantHeight
        )
        guard let glyph = normalisedDynamicGlyph(
            mask: mask,
            width: width,
            height: height,
            rect: rect
        ) else {
            return topology
        }

        let holeProfile = dynamicHoleProfile(glyph, width: 12, height: 20)
        let foregroundComponents = dynamicForegroundComponentCount(glyph, width: 12, height: 20)
        if let activeRect,
           let solidOne = decodeSolidFontOneShape(
               glyph,
               width: 12,
               height: 20,
               activeAspect: Double(activeRect.width / max(1, activeRect.height)),
               holeProfile: holeProfile,
               foregroundComponents: foregroundComponents
           ) {
            return solidOne
        }

        if holeProfile.count >= 2, topology?.digit == 8 {
            let middleEvidence = activeRect.map {
                dynamicMiddleSegmentEvidence(mask: mask, width: width, height: height, digitRect: $0)
            } ?? 0
            if middleEvidence < 0.58 {
                return DynamicGlyphDecode(
                    digit: 0,
                    confidence: 0.86,
                    method: "middle-segment-absent-zero",
                    alternatives: [8] + (topology?.alternatives ?? [])
                )
            }
            return DynamicGlyphDecode(
                digit: 8,
                confidence: 0.94,
                method: "hole-topology-two",
                alternatives: topology?.alternatives ?? []
            )
        }

        if holeProfile.count == 1,
           let suggested = holeProfile.suggestedDigit,
           [0, 6, 9].contains(suggested),
           topology?.digit == suggested {
            return DynamicGlyphDecode(
                digit: suggested,
                confidence: min(0.93, max(topology?.confidence ?? 0, 0.82)),
                method: "segment+hole-topology",
                alternatives: topology?.alternatives ?? []
            )
        }

        return topology
    }

    private static func decodeDynamicGlyph(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        dominantHeight: Double,
        key: OCRRegionKey,
        deadlineUptimeNanoseconds: UInt64?
    ) -> DynamicGlyphDecode? {
        guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }

        let activeRect = dynamicActiveRect(mask: mask, width: width, height: height, rect: rect)
        if isScoreKey(key), let activeRect {
            let aspect = Double(activeRect.width / max(1, activeRect.height))
            if aspect <= 0.46,
               Double(activeRect.height) >= dominantHeight * 0.58 {
                return DynamicGlyphDecode(digit: 1, confidence: 0.92, method: "score-narrow-one")
            }
        }

        let topology = decodeDynamicSegmentTopology(
            mask: mask,
            width: width,
            height: height,
            rect: rect,
            dominantHeight: dominantHeight
        )

        // UX16d8: evaluate a font-shape fallback even when segment topology returns
        // a candidate. Solid LCD/computer-font digits can create false middle-bar
        // evidence, most noticeably turning 0 into 8. Agreement between topology,
        // generic shape and enclosed-hole structure is stronger than either alone.
        let glyph = normalisedDynamicGlyph(
            mask: mask,
            width: width,
            height: height,
            rect: rect
        )
        let generic = glyph.flatMap {
            decodeGenericDynamicGlyph(
                $0,
                key: key,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
        }
        let holeProfile = glyph.map {
            dynamicHoleProfile($0, width: 12, height: 20)
        }
        let foregroundComponents = glyph.map {
            dynamicForegroundComponentCount($0, width: 12, height: 20)
        } ?? 0

        // UX16d15: the rink display's solid-font `1` has a broad angled head and
        // thick glow, so its active bounds are not narrow enough for the existing
        // one shortcut. Segment sampling then mistakes the filled head/stem for 9.
        // Resolve the font-neutral shape before accepting a closed-loop digit: no
        // enclosed hole, one connected foreground body, a straight right-hand lower
        // stem and a left-flared head. This same shape appears in Clock, Period and
        // score fields, so the rule is token-based rather than rink/field-specific.
        if let glyph,
           let activeRect,
           let holeProfile,
           let solidOne = decodeSolidFontOneShape(
               glyph,
               width: 12,
               height: 20,
               activeAspect: Double(activeRect.width / max(1, activeRect.height)),
               holeProfile: holeProfile,
               foregroundComponents: foregroundComponents
           ) {
            return solidOne
        }

        if let profile = holeProfile,
           profile.count >= 2,
           topology?.digit == 8 || generic?.digit == 8,
           let activeRect {
            let middleEvidence = dynamicMiddleSegmentEvidence(
                mask: mask,
                width: width,
                height: height,
                digitRect: activeRect
            )
            if middleEvidence < 0.58 {
                let alternatives = [topology?.digit, generic?.digit].compactMap { $0 }.filter { $0 != 0 }
                    + (topology?.alternatives ?? []) + (generic?.alternatives ?? [])
                return DynamicGlyphDecode(
                    digit: 0,
                    confidence: 0.86,
                    method: "middle-segment-absent-zero",
                    alternatives: alternatives
                )
            }
        }

        if let topology, let generic, topology.digit == generic.digit {
            return DynamicGlyphDecode(
                digit: topology.digit,
                confidence: min(0.98, max(topology.confidence, generic.confidence) + 0.04),
                method: "segment+generic-agreement",
                alternatives: topology.alternatives + generic.alternatives
            )
        }

        if let profile = holeProfile, profile.count >= 2 {
            // Two enclosed counters are a strong font-independent signature of 8.
            if topology?.digit == 8 || generic?.digit == 8 {
                let alternatives = [topology?.digit, generic?.digit].compactMap { $0 }.filter { $0 != 8 }
                    + (topology?.alternatives ?? []) + (generic?.alternatives ?? [])
                return DynamicGlyphDecode(digit: 8, confidence: 0.94, method: "hole-topology-two", alternatives: alternatives)
            }
        }

        if let profile = holeProfile,
           profile.count == 1,
           let suggested = profile.suggestedDigit,
           [0, 6, 9].contains(suggested) {
            // Resolve only among closed-loop digits. A closed-top 4 in some fonts
            // must not be converted into 9 unless another recogniser also supports it.
            if generic?.digit == suggested {
                return DynamicGlyphDecode(
                    digit: suggested,
                    confidence: min(0.93, max(generic?.confidence ?? 0, 0.82)),
                    method: "generic+hole-topology",
                    alternatives: [topology?.digit].compactMap { $0 }
                )
            }
            if topology?.digit == suggested {
                return DynamicGlyphDecode(
                    digit: suggested,
                    confidence: min(0.93, max(topology?.confidence ?? 0, 0.82)),
                    method: "segment+hole-topology",
                    alternatives: [generic?.digit].compactMap { $0 }
                )
            }
            if topology?.digit == 8, generic?.digit == suggested {
                return DynamicGlyphDecode(
                    digit: suggested,
                    confidence: 0.86,
                    method: "hole-resolved-8-ambiguity",
                    alternatives: [topology?.digit].compactMap { $0 }
                )
            }
        }

        if let topology, let generic {
            // A solid computer/LCD font normally forms one connected foreground
            // component, while a true segmented display retains several separate
            // bars. Use that structural distinction rather than a rink-specific
            // font setting when the two classifiers disagree.
            if foregroundComponents <= 2 {
                return DynamicGlyphDecode(
                    digit: generic.digit,
                    confidence: min(0.92, max(generic.confidence, 0.72)),
                    method: "connected-font-generic",
                    alternatives: [topology.digit] + generic.alternatives
                )
            }

            // Fragmented glyphs are segment-like. Exact segment topology remains
            // authoritative; a tolerant topology result can yield to a clearly
            // stronger generic shape. Otherwise reject the disagreement rather
            // than publishing a confident but contradictory digit.
            if topology.method == "segment-topology" {
                return DynamicGlyphDecode(
                    digit: topology.digit,
                    confidence: topology.confidence,
                    method: topology.method,
                    alternatives: [generic.digit] + generic.alternatives
                )
            }
            if generic.confidence >= topology.confidence + 0.05 {
                return DynamicGlyphDecode(
                    digit: generic.digit,
                    confidence: generic.confidence,
                    method: generic.method,
                    alternatives: [topology.digit] + generic.alternatives
                )
            }
            return nil
        }

        return topology ?? generic
    }

    private static func decodeSolidFontOneShape(
        _ glyph: [Bool],
        width: Int,
        height: Int,
        activeAspect: Double,
        holeProfile: DynamicHoleProfile,
        foregroundComponents: Int
    ) -> DynamicGlyphDecode? {
        guard width >= 8,
              height >= 12,
              glyph.count == width * height,
              activeAspect >= 0.40,
              // Build 674: legitimate solid-font 1 samples are narrow. The Guest
              // scoreboard 7 had a 0.69-0.74 active aspect and was being accepted as
              // 1 by this broad guard. Keep the known 1 range while excluding 7.
              activeAspect <= 0.58,
              holeProfile.count == 0,
              foregroundComponents > 0,
              foregroundComponents <= 2 else { return nil }

        struct RowInk {
            let y: Int
            let minX: Int
            let maxX: Int

            var width: Int { maxX - minX + 1 }
            var centre: Double { Double(minX + maxX) * 0.5 }
        }

        var rows: [RowInk] = []
        rows.reserveCapacity(height)
        for y in 0..<height {
            var minX = width
            var maxX = -1
            for x in 0..<width where glyph[y * width + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
            if minX <= maxX {
                rows.append(RowInk(y: y, minX: minX, maxX: maxX))
            }
        }
        guard rows.count >= max(8, Int(Double(height) * 0.65)) else { return nil }

        let lowerStart = Int((Double(height) * 0.40).rounded(.down))
        let upperEnd = max(1, Int((Double(height) * 0.42).rounded(.up)))
        let lower = rows.filter { $0.y >= lowerStart }
        let upper = rows.filter { $0.y < upperEnd }
        guard lower.count >= max(5, Int(Double(height) * 0.40)), !upper.isEmpty else { return nil }

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let middle = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[middle - 1] + sorted[middle]) * 0.5
            }
            return sorted[middle]
        }

        let widthDenominator = Double(max(1, width - 1))
        let lowerLeft = median(lower.map { Double($0.minX) }) / widthDenominator
        let lowerRight = median(lower.map { Double($0.maxX) }) / widthDenominator
        let lowerWidth = median(lower.map { Double($0.width) }) / Double(width)
        let lowerCentres = lower.map(\.centre)
        let centreSpread = ((lowerCentres.max() ?? 0) - (lowerCentres.min() ?? 0)) / Double(width)
        let upperMinimumLeft = Double(upper.map(\.minX).min() ?? width) / widthDenominator
        let headFlare = lowerLeft - upperMinimumLeft
        let rightEdgeCoverage = Double(lower.filter { Double($0.maxX) / widthDenominator >= 0.62 }.count)
            / Double(max(1, lower.count))

        guard lowerLeft >= 0.26,
              lowerRight >= 0.65,
              lowerWidth <= 0.72,
              centreSpread <= 0.24,
              headFlare >= 0.16,
              rightEdgeCoverage >= 0.70 else { return nil }

        return DynamicGlyphDecode(
            digit: 1,
            confidence: 0.94,
            method: "solid-font-one-shape"
        )
    }

    /// UX16d11 bounded recovery for a token that exists geometrically but was
    /// unclassified by the primary topology/generic decision. The work is limited
    /// to one 12x20 glyph and at most four local morphology variants. It cannot
    /// manufacture a missing token or bypass field-level clock validation.
    private static func recoverUnknownTimerDigit(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        key: OCRRegionKey,
        deadlineUptimeNanoseconds: UInt64?
    ) -> DynamicGlyphRecoveryAttempt {
        guard isTimerKey(key), width > 0, height > 0 else {
            return DynamicGlyphRecoveryAttempt(decode: nil, summary: "recovery-ineligible")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let recoveryDeadline = min(
            deadlineUptimeNanoseconds ?? UInt64.max,
            started + 80_000_000
        )
        guard beforeDeadline(recoveryDeadline) else {
            return DynamicGlyphRecoveryAttempt(decode: nil, summary: "recovery-no-budget")
        }

        let expanded = rect.insetBy(
            dx: -max(1, rect.width * 0.10),
            dy: -max(1, rect.height * 0.10)
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !expanded.isNull, !expanded.isEmpty,
              let base = normalisedDynamicGlyph(
                mask: mask,
                width: width,
                height: height,
                rect: expanded,
                targetWidth: 12,
                targetHeight: 20
              ) else {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            return DynamicGlyphRecoveryAttempt(
                decode: nil,
                summary: "recovery-normalise-failed-elapsedMs=\(String(format: "%.2f", elapsed))"
            )
        }

        let variants: [(String, [Bool])] = [
            ("neutral", base),
            ("dilate", morphDynamicGlyph(base, width: 12, height: 20, dilate: true)),
            ("erode", morphDynamicGlyph(base, width: 12, height: 20, dilate: false)),
            ("close", morphDynamicGlyph(
                morphDynamicGlyph(base, width: 12, height: 20, dilate: true),
                width: 12,
                height: 20,
                dilate: false
            ))
        ]

        var votes: [Int: [(name: String, decode: DynamicGlyphDecode)]] = [:]
        var attempted = 0
        for (name, variant) in variants {
            guard beforeDeadline(recoveryDeadline) else { break }
            attempted += 1
            guard let decoded = decodeRecoveryGlyphVariant(
                variant,
                key: key,
                deadlineUptimeNanoseconds: recoveryDeadline
            ) else { continue }
            votes[decoded.digit, default: []].append((name, decoded))
        }

        let ranked = votes.map { (digit: $0.key, items: $0.value) }.sorted {
            if $0.items.count != $1.items.count { return $0.items.count > $1.items.count }
            let lhs = $0.items.map { $0.decode.confidence }.reduce(0, +) / Double(max(1, $0.items.count))
            let rhs = $1.items.map { $0.decode.confidence }.reduce(0, +) / Double(max(1, $1.items.count))
            return lhs > rhs
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let voteText = ranked.map { entry in
            let names = entry.items.map { $0.name }.joined(separator: "+")
            return "\(entry.digit):\(entry.items.count)[\(names)]"
        }.joined(separator: ",")
        let summaryBase = "recovery-attempted=\(attempted)/\(variants.count)-votes=\(voteText.isEmpty ? "none" : voteText)-elapsedMs=\(String(format: "%.2f", elapsed))"

        guard let winner = ranked.first,
              winner.items.count >= 2,
              ranked.dropFirst().first?.items.count != winner.items.count else {
            return DynamicGlyphRecoveryAttempt(decode: nil, summary: "\(summaryBase)-result=no-consensus")
        }
        let average = winner.items.map { $0.decode.confidence }.reduce(0, +) / Double(winner.items.count)
        guard average >= 0.58 else {
            return DynamicGlyphRecoveryAttempt(decode: nil, summary: "\(summaryBase)-result=low-confidence")
        }
        let confidence = min(0.90, max(0.64, average + Double(winner.items.count - 2) * 0.04))
        let methods = winner.items.map { $0.name }.joined(separator: "+")
        return DynamicGlyphRecoveryAttempt(
            decode: DynamicGlyphDecode(
                digit: winner.digit,
                confidence: confidence,
                method: "unknown-token-recovery-\(winner.items.count)of\(variants.count)-\(methods)"
            ),
            summary: "\(summaryBase)-result=\(winner.digit)"
        )
    }

    private static func decodeRecoveryGlyphVariant(
        _ glyph: [Bool],
        key: OCRRegionKey,
        deadlineUptimeNanoseconds: UInt64?
    ) -> DynamicGlyphDecode? {
        guard glyph.count == 12 * 20, beforeDeadline(deadlineUptimeNanoseconds) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: 12, height: 20)
        let topology = decodeDynamicSegmentTopology(
            mask: glyph,
            width: 12,
            height: 20,
            rect: rect,
            dominantHeight: 20
        )
        let generic = decodeGenericDynamicGlyph(
            glyph,
            key: key,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        if let topology, let generic, topology.digit == generic.digit {
            return DynamicGlyphDecode(
                digit: topology.digit,
                confidence: min(0.92, max(topology.confidence, generic.confidence)),
                method: "recovery-segment+generic"
            )
        }

        let holes = dynamicHoleProfile(glyph, width: 12, height: 20)
        if holes.count >= 2, (topology?.digit == 8 || generic?.digit == 8) {
            return DynamicGlyphDecode(digit: 8, confidence: 0.88, method: "recovery-hole-two")
        }
        if holes.count == 1, let suggested = holes.suggestedDigit,
           (topology?.digit == suggested || generic?.digit == suggested) {
            return DynamicGlyphDecode(digit: suggested, confidence: 0.82, method: "recovery-hole-one")
        }
        if let topology, generic == nil { return topology }
        if let generic, topology == nil { return generic }
        if let topology, let generic {
            let components = dynamicForegroundComponentCount(glyph, width: 12, height: 20)
            if components <= 2 { return generic }
            if topology.method == "segment-topology" { return topology }
        }
        return nil
    }

    private static func morphDynamicGlyph(
        _ glyph: [Bool],
        width: Int,
        height: Int,
        dilate: Bool
    ) -> [Bool] {
        guard glyph.count == width * height, width > 2, height > 2 else { return glyph }
        var output = glyph
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var activeCount = 0
                for dy in -1...1 {
                    for dx in -1...1 where glyph[(y + dy) * width + x + dx] {
                        activeCount += 1
                    }
                }
                output[y * width + x] = dilate ? activeCount >= 1 : activeCount >= 6
            }
        }
        return output
    }

    private static func decodeGenericDynamicGlyph(
        _ glyph: [Bool],
        key: OCRRegionKey,
        deadlineUptimeNanoseconds: UInt64?
    ) -> DynamicGlyphDecode? {
        var bestByDigit: [Int: Double] = [:]
        for reference in genericGlyphReferences {
            guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }
            let score = glyphSimilarity(
                glyph,
                reference: reference.pixels,
                width: reference.width,
                height: reference.height
            )
            bestByDigit[reference.digit] = max(bestByDigit[reference.digit] ?? 0, score)
        }
        let ranked = bestByDigit.map { (digit: $0.key, score: $0.value) }.sorted { $0.score > $1.score }
        guard let best = ranked.first, let second = ranked.dropFirst().first else { return nil }
        let margin = best.score - second.score

        let timerKey = isTimerKey(key)
        let minimumScore = timerKey ? 0.53 : 0.58
        let minimumMargin = timerKey ? 0.025 : 0.045
        guard best.score >= minimumScore, margin >= minimumMargin else { return nil }

        let confidenceFloor = timerKey ? 0.58 : 0.62
        let confidence = min(0.90, max(confidenceFloor, best.score * 0.84 + min(0.10, margin * 1.5)))
        return DynamicGlyphDecode(
            digit: best.digit,
            confidence: confidence,
            method: "generic-template",
            alternatives: [second.digit]
        )
    }

    private static func dynamicForegroundComponentCount(
        _ glyph: [Bool],
        width: Int,
        height: Int
    ) -> Int {
        guard width > 0, height > 0, glyph.count == width * height else { return 0 }
        var visited = [Bool](repeating: false, count: glyph.count)
        let neighbours = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        var count = 0

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard glyph[index], !visited[index] else { continue }
                count += 1
                var queue = [(x, y)]
                visited[index] = true
                var head = 0
                while head < queue.count {
                    let (cx, cy) = queue[head]
                    head += 1
                    for (dx, dy) in neighbours {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        guard glyph[next], !visited[next] else { continue }
                        visited[next] = true
                        queue.append((nx, ny))
                    }
                }
            }
        }
        return count
    }

    private struct DynamicHoleProfile {
        let count: Int
        let suggestedDigit: Int?
    }

    private static func dynamicHoleProfile(
        _ glyph: [Bool],
        width: Int,
        height: Int
    ) -> DynamicHoleProfile {
        guard width > 2, height > 2, glyph.count == width * height else {
            return DynamicHoleProfile(count: 0, suggestedDigit: nil)
        }

        var exterior = [Bool](repeating: false, count: glyph.count)
        var queue: [(Int, Int)] = []
        queue.reserveCapacity(width * 2 + height * 2)

        func enqueueExterior(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let index = y * width + x
            guard !glyph[index], !exterior[index] else { return }
            exterior[index] = true
            queue.append((x, y))
        }

        for x in 0..<width {
            enqueueExterior(x, 0)
            enqueueExterior(x, height - 1)
        }
        for y in 0..<height {
            enqueueExterior(0, y)
            enqueueExterior(width - 1, y)
        }

        var head = 0
        let neighbours = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        while head < queue.count {
            let (x, y) = queue[head]
            head += 1
            for (dx, dy) in neighbours {
                enqueueExterior(x + dx, y + dy)
            }
        }

        var visited = exterior
        var holeCentres: [Double] = []
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                guard !glyph[index], !visited[index] else { continue }

                var component = [(x, y)]
                visited[index] = true
                var componentHead = 0
                var area = 0
                var yTotal = 0
                while componentHead < component.count {
                    let (cx, cy) = component[componentHead]
                    componentHead += 1
                    area += 1
                    yTotal += cy
                    for (dx, dy) in neighbours {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        guard !glyph[next], !visited[next] else { continue }
                        visited[next] = true
                        component.append((nx, ny))
                    }
                }
                if area >= 3 {
                    holeCentres.append(Double(yTotal) / Double(area) / Double(max(1, height - 1)))
                }
            }
        }

        if holeCentres.count >= 2 {
            return DynamicHoleProfile(count: holeCentres.count, suggestedDigit: 8)
        }
        guard let centre = holeCentres.first else {
            return DynamicHoleProfile(count: 0, suggestedDigit: nil)
        }
        let suggested: Int
        if centre < 0.43 {
            suggested = 9
        } else if centre > 0.57 {
            suggested = 6
        } else {
            suggested = 0
        }
        return DynamicHoleProfile(count: 1, suggestedDigit: suggested)
    }

    private static func dynamicMiddleSegmentEvidence(
        mask: [Bool],
        width: Int,
        height: Int,
        digitRect: CGRect
    ) -> Double {
        dynamicHorizontalEvidence(
            mask: mask,
            width: width,
            height: height,
            digitRect: digitRect,
            y0: 0.43,
            y1: 0.57,
            x0: 0.22,
            x1: 0.78
        )
    }

    private static func decodeDynamicSegmentTopology(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        dominantHeight: Double
    ) -> DynamicGlyphDecode? {
        guard let activeRect = dynamicActiveRect(mask: mask, width: width, height: height, rect: rect),
              activeRect.height >= max(6, CGFloat(dominantHeight * 0.42)) else { return nil }

        let aspect = Double(activeRect.width / max(1, activeRect.height))
        if aspect <= 0.44,
           Double(activeRect.height) >= dominantHeight * 0.58 {
            return DynamicGlyphDecode(digit: 1, confidence: 0.90, method: "segment-topology-narrow")
        }
        guard aspect >= 0.28, aspect <= 1.18 else { return nil }

        // Order: top, upper-left, upper-right, middle, lower-left,
        // lower-right, bottom. Narrow central sampling avoids the rounded ends of
        // horizontal bars impersonating left/right vertical segments.
        let evidence = [
            dynamicHorizontalEvidence(mask: mask, width: width, height: height, digitRect: activeRect, y0: 0.00, y1: 0.22, x0: 0.28, x1: 0.72),
            dynamicVerticalEvidence(mask: mask, width: width, height: height, digitRect: activeRect, x0: 0.00, x1: 0.18, y0: 0.24, y1: 0.42),
            dynamicVerticalEvidence(mask: mask, width: width, height: height, digitRect: activeRect, x0: 0.82, x1: 1.00, y0: 0.24, y1: 0.42),
            dynamicHorizontalEvidence(mask: mask, width: width, height: height, digitRect: activeRect, y0: 0.39, y1: 0.61, x0: 0.28, x1: 0.72),
            dynamicVerticalEvidence(mask: mask, width: width, height: height, digitRect: activeRect, x0: 0.00, x1: 0.18, y0: 0.58, y1: 0.76),
            dynamicVerticalEvidence(mask: mask, width: width, height: height, digitRect: activeRect, x0: 0.82, x1: 1.00, y0: 0.58, y1: 0.76),
            dynamicHorizontalEvidence(mask: mask, width: width, height: height, digitRect: activeRect, y0: 0.78, y1: 1.00, x0: 0.28, x1: 0.72)
        ]
        guard evidence.max() ?? 0 >= 0.42 else { return nil }

        let sorted = evidence.sorted()
        var largestGap = 0.0
        var threshold = 0.58
        if sorted.count >= 2 {
            for index in 0..<(sorted.count - 1) {
                let gap = sorted[index + 1] - sorted[index]
                if gap > largestGap {
                    largestGap = gap
                    threshold = (sorted[index + 1] + sorted[index]) * 0.5
                }
            }
        }
        if largestGap < 0.12 {
            threshold = (sorted.first ?? 0) >= 0.46 ? 0.42 : 0.58
        }
        threshold = min(0.78, max(0.40, threshold))
        let observed = evidence.map { $0 >= threshold }

        var ranked: [(digit: Int, mismatches: Int, cost: Double, minOn: Double, maxOff: Double)] = []
        for template in dynamicSegmentTemplates {
            var mismatches = 0
            var totalCost = 0.0
            var onValues: [Double] = []
            var offValues: [Double] = []
            for index in template.segments.indices {
                let expected = template.segments[index]
                let value = min(1.0, max(0.0, evidence[index]))
                if observed[index] != expected { mismatches += 1 }
                totalCost += expected ? (1.0 - value) : value
                if expected { onValues.append(value) } else { offValues.append(value) }
            }
            ranked.append((
                digit: template.digit,
                mismatches: mismatches,
                cost: totalCost / 7.0,
                minOn: onValues.min() ?? 0,
                maxOff: offValues.max() ?? 0
            ))
        }
        ranked.sort {
            if $0.mismatches != $1.mismatches { return $0.mismatches < $1.mismatches }
            return $0.cost < $1.cost
        }
        guard let best = ranked.first, let second = ranked.dropFirst().first else { return nil }
        let costMargin = second.cost - best.cost
        let separation = best.minOn - best.maxOff

        if best.mismatches == 0,
           best.minOn >= 0.34,
           best.cost <= 0.34 {
            let confidence = min(0.97, max(0.64, 0.76 + separation * 0.20 + costMargin * 0.45))
            return DynamicGlyphDecode(digit: best.digit, confidence: confidence, method: "segment-topology")
        }
        if best.mismatches == 1,
           best.cost <= 0.24,
           costMargin >= 0.055,
           best.minOn >= 0.42 {
            let confidence = min(0.86, max(0.60, 0.66 + costMargin * 0.60 + separation * 0.12))
            return DynamicGlyphDecode(digit: best.digit, confidence: confidence, method: "segment-topology-tolerant")
        }
        return nil
    }

    private static func dynamicActiveRect(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect
    ) -> CGRect? {
        var minX = max(0, Int(rect.minX.rounded(.down)))
        var maxX = min(width - 1, Int(rect.maxX.rounded(.up)) - 1)
        var minY = max(0, Int(rect.minY.rounded(.down)))
        var maxY = min(height - 1, Int(rect.maxY.rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return nil }

        // A token touching a field edge is commonly joined to a bezel line. Trim a
        // shallow edge guard before calculating the active bounds; the remaining
        // portion of a genuine top/bottom segment is still sampled.
        if minY <= 1 { minY = min(maxY, minY + max(1, Int(rect.height * 0.08))) }
        if maxY >= height - 2 { maxY = max(minY, maxY - max(1, Int(rect.height * 0.08))) }
        if minX <= 1 { minX = min(maxX, minX + max(1, Int(rect.width * 0.05))) }
        if maxX >= width - 2 { maxX = max(minX, maxX - max(1, Int(rect.width * 0.05))) }

        var activeMinX = width
        var activeMaxX = -1
        var activeMinY = height
        var activeMaxY = -1
        var activeCount = 0
        for y in minY...maxY {
            for x in minX...maxX where mask[y * width + x] {
                activeMinX = min(activeMinX, x)
                activeMaxX = max(activeMaxX, x)
                activeMinY = min(activeMinY, y)
                activeMaxY = max(activeMaxY, y)
                activeCount += 1
            }
        }
        guard activeCount >= 8,
              activeMinX <= activeMaxX,
              activeMinY <= activeMaxY else { return nil }
        return CGRect(
            x: CGFloat(activeMinX),
            y: CGFloat(activeMinY),
            width: CGFloat(activeMaxX - activeMinX + 1),
            height: CGFloat(activeMaxY - activeMinY + 1)
        )
    }

    private static func dynamicHorizontalEvidence(
        mask: [Bool],
        width: Int,
        height: Int,
        digitRect: CGRect,
        y0: CGFloat,
        y1: CGFloat,
        x0: CGFloat,
        x1: CGFloat
    ) -> Double {
        let minX = max(0, Int((digitRect.minX + digitRect.width * x0).rounded(.down)))
        let maxX = min(width - 1, Int((digitRect.minX + digitRect.width * x1).rounded(.up)) - 1)
        let minY = max(0, Int((digitRect.minY + digitRect.height * y0).rounded(.down)))
        let maxY = min(height - 1, Int((digitRect.minY + digitRect.height * y1).rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return 0 }
        var best = 0.0
        let span = Double(max(1, maxX - minX + 1))
        for y in minY...maxY {
            var active = 0
            for x in minX...maxX where mask[y * width + x] { active += 1 }
            best = max(best, Double(active) / span)
        }
        return best
    }

    private static func dynamicVerticalEvidence(
        mask: [Bool],
        width: Int,
        height: Int,
        digitRect: CGRect,
        x0: CGFloat,
        x1: CGFloat,
        y0: CGFloat,
        y1: CGFloat
    ) -> Double {
        let minX = max(0, Int((digitRect.minX + digitRect.width * x0).rounded(.down)))
        let maxX = min(width - 1, Int((digitRect.minX + digitRect.width * x1).rounded(.up)) - 1)
        let minY = max(0, Int((digitRect.minY + digitRect.height * y0).rounded(.down)))
        let maxY = min(height - 1, Int((digitRect.minY + digitRect.height * y1).rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return 0 }
        var best = 0.0
        let span = Double(max(1, maxY - minY + 1))
        for x in minX...maxX {
            var active = 0
            for y in minY...maxY where mask[y * width + x] { active += 1 }
            best = max(best, Double(active) / span)
        }
        return best
    }

    private static func normalisedDynamicGlyph(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        targetWidth: Int = 12,
        targetHeight: Int = 20
    ) -> [Bool]? {
        guard let activeRect = dynamicActiveRect(mask: mask, width: width, height: height, rect: rect) else { return nil }
        let sourceMinX = Int(activeRect.minX)
        let sourceMinY = Int(activeRect.minY)
        let sourceWidth = max(1, Int(activeRect.width))
        let sourceHeight = max(1, Int(activeRect.height))
        let scale = min(Double(targetWidth) / Double(sourceWidth), Double(targetHeight) / Double(sourceHeight))
        let fittedWidth = max(1, min(targetWidth, Int((Double(sourceWidth) * scale).rounded())))
        let fittedHeight = max(1, min(targetHeight, Int((Double(sourceHeight) * scale).rounded())))
        let offsetX = (targetWidth - fittedWidth) / 2
        let offsetY = (targetHeight - fittedHeight) / 2
        var output = [Bool](repeating: false, count: targetWidth * targetHeight)

        for fittedY in 0..<fittedHeight {
            let sourceY0 = sourceMinY + fittedY * sourceHeight / fittedHeight
            let sourceY1 = min(sourceMinY + sourceHeight - 1, sourceMinY + ((fittedY + 1) * sourceHeight / fittedHeight))
            for fittedX in 0..<fittedWidth {
                let sourceX0 = sourceMinX + fittedX * sourceWidth / fittedWidth
                let sourceX1 = min(sourceMinX + sourceWidth - 1, sourceMinX + ((fittedX + 1) * sourceWidth / fittedWidth))
                var active = 0
                var total = 0
                if sourceY0 <= sourceY1, sourceX0 <= sourceX1 {
                    for y in sourceY0...sourceY1 {
                        for x in sourceX0...sourceX1 {
                            total += 1
                            if mask[y * width + x] { active += 1 }
                        }
                    }
                }
                if total > 0, Double(active) / Double(total) >= 0.22 {
                    output[(offsetY + fittedY) * targetWidth + offsetX + fittedX] = true
                }
            }
        }
        return output
    }

    private static func interpretRawSequence(_ raw: String, key: OCRRegionKey) -> String? {
        // Build 556 retains only the safe part of the later timer work: remove one
        // extreme token only when the raw sequence is genuinely longer than the
        // canonical field shape. A normal MM:SS Clock such as 28:88 is never trimmed.
        if let edgeTrimmed = uniqueTimerEdgeTrimCandidate(raw, key: key) {
            return edgeTrimmed
        }

        // Build 531 ground-truth recovery: at a fresh Clock baseline the rink's
        // closed-loop zero can make the complete 20:00 display appear as 28:88.
        // Before the ordinary timer parser performs its local seconds repair,
        // search only for an exact standard period-start candidate. This is
        // deliberately Clock-only, requires one unique result and never rewrites
        // the leading digit. It therefore recovers 28:88 -> 20:00 without turning
        // ordinary valid values such as 19:58 into guessed alternatives.
        if key == .clock,
           let periodStart = uniqueClosedLoopPeriodStartCandidate(raw) {
            return periodStart
        }

        if let direct = interpretRawSequenceBase(raw, key: key) {
            return direct
        }

        // For other structurally invalid timers, retain the narrow 8 -> 0 search.
        // Publication is allowed only when the smallest substitution set produces
        // one unique valid value. Unknown tokens and leading digits are untouched.
        guard isTimerKey(key),
              !raw.isEmpty,
              !raw.contains("?"),
              raw.filter({ $0 == ":" }).count <= 1 else { return nil }
        let characters = Array(raw)
        let replaceable = characters.indices.filter { index in
            index > characters.startIndex && characters[index] == "8"
        }
        guard !replaceable.isEmpty, replaceable.count <= 5 else { return nil }

        var candidatesByReplacementCount: [Int: Set<String>] = [:]
        let combinationCount = 1 << replaceable.count
        for mask in 1..<combinationCount {
            var candidateCharacters = characters
            var replacementCount = 0
            for (bit, index) in replaceable.enumerated() where (mask & (1 << bit)) != 0 {
                candidateCharacters[index] = "0"
                replacementCount += 1
            }
            let candidateRaw = String(candidateCharacters)
            if let value = interpretRawSequenceBase(candidateRaw, key: key) {
                candidatesByReplacementCount[replacementCount, default: []].insert(value)
            }
        }
        guard let minimum = candidatesByReplacementCount.keys.min(),
              let candidates = candidatesByReplacementCount[minimum],
              candidates.count == 1 else { return nil }
        return candidates.first
    }

    private static func uniqueTimerEdgeTrimCandidate(_ raw: String, key: OCRRegionKey) -> String? {
        guard isTimerKey(key),
              !raw.contains("?"),
              raw.filter({ $0 == ":" }).count <= 1 else { return nil }

        let maximumCanonicalLength: Int
        if key == .clock {
            maximumCanonicalLength = raw.contains(":") ? 5 : 4
        } else {
            maximumCanonicalLength = raw.contains(":") ? 4 : 3
        }
        guard raw.count > maximumCanonicalLength else { return nil }

        // This is strictly over-length edge-artifact recovery.
        if interpretRawSequenceBase(raw, key: key) != nil { return nil }

        let characters = Array(raw)
        guard characters.count > 1 else { return nil }
        let trimmedCandidates = [
            String(characters.dropFirst()),
            String(characters.dropLast())
        ]
        var values = Set<String>()
        for candidate in trimmedCandidates where !candidate.isEmpty {
            if key == .clock,
               let periodStart = uniqueClosedLoopPeriodStartCandidate(candidate) {
                values.insert(periodStart)
                continue
            }
            if let direct = interpretRawSequenceBase(candidate, key: key) {
                values.insert(direct)
            }
        }
        guard values.count == 1 else { return nil }
        return values.first
    }

    private static func uniqueClosedLoopPeriodStartCandidate(_ raw: String) -> String? {
        guard !raw.isEmpty,
              !raw.contains("?"),
              raw.filter({ $0 == ":" }).count <= 1 else { return nil }
        let characters = Array(raw)
        let replaceable = characters.indices.filter { index in
            index > characters.startIndex && characters[index] == "8"
        }
        guard !replaceable.isEmpty, replaceable.count <= 5 else { return nil }

        let standardStarts: Set<String> = ["5:00", "10:00", "15:00", "20:00"]
        var matches: Set<String> = []
        let combinationCount = 1 << replaceable.count
        for mask in 1..<combinationCount {
            var candidateCharacters = characters
            for (bit, index) in replaceable.enumerated() where (mask & (1 << bit)) != 0 {
                candidateCharacters[index] = "0"
            }
            let candidateRaw = String(candidateCharacters)
            if let value = interpretRawSequenceBase(candidateRaw, key: .clock),
               standardStarts.contains(value) {
                matches.insert(value)
            }
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func interpretRawSequenceBase(_ raw: String, key: OCRRegionKey) -> String? {
        guard !raw.isEmpty, !raw.contains("?") else { return nil }
        let allowedCharacters = CharacterSet(charactersIn: "0123456789:")
        guard raw.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else { return nil }

        switch key {
        case .clock, .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            let colonCount = raw.filter { $0 == ":" }.count
            guard colonCount <= 1 else { return nil }

            let digits: String
            if colonCount == 1 {
                let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      (1...2).contains(parts[0].count),
                      parts[1].count == 2,
                      parts[0].allSatisfy({ $0.isNumber }),
                      parts[1].allSatisfy({ $0.isNumber }) else { return nil }
                digits = String(parts[0]) + String(parts[1])
            } else {
                let expectedDigitCount: ClosedRange<Int> = key == .clock ? 3...4 : 3...3
                guard expectedDigitCount.contains(raw.count),
                      raw.allSatisfy({ $0.isNumber }) else { return nil }
                digits = raw
            }

            let minutesText = String(digits.dropLast(2))
            var secondsText = String(digits.suffix(2))
            guard let minutes = Int(minutesText) else { return nil }
            var seconds = Int(secondsText) ?? -1
            // Build 529: the rink display's closed-loop zero can be classified as
            // hole-topology 8. In the tens-of-seconds slot, 8 is structurally
            // impossible. Repair only that exact position (8x -> 0x); the trusted
            // Clock continuity authority still rejects implausible jumps.
            if seconds >= 60, secondsText.first == "8", let units = secondsText.last, units.isNumber {
                secondsText = "0" + String(units)
                seconds = Int(secondsText) ?? -1
            }
            guard (0...59).contains(seconds) else { return nil }
            let value = String(format: "%d:%02d", minutes, seconds)
            return key == .clock
                ? (OCRValidationEngine.isValidGameClock(value) ? value : nil)
                : (OCRValidationEngine.isValidPenaltyTime(value) ? value : nil)

        case .period:
            guard raw.count == 1,
                  raw.allSatisfy({ $0.isNumber }),
                  let digit = raw.first,
                  ["1", "2", "3", "4", "5"].contains(String(digit)) else { return nil }
            return String(digit)

        case .homeScore, .awayScore, .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            guard raw.count <= 2,
                  raw.allSatisfy({ $0.isNumber }),
                  let number = Int(raw),
                  (0...99).contains(number) else { return nil }
            return String(number)

        default:
            return nil
        }
    }

    private struct RawRaster {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    private struct NamedMask {
        let label: String
        let mask: [Bool]
    }


    private static func strictCellConsensus(
        raster: RawRaster,
        key: OCRRegionKey,
        slots: [CGRect],
        colourProfile: OCRZoneColourProfile,
        deadlineUptimeNanoseconds: UInt64?
    ) -> ParsedValue? {
        guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }

        let digitIndexes: [Int]
        let colonIndex: Int?
        switch key {
        case .clock:
            guard slots.count == 5 else { return nil }
            digitIndexes = [0, 1, 3, 4]
            colonIndex = 2
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            guard slots.count == 4 else { return nil }
            digitIndexes = [0, 2, 3]
            colonIndex = 1
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            guard slots.count == 2 else { return nil }
            digitIndexes = [0, 1]
            colonIndex = nil
        case .homeScore, .awayScore, .period:
            guard slots.count == 1 else { return nil }
            digitIndexes = [0]
            colonIndex = nil
        default:
            return nil
        }

        let rawColour = colourMask(raster: raster, key: key, colourProfile: colourProfile)
        let rawContrast = adaptiveContrastMask(raster: raster, colourProfile: colourProfile, slots: slots)
        let colour = cellRestrictedMask(
            rawColour,
            width: raster.width,
            height: raster.height,
            slots: slots,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        let contrast = cellRestrictedMask(
            rawContrast,
            width: raster.width,
            height: raster.height,
            slots: slots,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }

        if let colonIndex {
            guard colonIndex < slots.count,
                  colonPresent(mask: colour, width: raster.width, height: raster.height, slot: slots[colonIndex]),
                  colonPresent(mask: contrast, width: raster.width, height: raster.height, slot: slots[colonIndex]) else {
                return nil
            }
        }

        var agreed: [DigitDecode] = []
        agreed.reserveCapacity(digitIndexes.count)
        for index in digitIndexes {
            guard beforeDeadline(deadlineUptimeNanoseconds), index < slots.count else { return nil }
            let slot = slots[index]
            guard let colourDigit = bestFixedDigit(
                mask: colour,
                width: raster.width,
                height: raster.height,
                slot: slot,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ), let contrastDigit = bestFixedDigit(
                mask: contrast,
                width: raster.width,
                height: raster.height,
                slot: slot,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ), colourDigit.digit == contrastDigit.digit else {
                return nil
            }
            agreed.append(
                DigitDecode(
                    digit: colourDigit.digit,
                    confidence: min(colourDigit.confidence, contrastDigit.confidence),
                    fractions: colourDigit.fractions
                )
            )
        }

        if isPlayerKey(key), agreed.count == 2 {
            // A one-digit player number is normally right aligned. A blank first
            // cell is handled before this point by the low-height glyph rejection,
            // so two decoded cells remain a genuine two-digit value.
        }

        let digits = agreed.map { String($0.digit) }.joined()
        let confidence = agreed.map(\.confidence).min() ?? 0
        guard confidence >= 0.52 else { return nil }
        let detail = agreed.map { "\($0.digit)/\(String(format: "%.2f", $0.confidence))" }.joined(separator: ";")

        if isTimerKey(key) {
            let minutesText = String(digits.dropLast(2))
            let secondsText = String(digits.suffix(2))
            guard !minutesText.isEmpty,
                  let minutes = Int(minutesText),
                  let seconds = Int(secondsText),
                  seconds < 60 else { return nil }
            let value = String(format: "%d:%02d", minutes, seconds)
            guard key == .clock
                    ? OCRValidationEngine.isValidGameClock(value)
                    : OCRValidationEngine.isValidPenaltyTime(value) else { return nil }
            return ParsedValue(
                value: value,
                rawText: digits,
                confidence: Float(confidence),
                diagnostic: "core-cell agreement=2/2 layout=\(key == .clock ? "MM:SS" : "M:SS") digits=[\(detail)]"
            )
        }

        guard let value = parseDigitText(digits, key: key) else { return nil }
        return ParsedValue(
            value: value,
            rawText: digits,
            confidence: Float(confidence),
            diagnostic: "core-cell agreement=2/2 digits=[\(detail)]"
        )
    }

    /// Keeps only pixels inside calibrated character cells. This removes the need
    /// for the previous whole-crop connected-component flood fill, which could
    /// delete valid strokes and was the last unbounded section of the parser.
    private static func cellRestrictedMask(
        _ source: [Bool],
        width: Int,
        height: Int,
        slots: [CGRect],
        deadlineUptimeNanoseconds: UInt64?
    ) -> [Bool] {
        var output = [Bool](repeating: false, count: source.count)
        for slot in slots {
            guard beforeDeadline(deadlineUptimeNanoseconds) else { return output }
            let guardX = max(1, Int((slot.width * 0.025).rounded()))
            let guardY = max(1, Int((slot.height * 0.025).rounded()))
            let minX = max(0, Int(slot.minX.rounded(.down)) + guardX)
            let maxX = min(width - 1, Int(slot.maxX.rounded(.up)) - 1 - guardX)
            let minY = max(0, Int(slot.minY.rounded(.down)) + guardY)
            let maxY = min(height - 1, Int(slot.maxY.rounded(.up)) - 1 - guardY)
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                let row = y * width
                for x in minX...maxX where source[row + x] {
                    output[row + x] = true
                }
            }
        }

        // One local speckle-removal pass. A valid anti-aliased stroke has at least
        // one neighbour; isolated glare pixels do not. Colon dots are large enough
        // to remain intact.
        var cleaned = output
        for slot in slots {
            guard beforeDeadline(deadlineUptimeNanoseconds) else { return cleaned }
            let minX = max(1, Int(slot.minX.rounded(.down)))
            let maxX = min(width - 2, Int(slot.maxX.rounded(.up)) - 1)
            let minY = max(1, Int(slot.minY.rounded(.down)))
            let maxY = min(height - 2, Int(slot.maxY.rounded(.up)) - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX where output[y * width + x] {
                    var neighbours = 0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            if output[(y + dy) * width + (x + dx)] { neighbours += 1 }
                        }
                    }
                    if neighbours == 0 { cleaned[y * width + x] = false }
                }
            }
        }
        return cleaned
    }

    private static func colonPresent(
        mask: [Bool],
        width: Int,
        height: Int,
        slot: CGRect
    ) -> Bool {
        let minX = max(0, Int(slot.minX.rounded(.down)))
        let maxX = min(width - 1, Int(slot.maxX.rounded(.up)) - 1)
        let minY = max(0, Int(slot.minY.rounded(.down)))
        let maxY = min(height - 1, Int(slot.maxY.rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return false }
        var active = 0
        var top = 0
        var bottom = 0
        let middle = (minY + maxY) / 2
        for y in minY...maxY {
            for x in minX...maxX where mask[y * width + x] {
                active += 1
                if y < middle { top += 1 } else { bottom += 1 }
            }
        }
        let area = max(1, (maxX - minX + 1) * (maxY - minY + 1))
        let fraction = Double(active) / Double(area)
        return fraction >= 0.018 && fraction <= 0.62 && top >= 2 && bottom >= 2
    }

    private static func rasterise(_ image: CGImage) -> RawRaster? {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 12, sourceHeight > 12 else { return nil }
        let scale = min(1.0, min(640.0 / Double(sourceWidth), 256.0 / Double(sourceHeight)))
        let width = max(13, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(13, Int((Double(sourceHeight) * scale).rounded()))
        guard width * height <= 164_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drew = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? RawRaster(width: width, height: height, rgba: pixels) : nil
    }

    private static func agreementMasks(
        raster: RawRaster,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile,
        slots: [CGRect]
    ) -> [NamedMask] {
        var colour = colourMask(raster: raster, key: key, colourProfile: colourProfile)
        var contrast = adaptiveContrastMask(raster: raster, colourProfile: colourProfile, slots: slots)
        sanitiseMask(&colour, width: raster.width, height: raster.height)
        sanitiseMask(&contrast, width: raster.width, height: raster.height)
        return [NamedMask(label: "colour", mask: colour), NamedMask(label: "contrast", mask: contrast)]
    }

    private static func colourMask(
        raster: RawRaster,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile
    ) -> [Bool] {
        let pipeline = colourProfile.resolvedPipeline(for: key)
        var mask = [Bool](repeating: false, count: raster.width * raster.height)
        for index in mask.indices {
            let offset = index * 4
            let r = Int(raster.rgba[offset])
            let g = Int(raster.rgba[offset + 1])
            let b = Int(raster.rgba[offset + 2])
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            let chroma = maximum - minimum
            let luminance = (77 * r + 150 * g + 29 * b) >> 8
            let brightNeutral = luminance >= 172 && chroma <= 38

            switch pipeline {
            case .redOnBlack:
                mask[index] = r >= 68 && r - g >= 22 && r - b >= 16
            case .yellowWhiteOnBlack:
                let yellow = r >= 78 && g >= 58 && r + g - (2 * b) >= 46 && abs(r - g) <= 105
                mask[index] = yellow || brightNeutral
            case .amberOrangeOnBlack:
                mask[index] = r >= 78 && g >= 34 && r - b >= 30 && r >= g
            case .greenOnBlack:
                mask[index] = g >= 70 && g - r >= 18 && g - b >= 14
            case .blueCyanOnBlack:
                mask[index] = b >= 68 && (b - r >= 16 || g - r >= 18) && max(b, g) - r >= 18
            case .lightOnDark:
                mask[index] = luminance >= 150
            case .darkOnLight:
                mask[index] = luminance <= 92
            case .greyscale:
                mask[index] = colourProfile.backgroundColour.isLight ? luminance <= 96 : luminance >= 148
            case .auto:
                mask[index] = maximum >= 125 && (chroma >= 20 || brightNeutral)
            }
        }
        return mask
    }

    private static func relaxedScoreColourMask(
        raster: RawRaster,
        key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile
    ) -> [Bool] {
        var mask = [Bool](repeating: false, count: raster.width * raster.height)
        let pipeline = colourProfile.resolvedPipeline(for: key)
        for index in mask.indices {
            let offset = index * 4
            let r = Int(raster.rgba[offset])
            let g = Int(raster.rgba[offset + 1])
            let b = Int(raster.rgba[offset + 2])
            let maximum = max(r, max(g, b))
            let minimum = min(r, min(g, b))
            let chroma = maximum - minimum
            let luminance = (77 * r + 150 * g + 29 * b) >> 8
            switch pipeline {
            case .redOnBlack:
                mask[index] = r >= 44 && r - g >= 10 && r - b >= 8
            case .yellowWhiteOnBlack:
                mask[index] = (r >= 52 && g >= 42 && r + g - 2 * b >= 20) || (luminance >= 126 && chroma <= 56)
            case .amberOrangeOnBlack:
                mask[index] = r >= 48 && g >= 24 && r - b >= 14
            case .greenOnBlack:
                mask[index] = g >= 46 && g - r >= 8 && g - b >= 6
            case .blueCyanOnBlack:
                mask[index] = max(b, g) >= 48 && max(b, g) - r >= 8
            case .lightOnDark, .greyscale, .auto:
                mask[index] = luminance >= 96 || (maximum >= 70 && chroma >= 12)
            case .darkOnLight:
                mask[index] = luminance <= 126
            }
        }
        return mask
    }

    private static func neutralScoreContrastMask(
        raster: RawRaster,
        colourProfile: OCRZoneColourProfile
    ) -> [Bool] {
        var intensities: [Int] = []
        intensities.reserveCapacity(raster.width * raster.height)
        for index in 0..<(raster.width * raster.height) {
            let offset = index * 4
            intensities.append(max(Int(raster.rgba[offset]), Int(raster.rgba[offset + 1]), Int(raster.rgba[offset + 2])))
        }
        let sorted = intensities.sorted()
        let lightBackground = colourProfile.backgroundColour.isLight
        let threshold: Int
        if lightBackground {
            threshold = max(28, min(158, percentile(sorted, 0.30) - 5))
        } else {
            let upper = percentile(sorted, 0.82)
            let high = percentile(sorted, 0.94)
            threshold = max(34, min(178, max(upper + 2, high - 42)))
        }
        return intensities.map { lightBackground ? $0 <= threshold : $0 >= threshold }
    }

    private static func adaptiveContrastMask(
        raster: RawRaster,
        colourProfile: OCRZoneColourProfile,
        slots: [CGRect]
    ) -> [Bool] {
        var samples: [Int] = []
        samples.reserveCapacity(max(32, slots.count * 96))
        for slot in slots {
            let minX = max(0, Int(slot.minX.rounded(.down)))
            let maxX = min(raster.width - 1, Int(slot.maxX.rounded(.up)) - 1)
            let minY = max(0, Int(slot.minY.rounded(.down)))
            let maxY = min(raster.height - 1, Int(slot.maxY.rounded(.up)) - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            let xStep = max(1, (maxX - minX + 1) / 16)
            let yStep = max(1, (maxY - minY + 1) / 20)
            for y in stride(from: minY, through: maxY, by: yStep) {
                for x in stride(from: minX, through: maxX, by: xStep) {
                    let offset = (y * raster.width + x) * 4
                    let r = Int(raster.rgba[offset])
                    let g = Int(raster.rgba[offset + 1])
                    let b = Int(raster.rgba[offset + 2])
                    samples.append(max(r, max(g, b)))
                }
            }
        }
        samples.sort()
        let isLightBackground = colourProfile.backgroundColour.isLight
        let threshold: Int
        if samples.isEmpty {
            threshold = isLightBackground ? 96 : 118
        } else if isLightBackground {
            threshold = max(34, min(150, percentile(samples, 0.28) - 8))
        } else {
            let upper = percentile(samples, 0.72)
            let high = percentile(samples, 0.88)
            let upperMid = percentile(samples, 0.82)
            threshold = max(48, min(175, max(upper + 4, upperMid - 24, high - 50)))
        }

        var mask = [Bool](repeating: false, count: raster.width * raster.height)
        for index in mask.indices {
            let offset = index * 4
            let r = Int(raster.rgba[offset])
            let g = Int(raster.rgba[offset + 1])
            let b = Int(raster.rgba[offset + 2])
            let intensity = max(r, max(g, b))
            mask[index] = isLightBackground ? intensity <= threshold : intensity >= threshold
        }
        return mask
    }

    private static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let clamped = max(0, min(1, fraction))
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * clamped).rounded()))
        return sorted[index]
    }

    private static func decode(
        mask: [Bool],
        width: Int,
        height: Int,
        key: OCRRegionKey,
        slots: [CGRect],
        variant: String,
        deadlineUptimeNanoseconds: UInt64?
    ) -> ParsedValue? {
        guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }
        let digitSlotIndexes: [Int]
        switch key {
        case .clock:
            guard slots.count == 5 else { return nil }
            digitSlotIndexes = [0, 1, 3, 4]
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            guard slots.count == 4 else { return nil }
            digitSlotIndexes = [0, 2, 3]
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            guard slots.count == 2 else { return nil }
            digitSlotIndexes = [0, 1]
        case .homeScore, .awayScore, .period:
            guard slots.count == 1 else { return nil }
            digitSlotIndexes = [0]
        default:
            return nil
        }

        var decoded: [DigitDecode?] = []
        decoded.reserveCapacity(digitSlotIndexes.count)
        for index in digitSlotIndexes {
            guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }
            decoded.append(bestFixedDigit(
                mask: mask,
                width: width,
                height: height,
                slot: slots[index],
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ))
        }

        if isTimerKey(key) {
            guard decoded.allSatisfy({ $0 != nil }) else { return nil }
            let values = decoded.compactMap { $0 }
            let digits = values.map { String($0.digit) }.joined()
            let minutesText = String(digits.dropLast(2))
            let secondsText = String(digits.suffix(2))
            guard let minutes = Int(minutesText), let seconds = Int(secondsText), seconds < 60 else { return nil }
            let value = String(format: "%d:%02d", minutes, seconds)
            guard key == .clock ? OCRValidationEngine.isValidGameClock(value) : OCRValidationEngine.isValidPenaltyTime(value) else { return nil }
            let confidence = values.map(\.confidence).min() ?? 0
            guard confidence >= 0.58 else { return nil }
            let detail = values.map { "\($0.digit)/\(String(format: "%.2f", $0.confidence))" }.joined(separator: ";")
            let layout = key == .clock ? "MM:SS" : "M:SS"
            return ParsedValue(
                value: value,
                rawText: digits,
                confidence: Float(confidence),
                diagnostic: "\(variant) layout=\(layout) slots=\(slots.count) digits=[\(detail)] agreedGeometry=true"
            )
        }

        if isPlayerKey(key), decoded.first == nil, let right = decoded.last ?? nil {
            decoded = [right]
        }
        guard decoded.allSatisfy({ $0 != nil }) else { return nil }
        let values = decoded.compactMap { $0 }
        let digits = values.map { String($0.digit) }.joined()
        guard let value = parseDigitText(digits, key: key) else { return nil }
        let confidence = values.map(\.confidence).min() ?? 0
        guard confidence >= 0.60 else { return nil }
        let detail = values.map { "\($0.digit)/\(String(format: "%.2f", $0.confidence))" }.joined(separator: ";")
        return ParsedValue(
            value: value,
            rawText: digits,
            confidence: Float(confidence),
            diagnostic: "\(variant) slots=\(slots.count) digits=[\(detail)] agreedGeometry=true"
        )
    }

    @inline(__always)
    private static func beforeDeadline(_ deadlineUptimeNanoseconds: UInt64?) -> Bool {
        guard let deadlineUptimeNanoseconds else { return true }
        return DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds
    }

    /// Removes the scoreboard cell border before digit classification.
    ///
    /// The UX16d2e failure showed clear crops being decoded as 1->9, 0->8 and
    /// period 1->2. The common cause was that long white box edges and screen glare
    /// were entering the seven-segment samples as lit strokes. This function removes
    /// only edge bands and edge-connected/line-like components; central digit strokes
    /// remain untouched. The work is bounded by the small field crop dimensions.
    private static func sanitiseMask(_ mask: inout [Bool], width: Int, height: Int) {
        guard width > 8, height > 8 else { return }
        let edgeX = max(1, Int(Double(width) * 0.025))
        let edgeY = max(1, Int(Double(height) * 0.025))

        for y in 0..<height {
            var rowCount = 0
            for x in 0..<width where mask[y * width + x] { rowCount += 1 }
            let nearHorizontalEdge = y < max(edgeY * 4, height / 5) || y >= min(height - edgeY * 4, height * 4 / 5)
            if nearHorizontalEdge && Double(rowCount) / Double(width) > 0.82 {
                for x in 0..<width { mask[y * width + x] = false }
            }
        }

        for x in 0..<width {
            var columnCount = 0
            for y in 0..<height where mask[y * width + x] { columnCount += 1 }
            let nearVerticalEdge = x < max(edgeX * 4, width / 5) || x >= min(width - edgeX * 4, width * 4 / 5)
            if nearVerticalEdge && Double(columnCount) / Double(height) > 0.82 {
                for y in 0..<height { mask[y * width + x] = false }
            }
        }

        // The actual scoreboard digits sit well inside the calibrated field cells.
        // Clear a very small outer guard so a crop-edge reflection cannot become a
        // left/right segment. This is deliberately much smaller than the zone padding.
        for y in 0..<height {
            for x in 0..<width where x < edgeX || x >= width - edgeX || y < edgeY || y >= height - edgeY {
                mask[y * width + x] = false
            }
        }

        var visited = [Bool](repeating: false, count: mask.count)
        let neighbours = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for start in 0..<mask.count where mask[start] && !visited[start] {
            var queue = [start]
            visited[start] = true
            var component: [Int] = []
            var minX = width, minY = height, maxX = -1, maxY = -1
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                component.append(index)
                let x = index % width
                let y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in neighbours {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if mask[next] && !visited[next] {
                        visited[next] = true
                        queue.append(next)
                    }
                }
            }

            let componentWidth = maxX - minX + 1
            let componentHeight = maxY - minY + 1
            let touchesGuard = minX <= edgeX || maxX >= width - edgeX - 1 || minY <= edgeY || maxY >= height - edgeY - 1
            let horizontalLine = componentWidth > Int(Double(width) * 0.82) && componentHeight < max(3, Int(Double(height) * 0.12))
            let verticalLine = componentHeight > Int(Double(height) * 0.82) && componentWidth < max(3, Int(Double(width) * 0.10)) && touchesGuard
            let tooSmall = component.count < max(3, Int(Double(width * height) * 0.0008))
            if (touchesGuard && (horizontalLine || verticalLine)) || tooSmall {
                for index in component { mask[index] = false }
            }
        }
    }

    private static func parseDigitText(_ digits: String, key: OCRRegionKey) -> String? {
        guard !digits.isEmpty else { return nil }
        switch key {
        case .period:
            guard let digit = digits.first, ["1", "2", "3", "4", "5"].contains(String(digit)) else { return nil }
            return String(digit)
        case .homeScore, .awayScore, .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            let clipped = String(digits.prefix(2))
            guard let number = Int(clipped), (0...99).contains(number) else { return nil }
            return String(number)
        default:
            return nil
        }
    }

    private static func activeFraction(mask: [Bool], width: Int, height: Int, digitRect: CGRect, sample: CGRect) -> Double {
        let minX = max(0, Int((digitRect.minX + sample.minX * digitRect.width).rounded(.down)))
        let maxX = min(width - 1, Int((digitRect.minX + sample.maxX * digitRect.width).rounded(.up)))
        let minY = max(0, Int((digitRect.minY + sample.minY * digitRect.height).rounded(.down)))
        let maxY = min(height - 1, Int((digitRect.minY + sample.maxY * digitRect.height).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return 0 }
        var active = 0
        var total = 0
        for y in minY...maxY {
            for x in minX...maxX {
                total += 1
                if mask[y * width + x] { active += 1 }
            }
        }
        return total > 0 ? Double(active) / Double(total) : 0
    }

    private static func slotRect(_ slot: OCRRegion, width: Int, height: Int) -> CGRect {
        let x = max(0, min(CGFloat(width - 1), slot.x * CGFloat(width)))
        let y = max(0, min(CGFloat(height - 1), slot.y * CGFloat(height)))
        let w = max(2, min(CGFloat(width) - x, slot.width * CGFloat(width)))
        let h = max(6, min(CGFloat(height) - y, slot.height * CGFloat(height)))
        return CGRect(x: x, y: y, width: w, height: h).integral
    }

    /// Small bounded local alignment search around the persisted cell. The slot
    /// remains authoritative; the search only absorbs camera anti-aliasing and a
    /// few pixels of calibration drift and never derives geometry from lit strokes.
    private static func bestFixedDigit(
        mask: [Bool],
        width: Int,
        height: Int,
        slot: CGRect,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> DigitDecode? {
        let dx = max(1.0, slot.width * 0.08)
        // UX16d4 Build 503: active-bounds normalisation already absorbs vertical
        // anti-aliasing and scale drift. The previous nine-position search repeated
        // the full glyph library up to nine times per digit and routinely consumed
        // the entire 0.42-0.65s live budget. Keep only the authoritative cell plus
        // one bounded left/right correction large enough for saved-slot drift.
        let offsets: [(CGFloat, CGFloat)] = [
            (0, 0), (-2 * dx, 0), (2 * dx, 0)
        ]
        var best: DigitDecode?
        for (xOffset, yOffset) in offsets {
            guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }
            let shifted = slot.offsetBy(dx: xOffset, dy: yOffset)
            let candidate = shifted.insetBy(dx: -slot.width * 0.025, dy: -slot.height * 0.015)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard candidate.width > 2, candidate.height > 6,
                  let decoded = decodeFixedDigit(
                    mask: mask,
                    width: width,
                    height: height,
                    rect: candidate,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                  ) else { continue }
            if best == nil || decoded.confidence > (best?.confidence ?? 0) { best = decoded }
        }
        return best
    }

    private struct GlyphReference {
        let digit: Int
        let rows: [String]
        let width: Int
        let height: Int
        let pixels: [Bool]

        init(digit: Int, rows: [String]) {
            self.digit = digit
            self.rows = rows
            self.width = rows.first?.count ?? 0
            self.height = rows.count
            self.pixels = rows.flatMap { row in row.map { $0 == "1" } }
        }
    }

    /// Legacy real-camera glyphs retained only for the fixed-cell diagnostics entry
    /// point above. UX16d6 production dynamic-token recognition does not consult
    /// these rink-specific examples; it uses segment topology first and generic
    /// aspect-preserving shapes only as a secondary fallback.
    private static let realFrameGlyphReferences: [GlyphReference] = [
        GlyphReference(digit: 1, rows: [
            "000001111000","000011111000","001111111000","011111111000","011111111000",
            "011101111000","000001111000","000001111000","000001111000","000001111000",
            "000001111000","000001111000","000001110000","000001110000","000001110000",
            "000011111000","111111111111","111111111111","111111111111","011111111111"
        ]),
        GlyphReference(digit: 1, rows: [
            "000000011110","000001111111","001111111111","011111111110","011111111110",
            "111111111110","001111111110","000001111110","000001111110","000001111110",
            "000001111110","000001111100","000001111100","000001111100","000011111100",
            "000011111100","000011111100","000011111100","000011111100","000011111000"
        ]),
        GlyphReference(digit: 9, rows: [
            "000011110000","000111111100","001111111110","011111111110","111110011111",
            "111100001111","111100001111","111100001111","111100001111","111111111111",
            "011111111111","001111111111","000111111111","000000001110","000000011110",
            "000000111110","011111111100","111111111000","111111110000","011111000000"
        ]),
        GlyphReference(digit: 0, rows: [
            "000011111000","000111111100","001111111110","011111111110","011110001111",
            "011100001111","111100001111","111100111111","111001111111","111111111111",
            "111111111111","111111101111","111111001111","111100001111","111100001110",
            "111100011110","011111111110","011111111100","001111111000","000111110000"
        ]),
        GlyphReference(digit: 0, rows: [
            "000011110000","000111111100","001111111100","011111111110","011111111110",
            "011110011111","111110011111","111110011111","111100011111","111100011111",
            "111100011111","111100011111","111100011111","111100011111","111110011110",
            "011111111110","011111111100","011111111100","001111111000","000011110000"
        ]),
        GlyphReference(digit: 8, rows: [
            "000011111000","000111111110","001111111110","011111111111","011110001111",
            "011110001111","011110001111","011111111110","001111111110","001111111100",
            "001111111110","011111111110","011110011111","111100001111","111100001111",
            "111100001111","111111111110","011111111110","001111111100","000111110000"
        ]),
        GlyphReference(digit: 4, rows: [
            "000000011100","000000111100","000001111100","000001111100","000011111100",
            "000011111100","000111111100","000111111100","001111011100","011110111100",
            "011110011100","111110111100","111111111111","111111111111","111111111111",
            "011111111111","000000111100","000000111100","000000111000","000000011000"
        ]),
        GlyphReference(digit: 4, rows: [
            "000000111110","000001111110","000001111110","000011111110","000111111110",
            "000111111110","001111111110","001111111110","011111111110","011111111110",
            "111110111110","111111111111","111111111111","111111111111","111111111111",
            "111111111111","000000111110","000000111100","000000111100","000000111100"
        ]),
        GlyphReference(digit: 5, rows: [
            "000101000000","001111111111","001111111111","001111111111","001111111110",
            "011111000000","011110000000","011111110000","011111111100","011111111110",
            "001111111111","000000011111","000000001111","000000001111","000000011111",
            "011111111111","111111111110","111111111100","111111111000","000000000000"
        ]),
        GlyphReference(digit: 5, rows: [
            "000111111111","000111111111","000111111111","000111111111","000111111111",
            "000111100000","001111100000","001111111100","001111111110","001111111111",
            "000111111111","000000001111","100000001111","100000001111","100000001111",
            "001111111111","001111111111","011111111110","011111111100","001111111000"
        ])
    ]

    private static let genericGlyphReferences: [GlyphReference] = {
        let patterns: [Int: [String]] = [
            0: ["01110","10001","10011","10101","11001","10001","01110"],
            1: ["00100","01100","00100","00100","00100","00100","01110"],
            2: ["01110","10001","00001","00010","00100","01000","11111"],
            3: ["11110","00001","00001","01110","00001","00001","11110"],
            4: ["00010","00110","01010","10010","11111","00010","00010"],
            5: ["11111","10000","10000","11110","00001","00001","11110"],
            6: ["01110","10000","10000","11110","10001","10001","01110"],
            7: ["11111","00001","00010","00100","01000","01000","01000"],
            8: ["01110","10001","10001","01110","10001","10001","01110"],
            9: ["01110","10001","10001","01111","00001","00001","01110"]
        ]
        return patterns.keys.sorted().compactMap { digit in
            guard let rows = patterns[digit] else { return nil }
            return GlyphReference(digit: digit, rows: expandGlyph(rows, targetWidth: 12, targetHeight: 20))
        }
    }()

    private static let allGlyphReferences: [GlyphReference] =
        realFrameGlyphReferences + genericGlyphReferences

    private static func expandGlyph(_ rows: [String], targetWidth: Int, targetHeight: Int) -> [String] {
        guard let sourceWidth = rows.first?.count, sourceWidth > 0, !rows.isEmpty else { return [] }
        return (0..<targetHeight).map { targetY in
            let sourceY = min(rows.count - 1, targetY * rows.count / targetHeight)
            let source = Array(rows[sourceY])
            return String((0..<targetWidth).map { targetX in
                let sourceX = min(sourceWidth - 1, targetX * sourceWidth / targetWidth)
                return source[sourceX]
            })
        }
    }

    private static func decodeRealFrameGlyph(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> DigitDecode? {
        guard let glyph = normalisedGlyph(mask: mask, width: width, height: height, rect: rect) else { return nil }
        var bestByDigit: [Int: Double] = [:]
        for reference in allGlyphReferences {
            guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }
            let score = glyphSimilarity(
                glyph,
                reference: reference.pixels,
                width: reference.width,
                height: reference.height
            )
            bestByDigit[reference.digit] = max(bestByDigit[reference.digit] ?? 0, score)
        }
        let ranked = bestByDigit.map { (digit: $0.key, score: $0.value) }.sorted { $0.score > $1.score }
        guard let best = ranked.first, let second = ranked.dropFirst().first else { return nil }
        let margin = best.score - second.score
        guard best.score >= 0.52, margin >= 0.020 else { return nil }
        return DigitDecode(digit: best.digit, confidence: min(0.98, best.score), fractions: [])
    }

    private static func normalisedGlyph(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        targetWidth: Int = 12,
        targetHeight: Int = 20
    ) -> [Bool]? {
        let minX = max(0, Int(rect.minX.rounded(.down)))
        let maxX = min(width - 1, Int(rect.maxX.rounded(.up)) - 1)
        let minY = max(0, Int(rect.minY.rounded(.down)))
        let maxY = min(height - 1, Int(rect.maxY.rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return nil }

        var activeMinX = width, activeMaxX = -1, activeMinY = height, activeMaxY = -1, activeCount = 0
        for y in minY...maxY {
            for x in minX...maxX where mask[y * width + x] {
                activeMinX = min(activeMinX, x); activeMaxX = max(activeMaxX, x)
                activeMinY = min(activeMinY, y); activeMaxY = max(activeMaxY, y)
                activeCount += 1
            }
        }
        guard activeCount >= 8, activeMinX <= activeMaxX, activeMinY <= activeMaxY else { return nil }
        let sourceWidth = max(1, activeMaxX - activeMinX + 1)
        let sourceHeight = max(1, activeMaxY - activeMinY + 1)
        let slotHeight = max(1.0, rect.height)
        // A blank scoreboard cell is commonly rendered as one or two horizontal
        // dashes. Reject that low-height band before any digit comparison so
        // `--` can never become player 11/00 or a penalty timer.
        if CGFloat(sourceHeight) < slotHeight * 0.34, sourceWidth > sourceHeight {
            return nil
        }
        var output = [Bool](repeating: false, count: targetWidth * targetHeight)
        for targetY in 0..<targetHeight {
            let y0 = activeMinY + targetY * sourceHeight / targetHeight
            let y1 = min(activeMaxY, activeMinY + ((targetY + 1) * sourceHeight / targetHeight))
            for targetX in 0..<targetWidth {
                let x0 = activeMinX + targetX * sourceWidth / targetWidth
                let x1 = min(activeMaxX, activeMinX + ((targetX + 1) * sourceWidth / targetWidth))
                var active = 0, total = 0
                if y0 <= y1, x0 <= x1 {
                    for y in y0...y1 {
                        for x in x0...x1 {
                            total += 1
                            if mask[y * width + x] { active += 1 }
                        }
                    }
                }
                output[targetY * targetWidth + targetX] = total > 0 && Double(active) / Double(total) >= 0.22
            }
        }
        return output
    }

    private static func glyphSimilarity(
        _ glyph: [Bool],
        reference: [Bool],
        width: Int,
        height: Int
    ) -> Double {
        guard width > 0, height > 0,
              glyph.count == width * height,
              reference.count == glyph.count else { return 0 }

        // UX16d4 Build 503: the reference bitmap is precomputed once and the
        // normalised cell is compared at the centre plus four cardinal one-pixel
        // shifts. Diagonal shifts duplicated work without improving any supplied
        // real-frame result and were a major source of live deadline expiry.
        let shifts = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]
        var best = 0.0
        for (dx, dy) in shifts {
            var intersection = 0
            var glyphActive = 0
            var referenceActive = 0
            for y in 0..<height {
                for x in 0..<width {
                    let g = glyph[y * width + x]
                    let rx = x - dx
                    let ry = y - dy
                    let r = rx >= 0 && rx < width && ry >= 0 && ry < height
                        ? reference[ry * width + rx]
                        : false
                    if g { glyphActive += 1 }
                    if r { referenceActive += 1 }
                    if g && r { intersection += 1 }
                }
            }
            let denominator = glyphActive + referenceActive
            if denominator > 0 {
                best = max(best, (2.0 * Double(intersection)) / Double(denominator))
            }
        }
        return best
    }

    private static func decodeFixedDigit(
        mask: [Bool],
        width: Int,
        height: Int,
        rect: CGRect,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> DigitDecode? {
        guard beforeDeadline(deadlineUptimeNanoseconds) else { return nil }
        if let glyph = decodeRealFrameGlyph(
            mask: mask,
            width: width,
            height: height,
            rect: rect,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        ) {
            return glyph
        }

        // Seven-segment occupancy remains a bounded fallback for physical rink
        // displays. The real-frame glyph library above owns connected/mock-font
        // digits such as the supplied 19:08 / 45 scoreboard.
        let sampleRect = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.035)
        guard sampleRect.width > 2, sampleRect.height > 6 else { return nil }
        let segmentRects = [
            CGRect(x: 0.18, y: 0.00, width: 0.64, height: 0.19),
            CGRect(x: 0.00, y: 0.13, width: 0.24, height: 0.34),
            CGRect(x: 0.76, y: 0.13, width: 0.24, height: 0.34),
            CGRect(x: 0.18, y: 0.40, width: 0.64, height: 0.20),
            CGRect(x: 0.00, y: 0.53, width: 0.24, height: 0.34),
            CGRect(x: 0.76, y: 0.53, width: 0.24, height: 0.34),
            CGRect(x: 0.18, y: 0.81, width: 0.64, height: 0.19)
        ]
        let fractions = segmentRects.map {
            activeFraction(mask: mask, width: width, height: height, digitRect: sampleRect, sample: $0)
        }
        let templates: [(Int, [Bool])] = [
            (0, [true, true, true, false, true, true, true]),
            (1, [false, false, true, false, false, true, false]),
            (2, [true, false, true, true, true, false, true]),
            (3, [true, false, true, true, false, true, true]),
            (4, [false, true, true, true, false, true, false]),
            (5, [true, true, false, true, false, true, true]),
            (6, [true, true, false, true, true, true, true]),
            (7, [true, false, true, false, false, true, false]),
            (8, [true, true, true, true, true, true, true]),
            (9, [true, true, true, true, false, true, true])
        ]
        var ranked: [(digit: Int, score: Double)] = []
        for (digit, template) in templates {
            var score = 0.0
            var onValues: [Double] = []
            var offValues: [Double] = []
            for (index, shouldBeOn) in template.enumerated() {
                let fraction = min(1, max(0, fractions[index]))
                if shouldBeOn {
                    onValues.append(fraction)
                    score += min(1, fraction * 2.8)
                } else {
                    offValues.append(fraction)
                    score += max(0, 1 - fraction * 3.0)
                }
            }
            let onMean = onValues.reduce(0, +) / Double(max(1, onValues.count))
            let offMean = offValues.reduce(0, +) / Double(max(1, offValues.count))
            score += max(-1.0, min(1.0, (onMean - offMean) * 2.0))
            ranked.append((digit, score))
        }
        ranked.sort { $0.score > $1.score }
        guard let first = ranked.first, let second = ranked.dropFirst().first else { return nil }
        let margin = first.score - second.score
        let normalized = max(0, min(1, first.score / 8.0))
        let marginScore = max(0, min(1, margin / 1.8))
        let confidence = normalized * 0.72 + marginScore * 0.28
        guard normalized >= 0.54, margin >= 0.38, confidence >= 0.56 else { return nil }
        return DigitDecode(digit: first.digit, confidence: confidence, fractions: fractions)
    }

    private static func isPlayerKey(_ key: OCRRegionKey) -> Bool {
        switch key {
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return true
        default:
            return false
        }
    }

    private static func isScoreKey(_ key: OCRRegionKey) -> Bool {
        key == .homeScore || key == .awayScore
    }

    private static func isTimerKey(_ key: OCRRegionKey) -> Bool {
        switch key {
        case .clock, .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return true
        default:
            return false
        }
    }
}
