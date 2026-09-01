// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Vision
import CoreVideo
import CoreGraphics
import CoreImage
import CoreFoundation
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

// MARK: - OCR Processor

/// Controls whether an OCR pass may enter framework text-recognition APIs whose
/// synchronous execution time is not bounded by the app. Production publication stays
/// on the bounded dynamic-token path except for one low-frequency, event-only fast Vision
/// recovery that may supply a validated two-digit penalty player. Explicit diagnostics
/// may additionally inspect legacy seven-segment, Vision and ML Kit fallbacks.
nonisolated enum RinkLensOCRExecutionPolicy: String, Sendable, Equatable {
    case liveBounded
    case diagnostics

    var allowsFrameworkTextFallback: Bool { self == .diagnostics }
    var allowsOrientationFallback: Bool { self == .diagnostics }
}

/// Exact processor stage owned by the single OCR executor. This is diagnostic state,
/// not a watchdog: it identifies the call that is currently executing without
/// creating replacement work.
nonisolated enum RinkLensOCRProcessingStage: String, Sendable, Equatable {
    case idle
    case fieldSetup
    case segmentation
    case vision
    case mlKit
    case enhancedVision
    case pipelineDiagnostics
    case publication
}

/// R20 one-owner Core Image resource for scoreboard processing. The context is
/// created lazily on the first background processing pass and is reused by live
/// Image Relay, OCR and selected-zone crop work. CIContext is designed for reuse;
/// keeping one context avoids five independent Metal/kernel/intermediate caches.
nonisolated final class ScoreboardImageProcessingResources: @unchecked Sendable {
    static let shared = ScoreboardImageProcessingResources()

    let ciContext: CIContext

    private init() {
        ciContext = CIContext(options: [.cacheIntermediates: false])
    }
}

nonisolated final class ScoreboardOCRProcessor: @unchecked Sendable {
    private let periodAllowedValues: Set<String> = ["1", "2", "3", "4", "5", "OT", "SO"]
    private let resources: ScoreboardImageProcessingResources
    private var ciContext: CIContext { resources.ciContext }
    private let sevenSegmentTimerRecognizer = SevenSegmentTimerRecognizer()

    init(resources: ScoreboardImageProcessingResources = .shared) {
        self.resources = resources
    }
    // v0.5.3: cache Vision requests. The OCR queue is serial, so these requests
    // are reused safely and we avoid recreating VNRecognizeTextRequest objects
    // for every sampled frame.
    private var cachedVisionRequests: [OCRRegionKey: VNRecognizeTextRequest] = [:]
    #if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
    private lazy var mlKitTextRecognizer = TextRecognizer.textRecognizer(options: TextRecognizerOptions())
    #endif

    private struct OCRCandidate {
        let raw: String
        let cleaned: String
        let confidence: Float
        let accepted: Bool
        let reason: String?
        let recognizer: RecognitionStrategy
    }

    private struct RecognizedTextCandidate {
        let text: String
        let confidence: Float
        let recognizer: RecognitionStrategy
    }

    struct OCRFieldDebug {
        let key: OCRRegionKey
        let raw: String
        let cleaned: String
        let accepted: String
        let recognizer: RecognitionStrategy
        let confidence: Float
        let validation: String
        let pipelineDiagnostic: String
        let mirrorApplied: Bool
    }

    struct RegionSuggestion {
        let region: OCRRegion
        let previewText: String
        let confidence: Float
    }

    /// The single authoritative field crop used by the UX16d2g2 template
    /// decoder. `sourceNormalizedRect` is expressed in the oriented 16:9 camera
    /// frame; `boardNormalizedRect` is the same field after the saved board quad
    /// has been rectified to a unit rectangle.
    struct TemplateFieldCropEvidence {
        let image: CGImage
        let sourceNormalizedRect: CGRect
        let boardNormalizedRect: CGRect
    }

    /// Rectified-board context used by Guided Calibration. `image` includes a
    /// magnification-dependent margin around the selected field, while
    /// `zoneNormalizedRect` identifies the exact live/Test OCR crop inside it.
    struct TemplateFieldLoupeEvidence {
        let image: CGImage
        let zoneNormalizedRect: CGRect
    }


    /// UX16d7: builds one perspective-corrected board image, crops each saved
    /// field in the same rectified coordinate space used by live/Test OCR, then
    /// hashes the complete field crop. The previous implementation sampled only
    /// 64 isolated camera pixels and could miss a narrow segment changing between
    /// sample points. This block-average perceptual hash lets every pixel in the
    /// corrected zone contribute while remaining a cheap UInt64 scheduler hint.
    func regionVisualHashes(
        from pixelBuffer: CVPixelBuffer,
        layout: ScoreboardOCRLayout,
        boardCalibration: BoardCalibrationQuad,
        keys: Set<OCRRegionKey>,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize,
        sampleGrid: Int = 8,
        previewRotationDegrees: CGFloat = 0
    ) -> [OCRRegionKey: UInt64] {
        guard !keys.isEmpty else { return [:] }

        let orientation = visionOrientation(for: deviceOrientation)
        let sourceQuad = rotatedBoardCalibration(
            boardCalibration,
            by: previewRotationDegrees
        )
        guard let boardImage = perspectiveCorrectedBoardImage(
            from: pixelBuffer,
            orientation: orientation,
            quad: sourceQuad,
            maximumDimension: 768
        ) else { return [:] }

        var hashes: [OCRRegionKey: UInt64] = [:]
        hashes.reserveCapacity(keys.count)
        for key in keys {
            let regionModel = layout[key]
            let sourceRegion = fieldInputRegion(
                from: regionModel.rect,
                boardCalibration: sourceQuad,
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees
            )
            guard let crop = rawTemplateFieldCrop(
                boardImage: boardImage,
                sourceUIRegion: sourceRegion,
                boardCalibration: sourceQuad,
                regionRotationDegrees: regionModel.rotationDegrees,
                cropPaddingPercent: 0,
                fieldKey: key
            ), let hash = wholeZonePerceptualHash(
                from: crop.image,
                sampleGrid: sampleGrid
            ) else { continue }
            hashes[key] = hash
        }
        return hashes
    }

    /// Build 747 high-resolution Clock path. Perspective-correct only the
    /// requested field directly from the original camera buffer. This preserves
    /// native digit pixels without paying for a full high-resolution board render.
    func imageRelayDirectFieldCrop(
        from pixelBuffer: CVPixelBuffer,
        layout: ScoreboardOCRLayout,
        boardCalibration: BoardCalibrationQuad,
        key: OCRRegionKey,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        maximumDimension: CGFloat = 640
    ) -> CGImage? {
        let orientation = visionOrientation(for: deviceOrientation)
        let sourceQuad = rotatedBoardCalibration(boardCalibration, by: previewRotationDegrees)
        let regionModel = layout[key]
        let padding: CGFloat
        switch key {
        case .clock:
            padding = BroadcastScorebugTemplateMetrics.clockSourceCropPaddingFraction
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            padding = 0.08
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            padding = 0.12
        default:
            padding = 0
        }

        let sourceCorners: [CGPoint]
        if sourceQuad.zonesFollowPerspective {
            let boardRegion = BoardPerspectiveMapper.clampedUnitRect(
                regionModel.rect.insetBy(dx: -regionModel.rect.width * padding, dy: -regionModel.rect.height * padding),
                minimumSize: 0.001
            )
            guard let projected = BoardPerspectiveMapper.projectedCorners(of: boardRegion, through: sourceQuad) else {
                return nil
            }
            sourceCorners = projected
        } else {
            let sourceRegion = fieldInputRegion(
                from: regionModel.rect,
                boardCalibration: sourceQuad,
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees
            )
            let expanded = BoardPerspectiveMapper.clampedUnitRect(
                sourceRegion.insetBy(dx: -sourceRegion.width * padding, dy: -sourceRegion.height * padding),
                minimumSize: 0.001
            )
            sourceCorners = [
                CGPoint(x: expanded.minX, y: expanded.minY),
                CGPoint(x: expanded.maxX, y: expanded.minY),
                CGPoint(x: expanded.maxX, y: expanded.maxY),
                CGPoint(x: expanded.minX, y: expanded.maxY)
            ]
        }
        guard sourceCorners.count == 4 else { return nil }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(orientation.rawValue))
        let extent = image.extent
        let toPoint: (CGPoint) -> CGPoint = { normalized in
            CGPoint(
                x: extent.minX + normalized.x * extent.width,
                y: extent.minY + (1 - normalized.y) * extent.height
            )
        }
        let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: toPoint(sourceCorners[0])),
            "inputTopRight": CIVector(cgPoint: toPoint(sourceCorners[1])),
            "inputBottomRight": CIVector(cgPoint: toPoint(sourceCorners[2])),
            "inputBottomLeft": CIVector(cgPoint: toPoint(sourceCorners[3]))
        ])
        guard var output = renderCanonicalBoardImage(
            corrected,
            extent: corrected.extent.integral,
            maximumDimension: maximumDimension,
            materialiseForCPUProcessing: true
        ) else { return nil }

        if abs(regionModel.rotationDegrees) > 0.05 {
            let source = CIImage(cgImage: output)
            let sourceExtent = source.extent
            let radians = regionModel.rotationDegrees * .pi / 180
            let centre = CGPoint(x: sourceExtent.midX, y: sourceExtent.midY)
            let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: radians)
                .translatedBy(x: -centre.x, y: -centre.y)
            let rotated = source.transformed(by: transform).cropped(to: sourceExtent)
            guard let rendered = ciContext.createCGImage(rotated, from: sourceExtent) else { return nil }
            output = rendered
        }
        return output
    }

    /// R21 real-time Image Relay path. Each due field is warped directly from
    /// the source frame at a field-sized output. This avoids constructing a 1280px
    /// perspective-corrected whole scoreboard merely to obtain a ~350x100 Clock.
    /// The shared ScoreboardOCRProcessor/CIContext remains the sole image resource owner.
    func imageRelayDirectFieldCrops(
        from pixelBuffer: CVPixelBuffer,
        layout: ScoreboardOCRLayout,
        boardCalibration: BoardCalibrationQuad,
        keys: Set<OCRRegionKey>,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0
    ) -> [OCRRegionKey: CGImage] {
        var crops: [OCRRegionKey: CGImage] = [:]
        crops.reserveCapacity(keys.count)
        for key in keys {
            let maximumDimension: CGFloat
            switch key {
            case .clock: maximumDimension = 480
            case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time: maximumDimension = 420
            case .homeScore, .awayScore: maximumDimension = 280
            case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player: maximumDimension = 240
            case .period: maximumDimension = 220
            default: maximumDimension = 320
            }
            if let crop = imageRelayDirectFieldCrop(
                from: pixelBuffer,
                layout: layout,
                boardCalibration: boardCalibration,
                key: key,
                deviceOrientation: deviceOrientation,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                maximumDimension: maximumDimension
            ) {
                crops[key] = crop
            }
        }
        return crops
    }

    /// Build 550: hashes the foreground occupancy of the perspective-corrected
    /// field rather than thresholding full-zone greyscale blocks against their
    /// median. Scoreboard crops are mostly black; the previous zero-median comparison
    /// rule could therefore turn nearly every block on when the median was zero,
    /// making narrow changes such as 0 -> 1 effectively invisible.
    ///
    /// The new signature estimates the border/background colour, creates a
    /// noise-filtered foreground mask from colour/luminance distance, normalises
    /// to the active glyph bounds, and records 8x8 block occupancy. Blank fields
    /// return zero, while a digit appearing, disappearing or changing shape alters
    /// several stable bits without depending on isolated point samples.
    private func wholeZonePerceptualHash(
        from image: CGImage,
        sampleGrid: Int
    ) -> UInt64? {
        let grid = max(4, min(8, sampleGrid))
        let workingWidth = max(72, grid * 12)
        let workingHeight = max(48, grid * 8)
        let bytesPerPixel = 4
        let bytesPerRow = workingWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * workingHeight)

        let rendered = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: workingWidth,
                    height: workingHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }

            context.interpolationQuality = .medium
            context.setShouldAntialias(true)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: workingWidth, height: workingHeight)
            )
            return true
        }
        guard rendered else { return nil }

        func channelMedian(_ values: [UInt8]) -> Int {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return Int(sorted[sorted.count / 2])
        }

        // Use the outer two-pixel ring as the local scoreboard background model.
        // This follows exposure/black-level drift without allowing the glyph itself
        // to define the threshold.
        var borderR: [UInt8] = []
        var borderG: [UInt8] = []
        var borderB: [UInt8] = []
        borderR.reserveCapacity((workingWidth + workingHeight) * 4)
        borderG.reserveCapacity((workingWidth + workingHeight) * 4)
        borderB.reserveCapacity((workingWidth + workingHeight) * 4)

        for y in 0..<workingHeight {
            for x in 0..<workingWidth where x < 2 || y < 2 || x >= workingWidth - 2 || y >= workingHeight - 2 {
                let offset = y * bytesPerRow + x * bytesPerPixel
                borderR.append(pixels[offset])
                borderG.append(pixels[offset + 1])
                borderB.append(pixels[offset + 2])
            }
        }

        let backgroundR = channelMedian(borderR)
        let backgroundG = channelMedian(borderG)
        let backgroundB = channelMedian(borderB)
        let backgroundLuma = (77 * backgroundR + 150 * backgroundG + 29 * backgroundB) >> 8

        var rawMask = [UInt8](repeating: 0, count: workingWidth * workingHeight)
        for y in 0..<workingHeight {
            for x in 0..<workingWidth {
                let pixelOffset = y * bytesPerRow + x * bytesPerPixel
                let r = Int(pixels[pixelOffset])
                let g = Int(pixels[pixelOffset + 1])
                let b = Int(pixels[pixelOffset + 2])
                let luma = (77 * r + 150 * g + 29 * b) >> 8
                let colourDistance = max(abs(r - backgroundR), max(abs(g - backgroundG), abs(b - backgroundB)))
                let lumaDistance = luma - backgroundLuma

                // Coloured red/yellow digits are selected by colour distance;
                // white digits are selected by luminance distance. Requiring both
                // a material local difference and some brightness rise suppresses
                // compression noise in the black background.
                if (colourDistance >= 22 && lumaDistance >= 8) || lumaDistance >= 30 {
                    rawMask[y * workingWidth + x] = 1
                }
            }
        }

        // Remove isolated one-pixel noise before measuring active bounds. A real
        // scoreboard stroke contributes a small connected neighbourhood even after
        // downscaling; single compression/reflection specks do not.
        var mask = [UInt8](repeating: 0, count: rawMask.count)
        if workingWidth > 2 && workingHeight > 2 {
            for y in 1..<(workingHeight - 1) {
                for x in 1..<(workingWidth - 1) where rawMask[y * workingWidth + x] != 0 {
                    var neighbours = 0
                    for ny in (y - 1)...(y + 1) {
                        for nx in (x - 1)...(x + 1) where rawMask[ny * workingWidth + nx] != 0 {
                            neighbours += 1
                        }
                    }
                    if neighbours >= 3 {
                        mask[y * workingWidth + x] = 1
                    }
                }
            }
        }

        var minX = workingWidth
        var minY = workingHeight
        var maxX = -1
        var maxY = -1
        var activePixelCount = 0
        for y in 0..<workingHeight {
            for x in 0..<workingWidth where mask[y * workingWidth + x] != 0 {
                activePixelCount += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        // A confirmed blank has a deterministic zero signature. Keep the minimum
        // deliberately small because player number 1 can be a very narrow glyph.
        guard activePixelCount >= 4, maxX >= minX, maxY >= minY else { return 0 }

        minX = max(0, minX - 1)
        minY = max(0, minY - 1)
        maxX = min(workingWidth - 1, maxX + 1)
        maxY = min(workingHeight - 1, maxY + 1)
        let activeWidth = maxX - minX + 1
        let activeHeight = maxY - minY + 1

        var hash: UInt64 = 0
        for row in 0..<grid {
            let startY = minY + (activeHeight * row) / grid
            let endY = minY + max(1, (activeHeight * (row + 1)) / grid)
            for column in 0..<grid {
                let startX = minX + (activeWidth * column) / grid
                let endX = minX + max(1, (activeWidth * (column + 1)) / grid)
                let boundedEndX = min(maxX + 1, max(startX + 1, endX))
                let boundedEndY = min(maxY + 1, max(startY + 1, endY))

                var active = 0
                var area = 0
                for y in startY..<boundedEndY {
                    for x in startX..<boundedEndX {
                        area += 1
                        active += Int(mask[y * workingWidth + x])
                    }
                }

                // Low occupancy is intentional: thin solid-font 1s and narrow
                // seven-segment strokes must still affect the signature.
                let required = max(1, Int(ceil(Double(area) * 0.06)))
                if active >= required {
                    let bit = row * grid + column
                    if bit < 64 { hash |= UInt64(1) << bit }
                }
            }
        }
        return hash
    }

    func detectSuggestedRegions(
        from pixelBuffer: CVPixelBuffer,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize
    ) -> [OCRRegionKey: RegionSuggestion] {
        let orientation = visionOrientation(for: deviceOrientation)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            try handler.perform([request])
            let observations = request.results ?? []
            var suggestions: [OCRRegionKey: RegionSuggestion] = [:]

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let uiRect = CGRect(
                    x: observation.boundingBox.minX,
                    y: 1 - observation.boundingBox.maxY,
                    width: observation.boundingBox.width,
                    height: observation.boundingBox.height
                )
                let key = classifySuggestedKey(text: text, rect: uiRect)
                guard let key else { continue }

                let region = OCRRegion(
                    x: max(0, uiRect.minX - 0.01),
                    y: max(0, uiRect.minY - 0.01),
                    width: min(1 - max(0, uiRect.minX - 0.01), uiRect.width + 0.02),
                    height: min(1 - max(0, uiRect.minY - 0.01), uiRect.height + 0.02)
                )
                let confidence = candidate.confidence
                let suggestion = RegionSuggestion(region: region, previewText: text, confidence: confidence)
                if suggestions[key] == nil || confidence > suggestions[key]!.confidence {
                    suggestions[key] = suggestion
                }
            }

            _ = previewSize
            return suggestions
        } catch {
            return [:]
        }
    }

    /// Produces the exact rectified saved-field crop consumed by the dynamic-token
    /// decoder. Calibration preview code may call this method so the operator is
    /// shown the same pixels that live/Test OCR receives rather than a separate
    /// full-frame crop path.
    func templateFieldCropEvidence(
        from pixelBuffer: CVPixelBuffer,
        uiRegion: CGRect,
        boardCalibration: BoardCalibrationQuad,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        regionRotationDegrees: CGFloat,
        key: OCRRegionKey? = nil,
        maximumBoardDimension: CGFloat = 1920
    ) -> TemplateFieldCropEvidence? {
        let orientation = visionOrientation(for: deviceOrientation)
        let sourceQuad = rotatedBoardCalibration(
            boardCalibration,
            by: previewRotationDegrees
        )
        guard let boardImage = perspectiveCorrectedBoardImage(
            from: pixelBuffer,
            orientation: orientation,
            quad: sourceQuad,
            maximumDimension: maximumBoardDimension
        ) else { return nil }
        let sourceRegion = fieldInputRegion(
            from: uiRegion,
            boardCalibration: sourceQuad,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
        return rawTemplateFieldCrop(
            boardImage: boardImage,
            sourceUIRegion: sourceRegion,
            boardCalibration: sourceQuad,
            regionRotationDegrees: regionRotationDegrees,
            cropPaddingPercent: 0,
            fieldKey: key
        )
    }

    /// Produces a Guided Calibration loupe from the same perspective-corrected
    /// board image and field mapping used by live/Test OCR. This removes the old
    /// mismatch where the guide showed an aspect-filled full-camera rectangle.
    func templateFieldLoupeEvidence(
        from pixelBuffer: CVPixelBuffer,
        uiRegion: CGRect,
        boardCalibration: BoardCalibrationQuad,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        regionRotationDegrees: CGFloat,
        key: OCRRegionKey? = nil,
        magnification: CGFloat,
        maximumBoardDimension: CGFloat = 960
    ) -> TemplateFieldLoupeEvidence? {
        let orientation = visionOrientation(for: deviceOrientation)
        let sourceQuad = rotatedBoardCalibration(boardCalibration, by: previewRotationDegrees)
        guard let boardImage = perspectiveCorrectedBoardImage(
            from: pixelBuffer,
            orientation: orientation,
            quad: sourceQuad,
            maximumDimension: maximumBoardDimension
        ) else { return nil }

        let sourceRegion = fieldInputRegion(
            from: uiRegion,
            boardCalibration: sourceQuad,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
        guard let exact = rawTemplateFieldCrop(
            boardImage: boardImage,
            sourceUIRegion: sourceRegion,
            boardCalibration: sourceQuad,
            regionRotationDegrees: regionRotationDegrees,
            cropPaddingPercent: 0,
            fieldKey: key
        ) else { return nil }

        // A rotated field is safest shown exactly as OCR receives it. For normal
        // zero-degree fields, include rectified-board context so the operator can
        // see which edge needs moving while the cyan rectangle stays exact.
        if abs(regionRotationDegrees) > 0.05 {
            return TemplateFieldLoupeEvidence(
                image: exact.image,
                zoneNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        }

        let factor: CGFloat
        switch magnification {
        case 0..<1.5: factor = 3.2
        case 1.5..<3: factor = 2.2
        case 3..<6: factor = 1.55
        default: factor = 1.24
        }

        let field = exact.boardNormalizedRect
        let contextWidth = min(1, max(field.width * factor, field.width + 0.004))
        let contextHeight = min(1, max(field.height * factor, field.height + 0.004))
        let context = CGRect(
            x: max(0, min(1 - contextWidth, field.midX - contextWidth / 2)),
            y: max(0, min(1 - contextHeight, field.midY - contextHeight / 2)),
            width: contextWidth,
            height: contextHeight
        )

        let boardWidth = CGFloat(boardImage.width)
        let boardHeight = CGFloat(boardImage.height)
        let pixelRect = CGRect(
            x: context.minX * boardWidth,
            y: context.minY * boardHeight,
            width: context.width * boardWidth,
            height: context.height * boardHeight
        ).integral.intersection(CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight))
        guard pixelRect.width > 8, pixelRect.height > 8,
              let contextImage = boardImage.cropping(to: pixelRect) else { return nil }

        // Build 672: the actual CGImage crop uses integral pixel boundaries.
        // Calculate the cyan zone from that exact crop, rather than the earlier
        // floating-point context rectangle, so the left/right outline always
        // covers the same pixels displayed by the loupe.
        let actualContext = CGRect(
            x: pixelRect.minX / boardWidth,
            y: pixelRect.minY / boardHeight,
            width: pixelRect.width / boardWidth,
            height: pixelRect.height / boardHeight
        )
        let zoneRect = CGRect(
            x: (field.minX - actualContext.minX) / actualContext.width,
            y: (field.minY - actualContext.minY) / actualContext.height,
            width: field.width / actualContext.width,
            height: field.height / actualContext.height
        )
        return TemplateFieldLoupeEvidence(
            image: contextImage,
            zoneNormalizedRect: BoardPerspectiveMapper.clampedUnitRect(zoneRect, minimumSize: 0.001)
        )
    }

    func parseScoreboard(
        from pixelBuffer: CVPixelBuffer,
        layout: ScoreboardOCRLayout,
        boardCalibration: BoardCalibrationQuad,
        scoreboardTemplate: RinkScoreboardTemplate?,
        thresholds: OCRThresholds,
        colourProfiles: OCRColourProfileSet = .defaults,
        deviceOrientation: UIDeviceOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        enableSegmentedFallback: Bool,
        keysToProcess: Set<OCRRegionKey>? = nil,
        processorAllowedKeys: Set<OCRRegionKey>? = nil,
        includePipelineDiagnostics: Bool = false,
        executionPolicy: RinkLensOCRExecutionPolicy = .diagnostics,
        maximumProcessingSeconds: TimeInterval = 0.55,
        sourceFrameID: Int? = nil,
        captureGeneration: Int = 0,
        stageObserver: (@Sendable (RinkLensOCRProcessingStage, OCRRegionKey?) -> Void)? = nil
    ) -> (state: ScoreboardState, rawText: String?, fieldDebug: [OCRFieldDebug])? {
        let processingStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let boundedSeconds = max(0.10, min(1.50, maximumProcessingSeconds))
        let deadlineUptimeNanoseconds = processingStartedUptimeNanoseconds + UInt64(boundedSeconds * 1_000_000_000)
        let primaryOrientation = visionOrientation(for: deviceOrientation)
        let candidateOrientations: [CGImagePropertyOrientation]
        if executionPolicy.allowsOrientationFallback {
            candidateOrientations = primaryOrientation == .up ? [.up, .right] : [primaryOrientation, .up]
        } else {
            // UX16d2b root correction: the CaptureEngine/OCR crop contract already has
            // one authoritative landscape orientation. Continuous OCR must not eagerly
            // execute a second orientation after the first useful result.
            candidateOrientations = [primaryOrientation]
        }
        // UX16d2g2 converts the saved board quad and every field from the same
        // preview/letterbox coordinate space into the oriented camera frame before
        // rectification. UX16d2g1 rectified the board but then applied the original
        // full-frame field rectangles directly to the board-only image.
        let sourceBoardQuad = rotatedBoardCalibration(
            boardCalibration,
            by: previewRotationDegrees
        )
        guard let boardImage = perspectiveCorrectedBoardImage(
            from: pixelBuffer,
            orientation: primaryOrientation,
            quad: sourceBoardQuad,
            maximumDimension: executionPolicy == .liveBounded ? 1280 : 1920
        ) else { return nil }

        // v0.8.1.7e: PROCESSOR-LEVEL OCR GATE.
        // The ViewModel scheduler decides which fields are due, but the OCR
        // processor also enforces the final allowed field set before any crop,
        // segmentation, Vision or ML Kit recognition work is created. This means a
        // stale scheduler decision cannot accidentally run score/period/penalty OCR
        // while the clock is running or not yet confirmed stopped.
        let activeKeys = Set(OCRRegionKey.productionOCRCases)
        let requestedKeys = keysToProcess.map { $0.intersection(activeKeys) } ?? activeKeys
        let allowedKeys = processorAllowedKeys.map { $0.intersection(activeKeys) } ?? activeKeys
        let effectiveKeys = requestedKeys.intersection(allowedKeys)
        // Build 633: this production processor is deliberately limited to the
        // authorised metadata fields. Clock and penalty-timer zones remain fully
        // calibrated for Image Relay, but they must never enter the OCR work list.
        // Scores run first so viewer values and goal candidates resolve promptly;
        // Period and penalty-player identity follow within the remaining budget.
        let processingPriority: [OCRRegionKey] = [
            .homeScore, .awayScore, .period,
            .homePenalty1Player, .awayPenalty1Player,
            .homePenalty2Player, .awayPenalty2Player
        ]
        let regionKeys = processingPriority.filter { effectiveKeys.contains($0) }
        guard !regionKeys.isEmpty else { return nil }

        var candidates: [OCRRegionKey: OCRCandidate] = [:]
        var fieldElapsedMilliseconds: [OCRRegionKey: Double] = [:]
        candidates.reserveCapacity(regionKeys.count)
        fieldElapsedMilliseconds.reserveCapacity(regionKeys.count)
        for key in regionKeys {
            guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else { break }
            let fieldStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            stageObserver?(.fieldSetup, key)
            let regionModel = layout[key]
            let region = regionModel.rect
            var best: OCRCandidate?
            for orientation in candidateOrientations {
                let candidate = recognizeCandidate(
                    for: key,
                    in: region,
                    regionRotationDegrees: regionModel.rotationDegrees,
                    pixelBuffer: pixelBuffer,
                    boardImage: orientation == primaryOrientation ? boardImage : nil,
                    boardCalibration: sourceBoardQuad,
                    orientation: orientation,
                    thresholds: thresholds,
                    colourProfile: colourProfiles.profile(for: key),
                    previewRotationDegrees: previewRotationDegrees,
                    previewSize: previewSize,
                    enableSegmentedFallback: enableSegmentedFallback,
                    executionPolicy: executionPolicy,
                    reserveTimerRecovery: executionPolicy == .liveBounded,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                    sourceFrameID: sourceFrameID,
                    captureGeneration: captureGeneration,
                    stageObserver: stageObserver
                )
                if best == nil
                    || (candidate.accepted && best?.accepted == false)
                    || (candidate.accepted == best?.accepted && candidate.confidence > (best?.confidence ?? 0)) {
                    best = candidate
                }
                // UX16d2b root correction: do not run a fallback orientation after a
                // strong deterministic segmented result has already solved the field.
                if candidate.accepted, candidate.recognizer == .segmented, candidate.confidence >= 0.85 {
                    break
                }
            }
            candidates[key] = best ?? OCRCandidate(raw: "", cleaned: "", confidence: 0, accepted: false, reason: "no text", recognizer: .vision)
            fieldElapsedMilliseconds[key] = Double(
                DispatchTime.now().uptimeNanoseconds - fieldStartedUptimeNanoseconds
            ) / 1_000_000
        }
        guard !candidates.isEmpty else { return nil }

        var state = ScoreboardState()
        state.homeTeam = "HOME"
        state.awayTeam = "GUEST"
        state.clock = parseClock(candidates[.clock]?.cleaned ?? "")
        let periodToken = candidates[.period]?.cleaned ?? ""
        state.period = parsePeriod(periodToken)
        state.periodLabel = periodAllowedValues.contains(periodToken) ? periodToken : nil
        state.homeScore = parseScoreInt(candidates[.homeScore]?.cleaned ?? "")
        state.awayScore = parseScoreInt(candidates[.awayScore]?.cleaned ?? "")
        // Shots have been removed from OCR and scoreboard display to reduce live workload.
        state.homeShots = nil
        state.awayShots = nil

        state.homePenalty1Player = parsePlayer(candidates[.homePenalty1Player]?.cleaned ?? "")
        state.homePenalty1Clock = parsePenaltyClock(candidates[.homePenalty1Time]?.cleaned ?? "")
        state.homePenalty2Player = parsePlayer(candidates[.homePenalty2Player]?.cleaned ?? "")
        state.homePenalty2Clock = parsePenaltyClock(candidates[.homePenalty2Time]?.cleaned ?? "")

        state.awayPenalty1Player = parsePlayer(candidates[.awayPenalty1Player]?.cleaned ?? "")
        state.awayPenalty1Clock = parsePenaltyClock(candidates[.awayPenalty1Time]?.cleaned ?? "")
        state.awayPenalty2Player = parsePlayer(candidates[.awayPenalty2Player]?.cleaned ?? "")
        state.awayPenalty2Clock = parsePenaltyClock(candidates[.awayPenalty2Time]?.cleaned ?? "")

        let pipelineDiagnostics: [OCRRegionKey: String]
        if includePipelineDiagnostics,
           DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds {
            stageObserver?(.pipelineDiagnostics, nil)
            pipelineDiagnostics = Dictionary(uniqueKeysWithValues: regionKeys.map { key in
                guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
                    return (key, "pipeProbe skipped: pass budget exhausted")
                }
                let regionModel = layout[key]
                return (
                    key,
                    pipelineProbeSummary(
                        for: key,
                        pixelBuffer: pixelBuffer,
                        orientation: primaryOrientation,
                        uiRegion: regionModel.rect,
                        regionRotationDegrees: regionModel.rotationDegrees,
                        previewSize: previewSize,
                        previewRotationDegrees: previewRotationDegrees,
                        colourProfile: colourProfiles.profile(for: key)
                    )
                )
            })
        } else {
            pipelineDiagnostics = Dictionary(uniqueKeysWithValues: regionKeys.map { key in
                let profile = colourProfiles.profile(for: key)
                return (key, "pipeProbe disabled pipeline=\(profile.resolvedPipeline(for: key).shortTitle) padding=\(Int((profile.cropPaddingPercent * 100).rounded()))%")
            })
        }

        let budgetElapsed = Double(DispatchTime.now().uptimeNanoseconds - processingStartedUptimeNanoseconds) / 1_000_000_000
        let budgetStatus = DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds ? "budget-exhausted" : "within-budget"
        let rawText = candidates.map { entry in
            let reason: String
            if entry.value.accepted {
                reason = entry.value.reason ?? "accepted"
            } else {
                reason = entry.value.reason ?? "rejected"
            }
            let acceptedValue = entry.value.accepted ? entry.value.cleaned : "RETAIN"
            let profile = colourProfiles.profile(for: entry.key)
            let pipelineDiagnostic = pipelineDiagnostics[entry.key] ?? "pipeline probe unavailable"
            let fieldElapsed = fieldElapsedMilliseconds[entry.key] ?? 0
            return "\(entry.key.rawValue): raw=\(entry.value.raw) cleaned=\(entry.value.cleaned) accepted=\(acceptedValue) recognizer=\(entry.value.recognizer.rawValue) conf=\(String(format: "%.2f", entry.value.confidence)) validation=\(reason) fieldElapsedMs=\(String(format: "%.2f", fieldElapsed)) rotation=\(String(format: "%.1f", layout[entry.key].rotationDegrees)) colour=\(profile.resolvedPipeline(for: entry.key).title) chars=\(profile.characterColour.title) bg=\(profile.backgroundColour.title) \(pipelineDiagnostic)"
        }
        .sorted()
        .joined(separator: "\n") + "\npassBudget=\(String(format: "%.3f", boundedSeconds))s elapsed=\(String(format: "%.3f", budgetElapsed))s status=\(budgetStatus) processed=\(candidates.count)/\(regionKeys.count)"

        let fieldDebug = regionKeys.map { key in
            let candidate = candidates[key] ?? OCRCandidate(raw: "", cleaned: "", confidence: 0, accepted: false, reason: "no text", recognizer: .vision)
            return OCRFieldDebug(
                key: key,
                raw: candidate.raw,
                cleaned: candidate.cleaned,
                accepted: candidate.accepted ? candidate.cleaned : "",
                recognizer: candidate.recognizer,
                confidence: candidate.confidence,
                validation: candidate.reason ?? (candidate.accepted ? "accepted" : "rejected"),
                pipelineDiagnostic: "\(pipelineDiagnostics[key] ?? "pipeline probe unavailable") fieldElapsedMs=\(String(format: "%.2f", fieldElapsedMilliseconds[key] ?? 0)) passBudgetMs=\(String(format: "%.0f", boundedSeconds * 1_000))",
                mirrorApplied: false
            )
        }
        stageObserver?(.publication, nil)
        return (state, rawText, fieldDebug)
    }

    private func recognizeCandidate(
        for key: OCRRegionKey,
        in region: CGRect,
        regionRotationDegrees: CGFloat,
        pixelBuffer: CVPixelBuffer,
        boardImage: CGImage?,
        boardCalibration: BoardCalibrationQuad,
        orientation: CGImagePropertyOrientation,
        thresholds: OCRThresholds,
        colourProfile: OCRZoneColourProfile,
        previewRotationDegrees: CGFloat = 0,
        previewSize: CGSize,
        enableSegmentedFallback: Bool,
        executionPolicy: RinkLensOCRExecutionPolicy,
        reserveTimerRecovery: Bool,
        deadlineUptimeNanoseconds: UInt64,
        sourceFrameID: Int?,
        captureGeneration: Int,
        stageObserver: (@Sendable (RinkLensOCRProcessingStage, OCRRegionKey?) -> Void)?
    ) -> OCRCandidate {
        // v0.8.1.7n: Period uses a digit classifier before generic text OCR.
        // The period crop is a tiny, isolated numeric field and Vision can read
        // clear digits as alphabetic glyphs such as A or J. Classify the lit
        // shape first and only allow hockey period values through.
        stageObserver?(.segmentation, key)

        // UX16d5: Test and continuous OCR share one bounded token-first path.
        // The saved field zone is authoritative; saved character cells and colon
        // slots are deliberately not consulted. Seven-segment recognition remains
        // reachable only below this point under the diagnostics execution policy.
        let normalizedSourceRegion = fieldInputRegion(
            from: region,
            boardCalibration: boardCalibration,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
        let dynamicTokenAttempt = dynamicTokenCandidate(
            for: key,
            boardImage: boardImage,
            sourceUIRegion: normalizedSourceRegion,
            boardCalibration: boardCalibration,
            regionRotationDegrees: regionRotationDegrees,
            colourProfile: colourProfile,
            reserveTimerRecovery: reserveTimerRecovery,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            sourceFrameID: sourceFrameID,
            captureGeneration: captureGeneration
        )
        if isPenaltyPlayerKey(key) {
            let dynamicDigitCount = dynamicTokenAttempt?.cleaned.filter { $0.isNumber }.count ?? 0
            // Build 558: player zones are sampled only at baseline/hash/active
            // penalty service, not on every Clock pass. The Build 557 physical log
            // showed 45 becoming 5/51 and 23 becoming ?3. Reuse the cached fast
            // Vision request as a low-frequency two-digit recovery. It may override
            // the deterministic result only with a validated two-digit number;
            // one-digit OCR remains the deterministic fallback and timer evidence
            // still cannot create a penalty independently.
            if dynamicDigitCount < 2,
               let recoveredPlayer = fastTwoDigitPenaltyPlayerCandidate(
                    for: key,
                    boardImage: boardImage,
                    sourceUIRegion: normalizedSourceRegion,
                    boardCalibration: boardCalibration,
                    regionRotationDegrees: regionRotationDegrees,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                    stageObserver: stageObserver
               ) {
                return recoveredPlayer
            }
        }
        if let dynamicTokenAttempt, dynamicTokenAttempt.accepted {
            return dynamicTokenAttempt
        }
        if executionPolicy == .liveBounded {
            return dynamicTokenAttempt ?? OCRCandidate(
                raw: "",
                cleaned: "",
                confidence: 0,
                accepted: false,
                reason: DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds
                    ? "dynamic token decoder exhausted the bounded processing budget"
                    : "dynamic token decoder returned no valid field sequence",
                recognizer: .templateDigits
            )
        }

        if key == .period,
           let periodDigit = periodDigitClassifierCandidate(
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            uiRegion: region,
            regionRotationDegrees: regionRotationDegrees,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
           ) {
            return periodDigit
        }

        let confidenceThreshold = threshold(for: key, thresholds: thresholds)

        // Diagnostics-only legacy recognisers begin below. Publication-capable calls
        // return above under `.liveBounded`; therefore seven-segment, Vision and ML Kit
        // output can be inspected but cannot update Test, Calibration or Broadcast state.
        if let timerPrimary = sevenSegmentTimerCandidate(
            for: key,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            uiRegion: region,
            regionRotationDegrees: regionRotationDegrees,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            colourProfile: colourProfile,
            executionPolicy: executionPolicy
        ) {
            return timerPrimary
        }

        var penaltyPlayerTextFallback: OCRCandidate?
        if isPenaltyPlayerKey(key), executionPolicy.allowsFrameworkTextFallback {
            stageObserver?(.vision, key)
            let playerTextCandidates = recognizedTextCandidates(
                for: key,
                in: region,
                pixelBuffer: pixelBuffer,
                boardImage: boardImage,
                orientation: orientation,
                previewSize: previewSize,
                regionRotationDegrees: regionRotationDegrees,
                previewRotationDegrees: previewRotationDegrees,
                colourProfile: colourProfile,
                stageObserver: stageObserver
            )
            let playerEvaluation = evaluateTextualCandidates(
                playerTextCandidates,
                for: key,
                confidenceThreshold: min(confidenceThreshold, 0.52),
                acceptedReason: "penalty player text OCR"
            )
            if let accepted = playerEvaluation.accepted {
                let digitCount = accepted.cleaned.filter { $0.isNumber }.count
                if digitCount >= 2 {
                    return accepted
                }
                // UX15d: a one-digit Vision/MLKit read must not pre-empt the
                // segmentation path for penalty-player zones. The reported
                // failure showed a visible HP1 value of 45 being reduced to a
                // single digit before the segmented glyph reader had a chance to
                // read the full player number. Keep the one-digit text result as
                // a fallback only.
                penaltyPlayerTextFallback = accepted
            }
        }

        // Legacy segmentation remains available only in explicit diagnostics.
        // It is intentionally downstream of the `.liveBounded` return and cannot
        // supply accepted evidence to production/Test publication paths.
        if let segmentedPrimary = segmentedPrimaryCandidate(
            for: key,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            uiRegion: region,
            regionRotationDegrees: regionRotationDegrees,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            colourProfile: colourProfile,
            executionPolicy: executionPolicy
        ) {
            return segmentedPrimary
        }

        if let penaltyPlayerTextFallback {
            return penaltyPlayerTextFallback
        }

        guard executionPolicy.allowsFrameworkTextFallback else {
            // UX16d2b root correction: continuous OCR never enters synchronous
            // Vision/ML Kit fallback APIs. Those APIs cannot be pre-empted safely and
            // were the only unbounded calls capable of occupying the sole executor.
            return OCRCandidate(
                raw: "",
                cleaned: "",
                confidence: 0,
                accepted: false,
                reason: "live bounded policy: no deterministic segmented candidate",
                recognizer: .segmented
            )
        }

        // Diagnostics-only fallback: use Vision / ML Kit text recognition.
        stageObserver?(.vision, key)
        let textualCandidates = recognizedTextCandidates(
            for: key,
            in: region,
            pixelBuffer: pixelBuffer,
            boardImage: boardImage,
            orientation: orientation,
            previewSize: previewSize,
            regionRotationDegrees: regionRotationDegrees,
            previewRotationDegrees: previewRotationDegrees,
            colourProfile: colourProfile,
            stageObserver: stageObserver
        )

        guard !textualCandidates.isEmpty else {
            // v0.8.1.7l: if the normal text path sees no text at all, still try
            // sharpened/upscaled/thresholded crop OCR before returning a hard miss.
            // This is intentionally a fallback so normal OCR behaviour is preserved.
            stageObserver?(.enhancedVision, key)
            if let enhanced = enhancedContrastCandidate(
                for: key,
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                uiRegion: region,
                regionRotationDegrees: regionRotationDegrees,
                confidenceThreshold: confidenceThreshold,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                colourProfile: colourProfile
            ) {
                return enhanced
            }

            if enableSegmentedFallback,
               segmentedFallbackEnabled(for: key),
               let fallback = segmentedFallback(for: key, pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: region, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, colourProfile: colourProfile) {
                return OCRCandidate(raw: "", cleaned: fallback, confidence: 1, accepted: true, reason: "segmented fallback", recognizer: .segmented)
            }
            return OCRCandidate(raw: "", cleaned: "", confidence: 0, accepted: false, reason: "no text", recognizer: .vision)
        }

        let evaluated = evaluateTextualCandidates(
            textualCandidates,
            for: key,
            confidenceThreshold: confidenceThreshold,
            acceptedReason: nil
        )
        let bestRejected = evaluated.rejected

        if let bestAccepted = evaluated.accepted { return bestAccepted }

        // Clock and penalty timers use seven-segment displays and can produce unstable
        // partial Vision reads such as ":", ":2", ":43", "2" or "43". Treat
        // those reads as failed timer reads and escalate to ML Kit and segmented
        // fallback before returning a rejection. Raw fragments must not update
        // ScoreboardState.
        var timerFallbackDiagnostic: OCRCandidate?
        if isTimerKey(key), bestRejected != nil {
            var fallbackDiagnostic: OCRCandidate?

            stageObserver?(.mlKit, key)
            if let mlKitEvaluation = mlKitTimerFallbackEvaluation(
                for: key,
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                uiRegion: region,
                regionRotationDegrees: regionRotationDegrees,
                confidenceThreshold: confidenceThreshold,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                colourProfile: colourProfile
            ) {
                if let accepted = mlKitEvaluation.accepted {
                    return accepted
                }
                fallbackDiagnostic = mlKitEvaluation.rejected
            }

            // UX15d: timers must not stop after a failed segmented attempt. In
            // UX15c a visible clock crop could be reduced to a partial OCR value
            // such as ":2" and then returned immediately as a rejected segmented
            // diagnostic, which prevented the enhanced/thresholded OCR path from
            // running. Keep the rejection for diagnostics, but continue to the
            // enhanced path before giving up.
            if segmentedFallbackEnabled(for: key) {
                if let fallback = segmentedFallback(for: key, pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: region, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, colourProfile: colourProfile) {
                    let raw = bestRejected?.raw ?? fallbackDiagnostic?.raw ?? ""
                    let confidence = max(bestRejected?.confidence ?? 0, fallbackDiagnostic?.confidence ?? 0)
                    return OCRCandidate(raw: raw, cleaned: fallback, confidence: confidence, accepted: true, reason: "segmented timer fallback", recognizer: .segmented)
                }

                let raw = bestRejected?.raw ?? fallbackDiagnostic?.raw ?? ""
                let cleaned = bestRejected?.cleaned ?? fallbackDiagnostic?.cleaned ?? ""
                let confidence = max(bestRejected?.confidence ?? 0, fallbackDiagnostic?.confidence ?? 0)
                timerFallbackDiagnostic = OCRCandidate(raw: raw, cleaned: cleaned, confidence: confidence, accepted: false, reason: "segmented fallback attempted; no valid timer", recognizer: .segmented)
            } else {
                timerFallbackDiagnostic = fallbackDiagnostic
            }
        }

        stageObserver?(.enhancedVision, key)
        if let enhanced = enhancedContrastCandidate(
            for: key,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            uiRegion: region,
            regionRotationDegrees: regionRotationDegrees,
            confidenceThreshold: confidenceThreshold,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            colourProfile: colourProfile
        ) {
            return enhanced
        }

        if enableSegmentedFallback,
           segmentedFallbackEnabled(for: key),
           let fallback = segmentedFallback(for: key, pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: region, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, colourProfile: colourProfile) {
            let raw = bestRejected?.raw ?? ""
            let confidence = bestRejected?.confidence ?? 0
            return OCRCandidate(raw: raw, cleaned: fallback, confidence: confidence, accepted: true, reason: "segmented fallback", recognizer: .segmented)
        }

        return timerFallbackDiagnostic ?? bestRejected ?? dynamicTokenAttempt ?? OCRCandidate(raw: "", cleaned: "", confidence: 0, accepted: false, reason: "no valid candidate", recognizer: .vision)
    }

    private func evaluateTextualCandidates(
        _ textualCandidates: [RecognizedTextCandidate],
        for key: OCRRegionKey,
        confidenceThreshold: Float,
        acceptedReason: String?
    ) -> (accepted: OCRCandidate?, rejected: OCRCandidate?) {
        var bestAccepted: OCRCandidate?
        var bestRejected: OCRCandidate?

        // UX15g: evaluate timer candidates with the most timer-like / most complete text first.
        // Vision can emit a high-confidence partial fragment (for example ":2") before a
        // lower-confidence full candidate. Prefer fuller timer candidates so a visible 2:43
        // has a chance to win before partial fragments are considered for diagnostics.
        let candidatesToEvaluate: [RecognizedTextCandidate]
        if isTimerKey(key) {
            candidatesToEvaluate = textualCandidates.sorted { lhs, rhs in
                let leftDigits = lhs.text.filter { $0.isNumber }.count
                let rightDigits = rhs.text.filter { $0.isNumber }.count
                if leftDigits != rightDigits { return leftDigits > rightDigits }
                let leftHasSep = lhs.text.contains(":") || lhs.text.contains(";") || lhs.text.contains(".")
                let rightHasSep = rhs.text.contains(":") || rhs.text.contains(";") || rhs.text.contains(".")
                if leftHasSep != rightHasSep { return leftHasSep && !rightHasSep }
                return lhs.confidence > rhs.confidence
            }
        } else {
            candidatesToEvaluate = textualCandidates
        }

        for candidate in candidatesToEvaluate {
            let recognizer = candidate.recognizer
            let raw = normalize(candidate.text, for: key)

            if requiresNumericInput(for: key), !hasNumericSignal(in: candidate.text), !(key == .period && hasPeriodDigitSubstitutionSignal(in: candidate.text)) {
                let rejected = OCRCandidate(raw: raw, cleaned: "", confidence: candidate.confidence, accepted: false, reason: "non-numeric text", recognizer: recognizer)
                if bestRejected == nil || rejected.confidence > bestRejected!.confidence {
                    bestRejected = rejected
                }
                continue
            }

            guard candidate.confidence >= confidenceThreshold else {
                let rejected = OCRCandidate(raw: raw, cleaned: "", confidence: candidate.confidence, accepted: false, reason: "low confidence", recognizer: recognizer)
                if bestRejected == nil || rejected.confidence > bestRejected!.confidence {
                    bestRejected = rejected
                }
                continue
            }

            var cleaned = clean(raw, for: key)
            if isTimerKey(key), let repairedTimer = repairTimerFromRaw(raw, cleaned: cleaned, for: key) {
                cleaned = repairedTimer
            }
            guard !cleaned.isEmpty else {
                let rejected = OCRCandidate(raw: raw, cleaned: cleaned, confidence: candidate.confidence, accepted: false, reason: "invalid characters", recognizer: recognizer)
                if bestRejected == nil || rejected.confidence > bestRejected!.confidence {
                    bestRejected = rejected
                }
                continue
            }

            guard validate(cleaned, for: key) else {
                let reason: String
                if isTimerKey(key), isPartialTimerFragment(raw: raw, cleaned: cleaned) {
                    reason = "invalid partial timer"
                } else {
                    reason = isTimerKey(key) ? "invalid timer format" : "invalid format"
                }
                let rejected = OCRCandidate(raw: raw, cleaned: cleaned, confidence: candidate.confidence, accepted: false, reason: reason, recognizer: recognizer)
                if bestRejected == nil || rejected.confidence > bestRejected!.confidence {
                    bestRejected = rejected
                }
                continue
            }

            let accepted = OCRCandidate(raw: raw, cleaned: cleaned, confidence: candidate.confidence, accepted: true, reason: acceptedReason, recognizer: recognizer)
            if bestAccepted == nil || accepted.confidence > bestAccepted!.confidence {
                bestAccepted = accepted
            }
        }

        return (bestAccepted, bestRejected)
    }

    private func mlKitTimerFallbackEvaluation(
        for key: OCRRegionKey,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        regionRotationDegrees: CGFloat,
        confidenceThreshold: Float,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        colourProfile: OCRZoneColourProfile
    ) -> (accepted: OCRCandidate?, rejected: OCRCandidate?)? {
        guard isTimerKey(key),
              let candidates = mlKitTextCandidates(for: key, pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: uiRegion, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, colourProfile: colourProfile),
              !candidates.isEmpty else { return nil }

        let mlKitCandidates = candidates.map { RecognizedTextCandidate(text: $0.text, confidence: $0.confidence, recognizer: .mlKit) }
        return evaluateTextualCandidates(
            mlKitCandidates,
            for: key,
            confidenceThreshold: confidenceThreshold,
            acceptedReason: "ML Kit timer fallback"
        )
    }

    private func isTimerKey(_ key: OCRRegionKey) -> Bool {
        switch key {
        case .clock, .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return true
        default:
            return false
        }
    }

    private func isPenaltyPlayerKey(_ key: OCRRegionKey) -> Bool {
        switch key {
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return true
        default:
            return false
        }
    }

    private func dynamicTokenCandidate(
        for key: OCRRegionKey,
        boardImage: CGImage?,
        sourceUIRegion: CGRect,
        boardCalibration: BoardCalibrationQuad,
        regionRotationDegrees: CGFloat,
        colourProfile: OCRZoneColourProfile,
        reserveTimerRecovery: Bool,
        deadlineUptimeNanoseconds: UInt64,
        sourceFrameID: Int?,
        captureGeneration: Int
    ) -> OCRCandidate? {
        let supported: Set<OCRRegionKey> = [
            .clock, .period, .homeScore, .awayScore,
            .homePenalty1Player, .homePenalty1Time,
            .homePenalty2Player, .homePenalty2Time,
            .awayPenalty1Player, .awayPenalty1Time,
            .awayPenalty2Player, .awayPenalty2Time
        ]
        guard supported.contains(key),
              DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds,
              let boardImage,
              let crop = rawTemplateFieldCrop(
                boardImage: boardImage,
                sourceUIRegion: sourceUIRegion,
                boardCalibration: boardCalibration,
                regionRotationDegrees: regionRotationDegrees,
                cropPaddingPercent: 0,
                fieldKey: key
              ) else { return nil }

        // UX16d17 Build 539: when the operator enables replay capture, persist
        // the exact rectified crop consumed by the production dynamic-token
        // decoder. The queue-safe sink is diagnostic-only and never blocks or
        // changes recognition/publication decisions.
        RinkLensOCRReplayFileSink.shared.captureCrop(
            key: key,
            image: crop.image,
            frameID: sourceFrameID,
            captureGeneration: captureGeneration,
            diagnostic: String(
                format: "source=%.4f,%.4f %.4fx%.4f board=%.4f,%.4f %.4fx%.4f",
                Double(crop.sourceNormalizedRect.minX),
                Double(crop.sourceNormalizedRect.minY),
                Double(crop.sourceNormalizedRect.width),
                Double(crop.sourceNormalizedRect.height),
                Double(crop.boardNormalizedRect.minX),
                Double(crop.boardNormalizedRect.minY),
                Double(crop.boardNormalizedRect.width),
                Double(crop.boardNormalizedRect.height)
            )
        )

        let primaryAttempt = RinkLensLightweightOCRParser.parseDynamicTokens(
            from: crop.image,
            key: key,
            colourProfile: colourProfile,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            sourceFrameID: sourceFrameID,
            captureGeneration: captureGeneration,
            reserveTimerRecovery: reserveTimerRecovery
        )
        let primaryEvidence = String(
            format: "UX16d5 dynamic-token source=%.4f,%.4f %.4fx%.4f board=%.4f,%.4f %.4fx%.4f crop=%dx%d; %@",
            Double(crop.sourceNormalizedRect.minX),
            Double(crop.sourceNormalizedRect.minY),
            Double(crop.sourceNormalizedRect.width),
            Double(crop.sourceNormalizedRect.height),
            Double(crop.boardNormalizedRect.minX),
            Double(crop.boardNormalizedRect.minY),
            Double(crop.boardNormalizedRect.width),
            Double(crop.boardNormalizedRect.height),
            crop.image.width,
            crop.image.height,
            primaryAttempt.diagnostic
        )

        if let value = primaryAttempt.value, validate(value, for: key) {
            return OCRCandidate(
                raw: primaryAttempt.rawText,
                cleaned: value,
                confidence: primaryAttempt.confidence,
                accepted: true,
                reason: primaryEvidence,
                recognizer: .templateDigits
            )
        }

        // UX16d11: a changed score zone that returns no token is absence of usable
        // geometry, not proof that the old visible score remains correct. Run one
        // expanded, neutral reacquisition attempt while this OCR pass owns budget.
        // Any accepted value still enters the reducer's two-read confirmation and
        // baseline publication remains event-free.
        let scoreKey = key == .homeScore || key == .awayScore
        let primaryEmpty = primaryAttempt.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if scoreKey,
           primaryEmpty,
           DispatchTime.now().uptimeNanoseconds + 25_000_000 < deadlineUptimeNanoseconds,
           let expandedCrop = rawTemplateFieldCrop(
                boardImage: boardImage,
                sourceUIRegion: sourceUIRegion,
                boardCalibration: boardCalibration,
                regionRotationDegrees: regionRotationDegrees,
                cropPaddingPercent: 0.12,
                fieldKey: key
           ) {
            let reacquisitionDeadline = min(
                deadlineUptimeNanoseconds,
                DispatchTime.now().uptimeNanoseconds + 95_000_000
            )
            let reacquired = RinkLensLightweightOCRParser.parseDynamicTokens(
                from: expandedCrop.image,
                key: key,
                colourProfile: colourProfile,
                deadlineUptimeNanoseconds: reacquisitionDeadline,
                sourceFrameID: sourceFrameID,
                captureGeneration: captureGeneration,
                scoreReacquisition: true
            )
            let reacquisitionEvidence = String(
                format: "UX16d11 score-reacquisition padding=12%% board=%.4f,%.4f %.4fx%.4f crop=%dx%d; %@",
                Double(expandedCrop.boardNormalizedRect.minX),
                Double(expandedCrop.boardNormalizedRect.minY),
                Double(expandedCrop.boardNormalizedRect.width),
                Double(expandedCrop.boardNormalizedRect.height),
                expandedCrop.image.width,
                expandedCrop.image.height,
                reacquired.diagnostic
            )
            if let value = reacquired.value, validate(value, for: key) {
                return OCRCandidate(
                    raw: reacquired.rawText,
                    cleaned: value,
                    confidence: reacquired.confidence,
                    accepted: true,
                    reason: primaryEvidence + " | " + reacquisitionEvidence,
                    recognizer: .templateDigits
                )
            }
            return OCRCandidate(
                raw: reacquired.rawText.isEmpty ? primaryAttempt.rawText : reacquired.rawText,
                cleaned: "",
                confidence: max(primaryAttempt.confidence, reacquired.confidence),
                accepted: false,
                reason: primaryEvidence + " | " + reacquisitionEvidence,
                recognizer: .templateDigits
            )
        }

        return OCRCandidate(
            raw: primaryAttempt.rawText,
            cleaned: "",
            confidence: primaryAttempt.confidence,
            accepted: false,
            reason: primaryEvidence,
            recognizer: .templateDigits
        )
    }

    private func sevenSegmentTimerCandidate(
        for key: OCRRegionKey,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        regionRotationDegrees: CGFloat,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        colourProfile: OCRZoneColourProfile,
        executionPolicy: RinkLensOCRExecutionPolicy
    ) -> OCRCandidate? {
        guard isTimerKey(key) else { return nil }

        let styles = executionPolicy == .liveBounded
            ? boundedSegmentationCropStyles(for: key, colourProfile: colourProfile)
            : segmentationCropStyles(for: key, colourProfile: colourProfile)
        var best: OCRCandidate?
        var votes: [String: Int] = [:]

        for style in styles {
            guard let cropped = croppedCGImage(pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: uiRegion, style: style, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, cropPaddingPercent: colourProfile.cropPaddingPercent) else {
                continue
            }
            let result = executionPolicy == .liveBounded
                ? sevenSegmentTimerRecognizer.recogniseTimerBounded(from: cropped, allowTwoMinuteDigits: key == .clock)
                : sevenSegmentTimerRecognizer.recogniseTimer(from: cropped, allowTwoMinuteDigits: key == .clock)
            guard let result else { continue }

            guard validate(result.value, for: key) else { continue }
            votes[result.value, default: 0] += 1
            let consensusConfidence = min(1.0, result.confidence + Float(max(0, votes[result.value, default: 1] - 1)) * 0.12)
            let candidate = OCRCandidate(
                raw: result.rawDigits,
                cleaned: result.value,
                confidence: consensusConfidence,
                accepted: true,
                reason: "seven-segment timer recogniser (\(result.layout)); \(result.diagnostic)",
                recognizer: .segmented
            )
            if best == nil || candidate.confidence > best!.confidence {
                best = candidate
            }
            if executionPolicy == .liveBounded,
               votes[result.value, default: 0] >= 2,
               candidate.confidence >= 0.88 {
                break
            }
        }

        return best
    }

    private func isPartialTimerFragment(raw: String, cleaned: String) -> Bool {
        let values = [raw, cleaned]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return true }

        return values.contains { value in
            value == ":" ||
            value.range(of: #"^:\d{1,2}$"#, options: .regularExpression) != nil ||
            value.range(of: #"^\d{1,2}$"#, options: .regularExpression) != nil ||
            value.range(of: #"^\d{1,2}:$"#, options: .regularExpression) != nil
        }
    }

    private func fastTwoDigitPenaltyPlayerCandidate(
        for key: OCRRegionKey,
        boardImage: CGImage?,
        sourceUIRegion: CGRect,
        boardCalibration: BoardCalibrationQuad,
        regionRotationDegrees: CGFloat,
        deadlineUptimeNanoseconds: UInt64,
        stageObserver: (@Sendable (RinkLensOCRProcessingStage, OCRRegionKey?) -> Void)?
    ) -> OCRCandidate? {
        guard isPenaltyPlayerKey(key),
              DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds,
              let boardImage,
              let expandedCrop = rawTemplateFieldCrop(
                boardImage: boardImage,
                sourceUIRegion: sourceUIRegion,
                boardCalibration: boardCalibration,
                regionRotationDegrees: regionRotationDegrees,
                cropPaddingPercent: 0.14,
                fieldKey: key
              ) else { return nil }

        stageObserver?(.vision, key)
        let request = makeRequest(for: key)
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        let handler = VNImageRequestHandler(cgImage: expandedCrop.image)
        try? handler.perform([request])
        guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else { return nil }

        let candidates = (request.results ?? []).flatMap { observation in
            observation.topCandidates(2).map {
                RecognizedTextCandidate(text: $0.string, confidence: $0.confidence, recognizer: .vision)
            }
        }
        let evaluation = evaluateTextualCandidates(
            candidates,
            for: key,
            confidenceThreshold: 0.34,
            acceptedReason: "Build 558 expanded fast Vision two-digit penalty-player recovery"
        )
        guard let accepted = evaluation.accepted else { return nil }
        let digits = accepted.cleaned.filter { $0.isNumber }
        guard digits.count == 2,
              let player = Int(digits),
              (1...99).contains(player) else { return nil }
        return OCRCandidate(
            raw: accepted.raw,
            cleaned: String(player),
            confidence: accepted.confidence,
            accepted: true,
            reason: String(
                format: "Build 558 event-only expanded fast Vision penalty-player recovery crop=%dx%d",
                expandedCrop.image.width,
                expandedCrop.image.height
            ),
            recognizer: .vision
        )
    }

    private func recognizedTextCandidates(
        for key: OCRRegionKey,
        in region: CGRect,
        pixelBuffer: CVPixelBuffer,
        boardImage: CGImage?,
        orientation: CGImagePropertyOrientation,
        previewSize: CGSize,
        regionRotationDegrees: CGFloat,
        previewRotationDegrees: CGFloat = 0,
        colourProfile: OCRZoneColourProfile,
        stageObserver: (@Sendable (RinkLensOCRProcessingStage, OCRRegionKey?) -> Void)? = nil
    ) -> [RecognizedTextCandidate] {
        if let boardImage {
            let rect = CGRect(
                x: region.minX * CGFloat(boardImage.width),
                y: (1 - region.minY - region.height) * CGFloat(boardImage.height),
                width: region.width * CGFloat(boardImage.width),
                height: region.height * CGFloat(boardImage.height)
            ).integral
            if abs(regionRotationDegrees) < 0.05, let roi = boardImage.cropping(to: rect) {
                let request = makeRequest(for: key)
                request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
                let handler = VNImageRequestHandler(cgImage: roi)
                try? handler.perform([request])
                let boardCandidates = (request.results ?? []).flatMap { obs in
                    obs.topCandidates(2).map { RecognizedTextCandidate(text: $0.string, confidence: $0.confidence, recognizer: .vision) }
                }
                if !boardCandidates.isEmpty { return boardCandidates }
            }
        }

        stageObserver?(.mlKit, key)
        if let mlKitCandidates = mlKitTextCandidates(
            for: key,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            uiRegion: region,
            regionRotationDegrees: regionRotationDegrees,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            colourProfile: colourProfile
        ), !mlKitCandidates.isEmpty {
            return mlKitCandidates.map { RecognizedTextCandidate(text: $0.text, confidence: $0.confidence, recognizer: .mlKit) }
        }

        stageObserver?(.vision, key)
        let request = makeRequest(for: key)
        request.regionOfInterest = visionROI(
            from: region,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            try handler.perform([request])
            return (request.results ?? [])
                .flatMap { observation in
                    observation.topCandidates(3).map { RecognizedTextCandidate(text: $0.string, confidence: $0.confidence, recognizer: .vision) }
                }
        } catch {
            return []
        }
    }

    private func mlKitTextCandidates(
        for key: OCRRegionKey,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        regionRotationDegrees: CGFloat = 0,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        colourProfile: OCRZoneColourProfile
    ) -> [(text: String, confidence: Float)]? {
        #if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
        let styles = textualCropStyles(for: key, colourProfile: colourProfile)
        var allCandidates: [(text: String, confidence: Float)] = []
        for style in styles {
            guard let cropped = croppedCGImage(pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: uiRegion, style: style, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, cropPaddingPercent: colourProfile.cropPaddingPercent) else { continue }
            let image = VisionImage(image: UIImage(cgImage: cropped))
            image.orientation = .up
            guard let text = try? mlKitTextRecognizer.results(in: image) else { continue }

            for block in text.blocks {
                for line in block.lines {
                    for element in line.elements {
                        allCandidates.append((element.text, 0.90))
                    }
                    allCandidates.append((line.text, 0.85))
                }
            }
        }
        return allCandidates
        #else
        _ = key
        _ = pixelBuffer
        _ = orientation
        _ = uiRegion
        _ = regionRotationDegrees
        _ = previewSize
        _ = previewRotationDegrees
        _ = colourProfile
        return nil
        #endif
    }

    private func enhancedContrastCandidate(
        for key: OCRRegionKey,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        regionRotationDegrees: CGFloat,
        confidenceThreshold: Float,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        colourProfile: OCRZoneColourProfile
    ) -> OCRCandidate? {
        let styles = textualCropStyles(for: key, colourProfile: colourProfile)

        var bestAcrossStyles: OCRCandidate?
        for style in styles {
            guard let cropped = croppedCGImage(pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: uiRegion, style: style, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, cropPaddingPercent: colourProfile.cropPaddingPercent) else { continue }
            let request = makeRequest(for: key)
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

            do {
                let handler = VNImageRequestHandler(cgImage: cropped)
                try handler.perform([request])
                let candidates: [(text: String, confidence: Float)] = (request.results ?? [])
                    .flatMap { observation in
                        observation.topCandidates(3).map { ($0.string, $0.confidence) }
                    }

                var bestForStyle: OCRCandidate?
                for candidate in candidates {
                    if requiresNumericInput(for: key), !hasNumericSignal(in: candidate.text), !(key == .period && hasPeriodDigitSubstitutionSignal(in: candidate.text)) { continue }
                    guard candidate.confidence >= confidenceThreshold else { continue }

                    let raw = normalize(candidate.text, for: key)
                    let cleaned = clean(raw, for: key)
                    guard !cleaned.isEmpty, validate(cleaned, for: key) else { continue }

                    let accepted = OCRCandidate(
                        raw: raw,
                        cleaned: cleaned,
                        confidence: candidate.confidence,
                        accepted: true,
                        reason: style.diagnosticLabel,
                        recognizer: .vision
                    )
                    if bestForStyle == nil || accepted.confidence > bestForStyle!.confidence {
                        bestForStyle = accepted
                    }
                }

                if let bestForStyle {
                    if bestAcrossStyles == nil || bestForStyle.confidence > bestAcrossStyles!.confidence {
                        bestAcrossStyles = bestForStyle
                    }
                }
            } catch {
                continue
            }
        }
        return bestAcrossStyles
    }

    private func rawTemplateFieldCrop(
        boardImage: CGImage,
        sourceUIRegion: CGRect,
        boardCalibration: BoardCalibrationQuad,
        regionRotationDegrees: CGFloat,
        cropPaddingPercent: Double,
        fieldKey: OCRRegionKey? = nil
    ) -> TemplateFieldCropEvidence? {
        let mappedRegion: CGRect?
        if boardCalibration.zonesFollowPerspective {
            mappedRegion = BoardPerspectiveMapper.clampedUnitRect(sourceUIRegion, minimumSize: 0.001)
        } else {
            mappedRegion = rectifiedBoardNormalizedRect(
                sourceUIRegion: sourceUIRegion,
                boardCalibration: boardCalibration
            )
        }
        guard var mapped = mappedRegion else { return nil }

        // UX16d15f Build 521: a saved penalty-time zone can map exactly to the
        // rectified board boundary. The 2026-07-04 evidence showed Away Penalty
        // 1 Time ending at x=1.0000 and repeatedly yielding no usable token. Move
        // only penalty-time crops a small distance inward while preserving their
        // width; score, clock, period and player geometry remain untouched.
        let penaltyTimeField: Bool
        switch fieldKey {
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            penaltyTimeField = true
        default:
            penaltyTimeField = false
        }
        if penaltyTimeField {
            let inwardShift = min(CGFloat(0.012), max(CGFloat(0.004), mapped.width * 0.06))
            if mapped.maxX >= 0.998 {
                mapped.origin.x = max(0, mapped.origin.x - inwardShift)
            } else if mapped.minX <= 0.002 {
                mapped.origin.x = min(1 - mapped.width, mapped.origin.x + inwardShift)
            }
        }

        let safePadding = CGFloat(max(0, min(0.18, cropPaddingPercent)))
        var padded = mapped.insetBy(
            dx: -(mapped.width * safePadding),
            dy: -(mapped.height * safePadding)
        )
        padded.origin.x = max(0, min(1, padded.origin.x))
        padded.origin.y = max(0, min(1, padded.origin.y))
        padded.size.width = max(0.001, min(1 - padded.origin.x, padded.width))
        padded.size.height = max(0.001, min(1 - padded.origin.y, padded.height))

        let width = CGFloat(boardImage.width)
        let height = CGFloat(boardImage.height)
        let pixelRect = CGRect(
            x: padded.minX * width,
            y: padded.minY * height,
            width: padded.width * width,
            height: padded.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width > 8, pixelRect.height > 8,
              !pixelRect.isNull, !pixelRect.isEmpty,
              let cropped = boardImage.cropping(to: pixelRect) else { return nil }

        let output: CGImage
        if abs(regionRotationDegrees) > 0.05 {
            let source = CIImage(cgImage: cropped)
            let extent = source.extent
            let radians = regionRotationDegrees * .pi / 180
            let centre = CGPoint(x: extent.midX, y: extent.midY)
            let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: radians)
                .translatedBy(x: -centre.x, y: -centre.y)
            let rotated = source.transformed(by: transform).cropped(to: extent)
            guard let rendered = ciContext.createCGImage(rotated, from: extent) else { return nil }
            output = rendered
        } else {
            output = cropped
        }

        let sourceEvidenceRect: CGRect
        if boardCalibration.zonesFollowPerspective,
           let projected = BoardPerspectiveMapper.projectedBoundingRect(of: sourceUIRegion, through: boardCalibration) {
            sourceEvidenceRect = BoardPerspectiveMapper.clampedUnitRect(projected, minimumSize: 0.001)
        } else {
            sourceEvidenceRect = sourceUIRegion
        }

        return TemplateFieldCropEvidence(
            image: output,
            sourceNormalizedRect: sourceEvidenceRect,
            boardNormalizedRect: padded
        )
    }

    /// Build 664 uses one field-coordinate contract. Perspective-enabled zones
    /// are already expressed in the rectified board square; legacy Build 663 zones
    /// are converted from the aspect-fit preview into source-camera coordinates.
    private func fieldInputRegion(
        from region: CGRect,
        boardCalibration: BoardCalibrationQuad,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat
    ) -> CGRect {
        if boardCalibration.zonesFollowPerspective {
            return BoardPerspectiveMapper.clampedUnitRect(region, minimumSize: 0.001)
        }
        return sourceNormalizedUIRect(
            from: region,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
    }

    /// Converts a calibration rectangle from the preview's top-left coordinate
    /// system into the oriented camera frame's top-left normalised coordinates.
    /// `visionROI` owns the aspect-fit/letterbox calculation; this method merely
    /// converts its bottom-left Vision result back to the UI convention used by
    /// the saved board quad.
    private func sourceNormalizedUIRect(
        from uiRect: CGRect,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat
    ) -> CGRect {
        let roi = visionROI(
            from: uiRect,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
        return CGRect(
            x: roi.minX,
            y: 1.0 - roi.minY - roi.height,
            width: roi.width,
            height: roi.height
        )
    }

    private func rotatedBoardCalibration(
        _ quad: BoardCalibrationQuad,
        by degrees: CGFloat
    ) -> BoardCalibrationQuad {
        BoardCalibrationQuad(
            topLeft: rotatedNormalizedPoint(quad.topLeft, by: degrees),
            topRight: rotatedNormalizedPoint(quad.topRight, by: degrees),
            bottomRight: rotatedNormalizedPoint(quad.bottomRight, by: degrees),
            bottomLeft: rotatedNormalizedPoint(quad.bottomLeft, by: degrees),
            zonesFollowPerspective: quad.zonesFollowPerspective
        )
    }

    private func rotatedNormalizedPoint(_ point: CGPoint, by degrees: CGFloat) -> CGPoint {
        let normalized = Int((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        switch normalized {
        case 90:
            return CGPoint(x: point.y, y: 1.0 - point.x)
        case 180:
            return CGPoint(x: 1.0 - point.x, y: 1.0 - point.y)
        case 270:
            return CGPoint(x: 1.0 - point.y, y: point.x)
        default:
            return point
        }
    }

    /// Maps a full-camera field rectangle into the unit-square board produced by
    /// CIPerspectiveCorrection. This is the missing UX16d2g1 transform: applying
    /// full-frame coordinates directly to a board-only image sampled the wrong
    /// pixels even though the calibration preview looked correct.
    private func rectifiedBoardNormalizedRect(
        sourceUIRegion: CGRect,
        boardCalibration: BoardCalibrationQuad
    ) -> CGRect? {
        guard let inverse = ProjectiveTransform.squareToQuad(boardCalibration)?.inverted() else {
            return nil
        }
        let points = [
            CGPoint(x: sourceUIRegion.minX, y: sourceUIRegion.minY),
            CGPoint(x: sourceUIRegion.maxX, y: sourceUIRegion.minY),
            CGPoint(x: sourceUIRegion.maxX, y: sourceUIRegion.maxY),
            CGPoint(x: sourceUIRegion.minX, y: sourceUIRegion.maxY)
        ].compactMap { inverse.applying($0) }
        guard points.count == 4 else { return nil }

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rect.origin.x = max(0, min(1, rect.origin.x))
        rect.origin.y = max(0, min(1, rect.origin.y))
        rect.size.width = max(0.001, min(1 - rect.origin.x, rect.width))
        rect.size.height = max(0.001, min(1 - rect.origin.y, rect.height))
        guard rect.width > 0.001, rect.height > 0.001 else { return nil }
        return rect
    }

    private struct ProjectiveTransform {
        let m00: Double
        let m01: Double
        let m02: Double
        let m10: Double
        let m11: Double
        let m12: Double
        let m20: Double
        let m21: Double
        let m22: Double

        static func squareToQuad(_ quad: BoardCalibrationQuad) -> ProjectiveTransform? {
            let x0 = Double(quad.topLeft.x)
            let y0 = Double(quad.topLeft.y)
            let x1 = Double(quad.topRight.x)
            let y1 = Double(quad.topRight.y)
            let x2 = Double(quad.bottomRight.x)
            let y2 = Double(quad.bottomRight.y)
            let x3 = Double(quad.bottomLeft.x)
            let y3 = Double(quad.bottomLeft.y)

            let dx1 = x1 - x2
            let dx2 = x3 - x2
            let dx3 = x0 - x1 + x2 - x3
            let dy1 = y1 - y2
            let dy2 = y3 - y2
            let dy3 = y0 - y1 + y2 - y3
            let denominator = dx1 * dy2 - dx2 * dy1

            let g: Double
            let h: Double
            if abs(denominator) < 1e-12 {
                g = 0
                h = 0
            } else {
                g = (dx3 * dy2 - dx2 * dy3) / denominator
                h = (dx1 * dy3 - dx3 * dy1) / denominator
            }

            return ProjectiveTransform(
                m00: x1 - x0 + g * x1,
                m01: x3 - x0 + h * x3,
                m02: x0,
                m10: y1 - y0 + g * y1,
                m11: y3 - y0 + h * y3,
                m12: y0,
                m20: g,
                m21: h,
                m22: 1
            )
        }

        func inverted() -> ProjectiveTransform? {
            let c00 = m11 * m22 - m12 * m21
            let c01 = -(m10 * m22 - m12 * m20)
            let c02 = m10 * m21 - m11 * m20
            let c10 = -(m01 * m22 - m02 * m21)
            let c11 = m00 * m22 - m02 * m20
            let c12 = -(m00 * m21 - m01 * m20)
            let c20 = m01 * m12 - m02 * m11
            let c21 = -(m00 * m12 - m02 * m10)
            let c22 = m00 * m11 - m01 * m10
            let determinant = m00 * c00 + m01 * c01 + m02 * c02
            guard abs(determinant) > 1e-12 else { return nil }
            let reciprocal = 1.0 / determinant
            return ProjectiveTransform(
                m00: c00 * reciprocal,
                m01: c10 * reciprocal,
                m02: c20 * reciprocal,
                m10: c01 * reciprocal,
                m11: c11 * reciprocal,
                m12: c21 * reciprocal,
                m20: c02 * reciprocal,
                m21: c12 * reciprocal,
                m22: c22 * reciprocal
            )
        }

        func applying(_ point: CGPoint) -> CGPoint? {
            let x = Double(point.x)
            let y = Double(point.y)
            let denominator = m20 * x + m21 * y + m22
            guard abs(denominator) > 1e-12 else { return nil }
            return CGPoint(
                x: CGFloat((m00 * x + m01 * y + m02) / denominator),
                y: CGFloat((m10 * x + m11 * y + m12) / denominator)
            )
        }
    }

    /// Build 670 makes the independently calibrated four-corner screen authoritative
    /// for every visual consumer. Full projective correction converts trapezoidal or
    /// skewed camera geometry into one upright canonical board before Guided
    /// Calibration, Test/live OCR, visual hashing and Image Relay crop it.
    private func perspectiveCorrectedBoardImage(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        quad: BoardCalibrationQuad,
        maximumDimension: CGFloat
    ) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(orientation.rawValue))

        let extent = image.extent
        let toPoint: (CGPoint) -> CGPoint = { normalized in
            CGPoint(
                x: extent.minX + normalized.x * extent.width,
                y: extent.minY + (1 - normalized.y) * extent.height
            )
        }
        let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: toPoint(quad.topLeft)),
            "inputTopRight": CIVector(cgPoint: toPoint(quad.topRight)),
            "inputBottomRight": CIVector(cgPoint: toPoint(quad.bottomRight)),
            "inputBottomLeft": CIVector(cgPoint: toPoint(quad.bottomLeft))
        ])
        return renderCanonicalBoardImage(
            corrected,
            extent: corrected.extent.integral,
            maximumDimension: maximumDimension
        )
    }

    private func renderCanonicalBoardImage(
        _ image: CIImage,
        extent: CGRect,
        maximumDimension: CGFloat,
        materialiseForCPUProcessing: Bool = false
    ) -> CGImage? {
        let canonicalExtent = extent.integral
        guard canonicalExtent.width > 16, canonicalExtent.height > 16,
              !canonicalExtent.isInfinite, !canonicalExtent.isNull else { return nil }
        let translated = image.transformed(by: CGAffineTransform(
            translationX: -canonicalExtent.origin.x,
            y: -canonicalExtent.origin.y
        ))
        let largest = max(canonicalExtent.width, canonicalExtent.height)
        let safeMaximum = max(64, maximumDimension)
        let scale = largest > safeMaximum ? safeMaximum / largest : 1.0
        let prepared: CIImage
        let renderExtent: CGRect
        if scale < 0.999 {
            prepared = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            renderExtent = CGRect(
                origin: .zero,
                size: CGSize(width: canonicalExtent.width * scale, height: canonicalExtent.height * scale)
            ).integral
        } else {
            prepared = translated
            renderExtent = CGRect(origin: .zero, size: canonicalExtent.size)
        }
        guard materialiseForCPUProcessing else {
            return ciContext.createCGImage(prepared, from: renderExtent)
        }

        // Recovery BJ / RL-147: Image Relay immediately performs bounded CPU
        // mask/hash work. Returning a GPU-backed CGImage and then drawing it into
        // CGContext forced a synchronous GPU-to-CPU readback on every Clock pass.
        // Render the small final field once into owned RGBA memory at the Core
        // Image acknowledgement boundary; all downstream work is then CPU-local.
        let width = max(1, Int(renderExtent.width.rounded(.up)))
        let height = max(1, Int(renderExtent.height.rounded(.up)))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            ciContext.render(
                prepared,
                toBitmap: base,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            return true
        }
        guard rendered,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func makeRequest(for key: OCRRegionKey) -> VNRecognizeTextRequest {
        if let cached = cachedVisionRequests[key] {
            return cached
        }
        let request = VNRecognizeTextRequest()

        // v0.8.2b: Pin the Vision text recognizer to revision 3 when the
        // installed OS supports it. If not, fall back to the latest supported
        // revision rather than relying on the framework default changing across
        // iOS releases.
        let supportedRevisions = VNRecognizeTextRequest.supportedRevisions
        if supportedRevisions.contains(3) {
            request.revision = 3
        } else if let latestRevision = supportedRevisions.max() {
            request.revision = latestRevision
        }

        request.recognitionLevel = key == .clock || key == .homeScore || key == .awayScore || key == .homePenalty1Time || key == .homePenalty2Time || key == .awayPenalty1Time || key == .awayPenalty2Time ? .accurate : .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01
        cachedVisionRequests[key] = request
        return request
    }

    // UX16d7a Build 507: keep the processor self-contained. The Build 506
    // rectified-zone path calls this helper directly; the similarly named
    // ViewModel helper is private to another type and therefore unavailable here.
    private func rotatedNormalizedRect(_ rect: CGRect, by degrees: CGFloat) -> CGRect {
        let normalized = Int((degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360))
        switch normalized {
        case 90:
            return CGRect(
                x: rect.minY,
                y: 1.0 - rect.minX - rect.width,
                width: rect.height,
                height: rect.width
            )
        case 180:
            return CGRect(
                x: 1.0 - rect.minX - rect.width,
                y: 1.0 - rect.minY - rect.height,
                width: rect.width,
                height: rect.height
            )
        case 270:
            return CGRect(
                x: 1.0 - rect.minY - rect.height,
                y: rect.minX,
                width: rect.height,
                height: rect.width
            )
        default:
            return rect
        }
    }

    private func visionROI(
        from uiRect: CGRect,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0
    ) -> CGRect {
        guard previewSize.width > 1, previewSize.height > 1 else {
            return CGRect(
                x: uiRect.minX,
                y: 1.0 - uiRect.minY - uiRect.height,
                width: uiRect.width,
                height: uiRect.height
            )
        }

        let mappedUIRect = rotatedNormalizedRect(uiRect, by: previewRotationDegrees)

        let rawWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let rawHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let orientedSize: CGSize
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            orientedSize = CGSize(width: rawHeight, height: rawWidth)
        default:
            orientedSize = CGSize(width: rawWidth, height: rawHeight)
        }

        let scale = min(previewSize.width / orientedSize.width, previewSize.height / orientedSize.height)
        let displayedWidth = orientedSize.width * scale
        let displayedHeight = orientedSize.height * scale
        let offsetX = (previewSize.width - displayedWidth) * 0.5
        let offsetY = (previewSize.height - displayedHeight) * 0.5

        let uiAbsolute = CGRect(
            x: mappedUIRect.minX * previewSize.width,
            y: mappedUIRect.minY * previewSize.height,
            width: mappedUIRect.width * previewSize.width,
            height: mappedUIRect.height * previewSize.height
        )

        var normalized = CGRect(
            x: (uiAbsolute.minX - offsetX) / displayedWidth,
            y: (uiAbsolute.minY - offsetY) / displayedHeight,
            width: uiAbsolute.width / displayedWidth,
            height: uiAbsolute.height / displayedHeight
        )
        normalized.origin.x = max(0, min(1, normalized.origin.x))
        normalized.origin.y = max(0, min(1, normalized.origin.y))
        normalized.size.width = max(0.001, min(1 - normalized.origin.x, normalized.size.width))
        normalized.size.height = max(0.001, min(1 - normalized.origin.y, normalized.size.height))

        return CGRect(
            x: normalized.minX,
            y: 1.0 - normalized.minY - normalized.height,
            width: normalized.width,
            height: normalized.height
        )
    }

    private func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch deviceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return .right
        }
    }

    private func threshold(for key: OCRRegionKey, thresholds: OCRThresholds) -> Float {
        switch key {
        case .clock: return thresholds.clock
        case .homeScore, .awayScore: return thresholds.score
        case .period: return thresholds.period
        case .homeShots, .awayShots: return thresholds.shots
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return thresholds.penaltyPlayer
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return thresholds.penaltyTime
        }
    }

    private func requiresNumericInput(for key: OCRRegionKey) -> Bool {
        switch key {
        case .clock, .period, .homeScore, .awayScore, .homeShots, .awayShots,
                .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player,
                .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return true
        }
    }

    private func hasNumericSignal(in text: String) -> Bool {
        text.contains(where: { $0.isNumber }) || text.contains(":") || text.contains(".")
    }

    private func hasPeriodDigitSubstitutionSignal(in text: String) -> Bool {
        // v0.8.1.7n: Period is numeric-only, but Vision frequently reads the
        // isolated period 2 as A and period 3 as J on the tested scoreboard.
        // This signal only bypasses the early numeric gate for the period field;
        // final acceptance still has to pass filteredPeriodText + validation.
        let upper = text.uppercased().replacingOccurrences(of: "PERIOD", with: "")
        return upper.contains("A") || upper.contains("J") || upper.contains("Z") || upper.contains("S") || upper.contains("I") || upper.contains("L")
    }

    private func classifySuggestedKey(text: String, rect: CGRect) -> OCRRegionKey? {
        let normalized = text.uppercased()
        let digits = normalized.filter(\.isNumber)
        let hasColon = normalized.contains(":") || normalized.contains(";") || normalized.contains(".")

        if hasColon {
            if rect.minY < 0.20 { return .clock }
            if rect.minX < 0.50 {
                return rect.minY < 0.56 ? .homePenalty1Time : .homePenalty2Time
            } else {
                return rect.minY < 0.56 ? .awayPenalty1Time : .awayPenalty2Time
            }
        }

        if normalized == "1" || normalized == "2" || normalized == "3" || normalized == "4" {
            if rect.midX > 0.42 && rect.midX < 0.58 { return .period }
        }

        if digits.count <= 2, !digits.isEmpty {
            if rect.minY < 0.33 {
                return rect.midX < 0.5 ? .homeScore : .awayScore
            }
            if rect.minY > 0.48 && rect.minY < 0.72 {
                return rect.midX < 0.5 ? (rect.minY < 0.58 ? .homePenalty1Player : .homePenalty2Player)
                                      : (rect.minY < 0.58 ? .awayPenalty1Player : .awayPenalty2Player)
            }
            if rect.midX < 0.50 {
                return rect.minY < 0.58 ? .homePenalty1Player : .homePenalty2Player
            } else {
                return rect.minY < 0.58 ? .awayPenalty1Player : .awayPenalty2Player
            }
        }

        return nil
    }

    private func segmentedFallbackEnabled(for key: OCRRegionKey) -> Bool {
        switch key {
        case .clock,
             .homeScore, .awayScore,
             .period,
             .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player,
             .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return true
        default:
            return false
        }
    }

    private func periodDigitClassifierCandidate(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, uiRegion: CGRect, regionRotationDegrees: CGFloat = 0, previewSize: CGSize, previewRotationDegrees: CGFloat = 0) -> OCRCandidate? {
        let styles = segmentationCropStyles(for: .period, colourProfile: OCRZoneColourProfile.defaultProfile(for: .period))
        var votes: [String: Float] = [:]

        for style in styles {
            guard let cropped = croppedCGImage(
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                uiRegion: uiRegion,
                style: style,
                regionRotationDegrees: regionRotationDegrees,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees
            ) else { continue }

            if let digit = classifySinglePeriodDigit(from: cropped) {
                votes[digit, default: 0] += style == .thresholded || style == .segmentationDilated || style == .segmentationEroded ? 1.10 : 1.0
            }
        }

        guard let winner = votes.max(by: { $0.value < $1.value }), periodAllowedValues.contains(winner.key), winner.value >= 1.0 else {
            return nil
        }

        return OCRCandidate(
            raw: winner.key,
            cleaned: winner.key,
            confidence: min(1.0, winner.value / 3.0),
            accepted: true,
            reason: "period digit classifier",
            recognizer: .segmented
        )
    }

    private func segmentedPrimaryCandidate(
        for key: OCRRegionKey,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        regionRotationDegrees: CGFloat = 0,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        colourProfile: OCRZoneColourProfile,
        executionPolicy: RinkLensOCRExecutionPolicy
    ) -> OCRCandidate? {
        guard segmentedFallbackEnabled(for: key) else { return nil }
        let styles = executionPolicy == .liveBounded
            ? boundedSegmentationCropStyles(for: key, colourProfile: colourProfile)
            : segmentationCropStyles(for: key, colourProfile: colourProfile)
        var best: OCRCandidate?
        var votes: [String: Int] = [:]

        for (index, style) in styles.enumerated() {
            guard let cropped = croppedCGImage(
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                uiRegion: uiRegion,
                style: style,
                regionRotationDegrees: regionRotationDegrees,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                cropPaddingPercent: colourProfile.cropPaddingPercent
            ) else { continue }

            let sequence: SevenSegmentDigitSequenceResult?
            switch key {
            case .homeScore, .awayScore,
                 .homePenalty1Player, .homePenalty2Player,
                 .awayPenalty1Player, .awayPenalty2Player:
                sequence = executionPolicy == .liveBounded
                    ? sevenSegmentTimerRecognizer.recogniseDigitSequenceBounded(from: cropped, maxDigits: 2, allowSingleDigit: true)
                    : sevenSegmentTimerRecognizer.recogniseDigitSequence(from: cropped, maxDigits: 2, allowSingleDigit: true)
            default:
                sequence = nil
            }

            guard let sequence, validate(sequence.value, for: key) else { continue }
            votes[sequence.value, default: 0] += 1
            let confidence = min(
                1.0,
                max(0.0, sequence.confidence - Float(index) * 0.025)
                    + Float(max(0, votes[sequence.value, default: 1] - 1)) * 0.12
            )
            let candidate = OCRCandidate(
                raw: sequence.rawDigits,
                cleaned: sequence.value,
                confidence: confidence,
                accepted: true,
                reason: "bounded segmentation style=\(style.traceLabel); \(sequence.diagnostic)",
                recognizer: .segmented
            )
            if best == nil || candidate.confidence > best!.confidence { best = candidate }
            if executionPolicy == .liveBounded,
               votes[sequence.value, default: 0] >= 2,
               candidate.confidence >= 0.88 { break }
        }
        return best
    }

    private func segmentedFallback(
        for key: OCRRegionKey,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        regionRotationDegrees: CGFloat = 0,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        colourProfile: OCRZoneColourProfile? = nil
    ) -> String? {
        let resolvedColourProfile = colourProfile ?? OCRZoneColourProfile.defaultProfile(for: key)
        let styles = segmentationCropStyles(for: key, colourProfile: resolvedColourProfile)
        for style in styles {
            guard let cropped = croppedCGImage(pixelBuffer: pixelBuffer, orientation: orientation, uiRegion: uiRegion, style: style, regionRotationDegrees: regionRotationDegrees, previewSize: previewSize, previewRotationDegrees: previewRotationDegrees, cropPaddingPercent: resolvedColourProfile.cropPaddingPercent) else { continue }
            if let value = segmentedFallback(from: cropped, for: key) {
                return value
            }
        }
        return nil
    }

    private func segmentedFallback(from cropped: CGImage, for key: OCRRegionKey) -> String? {
        switch key {
        case .homeScore, .awayScore:
            // v0.8.1.7p: score digits are often single, wide-margin crops.
            // The old generic segmentedDigits path estimated digit count from
            // crop width/height, split a one-digit score crop into two halves,
            // and could classify a clear 0 as 3. Use score-specific glyph
            // trimming first so the classifier sees the lit digit rather than
            // the surrounding scoreboard panel/border.
            guard let digits = segmentedScoreDigits(from: cropped, maxDigits: 2) else { return nil }
            let value = String(digits.suffix(2))
            return validate(value, for: key) ? value : nil

        case .period:
            guard let digits = segmentedDigits(from: cropped, maxDigits: 1),
                  let value = digits.last.map({ String($0) }),
                  periodAllowedValues.contains(value)
            else { return nil }
            return value

        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            // UX15c: player numbers use the same large seven-segment style as score
            // digits. Trim to the lit glyph area before splitting so a clear 45
            // is not reduced to a single digit from the middle/right of the crop.
            guard let digits = segmentedScoreDigits(from: cropped, maxDigits: 2) else { return nil }
            let value = String(digits.suffix(2))
            return validate(value, for: key) ? value : nil

        case .clock, .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            if let result = sevenSegmentTimerRecognizer.recogniseTimer(from: cropped, allowTwoMinuteDigits: key == .clock),
               validate(result.value, for: key) {
                return result.value
            }
            // Reject partial timer fragments; they are usually incomplete seven-segment reads.
            return nil
        default:
            return nil
        }
    }

    private enum OCRCropStyle {
        case standard
        case redChannel
        case yellowWhiteOnBlack
        case amberOrangeOnBlack
        case greenOnBlack
        case blueCyanOnBlack
        case lightOnDark
        case darkOnLight
        case sharpened
        case upscaledSharpened
        case thresholded
        case segmentationDilated
        case segmentationEroded

        var isThresholded: Bool {
            switch self {
            case .thresholded, .segmentationDilated, .segmentationEroded:
                return true
            default:
                return false
            }
        }

        var forcesSmallCropUpscale: Bool {
            switch self {
            case .upscaledSharpened, .thresholded, .segmentationDilated, .segmentationEroded:
                return true
            default:
                return false
            }
        }

        var traceLabel: String {
            switch self {
            case .standard: return "std"
            case .redChannel: return "red"
            case .yellowWhiteOnBlack: return "yellow"
            case .amberOrangeOnBlack: return "amber"
            case .greenOnBlack: return "green"
            case .blueCyanOnBlack: return "blue"
            case .lightOnDark: return "light"
            case .darkOnLight: return "dark"
            case .sharpened: return "sharp"
            case .upscaledSharpened: return "upsharp"
            case .thresholded: return "thresh"
            case .segmentationDilated: return "dilate"
            case .segmentationEroded: return "erode"
            }
        }

        var diagnosticLabel: String {
            switch self {
            case .standard: return "enhanced contrast OCR"
            case .redChannel: return "red-on-black OCR"
            case .yellowWhiteOnBlack: return "yellow/white-on-black OCR"
            case .amberOrangeOnBlack: return "amber/orange-on-black OCR"
            case .greenOnBlack: return "green-on-black OCR"
            case .blueCyanOnBlack: return "blue/cyan-on-black OCR"
            case .lightOnDark: return "light-on-dark OCR"
            case .darkOnLight: return "dark-on-light OCR"
            case .sharpened: return "sharpened OCR"
            case .upscaledSharpened: return "upscaled sharpened OCR"
            case .thresholded: return "thresholded OCR"
            case .segmentationDilated: return "segmentation dilation OCR"
            case .segmentationEroded: return "segmentation erosion OCR"
            }
        }
    }

    private func textualCropStyles(for key: OCRRegionKey, colourProfile: OCRZoneColourProfile) -> [OCRCropStyle] {
        switch colourProfile.resolvedPipeline(for: key) {
        case .redOnBlack:
            return [.redChannel, .thresholded, .upscaledSharpened, .standard]
        case .yellowWhiteOnBlack:
            return [.yellowWhiteOnBlack, .lightOnDark, .thresholded, .upscaledSharpened, .standard]
        case .amberOrangeOnBlack:
            return [.amberOrangeOnBlack, .yellowWhiteOnBlack, .redChannel, .thresholded, .standard]
        case .greenOnBlack:
            return [.greenOnBlack, .lightOnDark, .thresholded, .standard]
        case .blueCyanOnBlack:
            return [.blueCyanOnBlack, .lightOnDark, .thresholded, .standard]
        case .lightOnDark:
            return [.lightOnDark, .thresholded, .upscaledSharpened, .standard]
        case .darkOnLight:
            return [.darkOnLight, .thresholded, .standard]
        case .greyscale:
            return [.standard, .sharpened, .upscaledSharpened, .thresholded]
        case .auto:
            return textualCropStyles(for: key, colourProfile: OCRZoneColourProfile.defaultProfile(for: key))
        }
    }

    private func segmentationCropStyles(for key: OCRRegionKey, colourProfile: OCRZoneColourProfile) -> [OCRCropStyle] {
        var styles = textualCropStyles(for: key, colourProfile: colourProfile)
        styles.append(contentsOf: [.segmentationDilated, .segmentationEroded])
        var seen = Set<OCRCropStyle>()
        return styles.filter { seen.insert($0).inserted }
    }


    /// UX16d2e keeps live recognition finite: one colour-specific crop plus two
    /// deterministic morphology variants. Diagnostics retain the wider style set.
    private func boundedSegmentationCropStyles(
        for key: OCRRegionKey,
        colourProfile: OCRZoneColourProfile
    ) -> [OCRCropStyle] {
        let primary = textualCropStyles(for: key, colourProfile: colourProfile).first ?? .standard
        var styles: [OCRCropStyle] = [primary, .segmentationDilated, .segmentationEroded]
        var seen = Set<OCRCropStyle>()
        styles = styles.filter { seen.insert($0).inserted }
        return Array(styles.prefix(3))
    }
    private struct OCRCropPixelStats {
        let width: Int
        let height: Int
        let nonBlackPercent: Double
        let brightPercent: Double
    }

    private func pipelineProbeSummary(
        for key: OCRRegionKey,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        regionRotationDegrees: CGFloat,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        colourProfile: OCRZoneColourProfile
    ) -> String {
        // UX15e: the operator can see a clear Raw crop while Proc/Thresh may be
        // blank. Record compact per-style active-pixel metrics so logs show whether
        // the selected colour pipeline is losing the digit before OCR sees it.
        let resolvedPipeline = colourProfile.resolvedPipeline(for: key)
        let styles = Array(segmentationCropStyles(for: key, colourProfile: colourProfile).prefix(6))
        var summaries: [String] = []

        for style in styles {
            guard let image = croppedCGImage(
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                uiRegion: uiRegion,
                style: style,
                regionRotationDegrees: regionRotationDegrees,
                previewSize: previewSize,
                previewRotationDegrees: previewRotationDegrees,
                cropPaddingPercent: colourProfile.cropPaddingPercent
            ) else {
                summaries.append("\(style.traceLabel)=no-crop")
                continue
            }

            if let stats = cropPixelStats(from: image) {
                summaries.append(
                    String(
                        format: "%@=%dx%d nb=%.1f%% br=%.1f%%",
                        style.traceLabel,
                        stats.width,
                        stats.height,
                        stats.nonBlackPercent,
                        stats.brightPercent
                    )
                )
            } else {
                summaries.append("\(style.traceLabel)=no-stats")
            }
        }

        let cropRect = diagnosticPixelCropRect(
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            uiRegion: uiRegion,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees,
            cropPaddingPercent: colourProfile.cropPaddingPercent
        )
        let cropText = cropRect.map { rect in
            String(format: "crop=%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height)
        } ?? "crop=unavailable"

        return "pipeProbe key=\(key.rawValue) pipeline=\(resolvedPipeline.shortTitle) padding=\(Int((colourProfile.cropPaddingPercent * 100).rounded()))% \(cropText) styles=[\(summaries.joined(separator: "; "))]"
    }

    private func diagnosticPixelCropRect(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat,
        cropPaddingPercent: Double
    ) -> CGRect? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: Int32(orientation.rawValue))
        let normalizedCrop = visionROI(
            from: uiRegion,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
        let safePadding = CGFloat(Swift.max(0, Swift.min(0.18, cropPaddingPercent)))
        var paddedCrop = normalizedCrop.insetBy(
            dx: -(normalizedCrop.width * safePadding),
            dy: -(normalizedCrop.height * safePadding)
        )
        paddedCrop.origin.x = Swift.max(0, Swift.min(1, paddedCrop.origin.x))
        paddedCrop.origin.y = Swift.max(0, Swift.min(1, paddedCrop.origin.y))
        paddedCrop.size.width = Swift.max(0.001, Swift.min(1 - paddedCrop.origin.x, paddedCrop.width))
        paddedCrop.size.height = Swift.max(0.001, Swift.min(1 - paddedCrop.origin.y, paddedCrop.height))
        return CGRect(
            x: paddedCrop.minX * ciImage.extent.width,
            y: paddedCrop.minY * ciImage.extent.height,
            width: paddedCrop.width * ciImage.extent.width,
            height: paddedCrop.height * ciImage.extent.height
        )
        .integral
        .intersection(ciImage.extent)
    }

    private func cropPixelStats(from image: CGImage) -> OCRCropPixelStats? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        let total = Double(max(pixels.count, 1))
        let nonBlack = pixels.reduce(0) { $0 + ($1 > 18 ? 1 : 0) }
        let bright = pixels.reduce(0) { $0 + ($1 >= 150 ? 1 : 0) }
        return OCRCropPixelStats(
            width: width,
            height: height,
            nonBlackPercent: Double(nonBlack) * 100.0 / total,
            brightPercent: Double(bright) * 100.0 / total
        )
    }


    private func croppedCGImage(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        uiRegion: CGRect,
        style: OCRCropStyle = .standard,
        regionRotationDegrees: CGFloat = 0,
        previewSize: CGSize,
        previewRotationDegrees: CGFloat = 0,
        cropPaddingPercent: Double = 0
    ) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: Int32(orientation.rawValue))
        let width = ciImage.extent.width
        let height = ciImage.extent.height
        let normalizedCrop = visionROI(
            from: uiRegion,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            previewSize: previewSize,
            previewRotationDegrees: previewRotationDegrees
        )
        let safePadding = CGFloat(Swift.max(0, Swift.min(0.18, cropPaddingPercent)))
        var paddedCrop = normalizedCrop.insetBy(
            dx: -(normalizedCrop.width * safePadding),
            dy: -(normalizedCrop.height * safePadding)
        )
        paddedCrop.origin.x = Swift.max(0, Swift.min(1, paddedCrop.origin.x))
        paddedCrop.origin.y = Swift.max(0, Swift.min(1, paddedCrop.origin.y))
        paddedCrop.size.width = Swift.max(0.001, Swift.min(1 - paddedCrop.origin.x, paddedCrop.width))
        paddedCrop.size.height = Swift.max(0.001, Swift.min(1 - paddedCrop.origin.y, paddedCrop.height))

        let baseCrop = CGRect(
            x: paddedCrop.minX * width,
            y: paddedCrop.minY * height,
            width: paddedCrop.width * width,
            height: paddedCrop.height * height
        ).integral

        // UX13c: keep the live OCR crop locked to the visible calibration zone.
        // The previous 10px / 12% outer padding made OCR process more image than
        // the selected box, so Test OCR and live OCR no longer agreed visually.
        let crop = baseCrop
            .intersection(ciImage.extent)
            .integral
        guard crop.width > 4, crop.height > 4, !crop.isNull, !crop.isEmpty else { return nil }

        let cropped = ciImage
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))

        let preprocessed: CIImage
        switch style {
        case .standard:
            preprocessed = cropped
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.0, kCIInputBrightnessKey: 0.05])

        case .redChannel:
            preprocessed = cropped
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: 1.8, y: -0.75, z: -0.75, w: 0),
                        "inputGVector": CIVector(x: 1.8, y: -0.75, z: -0.75, w: 0),
                        "inputBVector": CIVector(x: 1.8, y: -0.75, z: -0.75, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                        "inputBiasVector": CIVector(x: 0.05, y: 0.05, z: 0.05, w: 0)
                    ]
                )
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 4.0, kCIInputBrightnessKey: 0.10])

        case .yellowWhiteOnBlack:
            preprocessed = cropped
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: 0.60, y: 0.60, z: -0.35, w: 0),
                        "inputGVector": CIVector(x: 0.60, y: 0.60, z: -0.35, w: 0),
                        "inputBVector": CIVector(x: 0.60, y: 0.60, z: -0.35, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                    ]
                )
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.4, kCIInputBrightnessKey: 0.08])

        case .amberOrangeOnBlack:
            preprocessed = cropped
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: 1.10, y: 0.45, z: -0.50, w: 0),
                        "inputGVector": CIVector(x: 1.10, y: 0.45, z: -0.50, w: 0),
                        "inputBVector": CIVector(x: 1.10, y: 0.45, z: -0.50, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                    ]
                )
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.7, kCIInputBrightnessKey: 0.08])

        case .greenOnBlack:
            preprocessed = cropped
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: -0.55, y: 1.70, z: -0.55, w: 0),
                        "inputGVector": CIVector(x: -0.55, y: 1.70, z: -0.55, w: 0),
                        "inputBVector": CIVector(x: -0.55, y: 1.70, z: -0.55, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                    ]
                )
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.5, kCIInputBrightnessKey: 0.08])

        case .blueCyanOnBlack:
            preprocessed = cropped
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: -0.45, y: -0.25, z: 1.65, w: 0),
                        "inputGVector": CIVector(x: -0.45, y: -0.25, z: 1.65, w: 0),
                        "inputBVector": CIVector(x: -0.45, y: -0.25, z: 1.65, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                    ]
                )
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 3.4, kCIInputBrightnessKey: 0.08])

        case .lightOnDark:
            preprocessed = cropped
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3.1, kCIInputBrightnessKey: 0.07])

        case .darkOnLight:
            preprocessed = cropped
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorInvert")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3.0, kCIInputBrightnessKey: 0.02])

        case .sharpened, .upscaledSharpened:
            preprocessed = cropped
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.35, kCIInputBrightnessKey: 0.04])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.72])

        case .thresholded:
            preprocessed = cropped
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3.4, kCIInputBrightnessKey: 0.02])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.82])

        case .segmentationDilated:
            preprocessed = cropped
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3.6, kCIInputBrightnessKey: 0.04])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.80])
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 1.0])

        case .segmentationEroded:
            preprocessed = cropped
                .applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3.6, kCIInputBrightnessKey: -0.02])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.80])
                .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": 1.0])
        }

        let outputExtent = CGRect(origin: .zero, size: crop.size)
        let corrected: CIImage
        let totalRotationDegrees = regionRotationDegrees + previewRotationDegrees
        if abs(totalRotationDegrees) > 0.05 {
            let radians = CGFloat(totalRotationDegrees) * .pi / 180
            let centre = CGPoint(x: outputExtent.midX, y: outputExtent.midY)
            let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: radians)
                .translatedBy(x: -centre.x, y: -centre.y)
            corrected = preprocessed.transformed(by: transform).cropped(to: outputExtent)
        } else {
            corrected = preprocessed.cropped(to: outputExtent)
        }

        // v0.8.1.7l: upscale small OCR crops before Vision/ML Kit/segmentation.
        // This helps tiny period/player/penalty digits without processing the full
        // camera frame. Large crops are still capped to avoid live-screen workload.
        let maxOCRCropDimension: CGFloat = 720
        let minimumOCRCropHeight: CGFloat = 96
        let largest = max(outputExtent.width, outputExtent.height)
        let smallCropScale: CGFloat
        if outputExtent.height < minimumOCRCropHeight {
            smallCropScale = min(3.0, minimumOCRCropHeight / max(outputExtent.height, 1.0))
        } else {
            smallCropScale = 1.0
        }
        let upscale = style.forcesSmallCropUpscale ? max(1.0, smallCropScale) : smallCropScale
        let downscale = largest * upscale > maxOCRCropDimension ? maxOCRCropDimension / (largest * upscale) : 1.0
        let scale = max(0.05, upscale * downscale)

        let renderImage: CIImage
        let renderExtent: CGRect
        if abs(scale - 1.0) > 0.001 {
            renderImage = corrected.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            renderExtent = CGRect(origin: .zero, size: CGSize(width: outputExtent.width * scale, height: outputExtent.height * scale)).integral
        } else {
            renderImage = corrected
            renderExtent = outputExtent
        }

        guard let rendered = ciContext.createCGImage(renderImage, from: renderExtent) else { return nil }
        if style.isThresholded {
            return thresholdedCGImage(from: rendered, threshold: 150)
        }
        return rendered
    }

    private func thresholdedCGImage(from image: CGImage, threshold: UInt8) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        for index in pixels.indices {
            pixels[index] = pixels[index] >= threshold ? 255 : 0
        }

        let providerData = pixels.withUnsafeBufferPointer { buffer -> CFData? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return CFDataCreate(kCFAllocatorDefault, baseAddress, pixels.count)
        }
        guard let providerData,
              let provider = CGDataProvider(data: providerData)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func segmentedDigits(from image: CGImage, maxDigits: Int) -> String? {
        let estimatedCount: Int
        let ratio = CGFloat(image.width) / max(CGFloat(image.height), 1)
        switch maxDigits {
        case 4:
            estimatedCount = ratio > 2.4 ? 4 : (ratio > 1.8 ? 3 : 2)
        default:
            estimatedCount = ratio > 1.35 ? 2 : 1
        }

        var digits: [String] = []
        for idx in 0..<estimatedCount {
            let x = CGFloat(idx) / CGFloat(estimatedCount)
            let w = 1.0 / CGFloat(estimatedCount)
            let rect = CGRect(x: x, y: 0, width: w, height: 1)
            if let digit = recognizeSevenSegmentDigit(in: image, normalizedRect: rect) {
                digits.append(String(digit))
            }
        }
        let value = digits.joined()
        return value.isEmpty ? nil : value
    }

    private func segmentedScoreDigits(from image: CGImage, maxDigits: Int) -> String? {
        guard let bitmap = grayscaleBitmap(from: image) else { return nil }
        let foregroundIsBright = shouldUseBrightForeground(bitmap)
        guard let glyphBounds = litGlyphBounds(in: bitmap, brightForeground: foregroundIsBright) else { return nil }

        // If the lit component is a single score digit, classify the trimmed
        // glyph directly. This fixes the observed clear 0 being displayed as 3.
        let glyphAspect = glyphBounds.width / max(glyphBounds.height, 0.001)
        if maxDigits <= 2, glyphAspect < 1.05 {
            if let digit = recognizeSevenSegmentDigit(in: image, normalizedRect: glyphBounds) {
                return String(digit)
            }
        }

        // For genuine two-digit scores, split only the trimmed glyph area, not
        // the whole padded scoreboard crop. This avoids classifying blank panel
        // space as a digit.
        let estimatedCount = maxDigits == 1 || glyphAspect < 1.05 ? 1 : min(maxDigits, 2)
        var digits: [String] = []
        for idx in 0..<estimatedCount {
            let x = glyphBounds.minX + (CGFloat(idx) / CGFloat(estimatedCount)) * glyphBounds.width
            let w = glyphBounds.width / CGFloat(estimatedCount)
            let rect = CGRect(x: x, y: glyphBounds.minY, width: w, height: glyphBounds.height)
            if let digit = recognizeSevenSegmentDigit(in: image, normalizedRect: rect) {
                digits.append(String(digit))
            }
        }

        let value = digits.joined()
        return value.isEmpty ? nil : value
    }

    private func litGlyphBounds(in bitmap: GrayBitmap, brightForeground: Bool) -> CGRect? {
        var minX = bitmap.width
        var minY = bitmap.height
        var maxX = -1
        var maxY = -1

        for y in 0..<bitmap.height {
            var rowActive = 0
            for x in 0..<bitmap.width {
                let p = bitmap.data[y * bitmap.width + x]
                if brightForeground ? p > 155 : p < 100 { rowActive += 1 }
            }
            let rowRatio = Double(rowActive) / Double(max(bitmap.width, 1))
            let isLikelyBorderRow = rowRatio > 0.55 && (y < bitmap.height / 4 || y > bitmap.height * 3 / 4)
            if isLikelyBorderRow { continue }

            for x in 0..<bitmap.width {
                let p = bitmap.data[y * bitmap.width + x]
                let active = brightForeground ? p > 155 : p < 100
                if active {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX > minX, maxY > minY else { return nil }
        let rect = CGRect(
            x: CGFloat(minX) / CGFloat(bitmap.width),
            y: CGFloat(minY) / CGFloat(bitmap.height),
            width: CGFloat(maxX - minX + 1) / CGFloat(bitmap.width),
            height: CGFloat(maxY - minY + 1) / CGFloat(bitmap.height)
        ).insetBy(dx: -0.04, dy: -0.04).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect.width > 0.02 && rect.height > 0.02 ? rect : nil
    }

    private func classifySinglePeriodDigit(from image: CGImage) -> String? {
        guard let bitmap = grayscaleBitmap(from: image) else { return nil }
        let foregroundIsBright = shouldUseBrightForeground(bitmap)

        // Ignore the scoreboard box/border by trimming to the lit component. Long
        // horizontal rows near the crop top/bottom are treated as border lines and
        // are excluded from the glyph bounds.
        var minX = bitmap.width
        var minY = bitmap.height
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.height {
            var rowActive = 0
            for x in 0..<bitmap.width {
                let p = bitmap.data[y * bitmap.width + x]
                if foregroundIsBright ? p > 155 : p < 100 { rowActive += 1 }
            }
            let isLikelyBorderRow = rowActive > Int(Double(bitmap.width) * 0.55) && (y < bitmap.height / 4 || y > bitmap.height * 3 / 4)
            if isLikelyBorderRow { continue }
            for x in 0..<bitmap.width {
                let p = bitmap.data[y * bitmap.width + x]
                let active = foregroundIsBright ? p > 155 : p < 100
                if active {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX > minX, maxY > minY else { return nil }
        let glyphRect = CGRect(
            x: CGFloat(minX) / CGFloat(bitmap.width),
            y: CGFloat(minY) / CGFloat(bitmap.height),
            width: CGFloat(maxX - minX + 1) / CGFloat(bitmap.width),
            height: CGFloat(maxY - minY + 1) / CGFloat(bitmap.height)
        ).insetBy(dx: -0.03, dy: -0.03).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        let segmentRects: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("top", 0.25, 0.05, 0.50, 0.15),
            ("upperLeft", 0.06, 0.18, 0.24, 0.32),
            ("upperRight", 0.70, 0.18, 0.24, 0.32),
            ("middle", 0.25, 0.42, 0.50, 0.16),
            ("lowerLeft", 0.06, 0.56, 0.24, 0.34),
            ("lowerRight", 0.70, 0.56, 0.24, 0.34),
            ("bottom", 0.25, 0.82, 0.50, 0.15)
        ]

        var bits = ""
        for (_, x, y, w, h) in segmentRects {
            let rect = CGRect(
                x: glyphRect.minX + x * glyphRect.width,
                y: glyphRect.minY + y * glyphRect.height,
                width: w * glyphRect.width,
                height: h * glyphRect.height
            )
            bits += segmentOn(bitmap, x: rect.minX, y: rect.minY, w: rect.width, h: rect.height, brightForeground: foregroundIsBright) ? "1" : "0"
        }

        // Restrict this classifier to hockey period digits only. The patterns use
        // seven-segment ordering: top, upper-left, upper-right, middle, lower-left,
        // lower-right, bottom.
        let periodPatterns: [String: String] = [
            "0010010": "1",
            "1011101": "2",
            "1011011": "3"
        ]
        var best: (value: String, distance: Int)?
        for (pattern, value) in periodPatterns {
            let distance = zip(pattern, bits).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            if best == nil || distance < best!.distance {
                best = (value, distance)
            }
        }

        guard let best, best.distance <= 2 else { return nil }
        return best.value
    }

    private func recognizeSevenSegmentDigit(in image: CGImage, normalizedRect: CGRect) -> Int? {
        let pixelRect = CGRect(
            x: normalizedRect.minX * CGFloat(image.width),
            y: normalizedRect.minY * CGFloat(image.height),
            width: normalizedRect.width * CGFloat(image.width),
            height: normalizedRect.height * CGFloat(image.height)
        ).integral
        guard let sub = image.cropping(to: pixelRect), let bitmap = grayscaleBitmap(from: sub) else { return nil }

        // v0.8.1.7m: segmentation must detect the lit digit stroke, not just
        // "dark" pixels. The cleanup preview shows this scoreboard is white-on-
        // dark. The old dark-pixel test treated black background as active
        // segments, which could make blank/solid dark crops look like an 8 and
        // could also reject the period 3 before the segmented path had a chance.
        let foregroundIsBright = shouldUseBrightForeground(bitmap)
        let fillRatio = foregroundFillRatio(bitmap, brightForeground: foregroundIsBright)
        if fillRatio < 0.025 || fillRatio > 0.62 { return nil }

        let segments: [Bool] = [
            segmentOn(bitmap, x: 0.25, y: 0.08, w: 0.50, h: 0.12, brightForeground: foregroundIsBright),
            segmentOn(bitmap, x: 0.10, y: 0.22, w: 0.18, h: 0.28, brightForeground: foregroundIsBright),
            segmentOn(bitmap, x: 0.72, y: 0.22, w: 0.18, h: 0.28, brightForeground: foregroundIsBright),
            segmentOn(bitmap, x: 0.25, y: 0.45, w: 0.50, h: 0.12, brightForeground: foregroundIsBright),
            segmentOn(bitmap, x: 0.10, y: 0.58, w: 0.18, h: 0.28, brightForeground: foregroundIsBright),
            segmentOn(bitmap, x: 0.72, y: 0.58, w: 0.18, h: 0.28, brightForeground: foregroundIsBright),
            segmentOn(bitmap, x: 0.25, y: 0.84, w: 0.50, h: 0.12, brightForeground: foregroundIsBright)
        ]

        let patterns: [String: Int] = [
            "1110111": 0, "0010010": 1, "1011101": 2, "1011011": 3, "0111010": 4,
            "1101011": 5, "1101111": 6, "1010010": 7, "1111111": 8, "1111011": 9
        ]
        let observed = segments.map { $0 ? "1" : "0" }.joined()
        var best: (digit: Int, distance: Int)?
        for (pattern, digit) in patterns {
            let distance = zip(pattern, observed).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            if best == nil || distance < best!.distance {
                best = (digit, distance)
            }
        }
        guard let best, best.distance <= 1 else { return nil }
        return best.digit
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

    private func shouldUseBrightForeground(_ bitmap: GrayBitmap) -> Bool {
        let total = max(bitmap.data.count, 1)
        let brightRatio = Double(bitmap.data.filter { $0 > 155 }.count) / Double(total)
        let darkRatio = Double(bitmap.data.filter { $0 < 100 }.count) / Double(total)

        // White LED/styled scoreboard digits on a dark panel are the common case
        // for IceCast. If there is a small but clear bright component on a mostly
        // dark crop, use bright pixels as the active digit stroke. Otherwise fall
        // back to dark foreground for black-on-light scoreboards.
        if brightRatio >= 0.025 && brightRatio <= 0.62 && darkRatio > brightRatio {
            return true
        }
        return false
    }

    private func foregroundFillRatio(_ bitmap: GrayBitmap, brightForeground: Bool) -> Double {
        let total = max(bitmap.data.count, 1)
        let foreground = bitmap.data.filter { pixel in
            brightForeground ? pixel > 155 : pixel < 100
        }.count
        return Double(foreground) / Double(total)
    }

    private func segmentOn(_ bitmap: GrayBitmap, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, brightForeground: Bool) -> Bool {
        let minX = max(Int(x * CGFloat(bitmap.width)), 0)
        let minY = max(Int(y * CGFloat(bitmap.height)), 0)
        let maxX = min(Int((x + w) * CGFloat(bitmap.width)), bitmap.width)
        let maxY = min(Int((y + h) * CGFloat(bitmap.height)), bitmap.height)
        guard maxX > minX, maxY > minY else { return false }
        var active = 0
        var total = 0
        for row in minY..<maxY {
            for col in minX..<maxX {
                let p = bitmap.data[row * bitmap.width + col]
                if brightForeground ? p > 155 : p < 100 { active += 1 }
                total += 1
            }
        }
        guard total > 0 else { return false }
        return Double(active) / Double(total) > 0.22
    }

    private func normalize(_ text: String, for key: OCRRegionKey) -> String {
        var value = text.uppercased()
            .replacingOccurrences(of: "|", with: "1")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "D", with: "0")
            .replacingOccurrences(of: "Q", with: "0")
            .replacingOccurrences(of: "Z", with: "2")
            .replacingOccurrences(of: "S", with: "5")
            .replacingOccurrences(of: "B", with: "8")
            .replacingOccurrences(of: "G", with: "6")
            .replacingOccurrences(of: ";", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if key == .clock || key == .homePenalty1Time || key == .homePenalty2Time || key == .awayPenalty1Time || key == .awayPenalty2Time {
            value = value.replacingOccurrences(of: ".", with: ":")
        }
        return value
    }

    private func clean(_ text: String, for key: OCRRegionKey) -> String {
        if key == .clock {
            return filteredClockText(text)
        }

        if key == .homePenalty1Time || key == .homePenalty2Time || key == .awayPenalty1Time || key == .awayPenalty2Time {
            return filteredPenaltyClockText(text)
        }

        if key == .period {
            return filteredPeriodText(text)
        }

        let cleanedScalars = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        return String(String.UnicodeScalarView(cleanedScalars))
    }

    private func filteredPeriodText(_ text: String) -> String {
        let upper = text.uppercased()
            .replacingOccurrences(of: "PERIOD", with: "")
            .replacingOccurrences(of: "1ST", with: "1")
            .replacingOccurrences(of: "2ND", with: "2")
            .replacingOccurrences(of: "3RD", with: "3")
            .replacingOccurrences(of: "4TH", with: "4")
            .replacingOccurrences(of: "5TH", with: "5")
            // v0.8.1.7m: Vision commonly reads this scoreboard's period 3 as J.
            // Keep this remap period-only so it cannot affect scores, clocks or
            // penalty player numbers.
            .replacingOccurrences(of: "J", with: "3")
            .replacingOccurrences(of: "A", with: "2")
            .replacingOccurrences(of: "Z", with: "2")
            .replacingOccurrences(of: "S", with: "3")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Only the shared allowed period values can leave the OCR cleaner.
        // This stops label text such as PERIOD, 1ST, I, L, or random OCR noise
        // entering smoothing / Live / Broadcast.
        if upper.contains("SO") { return "SO" }
        if upper.contains("OT") { return "OT" }
        if upper.contains("1") { return "1" }
        if upper.contains("2") { return "2" }
        if upper.contains("3") { return "3" }
        if upper.contains("4") { return "4" }
        if upper.contains("5") { return "5" }
        return ""
    }

    private func filteredClockText(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: #"[^0-9:]"#, with: "", options: .regularExpression)
        if let strict = firstMatch(in: stripped, pattern: #"([0-1]?\d:[0-5]\d)"#, group: 1) {
            return strict
        }

        if let loose = firstMatch(in: stripped, pattern: #"(\d{1,2}:?\d{2})"#, group: 1) {
            let normalized = loose.replacingOccurrences(of: #":"#, with: "")
            if normalized.count == 3 {
                return "\(normalized.prefix(1)):\(normalized.suffix(2))"
            } else if normalized.count == 4 {
                return "\(normalized.prefix(2)):\(normalized.suffix(2))"
            }
        }

        let digits = stripped.filter(\.isNumber)
        if digits.count >= 3 {
            let trimmed = String(digits.prefix(4))
            if trimmed.count == 3 {
                return "\(trimmed.prefix(1)):\(trimmed.suffix(2))"
            }
            if trimmed.count == 4 {
                return "\(trimmed.prefix(2)):\(trimmed.suffix(2))"
            }
        }

        // UX15g: do not return seconds-only or colon-only fragments for the game clock.
        // A crop that visibly contains 2:43 was being reduced to raw ":2" / cleaned "2"
        // and then published in calibration diagnostics. Timer fields must only leave
        // the cleaner as a full M:SS / MM:SS value, or empty so fallback/retain logic wins.
        return ""
    }

    private func filteredPenaltyClockText(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: #"[^0-9:]"#, with: "", options: .regularExpression)
        if let strict = firstMatch(in: stripped, pattern: #"([0-2]?\d:[0-5]\d)"#, group: 1) {
            return strict
        }

        if let loose = firstMatch(in: stripped, pattern: #"(\d{1,2}:?\d{2})"#, group: 1) {
            let normalized = loose.replacingOccurrences(of: #":"#, with: "")
            if normalized.count == 3 {
                return "\(normalized.prefix(1)):\(normalized.suffix(2))"
            } else if normalized.count == 4 {
                return "\(normalized.prefix(2)):\(normalized.suffix(2))"
            }
        }

        let digits = stripped.filter(\.isNumber)
        if digits.count >= 3 {
            let trimmed = String(digits.prefix(4))
            if trimmed.count == 3 {
                return "\(trimmed.prefix(1)):\(trimmed.suffix(2))"
            }
            if trimmed.count == 4 {
                return "\(trimmed.prefix(2)):\(trimmed.suffix(2))"
            }
        }

        // UX15g: do not accept seconds-only fragments such as "2", "43" or ":2" for
        // penalty timers. They are often partial seven-segment reads and should fall
        // back to ML Kit / segmented recognition or hold the previous trusted value.
        return ""
    }

    private func repairTimerFromRaw(_ raw: String, cleaned: String, for key: OCRRegionKey) -> String? {
        guard isTimerKey(key) else { return nil }
        let combined = cleaned.isEmpty ? raw : cleaned
        let digits = combined.filter { $0.isNumber }
        if digits.count == 3 {
            let candidate = "\(digits.prefix(1)):\(digits.suffix(2))"
            return validate(candidate, for: key) ? candidate : nil
        }
        if digits.count == 4 {
            let candidate = "\(digits.prefix(2)):\(digits.suffix(2))"
            return validate(candidate, for: key) ? candidate : nil
        }
        return nil
    }

    private func validate(_ value: String, for key: OCRRegionKey) -> Bool {
        switch key {
        case .homeScore, .awayScore, .homeShots, .awayShots,
                .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return value.range(of: #"^\d{1,2}$"#, options: .regularExpression) != nil
        case .clock:
            return value.range(of: #"^(?:[0-1]?\d|20):[0-5]\d$"#, options: .regularExpression) != nil
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return value.range(of: #"^(?:10|[0-9]):[0-5]\d$"#, options: .regularExpression) != nil
        case .period:
            return periodAllowedValues.contains(value)
        }
    }

    private func parseClock(_ text: String) -> String? {
        if let strict = firstMatch(in: text, pattern: #"((?:[0-1]?\d|20):[0-5]\d)"#, group: 1) {
            return strict
        }
        let digitsOnly = text.filter(\.isNumber)
        if digitsOnly.count == 3 {
            let repaired = "\(digitsOnly.prefix(1)):\(digitsOnly.suffix(2))"
            if repaired.range(of: #"^(?:[0-1]?\d|20):[0-5]\d$"#, options: .regularExpression) != nil {
                return repaired
            }
        } else if digitsOnly.count == 4 {
            let repaired = "\(digitsOnly.prefix(2)):\(digitsOnly.suffix(2))"
            if repaired.range(of: #"^(?:[0-1]?\d|20):[0-5]\d$"#, options: .regularExpression) != nil {
                return repaired
            }
        }
        return nil
    }

    private func parsePenaltyClock(_ text: String) -> String? {
        if let full = firstMatch(in: text, pattern: #"((?:10|[0-9]):[0-5]\d)"#, group: 1) {
            return full
        }
        return nil
    }

    private func parsePlayer(_ text: String) -> Int? {
        guard let value = parseInt(text), (1...99).contains(value) else { return nil }
        return value
    }

    private func parseScoreInt(_ text: String) -> Int? {
        guard let value = parseInt(text), (0...99).contains(value) else { return nil }
        return value
    }

    private func parseInt(_ text: String) -> Int? {
        guard let number = firstMatch(in: text, pattern: #"(\d{1,2})"#, group: 1) else { return nil }
        return Int(number)
    }

    private func parsePeriod(_ text: String) -> Int? {
        let token = text.uppercased().replacingOccurrences(of: " ", with: "")
        switch token {
        case "OT":
            return 4
        case "SO":
            return 5
        default:
            guard let number = parseInt(token), (1...5).contains(number) else { return nil }
            return number
        }
    }

    private func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard let captureRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[captureRange])
    }
}


#endif
