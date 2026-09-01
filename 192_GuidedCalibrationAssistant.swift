// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import CoreImage
import CoreVideo
import Foundation

// MARK: - Build 663 Guided Calibration Assistant

struct CalibrationQualitySnapshot: Equatable {
    var focusScore: Int = 0
    var exposureScore: Int = 0
    var contrastScore: Int = 0
    var zoneFitScore: Int = 0
    var readinessScore: Int = 0
    var focusText: String = "Waiting for frame"
    var exposureText: String = "Waiting for frame"
    var contrastText: String = "Waiting for frame"
    var zoneFitText: String = "Waiting for frame"
    var orientationText: String = "Waiting for frame"
    var suggestedRotationDegrees: CGFloat?
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var zonePixelWidth: Int = 0
    var zonePixelHeight: Int = 0
    var activeHeightFraction: CGFloat = 0
    var activeWidthFraction: CGFloat = 0
    var stableFrameCount: Int = 0

    static let waiting = CalibrationQualitySnapshot()

    var readinessText: String {
        switch readinessScore {
        case 80...100: return "Ready"
        case 60..<80: return "Usable"
        case 35..<60: return "Adjust"
        default: return "Not ready"
        }
    }
}

struct CalibrationAnalysisResult {
    let quality: CalibrationQualitySnapshot
    let loupeImage: UIImage?
    let loupeZoneRect: CGRect
    let loupeCharacterRect: CGRect?
}

@MainActor
enum CalibrationQualityAnalyzer {
    private static var ciContext: CIContext { ScoreboardImageProcessingResources.shared.ciContext }

    static func analyse(
        frame: RinkLensFrameHubFrame,
        region: OCRRegion,
        boardCalibration: BoardCalibrationQuad,
        previewMagnification: CGFloat,
        previewRotationDegrees: CGFloat,
        exactLoupe: ScoreboardOCRProcessor.TemplateFieldLoupeEvidence? = nil
    ) -> CalibrationAnalysisResult {
        let safeRegion = clamped(region.rect)
        let displayedZonePolygon: [CGPoint]
        let displayedScreenPolygon: [CGPoint]
        if boardCalibration.zonesFollowPerspective {
            displayedZonePolygon = BoardPerspectiveMapper.projectedCorners(of: safeRegion, through: boardCalibration) ?? corners(of: safeRegion)
            displayedScreenPolygon = [
                boardCalibration.topLeft,
                boardCalibration.topRight,
                boardCalibration.bottomRight,
                boardCalibration.bottomLeft
            ]
        } else {
            displayedZonePolygon = corners(of: safeRegion)
            displayedScreenPolygon = corners(of: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let rawZonePolygon = displayedZonePolygon.map { rotatedNormalizedPoint($0, by: previewRotationDegrees) }
        let rawScreenPolygon = displayedScreenPolygon.map { rotatedNormalizedPoint($0, by: previewRotationDegrees) }
        let rawRegion = clamped(boundingRect(rawZonePolygon))
        let rawScreenRegion = clamped(boundingRect(rawScreenPolygon))
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        guard width > 8, height > 8, safeRegion.width > 0.001, safeRegion.height > 0.001 else {
            return CalibrationAnalysisResult(quality: .waiting, loupeImage: nil, loupeZoneRect: .zero, loupeCharacterRect: nil)
        }

        let cameraZoneMetrics = sampledLumaMetrics(pixelBuffer: frame.pixelBuffer, region: rawRegion, polygon: rawZonePolygon)
        // Build 672: character geometry must be measured from the same upright,
        // perspective-corrected pixels shown in the Guided Calibration loupe.
        // The previous camera-space measurement could drift outside the cyan OCR
        // rectangle after projective correction, especially on the left side.
        let rectifiedZoneMetrics = exactLoupe.flatMap {
            sampledLumaMetrics(cgImage: $0.image, normalizedRegion: $0.zoneNormalizedRect)
        }
        let zoneMetrics = rectifiedZoneMetrics ?? cameraZoneMetrics
        let screenMetrics = sampledLumaMetrics(pixelBuffer: frame.pixelBuffer, region: rawScreenRegion, polygon: rawScreenPolygon)
        let zoneWidth: Int
        let zoneHeight: Int
        if let exactLoupe {
            zoneWidth = max(1, Int((exactLoupe.zoneNormalizedRect.width * CGFloat(exactLoupe.image.width)).rounded()))
            zoneHeight = max(1, Int((exactLoupe.zoneNormalizedRect.height * CGFloat(exactLoupe.image.height)).rounded()))
        } else {
            zoneWidth = max(1, Int((rawRegion.width * CGFloat(width)).rounded()))
            zoneHeight = max(1, Int((rawRegion.height * CGFloat(height)).rounded()))
        }

        let focusScore = Int(clamp(screenMetrics.edgeMean * 3.2, 0, 100).rounded())
        // A scoreboard is intentionally mostly black, so whole-frame mean brightness is
        // not a useful exposure target. Judge the illuminated characters and dynamic
        // range inside the four-corner scoreboard polygon instead.
        let illuminatedLevel = screenMetrics.percentile98
        let dynamicRange = illuminatedLevel - screenMetrics.percentile10
        let exposureTooBright = screenMetrics.highClipFraction > 0.055
            || (illuminatedLevel > 250 && screenMetrics.highClipFraction > 0.018)
        let exposureTooDark = illuminatedLevel < 125
            || dynamicRange < 52
        let exposureScore: Int
        if exposureTooBright {
            exposureScore = Int(clamp(58 - screenMetrics.highClipFraction * 360, 0, 58).rounded())
        } else if exposureTooDark {
            exposureScore = Int(clamp((illuminatedLevel / 125.0) * 58, 0, 58).rounded())
        } else {
            let highlightPenalty = abs(illuminatedLevel - 205) * 0.12
            let clipPenalty = screenMetrics.highClipFraction * 180
            exposureScore = Int(clamp(94 - highlightPenalty - clipPenalty, 70, 96).rounded())
        }
        let contrastScore = Int(clamp(zoneMetrics.standardDeviation * 2.35, 0, 100).rounded())

        let zoneFitScore: Int
        let zoneFitText: String
        if zoneMetrics.activeFraction < 0.012 {
            zoneFitScore = 20
            zoneFitText = "No strong character found"
        } else if zoneMetrics.touchesEdge || zoneMetrics.activeHeightFraction > 0.93 || zoneMetrics.activeWidthFraction > 0.96 {
            zoneFitScore = 42
            zoneFitText = "Too tight — character touches edge"
        } else if zoneMetrics.activeHeightFraction < 0.42 {
            zoneFitScore = 48
            zoneFitText = "Zone too large — reduce height"
        } else if zoneMetrics.activeHeightFraction > 0.88 {
            zoneFitScore = 67
            zoneFitText = "Tight — add a small margin"
        } else {
            zoneFitScore = 92
            zoneFitText = "Good character margin"
        }

        let focusText: String
        switch focusScore {
        case 72...100: focusText = "Good — lock focus when stable"
        case 45..<72: focusText = "Usable — fine-adjust focus"
        default: focusText = "Soft — adjust focus"
        }

        let exposureText: String
        if exposureTooBright {
            exposureText = "Too bright — reduce manual exposure"
        } else if exposureTooDark {
            exposureText = "Too dark — increase manual exposure"
        } else {
            exposureText = "Good — keep current manual exposure"
        }

        let contrastText: String
        switch contrastScore {
        case 70...100: contrastText = "Strong colour/background separation"
        case 45..<70: contrastText = "Usable separation"
        default: contrastText = "Weak separation — review colour profile"
        }

        let rotation = normalizedRotation(previewRotationDegrees)
        let rotationSwapsAxes = Int(abs(rotation).rounded()) % 180 == 90
        let displayedWidth = rotationSwapsAxes ? height : width
        let displayedHeight = rotationSwapsAxes ? width : height
        let isDisplayedLandscape = displayedWidth >= displayedHeight
        let screenTopAngle = atan2(
            boardCalibration.topRight.y - boardCalibration.topLeft.y,
            boardCalibration.topRight.x - boardCalibration.topLeft.x
        ) * 180 / .pi
        let orientationText: String
        if boardCalibration.zonesFollowPerspective {
            orientationText = String(
                format: "Screen deskew %+.1f° → upright · local %+.1f°",
                Double(screenTopAngle),
                Double(region.rotationDegrees)
            )
        } else {
            orientationText = isDisplayedLandscape
                ? "Landscape · \(Int(rotation.rounded()))°"
                : "Portrait feed · rotate preview 90°"
        }
        let suggestedRotation: CGFloat? = isDisplayedLandscape ? nil : normalizedRotation(rotation + 90)

        let readiness = Int(clamp(
            Double(focusScore) * 0.32
                + Double(exposureScore) * 0.24
                + Double(contrastScore) * 0.20
                + Double(zoneFitScore) * 0.24,
            0,
            100
        ).rounded())

        var quality = CalibrationQualitySnapshot(
            focusScore: focusScore,
            exposureScore: exposureScore,
            contrastScore: contrastScore,
            zoneFitScore: zoneFitScore,
            readinessScore: readiness,
            focusText: focusText,
            exposureText: exposureText,
            contrastText: contrastText,
            zoneFitText: zoneFitText,
            orientationText: orientationText,
            suggestedRotationDegrees: suggestedRotation,
            frameWidth: width,
            frameHeight: height,
            zonePixelWidth: zoneWidth,
            zonePixelHeight: zoneHeight,
            activeHeightFraction: zoneMetrics.activeHeightFraction,
            activeWidthFraction: zoneMetrics.activeWidthFraction,
            stableFrameCount: 0
        )

        let loupe: (image: UIImage?, zoneRect: CGRect)
        if let exactLoupe {
            loupe = (
                image: UIImage(cgImage: exactLoupe.image, scale: 1, orientation: .up),
                zoneRect: exactLoupe.zoneNormalizedRect
            )
        } else {
            loupe = makeLoupe(
                pixelBuffer: frame.pixelBuffer,
                region: rawRegion,
                magnification: previewMagnification
            )
        }
        quality.orientationText = orientationText
        return CalibrationAnalysisResult(
            quality: quality,
            loupeImage: loupe.image,
            loupeZoneRect: loupe.zoneRect,
            // Only publish the green character evidence from the exact upright
            // crop used by OCR/Image Relay. A temporary camera-space fallback can
            // still populate focus/exposure scores, but it must not draw a
            // misleading character rectangle over the rectified Guide preview.
            loupeCharacterRect: exactLoupe.flatMap { _ in
                zoneMetrics.activeRect.map { active in
                    CGRect(
                        x: loupe.zoneRect.minX + active.minX * loupe.zoneRect.width,
                        y: loupe.zoneRect.minY + active.minY * loupe.zoneRect.height,
                        width: active.width * loupe.zoneRect.width,
                        height: active.height * loupe.zoneRect.height
                    )
                }
            }
        )
    }

    private struct LumaMetrics {
        let mean: Double
        let standardDeviation: Double
        let edgeMean: Double
        let lowClipFraction: Double
        let highClipFraction: Double
        let activeFraction: Double
        let activeWidthFraction: CGFloat
        let activeHeightFraction: CGFloat
        let activeRect: CGRect?
        let touchesEdge: Bool
        let percentile10: Double
        let percentile90: Double
        let percentile98: Double
    }

    private static func sampledLumaMetrics(pixelBuffer: CVPixelBuffer, region: CGRect, polygon: [CGPoint]? = nil) -> LumaMetrics {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planar = CVPixelBufferIsPlanar(pixelBuffer) && CVPixelBufferGetPlaneCount(pixelBuffer) > 0
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            return LumaMetrics(mean: 0, standardDeviation: 0, edgeMean: 0, lowClipFraction: 1, highClipFraction: 0, activeFraction: 0, activeWidthFraction: 0, activeHeightFraction: 0, activeRect: nil, touchesEdge: false, percentile10: 0, percentile90: 0, percentile98: 0)
        }

        let x0 = max(0, min(width - 1, Int((region.minX * CGFloat(width)).rounded(.down))))
        let x1 = max(x0 + 1, min(width, Int((region.maxX * CGFloat(width)).rounded(.up))))
        let y0 = max(0, min(height - 1, Int((region.minY * CGFloat(height)).rounded(.down))))
        let y1 = max(y0 + 1, min(height, Int((region.maxY * CGFloat(height)).rounded(.up))))
        let cropWidth = max(1, x1 - x0)
        let cropHeight = max(1, y1 - y0)
        let sampleStep = max(1, Int(sqrt(Double(cropWidth * cropHeight) / 8_000.0)))

        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base else {
            return LumaMetrics(mean: 0, standardDeviation: 0, edgeMean: 0, lowClipFraction: 1, highClipFraction: 0, activeFraction: 0, activeWidthFraction: 0, activeHeightFraction: 0, activeRect: nil, touchesEdge: false, percentile10: 0, percentile90: 0, percentile98: 0)
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isBGRA = pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        func luma(x: Int, y: Int) -> Double {
            if planar {
                return Double(pointer[y * bytesPerRow + x])
            }
            if isBGRA {
                let offset = y * bytesPerRow + x * 4
                let b = Double(pointer[offset])
                let g = Double(pointer[offset + 1])
                let r = Double(pointer[offset + 2])
                return 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
            return Double(pointer[y * bytesPerRow + min(x, bytesPerRow - 1)])
        }

        var values: [(x: Int, y: Int, value: Double)] = []
        values.reserveCapacity(max(64, (cropWidth / sampleStep) * (cropHeight / sampleStep)))
        var sum = 0.0
        var sumSquares = 0.0
        var low = 0
        var high = 0
        var edgeSum = 0.0
        var edgeCount = 0

        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                if let polygon {
                    let point = CGPoint(
                        x: (CGFloat(x) + 0.5) / CGFloat(width),
                        y: (CGFloat(y) + 0.5) / CGFloat(height)
                    )
                    if !contains(point, in: polygon) {
                        x += sampleStep
                        continue
                    }
                }
                let value = luma(x: x, y: y)
                values.append((x, y, value))
                sum += value
                sumSquares += value * value
                if value <= 22 { low += 1 }
                if value >= 232 { high += 1 }
                if x + sampleStep < x1 {
                    edgeSum += abs(value - luma(x: x + sampleStep, y: y))
                    edgeCount += 1
                }
                if y + sampleStep < y1 {
                    edgeSum += abs(value - luma(x: x, y: y + sampleStep))
                    edgeCount += 1
                }
                x += sampleStep
            }
            y += sampleStep
        }

        guard !values.isEmpty else {
            return LumaMetrics(mean: 0, standardDeviation: 0, edgeMean: 0, lowClipFraction: 1, highClipFraction: 0, activeFraction: 0, activeWidthFraction: 0, activeHeightFraction: 0, activeRect: nil, touchesEdge: false, percentile10: 0, percentile90: 0, percentile98: 0)
        }
        let count = values.count
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        let standardDeviation = sqrt(variance)
        // Build 676: the green Guide rectangle is evidence only, but it must
        // never cut through a visible LED stroke. The former high threshold
        // tracked only the brightest centre of cream/white characters, so the
        // lower anti-aliased edge and colon could sit outside the rectangle until
        // a zone move changed the sampled histogram. Use a deliberately broader
        // bright-foreground threshold on the exact rectified crop.
        let threshold = min(220, mean + max(10, standardDeviation * 0.30))

        var activeCount = 0
        var minX = x1
        var maxX = x0
        var minY = y1
        var maxY = y0
        for sample in values where sample.value >= threshold {
            activeCount += 1
            minX = min(minX, sample.x)
            maxX = max(maxX, sample.x)
            minY = min(minY, sample.y)
            maxY = max(maxY, sample.y)
        }

        let activeFraction = Double(activeCount) / Double(count)
        let activeWidth: CGFloat
        let activeHeight: CGFloat
        let activeRect: CGRect?
        let touchesEdge: Bool
        if activeCount > 0 {
            activeWidth = CGFloat(maxX - minX + sampleStep) / CGFloat(cropWidth)
            activeHeight = CGFloat(maxY - minY + sampleStep) / CGFloat(cropHeight)
            activeRect = CGRect(
                x: CGFloat(minX - x0) / CGFloat(cropWidth),
                y: CGFloat(minY - y0) / CGFloat(cropHeight),
                width: activeWidth,
                height: activeHeight
            )
            let edgeMarginX = max(sampleStep, Int(CGFloat(cropWidth) * 0.055))
            let edgeMarginY = max(sampleStep, Int(CGFloat(cropHeight) * 0.055))
            touchesEdge = minX <= x0 + edgeMarginX || maxX >= x1 - edgeMarginX || minY <= y0 + edgeMarginY || maxY >= y1 - edgeMarginY
        } else {
            activeWidth = 0
            activeHeight = 0
            activeRect = nil
            touchesEdge = false
        }

        let sortedLuma = values.map(\.value).sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sortedLuma.isEmpty else { return 0 }
            let position = clamp(fraction, 0, 1) * Double(sortedLuma.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            if lower == upper { return sortedLuma[lower] }
            let weight = position - Double(lower)
            return sortedLuma[lower] * (1 - weight) + sortedLuma[upper] * weight
        }

        return LumaMetrics(
            mean: mean,
            standardDeviation: standardDeviation,
            edgeMean: edgeCount > 0 ? edgeSum / Double(edgeCount) : 0,
            lowClipFraction: Double(low) / Double(count),
            highClipFraction: Double(high) / Double(count),
            activeFraction: activeFraction,
            activeWidthFraction: clamp(activeWidth, 0, 1),
            activeHeightFraction: clamp(activeHeight, 0, 1),
            activeRect: activeRect,
            touchesEdge: touchesEdge,
            percentile10: percentile(0.10),
            percentile90: percentile(0.90),
            percentile98: percentile(0.98)
        )
    }


    private static func sampledLumaMetrics(cgImage: CGImage, normalizedRegion: CGRect) -> LumaMetrics? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let safe = normalizedRegion.standardized.intersection(unit)
        guard safe.width > 0.001, safe.height > 0.001 else { return nil }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let pixelRect = CGRect(
            x: safe.minX * CGFloat(imageWidth),
            y: safe.minY * CGFloat(imageHeight),
            width: safe.width * CGFloat(imageWidth),
            height: safe.height * CGFloat(imageHeight)
        ).integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard pixelRect.width > 2, pixelRect.height > 2,
              let crop = cgImage.cropping(to: pixelRect) else { return nil }

        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            // Keep the analyser's origin at the displayed top-left so the green
            // TOP/BOTTOM evidence maps directly onto the upright preview.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        let sampleStep = max(1, Int(sqrt(Double(width * height) / 8_000.0)))
        var values: [(x: Int, y: Int, value: Double)] = []
        values.reserveCapacity(max(64, (width / sampleStep) * (height / sampleStep)))
        var sum = 0.0
        var sumSquares = 0.0
        var low = 0
        var high = 0
        var edgeSum = 0.0
        var edgeCount = 0

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let value = Double(pixels[y * width + x])
                values.append((x, y, value))
                sum += value
                sumSquares += value * value
                if value <= 22 { low += 1 }
                if value >= 232 { high += 1 }
                if x + sampleStep < width {
                    edgeSum += abs(value - Double(pixels[y * width + x + sampleStep]))
                    edgeCount += 1
                }
                if y + sampleStep < height {
                    edgeSum += abs(value - Double(pixels[(y + sampleStep) * width + x]))
                    edgeCount += 1
                }
                x += sampleStep
            }
            y += sampleStep
        }
        guard !values.isEmpty else { return nil }

        let count = values.count
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        let standardDeviation = sqrt(variance)
        // Build 676: the green Guide rectangle is evidence only, but it must
        // never cut through a visible LED stroke. The former high threshold
        // tracked only the brightest centre of cream/white characters, so the
        // lower anti-aliased edge and colon could sit outside the rectangle until
        // a zone move changed the sampled histogram. Use a deliberately broader
        // bright-foreground threshold on the exact rectified crop.
        let threshold = min(220, mean + max(10, standardDeviation * 0.30))

        var activeCount = 0
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        for sample in values where sample.value >= threshold {
            activeCount += 1
            minX = min(minX, sample.x)
            maxX = max(maxX, sample.x)
            minY = min(minY, sample.y)
            maxY = max(maxY, sample.y)
        }

        let activeFraction = Double(activeCount) / Double(count)
        let activeWidth: CGFloat
        let activeHeight: CGFloat
        let activeRect: CGRect?
        let touchesEdge: Bool
        if activeCount > 0 {
            // Build 676 adds a bounded evidence margin around the detected
            // foreground. Vertical padding is intentionally larger because the
            // scoreboard's lower LED strokes and decimal/colon dots are dimmer
            // than the character centre. This box is diagnostic only; the saved
            // cyan/orange zone remains the OCR and Image Relay crop authority.
            let evidencePadX = max(sampleStep, Int((CGFloat(width) * 0.025).rounded(.up)))
            let evidencePadY = max(sampleStep, Int((CGFloat(height) * 0.075).rounded(.up)))
            minX = max(0, minX - evidencePadX)
            maxX = min(width - 1, maxX + evidencePadX)
            minY = max(0, minY - evidencePadY)
            maxY = min(height - 1, maxY + evidencePadY)
            activeWidth = CGFloat(maxX - minX + sampleStep) / CGFloat(width)
            activeHeight = CGFloat(maxY - minY + sampleStep) / CGFloat(height)
            activeRect = CGRect(
                x: CGFloat(minX) / CGFloat(width),
                y: CGFloat(minY) / CGFloat(height),
                width: activeWidth,
                height: activeHeight
            ).intersection(unit)
            let edgeMarginX = max(sampleStep, Int(CGFloat(width) * 0.055))
            let edgeMarginY = max(sampleStep, Int(CGFloat(height) * 0.055))
            touchesEdge = minX <= edgeMarginX
                || maxX >= width - edgeMarginX
                || minY <= edgeMarginY
                || maxY >= height - edgeMarginY
        } else {
            activeWidth = 0
            activeHeight = 0
            activeRect = nil
            touchesEdge = false
        }

        let sortedLuma = values.map(\.value).sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sortedLuma.isEmpty else { return 0 }
            let position = clamp(fraction, 0, 1) * Double(sortedLuma.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            if lower == upper { return sortedLuma[lower] }
            let weight = position - Double(lower)
            return sortedLuma[lower] * (1 - weight) + sortedLuma[upper] * weight
        }

        return LumaMetrics(
            mean: mean,
            standardDeviation: standardDeviation,
            edgeMean: edgeCount > 0 ? edgeSum / Double(edgeCount) : 0,
            lowClipFraction: Double(low) / Double(count),
            highClipFraction: Double(high) / Double(count),
            activeFraction: activeFraction,
            activeWidthFraction: clamp(activeWidth, 0, 1),
            activeHeightFraction: clamp(activeHeight, 0, 1),
            activeRect: activeRect,
            touchesEdge: touchesEdge,
            percentile10: percentile(0.10),
            percentile90: percentile(0.90),
            percentile98: percentile(0.98)
        )
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private static func boundingRect(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return true }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            let crosses = (a.y > point.y) != (b.y > point.y)
            if crosses {
                let denominator = b.y - a.y
                let safeDenominator = abs(denominator) < 0.000_001 ? 0.000_001 : denominator
                let intersectionX = (b.x - a.x) * (point.y - a.y) / safeDenominator + a.x
                if point.x < intersectionX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func rotatedNormalizedPoint(_ point: CGPoint, by degrees: CGFloat) -> CGPoint {
        let normalized = Int((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360).rounded())
        switch normalized {
        case 90:
            return CGPoint(x: point.y, y: 1 - point.x)
        case 180:
            return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270:
            return CGPoint(x: 1 - point.y, y: point.x)
        default:
            return point
        }
    }

    private static func makeLoupe(pixelBuffer: CVPixelBuffer, region: CGRect, magnification: CGFloat) -> (image: UIImage?, zoneRect: CGRect) {
        let factor: CGFloat
        switch magnification {
        case 0..<1.5: factor = 3.0
        case 1.5..<3: factor = 2.0
        case 3..<6: factor = 1.35
        default: factor = 1.08
        }

        let targetWidth = min(1, max(region.width * factor, region.width + 0.004))
        let targetHeight = min(1, max(region.height * factor, region.height + 0.004))
        let centre = CGPoint(x: region.midX, y: region.midY)
        let context = clamped(CGRect(
            x: centre.x - targetWidth / 2,
            y: centre.y - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        ))

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        let crop = CGRect(
            x: extent.minX + context.minX * extent.width,
            y: extent.minY + (1 - context.maxY) * extent.height,
            width: context.width * extent.width,
            height: context.height * extent.height
        ).intersection(extent)
        let cgImage = crop.width > 1 && crop.height > 1
            ? ciContext.createCGImage(ciImage, from: crop)
            : nil
        let image = cgImage.map { UIImage(cgImage: $0, scale: 1, orientation: .up) }
        let zoneRect = CGRect(
            x: (region.minX - context.minX) / context.width,
            y: (region.minY - context.minY) / context.height,
            width: region.width / context.width,
            height: region.height / context.height
        )
        return (image, clamped(zoneRect))
    }

    private static func clamped(_ rect: CGRect) -> CGRect {
        let width = clamp(rect.width, 0.001, 1)
        let height = clamp(rect.height, 0.001, 1)
        let x = clamp(rect.minX, 0, 1 - width)
        let y = clamp(rect.minY, 0, 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }


    private static func rotatedNormalizedRect(_ rect: CGRect, by degrees: CGFloat) -> CGRect {
        let normalized = Int((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360).rounded())
        switch normalized {
        case 90:
            return CGRect(x: rect.minY, y: 1 - rect.minX - rect.width, width: rect.height, height: rect.width)
        case 180:
            return CGRect(x: 1 - rect.minX - rect.width, y: 1 - rect.minY - rect.height, width: rect.width, height: rect.height)
        case 270:
            return CGRect(x: 1 - rect.minY - rect.height, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    private static func normalizedRotation(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result <= -180 { result += 360 }
        return result
    }

    private static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        max(lower, min(upper, value))
    }
}

private struct GuidedCalibrationToolbarButton: View {
    let title: String
    var systemImage: String? = nil
    let tint: Color
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, systemImage == nil ? 9 : 8)
            .frame(height: 26)
            .foregroundStyle(.white)
            .background(tint.opacity(isActive ? 0.40 : 0.18), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(isActive ? 0.95 : 0.58), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }
}

struct GuidedCalibrationAssistantPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject var runtime: CalibrationRuntimeViewModel
    let onNudge: (_ horizontalPixels: CGFloat, _ verticalPixels: CGFloat) -> Void
    let onResize: (_ widthPixels: CGFloat, _ heightPixels: CGFloat) -> Void
    let onApplySuggestedOrientation: () -> Void
    let onResetLocalZoneAngle: () -> Void

    @State private var colourSamplingMessage: String?
    @State private var floatingDragStartOffset: CGSize?
    @State private var isManualColourPicking = false
    @State private var colourPickPoint: CGPoint?

    private var quality: CalibrationQualitySnapshot { runtime.calibrationQuality }
    private var selectedKey: OCRRegionKey { viewModel.selectedRegionKey }
    private var selectedProfile: OCRZoneColourProfile { viewModel.ocrColourProfiles.profile(for: selectedKey) }
    private var zoneLocked: Bool { runtime.isRegionLocked(selectedKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.cyan)
                    Label("Guided Calibration", systemImage: "viewfinder.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                .contentShape(Rectangle())
                .gesture(floatingPanelDragGesture)
                .onTapGesture(count: 2) {
                    runtime.resetGuidedAssistantOffset()
                }
                .accessibilityLabel("Move Guided Calibration panel")
                .accessibilityHint("Drag to move the panel. Double tap to return it to its default position.")

                Spacer()
                Text("\(quality.readinessScore)% \(quality.readinessText)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(readinessColor.opacity(0.28), in: Capsule())
                Button {
                    runtime.setGuidedAssistantVisible(false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }

            Text(selectedKey.likelyTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))

            loupe

            HStack(spacing: 5) {
                Spacer(minLength: 0)
                GuidedCalibrationToolbarButton(
                    title: isManualColourPicking ? "Tap Character" : "Pick Colour",
                    systemImage: "eyedropper.halffull",
                    tint: .purple,
                    isActive: isManualColourPicking,
                    action: {
                        isManualColourPicking.toggle()
                        colourSamplingMessage = isManualColourPicking
                            ? "Tap the centre of an illuminated character stroke in the enlarged image."
                            : nil
                    }
                )
                GuidedCalibrationToolbarButton(
                    title: "Auto",
                    systemImage: "wand.and.stars",
                    tint: .purple,
                    action: {
                        isManualColourPicking = false
                        colourPickPoint = nil
                        colourSamplingMessage = viewModel.autoDetectSelectedZoneCharacterColour()
                        runtime.publishSnapshot(force: false)
                    }
                )
                GuidedCalibrationToolbarButton(
                    title: zoneLocked ? "Locked" : "Lock",
                    systemImage: zoneLocked ? "lock.fill" : "lock.open",
                    tint: zoneLocked ? .orange : .cyan,
                    isActive: zoneLocked,
                    action: { runtime.toggleRegionLock(selectedKey) }
                )
            }

            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(sampledProfileColour)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.white.opacity(0.90), lineWidth: 1.25)
                    if selectedProfile.isColourCalibrated {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(visibleCheckmarkColour)
                            .shadow(color: .black.opacity(0.55), radius: 1)
                    }
                }
                .frame(width: 52, height: 27)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Selected character colour \(selectedProfile.characterColour.title)")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected colour: \(selectedProfile.characterColour.title)")
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                    Text("Background: \(selectedProfile.backgroundColour.title) · \(selectedProfile.pipelineSelectionStatus(for: selectedKey))")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Text(selectedProfile.isColourCalibrated ? "✓ \(selectedProfile.calibrationStatusText)" : "○ Using field default — not sampled")
                        .font(.system(size: 8, weight: selectedProfile.isColourCalibrated ? .semibold : .regular))
                        .foregroundStyle(selectedProfile.isColourCalibrated ? Color.green : Color.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let colourSamplingMessage {
                Text(colourSamplingMessage)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto samples the whole zone and enables automatic pipeline selection. Pick Colour samples one lit stroke and locks the matching pipeline.")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(2)
                    Text("Green dotted box = detected-character evidence only. The cyan/orange zone is the saved OCR and Image Relay crop.")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.86))
                        .lineLimit(2)
                }
            }

            precisionControls
                .disabled(zoneLocked || quality.frameWidth <= 0)
                .opacity(zoneLocked ? 0.45 : 1)

            Divider().overlay(.white.opacity(0.18))

            qualityRow("Focus", score: quality.focusScore, text: quality.focusText)
            qualityRow("Exposure", score: quality.exposureScore, text: quality.exposureText)
            qualityRow("Colour", score: quality.contrastScore, text: quality.contrastText)
            qualityRow("Zone", score: quality.zoneFitScore, text: quality.zoneFitText)

            HStack(spacing: 6) {
                Image(systemName: "rectangle.portrait.rotate")
                Text(quality.orientationText)
                    .lineLimit(1)
                Spacer()
                if abs(viewModel.ocrLayout[selectedKey].rotationDegrees) > 0.15 {
                    Button("Reset local") { onResetLocalZoneAngle() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                } else if quality.suggestedRotationDegrees != nil {
                    Button("Apply") { onApplySuggestedOrientation() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                } else if runtime.cameraRotationLockEnabled {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.system(size: 10, weight: .semibold))

            Text("Zone \(quality.zonePixelWidth)×\(quality.zonePixelHeight) px · character H \(Int((quality.activeHeightFraction * 100).rounded()))% W \(Int((quality.activeWidthFraction * 100).rounded()))% · stable \(quality.stableFrameCount)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
        }
        .padding(12)
        .frame(width: 382, alignment: .leading)
        // Build 675 gives every Guide row one strict content boundary. Long focus,
        // exposure and zone guidance can no longer render to the left of the
        // rounded panel even when Dynamic Type or a compact Stage Manager width is
        // active.
        .clipped()
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.36), radius: 12, x: 0, y: 5)
        .foregroundStyle(.white)
        .offset(x: runtime.guidedAssistantOffsetX, y: runtime.guidedAssistantOffsetY)
        .onAppear {
            runtime.setGuidedAssistantOffset(
                clampedFloatingOffset(runtime.guidedAssistantOffset),
                persist: false
            )
            runtime.refreshGuidedCalibrationAnalysis(reason: "Guide appeared")
        }
        .onChange(of: selectedKey) { _, newKey in
            colourSamplingMessage = nil
            isManualColourPicking = false
            colourPickPoint = nil
            runtime.refreshGuidedCalibrationAnalysis(reason: "selected zone \(newKey.rawValue)")
        }
    }

    private var visibleCheckmarkColour: Color {
        let sampled = selectedProfile.sampledCharacterColour
        let luminance = sampled.map { (0.2126 * $0.red) + (0.7152 * $0.green) + (0.0722 * $0.blue) } ?? 0.5
        return luminance > 0.58 ? .black : .white
    }

    private var sampledProfileColour: Color {
        if let sampled = selectedProfile.sampledCharacterColour {
            return Color(red: sampled.red, green: sampled.green, blue: sampled.blue, opacity: sampled.alpha)
        }
        switch selectedProfile.characterColour {
        case .red: return .red
        case .yellow: return .yellow
        case .white: return .white
        case .amber, .orange: return .orange
        case .green: return .green
        case .blue, .cyan: return .cyan
        case .black, .dark: return .black
        case .auto: return .gray
        }
    }

    private var floatingPanelDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if floatingDragStartOffset == nil {
                    floatingDragStartOffset = runtime.guidedAssistantOffset
                    MainThreadStallMonitor.shared.markContext("guided calibration floating drag began")
                }
                guard let start = floatingDragStartOffset else { return }
                let proposed = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
                runtime.setGuidedAssistantOffset(clampedFloatingOffset(proposed), persist: false)
            }
            .onEnded { _ in
                floatingDragStartOffset = nil
                runtime.setGuidedAssistantOffset(runtime.guidedAssistantOffset, persist: true)
                MainThreadStallMonitor.shared.notePublish(source: "guided calibration floating panel move committed")
            }
    }

    private func clampedFloatingOffset(_ offset: CGSize) -> CGSize {
        // The panel is anchored at the top-right of CalibrationScreen. Keep at least
        // the header visible so a saved position can always be recovered on iPad,
        // Simulator, Stage Manager or after an orientation change.
        let activeWindowBounds = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)?
            .bounds
        let screen = activeWindowBounds ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let minimumVisibleWidth: CGFloat = 150
        let minimumVisibleHeaderHeight: CGFloat = 54
        let minimumX = -max(0, screen.width - minimumVisibleWidth)
        let maximumX: CGFloat = 24
        let minimumY: CGFloat = -64
        let maximumY = max(0, screen.height - minimumVisibleHeaderHeight - 76)
        return CGSize(
            width: max(minimumX, min(maximumX, offset.width)),
            height: max(minimumY, min(maximumY, offset.height))
        )
    }

    private var loupe: some View {
        GeometryReader { proxy in
            let previewBounds = CGRect(
                x: 8,
                y: 5,
                width: max(1, proxy.size.width - 16),
                height: max(1, proxy.size.height - 10)
            )
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black)

                if let image = runtime.selectedZoneLoupeImage {
                    let localFit = aspectFitRect(imageSize: image.size, containerSize: previewBounds.size)
                    let fitted = localFit.offsetBy(dx: previewBounds.minX, dy: previewBounds.minY)
                    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
                    let safeZone = runtime.selectedZoneLoupeZoneRect.standardized.intersection(unit)
                    let rawZoneFrame = CGRect(
                        x: fitted.minX + safeZone.minX * fitted.width,
                        y: fitted.minY + safeZone.minY * fitted.height,
                        width: safeZone.width * fitted.width,
                        height: safeZone.height * fitted.height
                    )
                    let zoneFrame = rawZoneFrame.intersection(fitted)

                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .clipped()

                    // Build 672: show the exact fitted image boundary as well as the
                    // selected OCR crop. Both are inset from the panel edge so neither
                    // the image nor a cyan/green outline can spill off the left side.
                    Rectangle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .allowsHitTesting(false)

                    if zoneFrame.width > 1, zoneFrame.height > 1 {
                        Rectangle()
                            .stroke(
                                zoneLocked ? Color.orange : Color.cyan,
                                style: StrokeStyle(lineWidth: 2, dash: zoneLocked ? [5, 3] : [])
                            )
                            .frame(width: max(2, zoneFrame.width), height: max(2, zoneFrame.height))
                            .position(x: zoneFrame.midX, y: zoneFrame.midY)
                            .allowsHitTesting(false)
                    }

                    if let character = runtime.selectedZoneLoupeCharacterRect,
                       character.width > 0.01,
                       character.height > 0.01 {
                        // The character evidence is measured from the same upright crop
                        // as the preview. Intersect it with the exact cyan zone so no
                        // stale camera-space geometry can appear outside on the left.
                        let safeCharacter = character.standardized.intersection(safeZone).intersection(unit)
                        let proposedCharacterFrame = CGRect(
                            x: fitted.minX + safeCharacter.minX * fitted.width,
                            y: fitted.minY + safeCharacter.minY * fitted.height,
                            width: safeCharacter.width * fitted.width,
                            height: safeCharacter.height * fitted.height
                        )
                        let characterFrame = proposedCharacterFrame.intersection(zoneFrame).intersection(fitted)
                        if characterFrame.width > 1, characterFrame.height > 1 {
                            Rectangle()
                                .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
                                .frame(width: max(2, characterFrame.width), height: max(2, characterFrame.height))
                                .position(x: characterFrame.midX, y: characterFrame.midY)
                                .allowsHitTesting(false)

                            boundaryLabel("TOP")
                                .position(
                                    x: max(zoneFrame.minX + 18, min(zoneFrame.maxX - 18, characterFrame.midX)),
                                    y: max(zoneFrame.minY + 7, min(zoneFrame.maxY - 7, characterFrame.minY + 7))
                                )
                            boundaryLabel("BOTTOM")
                                .position(
                                    x: max(zoneFrame.minX + 25, min(zoneFrame.maxX - 25, characterFrame.midX)),
                                    y: max(zoneFrame.minY + 7, min(zoneFrame.maxY - 7, characterFrame.maxY - 7))
                                )
                            boundaryLabel("WIDTH")
                                .position(x: characterFrame.midX, y: characterFrame.midY)
                        }
                    }

                    if isManualColourPicking {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                    .onChanged { value in
                                        colourPickPoint = normalizedLoupePoint(value.location, in: fitted.size)
                                    }
                                    .onEnded { value in
                                        let point = normalizedLoupePoint(value.location, in: fitted.size)
                                        colourPickPoint = point
                                        colourSamplingMessage = viewModel.manuallySampleSelectedZoneCharacterColour(
                                            from: image,
                                            normalizedPoint: point
                                        )
                                        isManualColourPicking = false
                                        runtime.publishSnapshot(force: false)
                                    }
                            )

                        if let colourPickPoint {
                            ZStack {
                                Circle().stroke(Color.yellow, lineWidth: 2)
                                    .frame(width: 22, height: 22)
                                Rectangle().fill(Color.yellow).frame(width: 26, height: 1)
                                Rectangle().fill(Color.yellow).frame(width: 1, height: 26)
                            }
                            .position(
                                x: fitted.minX + colourPickPoint.x * fitted.width,
                                y: fitted.minY + colourPickPoint.y * fitted.height
                            )
                            .allowsHitTesting(false)
                        }
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }

                if zoneLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .bold))
                        .padding(6)
                        .background(.black.opacity(0.72), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(5)
                }
            }
            .clipped()
        }
        .frame(height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private func boundaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 6, weight: .black))
            .foregroundStyle(.green)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(.black.opacity(0.72), in: Capsule())
            .allowsHitTesting(false)
    }

    private func normalizedLoupePoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(1, location.x / max(1, size.width))),
            y: max(0, min(1, location.y / max(1, size.height)))
        )
    }

    private func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private var precisionControls: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Text("Move")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 34, alignment: .leading)
                precisionButton("arrow.left") { onNudge(-runtime.precisionStepPixels, 0) }
                precisionButton("arrow.up") { onNudge(0, -runtime.precisionStepPixels) }
                precisionButton("arrow.down") { onNudge(0, runtime.precisionStepPixels) }
                precisionButton("arrow.right") { onNudge(runtime.precisionStepPixels, 0) }
                stepButton
            }
            HStack(spacing: 5) {
                Text("Size")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 34, alignment: .leading)
                textPrecisionButton("W−") { onResize(-runtime.precisionStepPixels, 0) }
                textPrecisionButton("W+") { onResize(runtime.precisionStepPixels, 0) }
                textPrecisionButton("H−") { onResize(0, -runtime.precisionStepPixels) }
                textPrecisionButton("H+") { onResize(0, runtime.precisionStepPixels) }
                Spacer(minLength: 0)
            }
        }
    }

    private var stepButton: some View {
        Button("\(Int(runtime.precisionStepPixels))px") {
            runtime.precisionStepPixels = runtime.precisionStepPixels < 4 ? 5 : 1
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func precisionButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func textPrecisionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .buttonStyle(.bordered)
            .controlSize(.mini)
    }

    private func qualityRow(_ title: String, score: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 52, alignment: .leading)
                .layoutPriority(2)
            Text("\(score)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .frame(width: 26, alignment: .trailing)
                .layoutPriority(2)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var readinessColor: Color {
        switch quality.readinessScore {
        case 80...100: return .green
        case 60..<80: return .yellow
        case 35..<60: return .orange
        default: return .red
        }
    }
}

struct GuidedCalibrationAssistantRestoreButton: View {
    @ObservedObject var runtime: CalibrationRuntimeViewModel

    var body: some View {
        Button {
            runtime.setGuidedAssistantVisible(true)
        } label: {
            Label("Guide", systemImage: "viewfinder.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
    }
}
#endif
