// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreGraphics

/// Timer-focused recogniser for seven-segment scoreboard clocks.
///
/// This is intentionally separate from Vision/ML Kit text OCR. It treats timer
/// fields as lit-segment patterns and returns only complete M:SS / MM:SS values.
/// Partial reads such as ":", ":43", "2" or "43" are not valid timer results.
nonisolated struct SevenSegmentTimerRecognitionResult {
    let value: String
    let confidence: Float
    let rawDigits: String
    let layout: String
    let diagnostic: String
    let segmentRects: [CGRect]
}

nonisolated struct SevenSegmentDigitSequenceResult {
    let value: String
    let confidence: Float
    let rawDigits: String
    let diagnostic: String
    let segmentRects: [CGRect]
}

private struct SevenSegmentComponent {
    let rect: CGRect
    let fill: Double
    let kind: String
}

nonisolated struct SevenSegmentTimerRecognizer {
    func recogniseDigitSequence(from image: CGImage, maxDigits: Int = 2, allowSingleDigit: Bool = true) -> SevenSegmentDigitSequenceResult? {
        let candidateImages = timerCandidateImages(from: image)
        var best: SevenSegmentDigitSequenceResult?
        for candidateImage in candidateImages {
            // UX16a: use the known scoreboard field shape first. Score/player/period
            // fields are not free-form text; they are fixed digit cells inside a saved
            // zone. This prevents a visible two-digit crop such as "45" being reduced
            // to one merged component and confidently accepted as "8".
            if let template = recogniseDigitSequenceByTemplateSlots(from: candidateImage, maxDigits: maxDigits, allowSingleDigit: allowSingleDigit) {
                if template.rawDigits.count >= 2 || template.confidence >= 0.78 {
                    return template
                }
                if best == nil || template.confidence > best!.confidence { best = template }
            }
            if let component = recogniseDigitSequenceByComponents(from: candidateImage, maxDigits: maxDigits, allowSingleDigit: allowSingleDigit) {
                if best == nil || component.confidence > best!.confidence { best = component }
            }
            if let fixed = recogniseDigitSequenceByFixedSlots(from: candidateImage, maxDigits: maxDigits, allowSingleDigit: allowSingleDigit) {
                if best == nil || fixed.confidence > best!.confidence { best = fixed }
            }
        }
        return best
    }

    /// UX16d2e live-bounded digit reader.
    ///
    /// Continuous OCR must have a fixed amount of deterministic work. This path
    /// tries at most two crop variants and three finite seven-segment layouts per
    /// variant. It never calls Vision or ML Kit and does not enumerate unbounded
    /// preprocessing or orientation fallbacks.
    func recogniseDigitSequenceBounded(
        from image: CGImage,
        maxDigits: Int = 2,
        allowSingleDigit: Bool = true
    ) -> SevenSegmentDigitSequenceResult? {
        let candidateImages = Array(timerCandidateImages(from: image).prefix(2))
        var best: SevenSegmentDigitSequenceResult?

        for candidateImage in candidateImages {
            if let template = recogniseDigitSequenceByTemplateSlots(
                from: candidateImage,
                maxDigits: maxDigits,
                allowSingleDigit: allowSingleDigit
            ) {
                if best == nil || template.confidence > best!.confidence { best = template }
                if template.rawDigits.count >= 2 && template.confidence >= 0.72 { return template }
                if template.rawDigits.count == 1 && template.confidence >= 0.84 { return template }
            }

            if let fixed = recogniseDigitSequenceByFixedSlots(
                from: candidateImage,
                maxDigits: maxDigits,
                allowSingleDigit: allowSingleDigit
            ) {
                if best == nil || fixed.confidence > best!.confidence { best = fixed }
                if fixed.confidence >= 0.84 { return fixed }
            }

            // One component pass is retained for thin or partially joined LED
            // strokes, but it is the final bounded attempt rather than an open-ended
            // recovery path.
            if let component = recogniseDigitSequenceByComponents(
                from: candidateImage,
                maxDigits: maxDigits,
                allowSingleDigit: allowSingleDigit
            ) {
                if best == nil || component.confidence > best!.confidence { best = component }
                if component.confidence >= 0.84 { return component }
            }
        }
        return best
    }

    func segmentationDiagnostic(from image: CGImage) -> String {
        guard let bitmap = grayscaleBitmap(from: image) else { return "bitmap=nil" }
        let brightComponents = segmentedComponents(in: bitmap, mode: .bright)
        let darkComponents = segmentedComponents(in: bitmap, mode: .dark)
        let brightActive = activePixelSummary(in: bitmap, mode: .bright)
        let darkActive = activePixelSummary(in: bitmap, mode: .dark)
        let brightRaw = rawComponentDebug(in: bitmap, mode: .bright)
        let darkRaw = rawComponentDebug(in: bitmap, mode: .dark)
        return "image=\(image.width)x\(image.height) bright{\(brightActive) comps=\(componentSummary(brightComponents)) raw=[\(brightRaw)]} dark{\(darkActive) comps=\(componentSummary(darkComponents)) raw=[\(darkRaw)]}"
    }

    func previewSegmentRectsForTimer(from image: CGImage, allowTwoMinuteDigits: Bool = true) -> [CGRect] {
        // UX15p: the preview must show one tile per expected timer character.
        // Prefer the same strict character-slot builder used by recognition so the
        // Segments panel exposes [M][:][S][S] or [M][M][:][S][S], never merged blobs.
        if let strict = strictTimerCharacterSlotCandidates(from: image, allowTwoMinuteDigits: allowTwoMinuteDigits).first {
            return strict.rects
        }
        let layout: TimerLayout = allowTwoMinuteDigits ? .mmss : .mss
        return strictFallbackCharacterRects(layout: layout)
    }

    func previewSegmentRectsForDigits(from image: CGImage, maxDigits: Int = 2, allowSingleDigit: Bool = true) -> [CGRect] {
        if let result = recogniseDigitSequence(from: image, maxDigits: maxDigits, allowSingleDigit: allowSingleDigit), !result.segmentRects.isEmpty {
            return result.segmentRects
        }
        let count = max(allowSingleDigit ? 1 : 2, min(maxDigits, max(1, Int((CGFloat(image.width) / max(CGFloat(image.height), 1) / 0.55).rounded()))))
        return (0..<count).map { index in
            CGRect(x: CGFloat(index) / CGFloat(count), y: 0, width: 1.0 / CGFloat(count), height: 1).insetBy(dx: 0.025, dy: 0.06)
        }
    }

    /// UX16d2e live-bounded timer reader.
    ///
    /// The authoritative scoreboard has a visible colon and fixed M:SS/MM:SS
    /// cells. Prefer the colon-anchored layout, then one full-crop fixed-slot
    /// attempt. The number of images and layouts is finite so a clock field cannot
    /// occupy the single OCR executor for several seconds.
    func recogniseTimerBounded(
        from image: CGImage,
        allowTwoMinuteDigits: Bool = true
    ) -> SevenSegmentTimerRecognitionResult? {
        let candidateImages = Array(timerCandidateImages(from: image).prefix(2))
        let layouts: [TimerLayout] = allowTwoMinuteDigits ? [.mmss, .mss] : [.mss]
        var best: SevenSegmentTimerRecognitionResult?

        func consider(_ result: SevenSegmentTimerRecognitionResult) {
            if best == nil || result.confidence > best!.confidence {
                best = result
            }
        }

        for candidateImage in candidateImages {
            for layout in layouts {
                if let result = recogniseTimerByColonAnchor(from: candidateImage, layout: layout) {
                    consider(result)
                    if layout == .mmss, result.rawDigits.count == 4, result.confidence >= 0.58 {
                        return result
                    }
                    if layout == .mss, result.rawDigits.count == 3, result.confidence >= 0.72 {
                        return result
                    }
                }
            }

            for layout in layouts {
                if let result = recogniseTimer(from: candidateImage, layout: layout) {
                    consider(result)
                    if result.confidence >= 0.82 { return result }
                }
            }
        }
        return best
    }

    func recogniseTimer(from image: CGImage, allowTwoMinuteDigits: Bool = true) -> SevenSegmentTimerRecognitionResult? {
        let candidateImages = timerCandidateImages(from: image)
        var best: SevenSegmentTimerRecognitionResult?

        for candidateImage in candidateImages {
            // UX15p: selected timer reads must be built from strict character slots.
            // Do not accept a timer if the slot builder cannot produce exactly
            // M:SS or MM:SS tiles. This prevents visually clean crops such as 19:34
            // being accepted as 11:17/0:03 from merged or partial slot groups.
            let strictCandidates = strictTimerCharacterSlotCandidates(from: candidateImage, allowTwoMinuteDigits: allowTwoMinuteDigits)
            for candidate in strictCandidates {
                if let strict = recogniseTimerUsingStrictCharacterSlots(image: candidateImage, candidate: candidate) {
                    if best == nil || strict.confidence > best!.confidence {
                        best = strict
                    }
                }
            }

            if best == nil {
                // Keep older paths as a last resort only when no strict timer slot
                // candidate can decode. These paths still include their own M:SS/MM:SS
                // validation, but UX15p avoids letting them override strict slots.
                let fallbackLayouts: [TimerLayout] = allowTwoMinuteDigits ? [.mmss, .mss] : [.mss]
                for layout in fallbackLayouts {
                    if let adaptive = recogniseTimerByFixedSlotsAdaptive(from: candidateImage, layout: layout) {
                        if best == nil || adaptive.confidence > best!.confidence { best = adaptive }
                    }
                    if let result = recogniseTimer(from: candidateImage, layout: layout) {
                        if best == nil || result.confidence > best!.confidence { best = result }
                    }
                }

                if let componentResult = recogniseTimerByComponents(from: candidateImage, allowTwoMinuteDigits: allowTwoMinuteDigits) {
                    if best == nil || componentResult.confidence > best!.confidence { best = componentResult }
                }
            }
        }

        return best
    }

    private func timerCandidateImages(from image: CGImage) -> [CGImage] {
        var candidates: [CGImage] = []
        if let trimmed = trimmedTimerImage(from: image) {
            candidates.append(trimmed)
        }
        candidates.append(image)
        return candidates
    }

    private func trimmedTimerImage(from image: CGImage) -> CGImage? {
        guard let bitmap = grayscaleBitmap(from: image) else { return nil }

        let brightBounds = activeBounds(in: bitmap, mode: .bright)
        let darkBounds = activeBounds(in: bitmap, mode: .dark)
        let selected = preferredTimerBounds(bright: brightBounds, dark: darkBounds)
        guard var bounds = selected else { return nil }

        bounds = bounds.insetBy(dx: -0.035, dy: -0.08).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixelRect = CGRect(
            x: bounds.minX * CGFloat(image.width),
            y: bounds.minY * CGFloat(image.height),
            width: bounds.width * CGFloat(image.width),
            height: bounds.height * CGFloat(image.height)
        ).integral

        guard pixelRect.width > 8,
              pixelRect.height > 8,
              pixelRect.width < CGFloat(image.width) * 0.98 || pixelRect.height < CGFloat(image.height) * 0.98
        else { return nil }

        return image.cropping(to: pixelRect)
    }

    private func preferredTimerBounds(bright: CGRect?, dark: CGRect?) -> CGRect? {
        switch (bright, dark) {
        case let (b?, d?):
            let brightArea = b.width * b.height
            let darkArea = d.width * d.height
            // Digit strokes on a dark scoreboard are normally a compact bright
            // component. The dark component often includes the full black panel,
            // so prefer the smaller but still meaningful foreground bounds.
            if brightArea > 0.01 && brightArea < darkArea { return b }
            if darkArea > 0.01 { return d }
            return b
        case let (b?, nil): return b
        case let (nil, d?): return d
        default: return nil
        }
    }

    private func activeBounds(in bitmap: GrayBitmap, mode: SegmentMode) -> CGRect? {
        var minX = bitmap.width
        var minY = bitmap.height
        var maxX = -1
        var maxY = -1

        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let pixel = bitmap.data[y * bitmap.width + x]
                let active: Bool
                switch mode {
                case .bright:
                    active = pixel > 145
                case .dark:
                    active = pixel < 95
                }
                guard active else { continue }
                minX = Swift.min(minX, x)
                minY = Swift.min(minY, y)
                maxX = Swift.max(maxX, x)
                maxY = Swift.max(maxY, y)
            }
        }

        guard maxX > minX, maxY > minY else { return nil }
        let rect = CGRect(
            x: CGFloat(minX) / CGFloat(bitmap.width),
            y: CGFloat(minY) / CGFloat(bitmap.height),
            width: CGFloat(maxX - minX + 1) / CGFloat(bitmap.width),
            height: CGFloat(maxY - minY + 1) / CGFloat(bitmap.height)
        )
        let area = rect.width * rect.height
        guard area > 0.01 && rect.width > 0.05 && rect.height > 0.20 else { return nil }
        return rect
    }

    private enum TimerLayout {
        case mss
        case mmss

        var slotCount: Int {
            switch self {
            case .mss: return 4      // M : S S
            case .mmss: return 5     // M M : S S
            }
        }

        var digitSlots: [Int] {
            switch self {
            case .mss: return [0, 2, 3]
            case .mmss: return [0, 1, 3, 4]
            }
        }

        var name: String {
            switch self {
            case .mss: return "M:SS"
            case .mmss: return "MM:SS"
            }
        }
    }

    private func recogniseTimerByFixedSlotsAdaptive(from image: CGImage, layout: TimerLayout) -> SevenSegmentTimerRecognitionResult? {
        guard let bitmap = grayscaleBitmap(from: image) else { return nil }

        let brightComponents = segmentedComponents(in: bitmap, mode: .bright)
        let darkComponents = segmentedComponents(in: bitmap, mode: .dark)
        let brightBounds = activeBounds(in: bitmap, mode: .bright)
        let darkBounds = activeBounds(in: bitmap, mode: .dark)

        let candidateBounds = fixedSlotDigitBounds(
            brightBounds: brightBounds,
            darkBounds: darkBounds,
            brightComponents: brightComponents,
            darkComponents: darkComponents
        )

        var best: SevenSegmentTimerRecognitionResult?
        var diagnostics: [String] = []

        for (index, bounds) in candidateBounds.enumerated() {
            guard bounds.width > 0.18, bounds.height > 0.25 else {
                diagnostics.append("candidate#\(index)=too-small \(normalizedRectText(bounds))")
                continue
            }

            let result = recogniseTimerUsingDigitBounds(image: image, bounds: bounds, layout: layout)
            if let result {
                if best == nil || result.confidence > best!.confidence {
                    best = result
                }
            } else {
                diagnostics.append("candidate#\(index)=decode-miss \(normalizedRectText(bounds))")
            }
        }

        if let best { return best }
        return nil
    }


    private struct TimerSlotCandidate {
        let layout: TimerLayout
        let rects: [CGRect]       // Includes colon tile.
        let source: String
        let score: CGFloat
    }

    private func strictTimerCharacterSlotCandidates(from image: CGImage, allowTwoMinuteDigits: Bool) -> [TimerSlotCandidate] {
        guard let bitmap = grayscaleBitmap(from: image) else { return [] }
        let brightBounds = activeBounds(in: bitmap, mode: .bright)
        let darkBounds = activeBounds(in: bitmap, mode: .dark)
        let bounds = preferredFullTimerBounds(bright: brightBounds, dark: darkBounds)
        let colonXs = colonAnchorXCandidates(in: bitmap, bounds: bounds)
        let ratio = CGFloat(image.width) / max(CGFloat(image.height), 1)

        var candidates: [TimerSlotCandidate] = []
        for colonX in colonXs {
            if allowTwoMinuteDigits {
                if let rects = strictMMSSRects(bounds: bounds, colonX: colonX) {
                    candidates.append(TimerSlotCandidate(layout: .mmss, rects: rects, source: "colon", score: strictLayoutScore(layout: .mmss, colonX: colonX, bounds: bounds, ratio: ratio)))
                }
            }
            if let rects = strictMSSRects(bounds: bounds, colonX: colonX) {
                candidates.append(TimerSlotCandidate(layout: .mss, rects: rects, source: "colon", score: strictLayoutScore(layout: .mss, colonX: colonX, bounds: bounds, ratio: ratio)))
            }
        }

        // Fallback candidates still have explicit colon tiles and fixed slot count.
        // They are for cases where red penalty timers contain a faint or broken colon.
        if allowTwoMinuteDigits {
            candidates.append(TimerSlotCandidate(layout: .mmss, rects: strictFallbackCharacterRects(layout: .mmss, bounds: bounds), source: "fallback", score: 0.18 + max(0, min(0.20, ratio - 2.4) * 0.10)))
        }
        candidates.append(TimerSlotCandidate(layout: .mss, rects: strictFallbackCharacterRects(layout: .mss, bounds: bounds), source: "fallback", score: ratio < 2.9 ? 0.22 : 0.10))

        var unique: [TimerSlotCandidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard strictSlotCountIsValid(candidate.rects, layout: candidate.layout) else { continue }
            let duplicate = unique.contains { existing in
                existing.layout == candidate.layout && zip(existing.rects, candidate.rects).allSatisfy { a, b in
                    abs(a.minX - b.minX) < 0.018 && abs(a.maxX - b.maxX) < 0.018
                }
            }
            if !duplicate { unique.append(candidate) }
        }
        return unique
    }

    private func colonAnchorXCandidates(in bitmap: GrayBitmap, bounds: CGRect) -> [CGFloat] {
        let brightComponents = segmentedComponents(in: bitmap, mode: .bright)
        let darkComponents = segmentedComponents(in: bitmap, mode: .dark)
        var xs: [CGFloat] = []

        for component in brightComponents + darkComponents {
            guard component.kind == "colon" else { continue }
            let x = component.rect.midX
            guard x > bounds.minX + bounds.width * 0.18,
                  x < bounds.minX + bounds.width * 0.66 else { continue }
            xs.append(x)
        }

        // Projection-based colon candidates catch scoreboard separators that merge
        // into digit blobs and never survive connected-component filtering.
        xs.append(contentsOf: verticalSeparatorCandidates(in: bitmap, mode: .bright, bounds: bounds))
        xs.append(contentsOf: verticalSeparatorCandidates(in: bitmap, mode: .dark, bounds: bounds))

        // Sensible fallbacks keep the Segments preview as explicit character tiles.
        xs.append(bounds.minX + bounds.width * 0.39) // MM:SS common colon position.
        xs.append(bounds.minX + bounds.width * 0.34) // M:SS common colon position.

        var unique: [CGFloat] = []
        for x in xs.sorted() {
            if !unique.contains(where: { abs($0 - x) < bounds.width * 0.045 }) {
                unique.append(x)
            }
        }
        return unique
    }

    private func verticalSeparatorCandidates(in bitmap: GrayBitmap, mode: SegmentMode, bounds: CGRect) -> [CGFloat] {
        let minX = max(0, Int(bounds.minX * CGFloat(bitmap.width)))
        let maxX = min(bitmap.width - 1, Int(bounds.maxX * CGFloat(bitmap.width)))
        let minY = max(0, Int(bounds.minY * CGFloat(bitmap.height)))
        let maxY = min(bitmap.height - 1, Int(bounds.maxY * CGFloat(bitmap.height)))
        guard maxX > minX + 6, maxY > minY + 6 else { return [] }

        var columns: [(x: Int, fill: Double)] = []
        for x in minX...maxX {
            var active = 0
            var total = 0
            for y in minY...maxY {
                let pixel = bitmap.data[y * bitmap.width + x]
                switch mode {
                case .bright:
                    if pixel > 135 { active += 1 }
                case .dark:
                    if pixel < 85 { active += 1 }
                }
                total += 1
            }
            columns.append((x, Double(active) / Double(max(total, 1))))
        }

        // Colon/dot separators tend to create narrow active columns between digit groups.
        let regionWidth = CGFloat(maxX - minX)
        let plausible = columns.filter { item in
            let nx = (CGFloat(item.x - minX) / max(regionWidth, 1))
            return nx > 0.18 && nx < 0.66 && item.fill > 0.08 && item.fill < 0.62
        }

        var candidates: [CGFloat] = []
        var run: [Int] = []
        var lastX: Int?
        for item in plausible {
            if let lastX, item.x > lastX + 1 {
                if let mid = midpointOfNarrowColumnRun(run, minX: minX, maxX: maxX) { candidates.append(mid) }
                run.removeAll()
            }
            run.append(item.x)
            lastX = item.x
        }
        if let mid = midpointOfNarrowColumnRun(run, minX: minX, maxX: maxX) { candidates.append(mid) }
        return candidates
    }

    private func midpointOfNarrowColumnRun(_ run: [Int], minX: Int, maxX: Int) -> CGFloat? {
        guard !run.isEmpty else { return nil }
        let runWidth = run.count
        let fullWidth = max(maxX - minX, 1)
        guard runWidth <= max(14, Int(Double(fullWidth) * 0.11)) else { return nil }
        let midPixel = (run.first! + run.last!) / 2
        // Caller uses normalized image coordinates. maxX is derived from the
        // bitmap width bound and is always close to the last valid pixel index.
        return CGFloat(midPixel) / CGFloat(max(maxX, 1))
    }

    private func strictLayoutScore(layout: TimerLayout, colonX: CGFloat, bounds: CGRect, ratio: CGFloat) -> CGFloat {
        let relativeX = (colonX - bounds.minX) / max(bounds.width, 0.001)
        switch layout {
        case .mss:
            return 1.0 - min(abs(relativeX - 0.34) * 2.2, 0.85) + (ratio < 3.0 ? 0.12 : 0.0)
        case .mmss:
            return 1.0 - min(abs(relativeX - 0.40) * 2.0, 0.85) + (ratio > 2.5 ? 0.12 : 0.0)
        }
    }

    private func strictMSSRects(bounds: CGRect, colonX: CGFloat) -> [CGRect]? {
        let width = bounds.width
        let colonWidth = width * 0.070
        let gap = width * 0.018
        let colonCenter = min(max(colonX, bounds.minX + width * 0.25), bounds.minX + width * 0.47)
        let colon = CGRect(x: colonCenter - colonWidth / 2, y: bounds.minY, width: colonWidth, height: bounds.height)
        let minute = CGRect(x: bounds.minX, y: bounds.minY, width: max(0, colon.minX - gap - bounds.minX), height: bounds.height)
        let rightStart = colon.maxX + gap
        let rightWidth = bounds.maxX - rightStart
        guard minute.width > width * 0.16, rightWidth > width * 0.32 else { return nil }
        let digitGap = width * 0.026
        let secondWidth = (rightWidth - digitGap) / 2
        let s1 = CGRect(x: rightStart, y: bounds.minY, width: secondWidth, height: bounds.height)
        let s2 = CGRect(x: rightStart + secondWidth + digitGap, y: bounds.minY, width: bounds.maxX - (rightStart + secondWidth + digitGap), height: bounds.height)
        return [minute, colon, s1, s2].map { insetStrictTimerSlot($0, in: bounds, isColon: $0 == colon) }
    }

    private func strictMMSSRects(bounds: CGRect, colonX: CGFloat) -> [CGRect]? {
        let width = bounds.width
        let colonWidth = width * 0.064
        let gap = width * 0.016
        let colonCenter = min(max(colonX, bounds.minX + width * 0.34), bounds.minX + width * 0.54)
        let colon = CGRect(x: colonCenter - colonWidth / 2, y: bounds.minY, width: colonWidth, height: bounds.height)
        let leftWidth = colon.minX - gap - bounds.minX
        let rightStart = colon.maxX + gap
        let rightWidth = bounds.maxX - rightStart
        guard leftWidth > width * 0.26, rightWidth > width * 0.28 else { return nil }
        let leftGap = width * 0.018
        let rightGap = width * 0.024
        let minuteWidth = (leftWidth - leftGap) / 2
        let secondWidth = (rightWidth - rightGap) / 2
        let m1 = CGRect(x: bounds.minX, y: bounds.minY, width: minuteWidth, height: bounds.height)
        let m2 = CGRect(x: bounds.minX + minuteWidth + leftGap, y: bounds.minY, width: minuteWidth, height: bounds.height)
        let s1 = CGRect(x: rightStart, y: bounds.minY, width: secondWidth, height: bounds.height)
        let s2 = CGRect(x: rightStart + secondWidth + rightGap, y: bounds.minY, width: bounds.maxX - (rightStart + secondWidth + rightGap), height: bounds.height)
        return [m1, m2, colon, s1, s2].map { insetStrictTimerSlot($0, in: bounds, isColon: $0 == colon) }
    }

    private func strictFallbackCharacterRects(layout: TimerLayout, bounds: CGRect = CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)) -> [CGRect] {
        switch layout {
        case .mss:
            let colon = CGRect(x: bounds.minX + bounds.width * 0.32, y: bounds.minY, width: bounds.width * 0.070, height: bounds.height)
            let minute = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * 0.28, height: bounds.height)
            let s1 = CGRect(x: bounds.minX + bounds.width * 0.44, y: bounds.minY, width: bounds.width * 0.23, height: bounds.height)
            let s2 = CGRect(x: bounds.minX + bounds.width * 0.70, y: bounds.minY, width: bounds.width * 0.26, height: bounds.height)
            return [minute, colon, s1, s2].map { insetStrictTimerSlot($0, in: bounds, isColon: $0 == colon) }
        case .mmss:
            let colon = CGRect(x: bounds.minX + bounds.width * 0.405, y: bounds.minY, width: bounds.width * 0.065, height: bounds.height)
            let m1 = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * 0.185, height: bounds.height)
            let m2 = CGRect(x: bounds.minX + bounds.width * 0.205, y: bounds.minY, width: bounds.width * 0.185, height: bounds.height)
            let s1 = CGRect(x: bounds.minX + bounds.width * 0.510, y: bounds.minY, width: bounds.width * 0.220, height: bounds.height)
            let s2 = CGRect(x: bounds.minX + bounds.width * 0.750, y: bounds.minY, width: bounds.width * 0.230, height: bounds.height)
            return [m1, m2, colon, s1, s2].map { insetStrictTimerSlot($0, in: bounds, isColon: $0 == colon) }
        }
    }

    private func insetStrictTimerSlot(_ rect: CGRect, in bounds: CGRect, isColon: Bool) -> CGRect {
        let dx = isColon ? min(rect.width * 0.08, bounds.width * 0.006) : min(rect.width * 0.035, bounds.width * 0.010)
        let dy = bounds.height * 0.045
        return rect.insetBy(dx: dx, dy: dy).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func strictSlotCountIsValid(_ rects: [CGRect], layout: TimerLayout) -> Bool {
        rects.count == layout.slotCount && layout.digitSlots.allSatisfy { $0 < rects.count && rects[$0].width > 0.05 }
    }

    private func recogniseTimerUsingStrictCharacterSlots(image: CGImage, candidate: TimerSlotCandidate) -> SevenSegmentTimerRecognitionResult? {
        let layout = candidate.layout
        guard strictSlotCountIsValid(candidate.rects, layout: layout) else { return nil }
        // UX16b: do not accept a merged two-minute-digit block as a single M slot.
        // If the crop actually contains MM:SS, the colon-anchored M:SS minute tile
        // becomes very wide (for example [19] -> decoded as 8). Reject that path so
        // the MM:SS candidate can decode [1][9][:][3][4].
        if layout == .mss,
           candidate.source == "colon",
           let minuteSlot = candidate.rects.first,
           minuteSlot.width > 0.31 {
            return nil
        }
        var digits: [Int] = []
        var confidences: [Float] = []
        var slotDiagnostics: [String] = []

        for slotIndex in layout.digitSlots {
            let slotRect = candidate.rects[slotIndex]
            guard let digit = recogniseDigit(in: image, normalizedRect: slotRect) else {
                slotDiagnostics.append("slot\(slotIndex)=miss@\(normalizedRectText(slotRect))")
                return nil
            }
            digits.append(digit.value)
            confidences.append(digit.confidence)
            slotDiagnostics.append("slot\(slotIndex)=\(digit.value)/\(String(format: "%.2f", digit.confidence))@\(normalizedRectText(slotRect))")
        }

        let value: String
        switch layout {
        case .mss:
            guard digits.count == 3 else { return nil }
            let seconds = digits[1] * 10 + digits[2]
            guard seconds < 60 else { return nil }
            value = "\(digits[0]):\(String(format: "%02d", seconds))"
        case .mmss:
            guard digits.count == 4 else { return nil }
            let minutes = digits[0] * 10 + digits[1]
            let seconds = digits[2] * 10 + digits[3]
            guard (0...20).contains(minutes), seconds < 60 else { return nil }
            value = "\(minutes):\(String(format: "%02d", seconds))"
        }

        let avgConfidence = confidences.reduce(0, +) / Float(max(confidences.count, 1))
        guard avgConfidence >= 0.46 else { return nil }
        let rawDigits = digits.map { String($0) }.joined()
        return SevenSegmentTimerRecognitionResult(
            value: value,
            confidence: avgConfidence,
            rawDigits: rawDigits,
            layout: "UX16b strict-slots \(layout.name)",
            diagnostic: "UX16b timerSlots expected=\(layout.name) actual=\(candidate.rects.count) source=\(candidate.source) raw=\(rawDigits) conf=\(String(format: "%.2f", avgConfidence)) tiles=[\(candidate.rects.map { normalizedRectText($0) }.joined(separator: ";"))] slots=[\(slotDiagnostics.joined(separator: ";"))]",
            segmentRects: candidate.rects
        )
    }

    private func recogniseTimerByColonAnchor(from image: CGImage, layout: TimerLayout) -> SevenSegmentTimerRecognitionResult? {
        guard let rects = colonAnchoredTimerSlotRects(from: image, layout: layout) else { return nil }
        let digitRects = rects.filter { $0.width > 0.075 }
        let expectedDigits = layout == .mmss ? 4 : 3
        guard digitRects.count == expectedDigits else { return nil }

        var digits: [Int] = []
        var confidences: [Float] = []
        var slotDiagnostics: [String] = []
        for (slot, slotRect) in digitRects.enumerated() {
            guard let digit = recogniseDigit(in: image, normalizedRect: slotRect) else {
                slotDiagnostics.append("slot\(slot)=miss@\(normalizedRectText(slotRect))")
                return nil
            }
            digits.append(digit.value)
            confidences.append(digit.confidence)
            slotDiagnostics.append("slot\(slot)=\(digit.value)/\(String(format: "%.2f", digit.confidence))@\(normalizedRectText(slotRect))")
        }

        let value: String
        switch layout {
        case .mss:
            guard digits.count == 3 else { return nil }
            let seconds = digits[1] * 10 + digits[2]
            guard seconds < 60 else { return nil }
            value = "\(digits[0]):\(String(format: "%02d", seconds))"
        case .mmss:
            guard digits.count == 4 else { return nil }
            let minutes = digits[0] * 10 + digits[1]
            let seconds = digits[2] * 10 + digits[3]
            guard (0...20).contains(minutes), seconds < 60 else { return nil }
            value = "\(minutes):\(String(format: "%02d", seconds))"
        }

        let avgConfidence = confidences.reduce(0, +) / Float(max(confidences.count, 1))
        guard avgConfidence >= 0.42 else { return nil }
        let rawDigits = digits.map { String($0) }.joined()
        let colonRect = rects.first { $0.width <= 0.075 }
        let colonText = colonRect.map { normalizedRectText($0) } ?? "none"
        return SevenSegmentTimerRecognitionResult(
            value: value,
            confidence: avgConfidence,
            rawDigits: rawDigits,
            layout: "UX15o colon-anchored \(layout.name)",
            diagnostic: "UX15o colonAnchorTimer layout=\(layout.name) colon=\(colonText) raw=\(rawDigits) conf=\(String(format: "%.2f", avgConfidence)) slots=[\(slotDiagnostics.joined(separator: ";"))]",
            segmentRects: rects
        )
    }

    private func colonAnchoredTimerSlotRects(from image: CGImage, layout: TimerLayout) -> [CGRect]? {
        guard let bitmap = grayscaleBitmap(from: image) else { return nil }
        let brightComponents = segmentedComponents(in: bitmap, mode: .bright)
        let darkComponents = segmentedComponents(in: bitmap, mode: .dark)
        let brightBounds = activeBounds(in: bitmap, mode: .bright)
        let darkBounds = activeBounds(in: bitmap, mode: .dark)
        let bounds = preferredFullTimerBounds(bright: brightBounds, dark: darkBounds)
        guard let colon = selectedColonAnchor(brightComponents: brightComponents, darkComponents: darkComponents, within: bounds) else { return nil }

        switch layout {
        case .mss:
            return mssColonAnchoredRects(bounds: bounds, colon: colon)
        case .mmss:
            return mmssColonAnchoredRects(bounds: bounds, colon: colon)
        }
    }

    private func preferredFullTimerBounds(bright: CGRect?, dark: CGRect?) -> CGRect {
        // Use a wide crop-aligned bound for timer slots. Active bounds are only
        // used to tighten vertical sampling slightly; horizontal slot anchoring
        // comes from the colon. This prevents the old middle-band 8:08/0:03 reads.
        let vertical: CGRect? = {
            if let bright, bright.height > 0.35 { return bright }
            if let dark, dark.height > 0.35 { return dark }
            return bright ?? dark
        }()
        let y = max(0.04, (vertical?.minY ?? 0.04) - 0.035)
        let maxY = min(0.96, (vertical?.maxY ?? 0.96) + 0.035)
        return CGRect(x: 0.02, y: y, width: 0.96, height: max(0.40, maxY - y))
    }

    private func selectedColonAnchor(
        brightComponents: [SevenSegmentComponent],
        darkComponents: [SevenSegmentComponent],
        within bounds: CGRect
    ) -> CGRect? {
        let components = (brightComponents + darkComponents).filter { component in
            guard component.kind == "colon" else { return false }
            let rect = component.rect
            guard rect.midX > bounds.minX + bounds.width * 0.18,
                  rect.midX < bounds.minX + bounds.width * 0.62 else { return false }
            guard rect.width >= 0.012, rect.width <= 0.095 else { return false }
            guard rect.height >= 0.22, rect.height <= 0.90 else { return false }
            return true
        }
        guard !components.isEmpty else { return nil }

        let targetX = bounds.minX + bounds.width * 0.39
        return components.sorted { lhs, rhs in
            let lhsScore = abs(lhs.rect.midX - targetX) + lhs.rect.width * 1.8 - CGFloat(lhs.fill) * 0.03
            let rhsScore = abs(rhs.rect.midX - targetX) + rhs.rect.width * 1.8 - CGFloat(rhs.fill) * 0.03
            return lhsScore < rhsScore
        }.first?.rect
    }

    private func mssColonAnchoredRects(bounds: CGRect, colon: CGRect) -> [CGRect]? {
        let width = bounds.width
        let gap = width * 0.030
        let colonX = min(max(colon.midX, bounds.minX + width * 0.24), bounds.minX + width * 0.55)
        let rightStart = min(max(colon.maxX + gap, bounds.minX + width * 0.40), bounds.maxX - width * 0.35)
        let rightAvailable = bounds.maxX - rightStart
        guard rightAvailable > width * 0.34 else { return nil }
        let secondSlotWidth = rightAvailable * 0.46
        let secondGap = rightAvailable * 0.08
        let minuteWidth = min(width * 0.34, max(width * 0.22, secondSlotWidth * 1.35))
        let minuteEnd = max(bounds.minX + minuteWidth, colonX - gap * 0.65)
        let minuteStart = max(bounds.minX, minuteEnd - minuteWidth)

        let minute = CGRect(x: minuteStart, y: bounds.minY, width: minuteEnd - minuteStart, height: bounds.height)
        let colonRect = CGRect(x: max(bounds.minX, colon.minX - gap * 0.45), y: bounds.minY, width: min(width * 0.075, colon.width + gap * 0.90), height: bounds.height)
        let tens = CGRect(x: rightStart, y: bounds.minY, width: secondSlotWidth, height: bounds.height)
        let ones = CGRect(x: rightStart + secondSlotWidth + secondGap, y: bounds.minY, width: bounds.maxX - (rightStart + secondSlotWidth + secondGap), height: bounds.height)

        return [minute, colonRect, tens, ones].map { insetTimerSlot($0, in: bounds) }
    }

    private func mmssColonAnchoredRects(bounds: CGRect, colon: CGRect) -> [CGRect]? {
        let width = bounds.width
        let gap = width * 0.026
        let colonX = min(max(colon.midX, bounds.minX + width * 0.36), bounds.minX + width * 0.64)
        let leftAvailable = max(0, colonX - gap - bounds.minX)
        let rightStart = min(max(colon.maxX + gap, bounds.minX + width * 0.50), bounds.maxX - width * 0.30)
        let rightAvailable = bounds.maxX - rightStart
        guard leftAvailable > width * 0.30, rightAvailable > width * 0.28 else { return nil }

        let minuteGap = leftAvailable * 0.06
        let minuteWidth = (leftAvailable - minuteGap) / 2
        let secondGap = rightAvailable * 0.08
        let secondWidth = (rightAvailable - secondGap) / 2

        let m1 = CGRect(x: bounds.minX, y: bounds.minY, width: minuteWidth, height: bounds.height)
        let m2 = CGRect(x: bounds.minX + minuteWidth + minuteGap, y: bounds.minY, width: minuteWidth, height: bounds.height)
        let colonRect = CGRect(x: max(bounds.minX, colon.minX - gap * 0.45), y: bounds.minY, width: min(width * 0.075, colon.width + gap * 0.90), height: bounds.height)
        let s1 = CGRect(x: rightStart, y: bounds.minY, width: secondWidth, height: bounds.height)
        let s2 = CGRect(x: rightStart + secondWidth + secondGap, y: bounds.minY, width: bounds.maxX - (rightStart + secondWidth + secondGap), height: bounds.height)

        return [m1, m2, colonRect, s1, s2].map { insetTimerSlot($0, in: bounds) }
    }

    private func insetTimerSlot(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let dx = min(rect.width * 0.045, bounds.width * 0.014)
        let dy = bounds.height * 0.045
        return rect.insetBy(dx: dx, dy: dy).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func fixedSlotDigitBounds(
        brightBounds: CGRect?,
        darkBounds: CGRect?,
        brightComponents: [SevenSegmentComponent],
        darkComponents: [SevenSegmentComponent]
    ) -> [CGRect] {
        var candidates: [CGRect] = []

        // UX15n: anchor timer decoding to the full selected crop first. The
        // scoreboard may expose several digit strokes as colon-like components;
        // those must not shrink the timer to a narrow middle band.
        candidates.append(CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92))
        candidates.append(CGRect(x: 0.04, y: 0.08, width: 0.92, height: 0.84))

        // Large digit-like components are still useful diagnostic/fallback
        // candidates, but too-narrow candidates are rejected before acceptance.
        // This avoids the 2:43 -> 8:08 failure where only x=0.42-0.65 was read.
        let allComponents = brightComponents + darkComponents
        let digitComponents = allComponents.filter { $0.kind == "digit" }
        for component in digitComponents.sorted(by: { ($0.rect.width * $0.rect.height) > ($1.rect.width * $1.rect.height) }).prefix(3) {
            candidates.append(component.rect.insetBy(dx: -0.015, dy: -0.035).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
        }

        let colonComponents = allComponents.filter { $0.kind == "colon" }
        if let brightBounds {
            candidates.append(brightBounds.insetBy(dx: -0.020, dy: -0.045).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
            for colon in colonComponents where colon.rect.midX < brightBounds.minX + brightBounds.width * 0.28 {
                let left = min(max(colon.rect.maxX + 0.018, brightBounds.minX), brightBounds.maxX)
                let rect = CGRect(x: left, y: brightBounds.minY, width: brightBounds.maxX - left, height: brightBounds.height)
                    .insetBy(dx: -0.010, dy: -0.040)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                candidates.append(rect)
            }
        }
        if let darkBounds {
            candidates.append(darkBounds.insetBy(dx: -0.020, dy: -0.045).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
            for colon in colonComponents where colon.rect.midX < darkBounds.minX + darkBounds.width * 0.28 {
                let left = min(max(colon.rect.maxX + 0.018, darkBounds.minX), darkBounds.maxX)
                let rect = CGRect(x: left, y: darkBounds.minY, width: darkBounds.maxX - left, height: darkBounds.height)
                    .insetBy(dx: -0.010, dy: -0.040)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                candidates.append(rect)
            }
        }

        // Fallback to the whole crop with a small safety inset. This keeps Test OCR
        // deterministic even when all connected components merge into one panel blob.
        candidates.append(CGRect(x: 0.03, y: 0.03, width: 0.94, height: 0.94))

        var unique: [CGRect] = []
        for candidate in candidates {
            guard candidate.width > 0.12, candidate.height > 0.20 else { continue }
            let duplicate = unique.contains { existing in
                abs(existing.minX - candidate.minX) < 0.025 &&
                abs(existing.maxX - candidate.maxX) < 0.025 &&
                abs(existing.minY - candidate.minY) < 0.040 &&
                abs(existing.maxY - candidate.maxY) < 0.040
            }
            if !duplicate { unique.append(candidate) }
        }
        return unique
    }

    private func timerSlotRects(in bounds: CGRect, layout: TimerLayout) -> [CGRect] {
        let fractions: [(CGFloat, CGFloat)]
        switch layout {
        case .mss:
            // M:SS. Leave a colon gap between minute and tens-of-seconds so the
            // separator does not contaminate digit sampling.
            fractions = [(0.00, 0.30), (0.43, 0.66), (0.69, 1.00)]
        case .mmss:
            // MM:SS. Four digit slots with a central colon gap.
            fractions = [(0.00, 0.20), (0.22, 0.43), (0.55, 0.76), (0.78, 1.00)]
        }

        return fractions.map { start, end in
            let x = bounds.minX + bounds.width * start
            let width = bounds.width * (end - start)
            return CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
                .insetBy(dx: max(0.002, width * 0.055), dy: bounds.height * 0.045)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func recogniseTimerUsingDigitBounds(image: CGImage, bounds: CGRect, layout: TimerLayout) -> SevenSegmentTimerRecognitionResult? {
        let minWidth: CGFloat = layout == .mmss ? 0.62 : 0.52
        guard bounds.width >= minWidth else {
            return nil
        }

        var digits: [Int] = []
        var confidences: [Float] = []
        var slotDiagnostics: [String] = []
        let segmentRects = timerSlotRects(in: bounds, layout: layout)

        for (slot, slotRect) in segmentRects.enumerated() {
            guard let digit = recogniseDigit(in: image, normalizedRect: slotRect) else {
                slotDiagnostics.append("slot\(slot)=miss@\(normalizedRectText(slotRect))")
                return nil
            }
            digits.append(digit.value)
            confidences.append(digit.confidence)
            slotDiagnostics.append("slot\(slot)=\(digit.value)/\(String(format: "%.2f", digit.confidence))@\(normalizedRectText(slotRect))")
        }

        let value: String
        switch layout {
        case .mss:
            guard digits.count == 3 else { return nil }
            let seconds = digits[1] * 10 + digits[2]
            guard seconds < 60 else { return nil }
            value = "\(digits[0]):\(String(format: "%02d", seconds))"
        case .mmss:
            guard digits.count == 4 else { return nil }
            let minutes = digits[0] * 10 + digits[1]
            let seconds = digits[2] * 10 + digits[3]
            guard (0...20).contains(minutes), seconds < 60 else { return nil }
            value = "\(minutes):\(String(format: "%02d", seconds))"
        }

        let avgConfidence = confidences.reduce(0, +) / Float(max(confidences.count, 1))
        guard avgConfidence >= 0.52 else { return nil }
        let rawDigits = digits.map { String($0) }.joined()
        return SevenSegmentTimerRecognitionResult(
            value: value,
            confidence: avgConfidence,
            rawDigits: rawDigits,
            layout: "UX15n fixed-slot \(layout.name)",
            diagnostic: "UX15n fixedSlotTimer layout=\(layout.name) bounds=\(normalizedRectText(bounds)) raw=\(rawDigits) conf=\(String(format: "%.2f", avgConfidence)) slots=[\(slotDiagnostics.joined(separator: ";"))]",
            segmentRects: segmentRects
        )
    }

    private func normalizedRectText(_ rect: CGRect) -> String {
        "\(String(format: "%.2f", rect.minX))-\(String(format: "%.2f", rect.maxX))x\(String(format: "%.2f", rect.minY))-\(String(format: "%.2f", rect.maxY))"
    }

    private func recogniseTimer(from image: CGImage, layout: TimerLayout) -> SevenSegmentTimerRecognitionResult? {
        var digits: [Int] = []
        var confidences: [Float] = []
        let segmentRects = timerSlotRects(in: CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92), layout: layout)

        for normalizedSlot in segmentRects {
            guard let digit = recogniseDigit(in: image, normalizedRect: normalizedSlot) else {
                return nil
            }
            digits.append(digit.value)
            confidences.append(digit.confidence)
        }

        let rawDigits = digits.map { String($0) }.joined()
        let value: String
        switch layout {
        case .mss:
            guard digits.count == 3 else { return nil }
            let seconds = digits[1] * 10 + digits[2]
            guard seconds < 60 else { return nil }
            value = "\(digits[0]):\(String(format: "%02d", seconds))"
        case .mmss:
            guard digits.count == 4 else { return nil }
            let minutes = digits[0] * 10 + digits[1]
            let seconds = digits[2] * 10 + digits[3]
            guard (0...20).contains(minutes), seconds < 60 else { return nil }
            value = "\(minutes):\(String(format: "%02d", seconds))"
        }

        let avgConfidence = confidences.reduce(0, +) / Float(max(confidences.count, 1))
        guard avgConfidence >= 0.70 else { return nil }
        return SevenSegmentTimerRecognitionResult(
            value: value,
            confidence: avgConfidence,
            rawDigits: rawDigits,
            layout: layout.name,
            diagnostic: "UX15n fullCropFixedSlots layout=\(layout.name) raw=\(rawDigits) conf=\(String(format: "%.2f", avgConfidence))",
            segmentRects: segmentRects
        )
    }

    private func recogniseTimerByComponents(from image: CGImage, allowTwoMinuteDigits: Bool) -> SevenSegmentTimerRecognitionResult? {
        guard let bitmap = grayscaleBitmap(from: image) else { return nil }

        let attempts: [(mode: SegmentMode, components: [SevenSegmentComponent])] = [
            (.bright, segmentedComponents(in: bitmap, mode: .bright)),
            (.dark, segmentedComponents(in: bitmap, mode: .dark))
        ]

        var best: SevenSegmentTimerRecognitionResult?
        for attempt in attempts where !attempt.components.isEmpty {
            if let result = recogniseTimerFromComponents(
                image: image,
                components: attempt.components,
                mode: attempt.mode,
                allowTwoMinuteDigits: allowTwoMinuteDigits
            ) {
                if best == nil || result.confidence > best!.confidence {
                    best = result
                }
            }
        }
        return best
    }

    private func segmentedComponents(in bitmap: GrayBitmap, mode: SegmentMode) -> [SevenSegmentComponent] {
        let width = bitmap.width
        let height = bitmap.height
        guard width > 8, height > 8 else { return [] }

        var activeColumns = [Bool](repeating: false, count: width)
        let minColumnPixels = max(1, Int(Double(height) * 0.008))
        for x in 0..<width {
            var active = 0
            for y in 0..<height {
                if isActive(bitmap.data[y * width + x], mode: mode) { active += 1 }
            }
            activeColumns[x] = active >= minColumnPixels
        }

        let maxGap = max(3, Int(Double(width) * 0.035))
        var runs: [(start: Int, end: Int)] = []
        var start: Int?
        var lastActive: Int?
        for x in 0..<width {
            if activeColumns[x] {
                if start == nil { start = x }
                lastActive = x
            } else if let s = start, let last = lastActive, x - last > maxGap {
                runs.append((s, last))
                start = nil
                lastActive = nil
            }
        }
        if let s = start, let last = lastActive { runs.append((s, last)) }

        var components: [SevenSegmentComponent] = []
        for run in runs {
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            var active = 0
            for y in 0..<height {
                for x in max(0, run.start)..<min(width, run.end + 1) {
                    if isActive(bitmap.data[y * width + x], mode: mode) {
                        minX = Swift.min(minX, x)
                        minY = Swift.min(minY, y)
                        maxX = Swift.max(maxX, x)
                        maxY = Swift.max(maxY, y)
                        active += 1
                    }
                }
            }
            guard maxX > minX, maxY > minY else { continue }
            let rect = CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: CGFloat(maxX - minX + 1) / CGFloat(width),
                height: CGFloat(maxY - minY + 1) / CGFloat(height)
            )
            let areaPixels = max(1, (maxX - minX + 1) * (maxY - minY + 1))
            let fill = Double(active) / Double(areaPixels)
            let aspect = rect.width / max(rect.height, 0.001)
            let kind = (rect.height < 0.46 && rect.width < 0.16) || aspect < 0.22 ? "colon" : "digit"
            guard rect.width > 0.006, rect.height > 0.075, fill > 0.003 else { continue }
            components.append(SevenSegmentComponent(rect: rect, fill: fill, kind: kind))
        }

        // Drop likely border/whole-panel components. True digits are compact and normally
        // leave margin around the timer zone.
        return components
            .filter { $0.rect.width < 0.985 && $0.rect.height < 0.995 }
            .sorted { $0.rect.minX < $1.rect.minX }
    }

    private func recogniseTimerFromComponents(
        image: CGImage,
        components: [SevenSegmentComponent],
        mode: SegmentMode,
        allowTwoMinuteDigits: Bool
    ) -> SevenSegmentTimerRecognitionResult? {
        let digitComponents = components.filter { $0.kind == "digit" }
        guard digitComponents.count == 3 || (allowTwoMinuteDigits && digitComponents.count == 4) else { return nil }

        var digits: [Int] = []
        var confidences: [Float] = []
        var diagnostics: [String] = []
        for component in digitComponents {
            let padded = component.rect.insetBy(dx: -0.015, dy: -0.035).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let digit = recogniseDigit(in: image, normalizedRect: padded) else {
                diagnostics.append("miss@\(String(format: "%.2f", component.rect.minX))")
                return nil
            }
            digits.append(digit.value)
            confidences.append(digit.confidence)
            diagnostics.append("\(digit.value)@\(String(format: "%.2f", component.rect.minX))/\(String(format: "%.2f", digit.confidence))")
        }

        let rawDigits = digits.map { String($0) }.joined()
        let value: String
        let layout: String
        if digits.count == 3 {
            let seconds = digits[1] * 10 + digits[2]
            guard seconds < 60 else { return nil }
            value = "\(digits[0]):\(String(format: "%02d", seconds))"
            layout = "components M:SS"
        } else {
            let minutes = digits[0] * 10 + digits[1]
            let seconds = digits[2] * 10 + digits[3]
            guard (0...20).contains(minutes), seconds < 60 else { return nil }
            value = "\(minutes):\(String(format: "%02d", seconds))"
            layout = "components MM:SS"
        }

        let avgConfidence = confidences.reduce(0, +) / Float(max(confidences.count, 1))
        guard avgConfidence >= 0.64 else { return nil }
        let componentSummary = components.map { component in
            "\(component.kind):\(String(format: "%.2f", component.rect.minX))-\(String(format: "%.2f", component.rect.maxX))"
        }.joined(separator: ",")
        return SevenSegmentTimerRecognitionResult(
            value: value,
            confidence: avgConfidence,
            rawDigits: rawDigits,
            layout: layout,
            diagnostic: "componentFirst mode=\(mode.label) comps=[\(componentSummary)] digits=[\(diagnostics.joined(separator: ","))] raw=\(rawDigits) conf=\(String(format: "%.2f", avgConfidence))",
            segmentRects: digitComponents.map { $0.rect.insetBy(dx: -0.015, dy: -0.035).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        )
    }


    private func recogniseDigitSequenceByTemplateSlots(from image: CGImage, maxDigits: Int, allowSingleDigit: Bool) -> SevenSegmentDigitSequenceResult? {
        guard maxDigits > 0 else { return nil }
        let aspect = CGFloat(image.width) / max(CGFloat(image.height), 1)
        var counts: [Int] = []

        if maxDigits >= 2 && aspect >= 1.22 {
            counts.append(2)
        }
        if allowSingleDigit {
            counts.append(1)
        }
        if maxDigits >= 2 && !counts.contains(2) && aspect >= 1.65 {
            counts.insert(2, at: 0)
        }
        if counts.isEmpty {
            counts.append(min(maxDigits, 1))
        }

        var best: SevenSegmentDigitSequenceResult?
        for count in counts where count <= maxDigits {
            let rects = templateDigitRects(count: count, aspect: aspect)
            var rawDigits = ""
            var slotDiagnostics: [String] = []
            var confidences: [Float] = []
            var failed = false

            for (index, rect) in rects.enumerated() {
                guard let digit = recogniseDigit(in: image, normalizedRect: rect) else {
                    slotDiagnostics.append("slot\(index)=nil@\(normalizedRectText(rect))")
                    failed = true
                    break
                }
                if digit.confidence < 0.50 {
                    slotDiagnostics.append("slot\(index)=\(digit.value)/low@\(normalizedRectText(rect))")
                    failed = true
                    break
                }
                rawDigits += String(digit.value)
                confidences.append(digit.confidence)
                slotDiagnostics.append("slot\(index)=\(digit.value)/\(String(format: "%.2f", digit.confidence))@\(normalizedRectText(rect))")
            }

            guard !failed, rawDigits.count == count, !confidences.isEmpty else { continue }
            let avg = confidences.reduce(Float(0), +) / Float(confidences.count)
            let result = SevenSegmentDigitSequenceResult(
                value: rawDigits,
                confidence: min(0.98, avg + (count >= 2 ? 0.04 : 0.0)),
                rawDigits: rawDigits,
                diagnostic: "UX16a templateDigits expected=\(count) actual=\(rawDigits.count) aspect=\(String(format: "%.2f", Double(aspect))) raw=\(rawDigits) conf=\(String(format: "%.2f", avg)) slots=[\(slotDiagnostics.joined(separator: ";"))]",
                segmentRects: rects
            )
            if best == nil || result.confidence > best!.confidence { best = result }
        }

        return best
    }

    private func templateDigitRects(count: Int, aspect: CGFloat) -> [CGRect] {
        let y: CGFloat = 0.08
        let h: CGFloat = 0.84
        if count <= 1 {
            // A one-digit score/period/player may sit in the centre of a wider saved
            // zone. Keep enough width to include glow while ignoring borders.
            let width: CGFloat = aspect > 1.35 ? 0.58 : 0.86
            return [CGRect(x: (1.0 - width) / 2.0, y: y, width: width, height: h)]
        }

        let outerPad: CGFloat = 0.04
        let gap: CGFloat = aspect > 1.75 ? 0.035 : 0.02
        let available = max(0.2, 1.0 - (outerPad * 2.0) - gap)
        let slotWidth = available / 2.0
        return [
            CGRect(x: outerPad, y: y, width: slotWidth, height: h),
            CGRect(x: outerPad + slotWidth + gap, y: y, width: slotWidth, height: h)
        ]
    }

    private func recogniseDigitSequenceByComponents(from image: CGImage, maxDigits: Int, allowSingleDigit: Bool) -> SevenSegmentDigitSequenceResult? {
        guard let bitmap = grayscaleBitmap(from: image) else { return nil }
        let attempts: [(mode: SegmentMode, components: [SevenSegmentComponent])] = [
            (.bright, segmentedComponents(in: bitmap, mode: .bright)),
            (.dark, segmentedComponents(in: bitmap, mode: .dark))
        ]
        var best: SevenSegmentDigitSequenceResult?
        for attempt in attempts where !attempt.components.isEmpty {
            let digitComponents = attempt.components.filter { $0.kind == "digit" }
            guard digitComponents.count <= maxDigits, digitComponents.count >= (allowSingleDigit ? 1 : 2) else { continue }
            var digits: [Int] = []
            var confidences: [Float] = []
            var detail: [String] = []
            for component in digitComponents {
                let padded = component.rect.insetBy(dx: -0.020, dy: -0.045).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard let digit = recogniseDigit(in: image, normalizedRect: padded) else {
                    detail.append("miss@\(String(format: "%.2f", component.rect.minX))")
                    digits.removeAll()
                    break
                }
                digits.append(digit.value)
                confidences.append(digit.confidence)
                detail.append("\(digit.value)@\(String(format: "%.2f", component.rect.minX))/\(String(format: "%.2f", digit.confidence))")
            }
            guard !digits.isEmpty, digits.count == digitComponents.count else { continue }
            let avg = confidences.reduce(0, +) / Float(max(confidences.count, 1))
            guard avg >= 0.50 else { continue }
            let value = digits.map { String($0) }.joined()
            let result = SevenSegmentDigitSequenceResult(
                value: value,
                confidence: avg,
                rawDigits: value,
                diagnostic: "componentDigits mode=\(attempt.mode.label) digitCount=\(digits.count) comps=[\(componentSummary(attempt.components))] digits=[\(detail.joined(separator: ","))] conf=\(String(format: "%.2f", avg))",
                segmentRects: digitComponents.map { $0.rect.insetBy(dx: -0.020, dy: -0.045).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            )
            if best == nil || result.confidence > best!.confidence { best = result }
        }
        return best
    }

    private func recogniseDigitSequenceByFixedSlots(from image: CGImage, maxDigits: Int, allowSingleDigit: Bool) -> SevenSegmentDigitSequenceResult? {
        let ratio = CGFloat(image.width) / max(CGFloat(image.height), 1)
        let likelyDigits = min(maxDigits, max(1, Int((ratio / 0.55).rounded())))
        let counts = Array(Set([likelyDigits, maxDigits, allowSingleDigit ? 1 : maxDigits])).filter { $0 >= (allowSingleDigit ? 1 : 2) && $0 <= maxDigits }.sorted()
        var best: SevenSegmentDigitSequenceResult?
        for count in counts {
            var digits: [Int] = []
            var confidences: [Float] = []
            for slot in 0..<count {
                let rect = CGRect(x: CGFloat(slot) / CGFloat(count), y: 0, width: 1.0 / CGFloat(count), height: 1).insetBy(dx: 0.025, dy: 0.06)
                guard let digit = recogniseDigit(in: image, normalizedRect: rect) else {
                    digits.removeAll()
                    break
                }
                digits.append(digit.value)
                confidences.append(digit.confidence)
            }
            guard digits.count == count else { continue }
            let avg = confidences.reduce(0, +) / Float(max(confidences.count, 1))
            guard avg >= 0.50 else { continue }
            let value = digits.map { String($0) }.joined()
            let result = SevenSegmentDigitSequenceResult(
                value: value,
                confidence: avg,
                rawDigits: value,
                diagnostic: "fixedSlotDigits slots=\(count) raw=\(value) conf=\(String(format: "%.2f", avg))",
                segmentRects: (0..<count).map { index in CGRect(x: CGFloat(index) / CGFloat(count), y: 0, width: 1.0 / CGFloat(count), height: 1).insetBy(dx: 0.025, dy: 0.06) }
            )
            if best == nil || result.confidence > best!.confidence { best = result }
        }
        return best
    }

    private func rawComponentDebug(in bitmap: GrayBitmap, mode: SegmentMode) -> String {
        let width = bitmap.width
        let height = bitmap.height
        guard width > 8, height > 8 else { return "bitmap-too-small" }

        var activeColumns = [Bool](repeating: false, count: width)
        let minColumnPixels = max(1, Int(Double(height) * 0.008))
        for x in 0..<width {
            var active = 0
            for y in 0..<height {
                if isActive(bitmap.data[y * width + x], mode: mode) { active += 1 }
            }
            activeColumns[x] = active >= minColumnPixels
        }

        let maxGap = max(3, Int(Double(width) * 0.035))
        var runs: [(start: Int, end: Int)] = []
        var start: Int?
        var lastActive: Int?
        for x in 0..<width {
            if activeColumns[x] {
                if start == nil { start = x }
                lastActive = x
            } else if let s = start, let last = lastActive, x - last > maxGap {
                runs.append((s, last))
                start = nil
                lastActive = nil
            }
        }
        if let s = start, let last = lastActive { runs.append((s, last)) }
        if runs.isEmpty { return "no-column-runs minCol=\(minColumnPixels) gap=\(maxGap)" }

        var parts: [String] = []
        for (index, run) in runs.prefix(12).enumerated() {
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1
            var active = 0
            for y in 0..<height {
                for x in max(0, run.start)..<min(width, run.end + 1) {
                    if isActive(bitmap.data[y * width + x], mode: mode) {
                        minX = Swift.min(minX, x)
                        minY = Swift.min(minY, y)
                        maxX = Swift.max(maxX, x)
                        maxY = Swift.max(maxY, y)
                        active += 1
                    }
                }
            }
            if maxX <= minX || maxY <= minY {
                parts.append("#\(index) run=\(run.start)-\(run.end) reject=empty")
                continue
            }
            let rect = CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: CGFloat(maxX - minX + 1) / CGFloat(width),
                height: CGFloat(maxY - minY + 1) / CGFloat(height)
            )
            let areaPixels = max(1, (maxX - minX + 1) * (maxY - minY + 1))
            let fill = Double(active) / Double(areaPixels)
            var reasons: [String] = []
            if rect.width <= 0.006 { reasons.append("too-narrow") }
            if rect.height <= 0.075 { reasons.append("too-short") }
            if fill <= 0.003 { reasons.append("too-sparse") }
            if rect.width >= 0.985 { reasons.append("too-wide") }
            if rect.height >= 0.995 { reasons.append("too-tall") }
            let aspect = rect.width / max(rect.height, 0.001)
            let kind = (rect.height < 0.46 && rect.width < 0.16) || aspect < 0.22 ? "colon" : "digit"
            let status = reasons.isEmpty ? "kept" : "reject=\(reasons.joined(separator: "+"))"
            parts.append("#\(index) \(kind):\(String(format: "%.2f", rect.minX))-\(String(format: "%.2f", rect.maxX))x\(String(format: "%.2f", rect.minY))-\(String(format: "%.2f", rect.maxY))/fill=\(String(format: "%.3f", fill))/\(status)")
        }
        if runs.count > 12 { parts.append("+\(runs.count - 12) more") }
        return parts.joined(separator: ";")
    }

    private func activePixelSummary(in bitmap: GrayBitmap, mode: SegmentMode) -> String {
        var active = 0
        for pixel in bitmap.data where isActive(pixel, mode: mode) { active += 1 }
        let total = max(1, bitmap.width * bitmap.height)
        let pct = Double(active) * 100.0 / Double(total)
        return "active=\(String(format: "%.1f", pct))%"
    }

    private func componentSummary(_ components: [SevenSegmentComponent]) -> String {
        if components.isEmpty { return "none" }
        return components.map { c in
            "\(c.kind):\(String(format: "%.2f", c.rect.minX))-\(String(format: "%.2f", c.rect.maxX))x\(String(format: "%.2f", c.rect.minY))-\(String(format: "%.2f", c.rect.maxY))/fill=\(String(format: "%.2f", c.fill))"
        }.joined(separator: ";")
    }

    private func isActive(_ pixel: UInt8, mode: SegmentMode) -> Bool {
        switch mode {
        case .bright: return pixel > 135
        case .dark: return pixel < 85
        }
    }

    private struct DigitResult {
        let value: Int
        let confidence: Float
    }

    private func recogniseDigit(in image: CGImage, normalizedRect: CGRect) -> DigitResult? {
        let pixelRect = CGRect(
            x: normalizedRect.minX * CGFloat(image.width),
            y: normalizedRect.minY * CGFloat(image.height),
            width: normalizedRect.width * CGFloat(image.width),
            height: normalizedRect.height * CGFloat(image.height)
        ).integral

        guard pixelRect.width > 4,
              pixelRect.height > 4,
              let sub = image.cropping(to: pixelRect),
              let bitmap = grayscaleBitmap(from: sub) else { return nil }

        let bright = recogniseDigit(in: bitmap, mode: .bright)
        let dark = recogniseDigit(in: bitmap, mode: .dark)

        switch (bright, dark) {
        case let (b?, d?): return b.confidence >= d.confidence ? b : d
        case let (b?, nil): return b
        case let (nil, d?): return d
        default: return nil
        }
    }

    private enum SegmentMode {
        case bright
        case dark

        var label: String {
            switch self {
            case .bright: return "bright"
            case .dark: return "dark"
            }
        }
    }

    private func recogniseDigit(in bitmap: GrayBitmap, mode: SegmentMode) -> DigitResult? {
        let activeFill = fillRatio(bitmap, mode: mode, x: 0, y: 0, w: 1, h: 1)
        guard activeFill > 0.0025, activeFill < 0.82 else { return nil }

        let segments: [Bool] = [
            segmentOn(bitmap, mode: mode, x: 0.25, y: 0.06, w: 0.50, h: 0.13), // top
            segmentOn(bitmap, mode: mode, x: 0.08, y: 0.20, w: 0.20, h: 0.30), // upper-left
            segmentOn(bitmap, mode: mode, x: 0.72, y: 0.20, w: 0.20, h: 0.30), // upper-right
            segmentOn(bitmap, mode: mode, x: 0.25, y: 0.43, w: 0.50, h: 0.14), // middle
            segmentOn(bitmap, mode: mode, x: 0.08, y: 0.56, w: 0.20, h: 0.30), // lower-left
            segmentOn(bitmap, mode: mode, x: 0.72, y: 0.56, w: 0.20, h: 0.30), // lower-right
            segmentOn(bitmap, mode: mode, x: 0.25, y: 0.83, w: 0.50, h: 0.13)  // bottom
        ]

        let patterns: [String: Int] = [
            "1110111": 0,
            "0010010": 1,
            "1011101": 2,
            "1011011": 3,
            "0111010": 4,
            "1101011": 5,
            "1101111": 6,
            "1010010": 7,
            "1111111": 8,
            "1111011": 9
        ]

        let observed = segments.map { $0 ? "1" : "0" }.joined()
        var best: (digit: Int, distance: Int)?
        for (pattern, digit) in patterns {
            let distance = zip(pattern, observed).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            if best == nil || distance < best!.distance {
                best = (digit, distance)
            }
        }

        guard let best, best.distance <= 2 else { return nil }
        let confidence = max(0, 1.0 - Float(best.distance) / 7.0)
        return DigitResult(value: best.digit, confidence: confidence)
    }

    private struct GrayBitmap {
        let width: Int
        let height: Int
        let data: [UInt8]
    }

    private func grayscaleBitmap(from image: CGImage) -> GrayBitmap? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayBitmap(width: width, height: height, data: pixels)
    }

    private func segmentOn(_ bitmap: GrayBitmap, mode: SegmentMode, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Bool {
        fillRatio(bitmap, mode: mode, x: x, y: y, w: w, h: h) > 0.075
    }

    private func fillRatio(_ bitmap: GrayBitmap, mode: SegmentMode, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Double {
        let minX = max(Int(x * CGFloat(bitmap.width)), 0)
        let minY = max(Int(y * CGFloat(bitmap.height)), 0)
        let maxX = min(Int((x + w) * CGFloat(bitmap.width)), bitmap.width)
        let maxY = min(Int((y + h) * CGFloat(bitmap.height)), bitmap.height)
        guard maxX > minX, maxY > minY else { return 0 }

        var active = 0
        var total = 0
        for row in minY..<maxY {
            for col in minX..<maxX {
                let pixel = bitmap.data[row * bitmap.width + col]
                switch mode {
                case .bright:
                    if pixel > 135 { active += 1 }
                case .dark:
                    if pixel < 85 { active += 1 }
                }
                total += 1
            }
        }
        return Double(active) / Double(max(total, 1))
    }
}

#endif
