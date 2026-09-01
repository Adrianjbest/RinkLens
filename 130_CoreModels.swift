// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

// MARK: - Core Models

nonisolated struct OCRRegion: Hashable, Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// Region-specific OCR correction angle in degrees.
    /// Use this when the scoreboard digits are slightly tilted relative to the camera.
    var rotationDegrees: CGFloat = 0

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    private enum CodingKeys: String, CodingKey {
        case x, y, width, height, rotationDegrees
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rotationDegrees: CGFloat = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(CGFloat.self, forKey: .x)
        y = try container.decode(CGFloat.self, forKey: .y)
        width = try container.decode(CGFloat.self, forKey: .width)
        height = try container.decode(CGFloat.self, forKey: .height)
        rotationDegrees = try container.decodeIfPresent(CGFloat.self, forKey: .rotationDegrees) ?? 0
    }

    /// Build 715 suppresses sub-pixel SwiftUI binding feedback without changing
    /// the authoritative calibrated geometry. At the 1280px rectified-board
    /// ceiling, the default tolerance is below one third of a source pixel.
    nonisolated func isApproximatelyEqual(
        to other: OCRRegion,
        tolerance: CGFloat = 0.0002
    ) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
            && abs(rotationDegrees - other.rotationDegrees) <= 0.01
    }
}

nonisolated struct MirrorSpec: Hashable, Codable {
    var homeKey: OCRRegionKey
    var awayKey: OCRRegionKey
    var lockWidth: Bool = true
    var lockHeight: Bool = true
    var lockY: Bool = true
    var isLinked: Bool = true
}

nonisolated struct BoardCalibrationQuad: Hashable, Codable {
    var topLeft: CGPoint = CGPoint(x: 0.05, y: 0.05)
    var topRight: CGPoint = CGPoint(x: 0.95, y: 0.05)
    var bottomRight: CGPoint = CGPoint(x: 0.95, y: 0.95)
    var bottomLeft: CGPoint = CGPoint(x: 0.05, y: 0.95)

    /// Build 664 coordinate contract. When enabled, every OCR/Image Relay zone is
    /// stored in the rectified scoreboard's unit square and projected through this
    /// four-corner guide for display. Older templates decode as `false`, preserving
    /// Build 663 preview-space geometry until the operator explicitly enables Screen Align.
    var zonesFollowPerspective: Bool = false

    private enum CodingKeys: String, CodingKey {
        case topLeft, topRight, bottomRight, bottomLeft, zonesFollowPerspective
    }

    init(
        topLeft: CGPoint = CGPoint(x: 0.05, y: 0.05),
        topRight: CGPoint = CGPoint(x: 0.95, y: 0.05),
        bottomRight: CGPoint = CGPoint(x: 0.95, y: 0.95),
        bottomLeft: CGPoint = CGPoint(x: 0.05, y: 0.95),
        zonesFollowPerspective: Bool = false
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
        self.zonesFollowPerspective = zonesFollowPerspective
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topLeft = try container.decodeIfPresent(CGPoint.self, forKey: .topLeft) ?? CGPoint(x: 0.05, y: 0.05)
        topRight = try container.decodeIfPresent(CGPoint.self, forKey: .topRight) ?? CGPoint(x: 0.95, y: 0.05)
        bottomRight = try container.decodeIfPresent(CGPoint.self, forKey: .bottomRight) ?? CGPoint(x: 0.95, y: 0.95)
        bottomLeft = try container.decodeIfPresent(CGPoint.self, forKey: .bottomLeft) ?? CGPoint(x: 0.05, y: 0.95)
        zonesFollowPerspective = try container.decodeIfPresent(Bool.self, forKey: .zonesFollowPerspective) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(topLeft, forKey: .topLeft)
        try container.encode(topRight, forKey: .topRight)
        try container.encode(bottomRight, forKey: .bottomRight)
        try container.encode(bottomLeft, forKey: .bottomLeft)
        try container.encode(zonesFollowPerspective, forKey: .zonesFollowPerspective)
    }
}

/// Shared square-to-quadrilateral homography used by Calibration display,
/// template migration, OCR, Image Relay and per-zone colour sampling.
/// Keeping this outside the OCR processor prevents the visible guide from ever
/// becoming a decorative coordinate system that differs from recognition.
nonisolated enum BoardPerspectiveMapper {
    private struct Matrix {
        let m00: Double
        let m01: Double
        let m02: Double
        let m10: Double
        let m11: Double
        let m12: Double
        let m20: Double
        let m21: Double
        let m22: Double

        static func squareToQuad(_ quad: BoardCalibrationQuad) -> Matrix? {
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

            return Matrix(
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

        func inverted() -> Matrix? {
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
            return Matrix(
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
            let outputX = (m00 * x + m01 * y + m02) / denominator
            let outputY = (m10 * x + m11 * y + m12) / denominator
            guard outputX.isFinite, outputY.isFinite else { return nil }
            return CGPoint(x: CGFloat(outputX), y: CGFloat(outputY))
        }
    }

    static func project(_ boardPoint: CGPoint, through quad: BoardCalibrationQuad) -> CGPoint? {
        Matrix.squareToQuad(quad)?.applying(boardPoint)
    }

    static func unproject(_ sourcePoint: CGPoint, through quad: BoardCalibrationQuad) -> CGPoint? {
        Matrix.squareToQuad(quad)?.inverted()?.applying(sourcePoint)
    }

    static func projectedCorners(of boardRect: CGRect, through quad: BoardCalibrationQuad) -> [CGPoint]? {
        let corners = [
            CGPoint(x: boardRect.minX, y: boardRect.minY),
            CGPoint(x: boardRect.maxX, y: boardRect.minY),
            CGPoint(x: boardRect.maxX, y: boardRect.maxY),
            CGPoint(x: boardRect.minX, y: boardRect.maxY)
        ]
        let mapped = corners.compactMap { project($0, through: quad) }
        return mapped.count == 4 ? mapped : nil
    }

    static func projectedBoundingRect(of boardRect: CGRect, through quad: BoardCalibrationQuad) -> CGRect? {
        guard let points = projectedCorners(of: boardRect, through: quad) else { return nil }
        return boundingRect(points)
    }

    static func inverseBoundingRect(of sourceRect: CGRect, through quad: BoardCalibrationQuad) -> CGRect? {
        let corners = [
            CGPoint(x: sourceRect.minX, y: sourceRect.minY),
            CGPoint(x: sourceRect.maxX, y: sourceRect.minY),
            CGPoint(x: sourceRect.maxX, y: sourceRect.maxY),
            CGPoint(x: sourceRect.minX, y: sourceRect.maxY)
        ]
        let mapped = corners.compactMap { unproject($0, through: quad) }
        guard mapped.count == 4 else { return nil }
        return clampedUnitRect(boundingRect(mapped), minimumSize: 0.001)
    }

    static func clampedUnitRect(_ rect: CGRect, minimumSize: CGFloat = 0.001) -> CGRect {
        let safeMinimum = max(0.0001, min(0.25, minimumSize))
        let x = max(0, min(1 - safeMinimum, rect.minX))
        let y = max(0, min(1 - safeMinimum, rect.minY))
        let width = max(safeMinimum, min(1 - x, rect.width))
        let height = max(safeMinimum, min(1 - y, rect.height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func clampedPoint(_ point: CGPoint, margin: CGFloat = 0.005) -> CGPoint {
        let safeMargin = max(0, min(0.2, margin))
        return CGPoint(
            x: max(safeMargin, min(1 - safeMargin, point.x)),
            y: max(safeMargin, min(1 - safeMargin, point.y))
        )
    }

    static func isUsable(_ quad: BoardCalibrationQuad) -> Bool {
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let closedPoints = points + [points[0]]
        var signedArea: CGFloat = 0
        for index in 0..<points.count {
            let current = closedPoints[index]
            let next = closedPoints[index + 1]
            signedArea += current.x * next.y - next.x * current.y
        }
        let area = abs(signedArea) / 2
        guard area > 0.02 else { return false }
        guard quad.topLeft.x < quad.topRight.x,
              quad.bottomLeft.x < quad.bottomRight.x,
              quad.topLeft.y < quad.bottomLeft.y,
              quad.topRight.y < quad.bottomRight.y else { return false }
        return true
    }

    private static func boundingRect(_ points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

nonisolated enum OCRRegionKey: String, CaseIterable, Identifiable, Codable {
    case clock, period, homeScore, awayScore, homeShots, awayShots
    case homePenalty1Player, homePenalty1Time, homePenalty2Player, homePenalty2Time
    case awayPenalty1Player, awayPenalty1Time, awayPenalty2Player, awayPenalty2Time

    var id: String { rawValue }


    /// Build 632 calibration boundary. Calibration geometry is required by both
    /// OCR and Image Relay, so removing OCR authority must never hide a zone.
    /// Shots remain disabled, but Clock and every penalty timer/player pair stay
    /// selectable, persistable and editable as grouped physical regions.
    static var calibrationCases: [OCRRegionKey] {
        [
            .clock,
            .period,
            .homeScore,
            .awayScore,
            .homePenalty1Player,
            .homePenalty1Time,
            .homePenalty2Player,
            .homePenalty2Time,
            .awayPenalty1Player,
            .awayPenalty1Time,
            .awayPenalty2Player,
            .awayPenalty2Time
        ]
    }

    /// Build 632 hard production OCR boundary. Clock movement and penalty timers
    /// remain Image Relay-only. OCR is authorised only for the two scores, Period
    /// and penalty player-number identification.
    static var productionOCRCases: [OCRRegionKey] {
        [
            .homeScore,
            .awayScore,
            .period,
            .homePenalty1Player,
            .homePenalty2Player,
            .awayPenalty1Player,
            .awayPenalty2Player
        ]
    }

    /// Physical crops published or retained by Image Relay. Score crops are
    /// included as OCR-failure fallback; Period remains OCR-rendered but still has
    /// an independently calibrated zone.
    static var imageRelayCases: [OCRRegionKey] {
        [
            .clock,
            .homeScore,
            .awayScore,
            .homePenalty1Player,
            .homePenalty1Time,
            .homePenalty2Player,
            .homePenalty2Time,
            .awayPenalty1Player,
            .awayPenalty1Time,
            .awayPenalty2Player,
            .awayPenalty2Time
        ]
    }

    var isProductionOCRAuthorised: Bool {
        Self.productionOCRCases.contains(self)
    }

    var isShotRegion: Bool {
        self == .homeShots || self == .awayShots
    }


    var likelyTitle: String {
        switch self {
        case .clock: return "Clock"
        case .period: return "Period"
        case .homeScore: return "Home Score"
        case .awayScore: return "Away Score"
        case .homeShots: return "Home Shots"
        case .awayShots: return "Away Shots"
        case .homePenalty1Player: return "Home Penalty 1 Player"
        case .homePenalty1Time: return "Home Penalty 1 Time"
        case .homePenalty2Player: return "Home Penalty 2 Player"
        case .homePenalty2Time: return "Home Penalty 2 Time"
        case .awayPenalty1Player: return "Away Penalty 1 Player"
        case .awayPenalty1Time: return "Away Penalty 1 Time"
        case .awayPenalty2Player: return "Away Penalty 2 Player"
        case .awayPenalty2Time: return "Away Penalty 2 Time"
        }
    }
}



// MARK: - v0.8.0.0 Operator OCR Settings

enum OCRScoreboardType: String, CaseIterable, Identifiable, Codable {
    case ledHighContrast
    case standardIndoor
    case dimNoisy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ledHighContrast: return "LED / High Contrast"
        case .standardIndoor: return "Standard Indoor"
        case .dimNoisy: return "Dim / Noisy"
        }
    }

    var helpText: String {
        switch self {
        case .ledHighContrast:
            return "Use for bright, sharp scoreboards with clear digits. OCR can run quicker with slightly lower confidence."
        case .standardIndoor:
            return "Recommended default for most rinks. Balanced reading speed and stability."
        case .dimNoisy:
            return "Use when the scoreboard is dark, blurry, angled or noisy. OCR becomes more conservative."
        }
    }

    var confidenceAdjustment: Float {
        switch self {
        case .ledHighContrast: return -0.03
        case .standardIndoor: return 0
        case .dimNoisy: return 0.08
        }
    }

    var cadenceMultiplier: Double {
        switch self {
        case .ledHighContrast: return 0.90
        case .standardIndoor: return 1.00
        case .dimNoisy: return 1.20
        }
    }
}

enum OCROperatorMode: String, CaseIterable, Identifiable, Codable {
    case setup
    case match
    case broadcast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .match: return "Match"
        case .broadcast: return "Broadcast"
        }
    }

    var helpText: String {
        switch self {
        case .setup: return "Fastest updates and most diagnostic feedback. Use while aligning zones or troubleshooting."
        case .match: return "Recommended default. Balances speed and stability for normal game operation."
        case .broadcast: return "Most stable output for streaming. Slightly slower, safer public updates."
        }
    }

    var confidenceAdjustment: Float {
        switch self {
        case .setup: return -0.05
        case .match: return 0
        case .broadcast: return 0.05
        }
    }

    var cadenceMultiplier: Double {
        switch self {
        case .setup: return 0.75
        case .match: return 1.00
        case .broadcast: return 1.25
        }
    }
}

enum OCRZoneReadingPreset: String, CaseIterable, Identifiable, Codable {
    case responsive
    case balanced
    case stable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .responsive: return "Responsive"
        case .balanced: return "Balanced"
        case .stable: return "Stable"
        }
    }

    var helpText: String {
        switch self {
        case .responsive: return "Quickest updates. Use during setup or where values are very clear."
        case .balanced: return "Recommended. Good speed without making the public overlay too jumpy."
        case .stable: return "Safest. Slower updates, fewer false changes."
        }
    }
}

struct OCRZoneTuning: Equatable {
    var cadenceSeconds: Double
    var confidence: Float
    var trust: Int
}

struct OCROperatorTuningSnapshot: Equatable {
    var clock: OCRZoneTuning
    var score: OCRZoneTuning
    var period: OCRZoneTuning
    var penaltyTime: OCRZoneTuning
    var penaltyPlayer: OCRZoneTuning
}

nonisolated struct ScoreboardOCRLayout: Codable, Hashable {
    var clock = OCRRegion(x: 0.39, y: 0.03, width: 0.22, height: 0.13)
    var period = OCRRegion(x: 0.46, y: 0.21, width: 0.08, height: 0.07)
    var homeScore = OCRRegion(x: 0.115, y: 0.155, width: 0.14, height: 0.11)
    var awayScore = OCRRegion(x: 0.745, y: 0.155, width: 0.14, height: 0.11)

    var homePenalty1Player = OCRRegion(x: 0.06, y: 0.43, width: 0.09, height: 0.10)
    var homePenalty1Time = OCRRegion(x: 0.16, y: 0.43, width: 0.17, height: 0.10)
    var homePenalty2Player = OCRRegion(x: 0.06, y: 0.62, width: 0.09, height: 0.10)
    var homePenalty2Time = OCRRegion(x: 0.16, y: 0.62, width: 0.17, height: 0.10)

    var awayPenalty1Player = OCRRegion(x: 0.67, y: 0.43, width: 0.09, height: 0.10)
    var awayPenalty1Time = OCRRegion(x: 0.77, y: 0.43, width: 0.17, height: 0.10)
    var awayPenalty2Player = OCRRegion(x: 0.67, y: 0.62, width: 0.09, height: 0.10)
    var awayPenalty2Time = OCRRegion(x: 0.77, y: 0.62, width: 0.17, height: 0.10)

    var homeShots = OCRRegion(x: 0.52, y: 0.52, width: 0.08, height: 0.11)
    var awayShots = OCRRegion(x: 0.40, y: 0.52, width: 0.08, height: 0.11)
    // Mirroring is disabled. Each OCR region is calibrated independently.
    // These properties remain for backwards-compatible template decoding only.
    var mirrorAxisX: CGFloat = 0.5
    var mirrorSpecs: [MirrorSpec] = []

    private mutating func setRegion(for key: OCRRegionKey, value: OCRRegion) {
        switch key {
        case .clock: clock = value
        case .period: period = value
        case .homeScore: homeScore = value
        case .awayScore: awayScore = value
        case .homeShots: homeShots = value
        case .awayShots: awayShots = value
        case .homePenalty1Player: homePenalty1Player = value
        case .homePenalty1Time: homePenalty1Time = value
        case .homePenalty2Player: homePenalty2Player = value
        case .homePenalty2Time: homePenalty2Time = value
        case .awayPenalty1Player: awayPenalty1Player = value
        case .awayPenalty1Time: awayPenalty1Time = value
        case .awayPenalty2Player: awayPenalty2Player = value
        case .awayPenalty2Time: awayPenalty2Time = value
        }
    }

    private func mirroredRegion(from source: OCRRegion, spec: MirrorSpec) -> OCRRegion {
        let mirroredX = (2 * mirrorAxisX) - source.x - source.width
        let base = self[spec.awayKey]
        return OCRRegion(
            x: clamp(mirroredX, min: 0, max: 1 - (spec.lockWidth ? source.width : base.width)),
            y: spec.lockY ? source.y : base.y,
            width: spec.lockWidth ? source.width : base.width,
            height: spec.lockHeight ? source.height : base.height
        )
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    mutating func setMirrorLinked(_ linked: Bool, for key: OCRRegionKey) {
        // Mirroring is intentionally disabled. Keep this as a no-op for older code/templates.
        _ = linked
        _ = key
    }

    func isApproximatelyEqual(
        to other: ScoreboardOCRLayout,
        tolerance: CGFloat = 0.0002
    ) -> Bool {
        OCRRegionKey.calibrationCases.allSatisfy {
            self[$0].isApproximatelyEqual(to: other[$0], tolerance: tolerance)
        }
    }

    subscript(_ key: OCRRegionKey) -> OCRRegion {
        get {
            switch key {
            case .clock: return clock
            case .period: return period
            case .homeScore: return homeScore
            case .awayScore: return awayScore
            case .homeShots: return homeShots
            case .awayShots: return awayShots
            case .homePenalty1Player: return homePenalty1Player
            case .homePenalty1Time: return homePenalty1Time
            case .homePenalty2Player: return homePenalty2Player
            case .homePenalty2Time: return homePenalty2Time
            case .awayPenalty1Player: return awayPenalty1Player
            case .awayPenalty1Time: return awayPenalty1Time
            case .awayPenalty2Player: return awayPenalty2Player
            case .awayPenalty2Time: return awayPenalty2Time
            }
        }
        set {
            // Automatic mirroring removed: changing one OCR region no longer moves another.
            setRegion(for: key, value: newValue)
        }
    }
}


// MARK: - UX16b Per-Rink Scoreboard Template Persistence

struct RinkScoreboardTemplateField: Codable, Hashable {
    var key: OCRRegionKey
    var fieldRegion: OCRRegion
    /// Character-slot rectangles are normalised inside fieldRegion, not absolute screen space.
    /// This lets a saved rink/profile keep stable digit cells even if the outer zone is moved.
    var characterSlots: [OCRRegion]
    var colourProfile: OCRZoneColourProfile
    var validationRule: String
}

struct RinkScoreboardTemplate: Codable, Hashable {
    var version: Int = 2
    var enabled: Bool = true
    var createdAt: Date = .now
    var modifiedAt: Date = .now
    var source: String = "UX16b-generated-from-calibration-layout"
    var fields: [RinkScoreboardTemplateField] = []

    init(
        version: Int = 2,
        enabled: Bool = true,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        source: String = "UX16b-generated-from-calibration-layout",
        fields: [RinkScoreboardTemplateField] = []
    ) {
        self.version = version
        self.enabled = enabled
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.source = source
        self.fields = fields
    }

    init(layout: ScoreboardOCRLayout, colourProfiles: OCRColourProfileSet, existingCreatedAt: Date? = nil) {
        self.version = 2
        self.enabled = true
        self.createdAt = existingCreatedAt ?? .now
        self.modifiedAt = .now
        self.source = "UX16b-generated-from-calibration-layout"
        self.fields = OCRRegionKey.calibrationCases.map { key in
            RinkScoreboardTemplateField(
                key: key,
                fieldRegion: layout[key],
                characterSlots: RinkScoreboardTemplate.defaultCharacterSlots(for: key),
                colourProfile: colourProfiles[key],
                validationRule: RinkScoreboardTemplate.validationRule(for: key)
            )
        }
    }

    static func validationRule(for key: OCRRegionKey) -> String {
        switch key {
        case .clock: return "clock MM:SS preferred, M:SS only when one minute digit is detected"
        case .homeScore, .awayScore: return "score 0-99"
        case .period: return "period 1-9"
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player: return "player number 1-99"
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time: return "penalty timer M:SS"
        case .homeShots, .awayShots: return "shots disabled"
        }
    }

    static func defaultCharacterSlots(for key: OCRRegionKey) -> [OCRRegion] {
        switch key {
        case .clock:
            // UX16d2g v2: fixed [M][M][:][S][S] cells measured from the real
            // calibrated scoreboard crop. MM:SS is structural and may not fall
            // back to a three-digit guess when one cell is uncertain.
            return [
                OCRRegion(x: 0.18, y: 0.24, width: 0.14, height: 0.62),
                OCRRegion(x: 0.32, y: 0.24, width: 0.15, height: 0.62),
                OCRRegion(x: 0.48, y: 0.24, width: 0.10, height: 0.62),
                OCRRegion(x: 0.59, y: 0.24, width: 0.17, height: 0.62),
                OCRRegion(x: 0.74, y: 0.24, width: 0.17, height: 0.62)
            ]
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return [
                OCRRegion(x: 0.09, y: 0.18, width: 0.18, height: 0.68),
                OCRRegion(x: 0.30, y: 0.18, width: 0.12, height: 0.68),
                OCRRegion(x: 0.44, y: 0.18, width: 0.20, height: 0.68),
                OCRRegion(x: 0.64, y: 0.18, width: 0.20, height: 0.68)
            ]
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return [
                OCRRegion(x: 0.20, y: 0.14, width: 0.36, height: 0.74),
                OCRRegion(x: 0.56, y: 0.14, width: 0.36, height: 0.74)
            ]
        case .homeScore, .awayScore:
            return [OCRRegion(x: 0.28, y: 0.22, width: 0.44, height: 0.62)]
        case .period:
            return [OCRRegion(x: 0.28, y: 0.20, width: 0.44, height: 0.64)]
        case .homeShots, .awayShots:
            return []
        }
    }

    func field(for key: OCRRegionKey) -> RinkScoreboardTemplateField? {
        fields.first(where: { $0.key == key })
    }

    /// Version-1 templates stored generated placeholder slots that were never
    /// calibrated against the real field crops. Migrate those generated templates
    /// in memory to the v2 slot contract; explicit future slot edits remain intact.
    func effectiveCharacterSlots(for key: OCRRegionKey) -> [OCRRegion] {
        guard let field = field(for: key) else {
            return Self.defaultCharacterSlots(for: key)
        }
        if version < 2, source.contains("generated-from-calibration-layout") {
            return Self.defaultCharacterSlots(for: key)
        }
        return field.characterSlots.isEmpty ? Self.defaultCharacterSlots(for: key) : field.characterSlots
    }

    var summary: String {
        "scoreboardTemplate v\(version) enabled=\(enabled) fields=\(fields.count) source=\(source)"
    }
}

nonisolated struct ScoreboardState: Equatable {
    var homeTeam: String?
    var awayTeam: String?
    var homeScore: Int?
    var awayScore: Int?
    var clock: String?
    var period: Int?
    // v0.7.7.6: Keep the OCR/manual period token as text so OT and SO can be
    // displayed without being collapsed into numeric period 4/5. The numeric
    // period remains for legacy code and event metadata.
    var periodLabel: String?
    var homeShots: Int?
    var awayShots: Int?

    var homePenalty1Player: Int?
    var homePenalty1Clock: String?
    var homePenalty2Player: Int?
    var homePenalty2Clock: String?

    var awayPenalty1Player: Int?
    var awayPenalty1Clock: String?
    var awayPenalty2Player: Int?
    var awayPenalty2Clock: String?

    var periodDisplay: String { "PERIOD \(periodLabel ?? period.map { String($0) } ?? "-")" }
    var shotsDisplay: String { "\(awayShots.map { String($0) } ?? "--")   \(homeShots.map { String($0) } ?? "--")" }
}

struct OCRThresholds: Equatable {
    var clock: Float = 0.35
    var score: Float = 0.45
    var period: Float = 0.50
    var shots: Float = 0.45
    var penaltyPlayer: Float = 0.40
    var penaltyTime: Float = 0.40
}

enum OCRFieldKind: String, Codable {
    case clock, period, score, shots, penaltyPlayer, penaltyTime
}


// MARK: - UX14t Per-Rink OCR Colour Profiles

nonisolated enum OCRCharacterColour: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto, red, yellow, white, amber, orange, green, blue, cyan, black, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .white: return "White"
        case .amber: return "Amber"
        case .orange: return "Orange"
        case .green: return "Green"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .black: return "Black/Dark"
        case .dark: return "Dark"
        }
    }
}

nonisolated enum OCRBackgroundColour: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto, black, dark, darkBlue, grey, white, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .black: return "Black"
        case .dark: return "Dark"
        case .darkBlue: return "Dark Blue"
        case .grey: return "Grey"
        case .white: return "White"
        case .light: return "Light"
        }
    }

    var isLight: Bool {
        switch self {
        case .white, .light: return true
        default: return false
        }
    }
}

nonisolated enum OCRColourPipeline: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto
    case redOnBlack
    case yellowWhiteOnBlack
    case amberOrangeOnBlack
    case greenOnBlack
    case blueCyanOnBlack
    case lightOnDark
    case darkOnLight
    case greyscale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .redOnBlack: return "Red on Black"
        case .yellowWhiteOnBlack: return "Yellow/White on Black"
        case .amberOrangeOnBlack: return "Amber/Orange on Black"
        case .greenOnBlack: return "Green on Black"
        case .blueCyanOnBlack: return "Blue/Cyan on Black"
        case .lightOnDark: return "Light on Dark"
        case .darkOnLight: return "Dark on Light"
        case .greyscale: return "Greyscale"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "Auto"
        case .redOnBlack: return "Red"
        case .yellowWhiteOnBlack: return "Yellow/White"
        case .amberOrangeOnBlack: return "Amber"
        case .greenOnBlack: return "Green"
        case .blueCyanOnBlack: return "Blue/Cyan"
        case .lightOnDark: return "Light/Dark"
        case .darkOnLight: return "Dark/Light"
        case .greyscale: return "Grey"
        }
    }

    var helpText: String {
        switch self {
        case .auto:
            return "Uses the saved character/background colours and the selected zone group to choose a stable OCR enhancement path."
        case .redOnBlack:
            return "Isolates red LED digits on a black/dark background. Use for red scores and red penalty timers."
        case .yellowWhiteOnBlack:
            return "Boosts yellow or white digits on a black/dark background. Use for most clocks and period digits."
        case .amberOrangeOnBlack:
            return "Boosts amber/orange LED digits that sit between red and yellow."
        case .greenOnBlack:
            return "Isolates green LED digits on a black/dark background."
        case .blueCyanOnBlack:
            return "Isolates blue or cyan display text on a black/dark background."
        case .lightOnDark:
            return "Generic high-contrast path for any light text on a dark background."
        case .darkOnLight:
            return "Inverted path for dark text on light/white backgrounds."
        case .greyscale:
            return "Legacy greyscale contrast and threshold pipeline."
        }
    }
}

nonisolated struct OCRSampledColour: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var hexText: String {
        let r = Int(max(0, min(1, red)) * 255.0 + 0.5)
        let g = Int(max(0, min(1, green)) * 255.0 + 0.5)
        let b = Int(max(0, min(1, blue)) * 255.0 + 0.5)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

nonisolated enum OCRColourCalibrationSource: String, Codable, Hashable {
    case automatic
    case manual

    var title: String {
        switch self {
        case .automatic: return "Auto detected"
        case .manual: return "Manually sampled"
        }
    }
}

nonisolated struct OCRZoneColourProfile: Codable, Hashable {
    var characterColour: OCRCharacterColour = .auto
    var backgroundColour: OCRBackgroundColour = .black
    var pipeline: OCRColourPipeline = .auto
    var allowAutoDetect: Bool = true
    var cropPaddingPercent: Double = 0.06
    // Optional for backwards-compatible decoding of Build 669 and older rink templates.
    var sampledCharacterColour: OCRSampledColour? = nil
    var calibrationSource: OCRColourCalibrationSource? = nil

    static func defaultProfile(for key: OCRRegionKey) -> OCRZoneColourProfile {
        switch key {
        case .clock, .period:
            return OCRZoneColourProfile(characterColour: .yellow, backgroundColour: .black, pipeline: .yellowWhiteOnBlack, allowAutoDetect: true, cropPaddingPercent: 0.06)
        case .homeScore, .awayScore:
            return OCRZoneColourProfile(characterColour: .red, backgroundColour: .black, pipeline: .redOnBlack, allowAutoDetect: true, cropPaddingPercent: 0.08)
        case .homePenalty1Time, .homePenalty2Time, .awayPenalty1Time, .awayPenalty2Time:
            return OCRZoneColourProfile(characterColour: .red, backgroundColour: .black, pipeline: .redOnBlack, allowAutoDetect: true, cropPaddingPercent: 0.08)
        case .homePenalty1Player, .homePenalty2Player, .awayPenalty1Player, .awayPenalty2Player:
            return OCRZoneColourProfile(characterColour: .yellow, backgroundColour: .black, pipeline: .yellowWhiteOnBlack, allowAutoDetect: true, cropPaddingPercent: 0.06)
        case .homeShots, .awayShots:
            return OCRZoneColourProfile(characterColour: .white, backgroundColour: .black, pipeline: .lightOnDark, allowAutoDetect: true, cropPaddingPercent: 0.06)
        }
    }

    /// `allowAutoDetect` is retained in the persisted schema for backwards
    /// compatibility. From Build 735 it is the authoritative per-zone switch for
    /// automatic pipeline selection; it does not start continuous colour sampling.
    var usesAutomaticPipelineSelection: Bool {
        allowAutoDetect || pipeline == .auto
    }

    func resolvedPipeline(for key: OCRRegionKey) -> OCRColourPipeline {
        guard usesAutomaticPipelineSelection else { return pipeline }
        if backgroundColour.isLight { return .darkOnLight }
        switch characterColour {
        case .red:
            return .redOnBlack
        case .yellow, .white:
            return .yellowWhiteOnBlack
        case .amber, .orange:
            return .amberOrangeOnBlack
        case .green:
            return .greenOnBlack
        case .blue, .cyan:
            return .blueCyanOnBlack
        case .black, .dark:
            return .darkOnLight
        case .auto:
            let fieldDefault = OCRZoneColourProfile.defaultProfile(for: key).pipeline
            return fieldDefault == .auto ? .greyscale : fieldDefault
        }
    }

    mutating func setAutomaticPipelineSelection(_ enabled: Bool, for key: OCRRegionKey) {
        if enabled {
            allowAutoDetect = true
            pipeline = .auto
        } else {
            let fixedPipeline = resolvedPipeline(for: key)
            allowAutoDetect = false
            pipeline = fixedPipeline == .auto ? .greyscale : fixedPipeline
        }
    }

    mutating func setPipelineSelection(_ selectedPipeline: OCRColourPipeline, for key: OCRRegionKey) {
        if selectedPipeline == .auto {
            setAutomaticPipelineSelection(true, for: key)
        } else {
            allowAutoDetect = false
            pipeline = selectedPipeline
        }
    }

    func pipelineSelectionStatus(for key: OCRRegionKey) -> String {
        let resolved = resolvedPipeline(for: key)
        return usesAutomaticPipelineSelection
            ? "Auto → \(resolved.title)"
            : "Fixed → \(resolved.title)"
    }

    var isColourCalibrated: Bool {
        calibrationSource != nil
    }

    var calibrationStatusText: String {
        guard let calibrationSource else { return "Default" }
        return calibrationSource.title
    }

    var summaryText: String {
        let pipelineMode = usesAutomaticPipelineSelection ? "Auto" : pipeline.title
        return "\(characterColour.title) on \(backgroundColour.title) · \(pipelineMode) · padding \(Int((cropPaddingPercent * 100).rounded()))%"
    }
}

nonisolated struct OCRColourProfileSet: Codable, Hashable {
    var profilesByRegionRawValue: [String: OCRZoneColourProfile] = [:]

    static var defaults: OCRColourProfileSet {
        var set = OCRColourProfileSet()
        for key in OCRRegionKey.allCases {
            set[key] = OCRZoneColourProfile.defaultProfile(for: key)
        }
        return set
    }

    subscript(_ key: OCRRegionKey) -> OCRZoneColourProfile {
        get { profilesByRegionRawValue[key.rawValue] ?? OCRZoneColourProfile.defaultProfile(for: key) }
        set { profilesByRegionRawValue[key.rawValue] = newValue }
    }

    func profile(for key: OCRRegionKey) -> OCRZoneColourProfile { self[key] }

    var compactSummary: String {
        let clock = self[.clock].resolvedPipeline(for: .clock).shortTitle
        let score = self[.homeScore].resolvedPipeline(for: .homeScore).shortTitle
        let penaltyTime = self[.homePenalty1Time].resolvedPipeline(for: .homePenalty1Time).shortTitle
        let penaltyPlayer = self[.homePenalty1Player].resolvedPipeline(for: .homePenalty1Player).shortTitle
        return "clock=\(clock); score=\(score); penaltyTime=\(penaltyTime); penaltyPlayer=\(penaltyPlayer)"
    }
}

enum GameClockDirection: String, CaseIterable, Identifiable, Codable, Hashable {
    case auto
    case countUp
    case countDown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .countUp: return "Count Up"
        case .countDown: return "Count Down"
        }
    }

    var helpText: String {
        switch self {
        case .auto:
            return "Auto detects whether the game clock is counting up or down from repeated valid OCR readings."
        case .countUp:
            return "Use when the game clock increases during the period, for example 00:00 to 20:00."
        case .countDown:
            return "Use when the game clock decreases during warm-up or game play, for example 20:00 to 00:00."
        }
    }
}

enum RecognitionStrategy: String, Codable {
    case none
    case vision
    case mlKit
    case segmented
    case templateDigits
}


struct OCRDiagnosticDisplayOptions: Equatable, Codable {
    var showOCRBoxes: Bool = true
    var showOCRRawValues: Bool = true
    var showOCRConfidence: Bool = true
    var showRecogniserColours: Bool = true
    var showAcceptedValues: Bool = true
}

struct OCRRecognitionPlan: Codable, Hashable {
    var strategies: [RecognitionStrategy]

    init(strategies: [RecognitionStrategy]) {
        self.strategies = strategies
    }

    init(primary: RecognitionStrategy, secondary: RecognitionStrategy? = nil) {
        self.strategies = [primary] + (secondary.map { [$0] } ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case strategies
        case primary
        case secondary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try container.decodeIfPresent([RecognitionStrategy].self, forKey: .strategies), !decoded.isEmpty {
            strategies = decoded
            return
        }
        let primary = try container.decode(RecognitionStrategy.self, forKey: .primary)
        let secondary = try container.decodeIfPresent(RecognitionStrategy.self, forKey: .secondary)
        strategies = [primary] + (secondary.map { [$0] } ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(strategies, forKey: .strategies)
    }
}

struct DefaultScoreboardValues: Codable, Hashable {
    var clock: String = "20:00"
    var homeGoals: Int = 0
    var awayGoals: Int = 0
    var period: Int = 1
    var periodOption: String = "1"
    var homePenalty1Player: Int = 0
    var homePenalty1Clock: String = "--:--"
    var homePenalty2Player: Int = 0
    var homePenalty2Clock: String = "--:--"
    var awayPenalty1Player: Int = 0
    var awayPenalty1Clock: String = "--:--"
    var awayPenalty2Player: Int = 0
    var awayPenalty2Clock: String = "--:--"

    private enum CodingKeys: String, CodingKey {
        case clock, homeGoals, awayGoals, period, periodOption
        case homePenalty1Player, homePenalty1Clock, homePenalty2Player, homePenalty2Clock
        case awayPenalty1Player, awayPenalty1Clock, awayPenalty2Player, awayPenalty2Clock
    }

    init() {}

    init(
        clock: String = "20:00",
        homeGoals: Int = 0,
        awayGoals: Int = 0,
        period: Int = 1,
        periodOption: String = "1",
        homePenalty1Player: Int = 0,
        homePenalty1Clock: String = "--:--",
        homePenalty2Player: Int = 0,
        homePenalty2Clock: String = "--:--",
        awayPenalty1Player: Int = 0,
        awayPenalty1Clock: String = "--:--",
        awayPenalty2Player: Int = 0,
        awayPenalty2Clock: String = "--:--"
    ) {
        self.clock = clock
        self.homeGoals = homeGoals
        self.awayGoals = awayGoals
        self.period = period
        self.periodOption = periodOption
        self.homePenalty1Player = homePenalty1Player
        self.homePenalty1Clock = homePenalty1Clock
        self.homePenalty2Player = homePenalty2Player
        self.homePenalty2Clock = homePenalty2Clock
        self.awayPenalty1Player = awayPenalty1Player
        self.awayPenalty1Clock = awayPenalty1Clock
        self.awayPenalty2Player = awayPenalty2Player
        self.awayPenalty2Clock = awayPenalty2Clock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clock = try c.decodeIfPresent(String.self, forKey: .clock) ?? "20:00"
        homeGoals = try c.decodeIfPresent(Int.self, forKey: .homeGoals) ?? 0
        awayGoals = try c.decodeIfPresent(Int.self, forKey: .awayGoals) ?? 0
        period = try c.decodeIfPresent(Int.self, forKey: .period) ?? 1
        periodOption = try c.decodeIfPresent(String.self, forKey: .periodOption) ?? String(period)
        homePenalty1Player = try c.decodeIfPresent(Int.self, forKey: .homePenalty1Player) ?? 0
        homePenalty1Clock = try c.decodeIfPresent(String.self, forKey: .homePenalty1Clock) ?? "--:--"
        homePenalty2Player = try c.decodeIfPresent(Int.self, forKey: .homePenalty2Player) ?? 0
        homePenalty2Clock = try c.decodeIfPresent(String.self, forKey: .homePenalty2Clock) ?? "--:--"
        awayPenalty1Player = try c.decodeIfPresent(Int.self, forKey: .awayPenalty1Player) ?? 0
        awayPenalty1Clock = try c.decodeIfPresent(String.self, forKey: .awayPenalty1Clock) ?? "--:--"
        awayPenalty2Player = try c.decodeIfPresent(Int.self, forKey: .awayPenalty2Player) ?? 0
        awayPenalty2Clock = try c.decodeIfPresent(String.self, forKey: .awayPenalty2Clock) ?? "--:--"
    }
}

struct AcceptedOCRValueState: Hashable, Codable {
    var acceptedText: String?
    var lastConfidence: Float = 0
    var recognizerUsed: RecognitionStrategy = .vision
    var lastUpdated: Date?
}

struct TeamIdentityTemplate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var homeTeamName: String
    var awayTeamName: String
    var homeLogoFileName: String?
    var awayLogoFileName: String?
    /// Optional scoreboard appearance saved with the team profile.
    /// This lets a club/profile restore its preferred scoreboard look and feel
    /// at the same time as its names and logos.
    var scoreboardSettings: BroadcastScoreboardTemplateSettings?
    var createdAt: Date = .now

    /// Returns the complete persisted profile value for one operator save.
    /// The caller submits intent; `RinkLensTeamIdentityStore` remains the sole
    /// mutable owner that commits the returned value to its catalogue.
    func updatingCurrentProfile(
        title: String,
        homeTeamName: String,
        awayTeamName: String,
        homeLogoFileName: String?,
        awayLogoFileName: String?,
        scoreboardSettings: BroadcastScoreboardTemplateSettings?
    ) -> TeamIdentityTemplate {
        var updated = self
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHome = homeTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAway = awayTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmedTitle.isEmpty
            ? "\(trimmedHome) vs \(trimmedAway)"
            : trimmedTitle
        updated.homeTeamName = homeTeamName
        updated.awayTeamName = awayTeamName
        updated.homeLogoFileName = homeLogoFileName
        updated.awayLogoFileName = awayLogoFileName
        updated.scoreboardSettings = scoreboardSettings
        return updated
    }
}


// MARK: - v0.9.1m Calibration Camera Profile

enum CalibrationCameraProfileMode: String, CaseIterable, Identifiable, Codable, Hashable {
    case matchBroadcast = "matchBroadcast"
    case manual = "manual"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchBroadcast: return "Match Broadcast View Settings"
        case .manual: return "Manual Calibration Settings"
        }
    }

    var shortTitle: String {
        switch self {
        case .matchBroadcast: return "Match Broadcast"
        case .manual: return "Manual"
        }
    }

    var helpText: String {
        switch self {
        case .matchBroadcast:
            return "Calibration mirrors the Broadcast camera source, zoom, resolution and FPS where the device allows it. Manual controls are read-only."
        case .manual:
            return "Calibration uses its own locked OCR camera profile so the scoreboard image stays stable while zones are edited and tested."
        }
    }
}

enum CalibrationCameraSourceKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case builtInBack = "builtInBack"
    case builtInFront = "builtInFront"
    case external = "external"
    case unknown = "unknown"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtInBack: return "Built-in Back Camera"
        case .builtInFront: return "Built-in Front Camera"
        case .external: return "External Camera"
        case .unknown: return "Unknown Camera"
        }
    }
}

struct CalibrationCameraProfile: Codable, Hashable {
    var selectedCameraSourceID: String?
    var selectedCameraSourceKind: CalibrationCameraSourceKind = .builtInBack
    var profileMode: CalibrationCameraProfileMode = .manual
    var manualCalibrationModeEnabled: Bool = true

    var lockedZoomValue: Double = 1.0
    var zoomLocked: Bool = true
    var focusValue: Double = 0.5
    var focusLocked: Bool = true
    var exposureISOValue: Double?
    var exposureDurationSeconds: Double?
    var exposureBiasValue: Double?
    var exposureLocked: Bool = true
    var whiteBalanceTemperatureValue: Double?
    var whiteBalanceTintValue: Double?
    var whiteBalanceLocked: Bool = true
    var isoLocked: Bool = false
    var shutterSpeedLocked: Bool = false

    var resolutionFormatID: String?
    var frameRate: Int?
    var frameDurationValue: Int64?
    var frameDurationTimescale: Int32?

    var exactCaptureCadence: RinkLensCaptureCadence? {
        if let value = frameDurationValue, let timescale = frameDurationTimescale {
            return RinkLensCaptureCadence(durationValue: value, durationTimescale: timescale)
        }
        return frameRate.map { RinkLensCaptureCadence(integerFPS: $0) }
    }

    mutating func setExactCaptureCadence(_ cadence: RinkLensCaptureCadence?) {
        frameRate = cadence?.nominalFPS
        frameDurationValue = cadence?.durationValue
        frameDurationTimescale = cadence?.durationTimescale
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case selectedCameraSourceID, selectedCameraSourceKind, profileMode, manualCalibrationModeEnabled
        case lockedZoomValue, zoomLocked, focusValue, focusLocked
        case exposureISOValue, exposureDurationSeconds, exposureBiasValue, exposureLocked
        case whiteBalanceTemperatureValue, whiteBalanceTintValue, whiteBalanceLocked
        case isoLocked, shutterSpeedLocked, resolutionFormatID, frameRate
        case frameDurationValue, frameDurationTimescale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedCameraSourceID = try container.decodeIfPresent(String.self, forKey: .selectedCameraSourceID)
        selectedCameraSourceKind = try container.decodeIfPresent(CalibrationCameraSourceKind.self, forKey: .selectedCameraSourceKind) ?? .builtInBack
        profileMode = try container.decodeIfPresent(CalibrationCameraProfileMode.self, forKey: .profileMode) ?? .manual
        manualCalibrationModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .manualCalibrationModeEnabled) ?? (profileMode == .manual)
        lockedZoomValue = try container.decodeIfPresent(Double.self, forKey: .lockedZoomValue) ?? 1.0
        zoomLocked = try container.decodeIfPresent(Bool.self, forKey: .zoomLocked) ?? true
        focusValue = try container.decodeIfPresent(Double.self, forKey: .focusValue) ?? 0.5
        focusLocked = try container.decodeIfPresent(Bool.self, forKey: .focusLocked) ?? true
        exposureISOValue = try container.decodeIfPresent(Double.self, forKey: .exposureISOValue)
        exposureDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .exposureDurationSeconds)
        exposureBiasValue = try container.decodeIfPresent(Double.self, forKey: .exposureBiasValue)
        exposureLocked = try container.decodeIfPresent(Bool.self, forKey: .exposureLocked) ?? true
        whiteBalanceTemperatureValue = try container.decodeIfPresent(Double.self, forKey: .whiteBalanceTemperatureValue)
        whiteBalanceTintValue = try container.decodeIfPresent(Double.self, forKey: .whiteBalanceTintValue)
        whiteBalanceLocked = try container.decodeIfPresent(Bool.self, forKey: .whiteBalanceLocked) ?? true
        isoLocked = try container.decodeIfPresent(Bool.self, forKey: .isoLocked) ?? false
        shutterSpeedLocked = try container.decodeIfPresent(Bool.self, forKey: .shutterSpeedLocked) ?? false
        resolutionFormatID = try container.decodeIfPresent(String.self, forKey: .resolutionFormatID)
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate)
        frameDurationValue = try container.decodeIfPresent(Int64.self, forKey: .frameDurationValue)
        frameDurationTimescale = try container.decodeIfPresent(Int32.self, forKey: .frameDurationTimescale)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedCameraSourceID, forKey: .selectedCameraSourceID)
        try container.encode(selectedCameraSourceKind, forKey: .selectedCameraSourceKind)
        try container.encode(profileMode, forKey: .profileMode)
        try container.encode(manualCalibrationModeEnabled, forKey: .manualCalibrationModeEnabled)
        try container.encode(lockedZoomValue, forKey: .lockedZoomValue)
        try container.encode(zoomLocked, forKey: .zoomLocked)
        try container.encode(focusValue, forKey: .focusValue)
        try container.encode(focusLocked, forKey: .focusLocked)
        try container.encodeIfPresent(exposureISOValue, forKey: .exposureISOValue)
        try container.encodeIfPresent(exposureDurationSeconds, forKey: .exposureDurationSeconds)
        try container.encodeIfPresent(exposureBiasValue, forKey: .exposureBiasValue)
        try container.encode(exposureLocked, forKey: .exposureLocked)
        try container.encodeIfPresent(whiteBalanceTemperatureValue, forKey: .whiteBalanceTemperatureValue)
        try container.encodeIfPresent(whiteBalanceTintValue, forKey: .whiteBalanceTintValue)
        try container.encode(whiteBalanceLocked, forKey: .whiteBalanceLocked)
        try container.encode(isoLocked, forKey: .isoLocked)
        try container.encode(shutterSpeedLocked, forKey: .shutterSpeedLocked)
        try container.encodeIfPresent(resolutionFormatID, forKey: .resolutionFormatID)
        try container.encodeIfPresent(frameRate, forKey: .frameRate)
        try container.encodeIfPresent(frameDurationValue, forKey: .frameDurationValue)
        try container.encodeIfPresent(frameDurationTimescale, forKey: .frameDurationTimescale)
    }

    var lockSummary: String {
        var locks: [String] = []
        if zoomLocked { locks.append("Zoom") }
        if focusLocked { locks.append("Focus") }
        if exposureLocked { locks.append("Exposure") }
        if whiteBalanceLocked { locks.append("White balance") }
        if isoLocked { locks.append("ISO") }
        if shutterSpeedLocked { locks.append("Shutter") }
        return locks.isEmpty ? "No manual locks" : locks.joined(separator: ", ")
    }
}

struct RinkTemplate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = .now
    var modifiedAt: Date = .now
    /// Monotonic revision of the physically calibrated OCR/relay zones.
    /// Older saved templates decode as revision 1.
    var zoneRevision: Int = 1
    var venueName: String?
    var notes: String?
    var layout: ScoreboardOCRLayout = ScoreboardOCRLayout()
    var calibrationRotationDegrees: Double = 0
    /// Manual OCR/calibration camera preview rotation saved with the rink template.
    /// This is separate from the legacy calibrationRotationDegrees/board rotation and
    /// is restored when a template is loaded so each rink can keep its own OCR camera orientation.
    var ocrPreviewRotationOffsetDegrees: Double = 180
    var scoreboardType: String = "Standard"
    var defaultHomeTeamName: String?
    var defaultAwayTeamName: String?
    var isDefault: Bool = false
    var isFavorite: Bool = false
    var imageFileName: String?
    var cameraZoomFactor: Double = 1.0
    var boardCalibration: BoardCalibrationQuad = BoardCalibrationQuad()
    var profileName: String? = "default"
    var gameClockDirection: GameClockDirection = .auto
    var defaultHomeLogoFileName: String?
    var defaultAwayLogoFileName: String?
    var broadcastScoreboardSettings: BroadcastScoreboardTemplateSettings?
    var calibrationCameraProfile: CalibrationCameraProfile = CalibrationCameraProfile()
    var ocrColourProfiles: OCRColourProfileSet = .defaults
    var scoreboardTemplate: RinkScoreboardTemplate? = nil

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        zoneRevision: Int = 1,
        venueName: String? = nil,
        notes: String? = nil,
        layout: ScoreboardOCRLayout = ScoreboardOCRLayout(),
        calibrationRotationDegrees: Double = 0,
        ocrPreviewRotationOffsetDegrees: Double = 180,
        scoreboardType: String = "Standard",
        defaultHomeTeamName: String? = nil,
        defaultAwayTeamName: String? = nil,
        isDefault: Bool = false,
        isFavorite: Bool = false,
        imageFileName: String? = nil,
        cameraZoomFactor: Double = 1.0,
        boardCalibration: BoardCalibrationQuad = BoardCalibrationQuad(),
        profileName: String? = "default",
        gameClockDirection: GameClockDirection = .auto,
        defaultHomeLogoFileName: String? = nil,
        defaultAwayLogoFileName: String? = nil,
        broadcastScoreboardSettings: BroadcastScoreboardTemplateSettings? = nil,
        calibrationCameraProfile: CalibrationCameraProfile = CalibrationCameraProfile(),
        ocrColourProfiles: OCRColourProfileSet = .defaults,
        scoreboardTemplate: RinkScoreboardTemplate? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.zoneRevision = max(1, zoneRevision)
        self.venueName = venueName
        self.notes = notes
        self.layout = layout
        self.calibrationRotationDegrees = calibrationRotationDegrees
        self.ocrPreviewRotationOffsetDegrees = ocrPreviewRotationOffsetDegrees
        self.scoreboardType = scoreboardType
        self.defaultHomeTeamName = defaultHomeTeamName
        self.defaultAwayTeamName = defaultAwayTeamName
        self.isDefault = isDefault
        self.isFavorite = isFavorite
        self.imageFileName = imageFileName
        self.cameraZoomFactor = cameraZoomFactor
        self.boardCalibration = boardCalibration
        self.profileName = profileName
        self.gameClockDirection = gameClockDirection
        self.defaultHomeLogoFileName = defaultHomeLogoFileName
        self.defaultAwayLogoFileName = defaultAwayLogoFileName
        self.broadcastScoreboardSettings = broadcastScoreboardSettings
        self.calibrationCameraProfile = calibrationCameraProfile
        self.ocrColourProfiles = ocrColourProfiles
        self.scoreboardTemplate = scoreboardTemplate
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, modifiedAt, zoneRevision, venueName, notes, layout
        case calibrationRotationDegrees, ocrPreviewRotationOffsetDegrees, scoreboardType, defaultHomeTeamName, defaultAwayTeamName
        case isDefault, isFavorite, imageFileName, cameraZoomFactor
        case boardCalibration, profileName, gameClockDirection
        case defaultHomeLogoFileName, defaultAwayLogoFileName, broadcastScoreboardSettings
        case calibrationCameraProfile, ocrColourProfiles, scoreboardTemplate
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = RinkTemplate(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Template",
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now,
            modifiedAt: try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .now,
            zoneRevision: try container.decodeIfPresent(Int.self, forKey: .zoneRevision) ?? 1,
            venueName: try container.decodeIfPresent(String.self, forKey: .venueName),
            notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? container.decodeIfPresent(String.self, forKey: .description),
            layout: try container.decodeIfPresent(ScoreboardOCRLayout.self, forKey: .layout) ?? ScoreboardOCRLayout(),
            calibrationRotationDegrees: try container.decodeIfPresent(Double.self, forKey: .calibrationRotationDegrees) ?? 0,
            ocrPreviewRotationOffsetDegrees: try container.decodeIfPresent(Double.self, forKey: .ocrPreviewRotationOffsetDegrees) ?? 180,
            scoreboardType: try container.decodeIfPresent(String.self, forKey: .scoreboardType) ?? "Standard",
            defaultHomeTeamName: try container.decodeIfPresent(String.self, forKey: .defaultHomeTeamName),
            defaultAwayTeamName: try container.decodeIfPresent(String.self, forKey: .defaultAwayTeamName),
            isDefault: try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
            isFavorite: try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            imageFileName: try container.decodeIfPresent(String.self, forKey: .imageFileName),
            cameraZoomFactor: try container.decodeIfPresent(Double.self, forKey: .cameraZoomFactor) ?? 1.0,
            boardCalibration: try container.decodeIfPresent(BoardCalibrationQuad.self, forKey: .boardCalibration) ?? BoardCalibrationQuad(),
            profileName: try container.decodeIfPresent(String.self, forKey: .profileName) ?? "default",
            gameClockDirection: try container.decodeIfPresent(GameClockDirection.self, forKey: .gameClockDirection) ?? .auto,
            defaultHomeLogoFileName: try container.decodeIfPresent(String.self, forKey: .defaultHomeLogoFileName),
            defaultAwayLogoFileName: try container.decodeIfPresent(String.self, forKey: .defaultAwayLogoFileName),
            broadcastScoreboardSettings: try container.decodeIfPresent(BroadcastScoreboardTemplateSettings.self, forKey: .broadcastScoreboardSettings),
            calibrationCameraProfile: try container.decodeIfPresent(CalibrationCameraProfile.self, forKey: .calibrationCameraProfile) ?? CalibrationCameraProfile(),
            ocrColourProfiles: try container.decodeIfPresent(OCRColourProfileSet.self, forKey: .ocrColourProfiles) ?? .defaults,
            scoreboardTemplate: try container.decodeIfPresent(RinkScoreboardTemplate.self, forKey: .scoreboardTemplate)
        )
        if let modified = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) {
            modifiedAt = modified
        } else {
            modifiedAt = createdAt
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(zoneRevision, forKey: .zoneRevision)
        try container.encodeIfPresent(venueName, forKey: .venueName)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(layout, forKey: .layout)
        try container.encode(calibrationRotationDegrees, forKey: .calibrationRotationDegrees)
        try container.encode(ocrPreviewRotationOffsetDegrees, forKey: .ocrPreviewRotationOffsetDegrees)
        try container.encode(scoreboardType, forKey: .scoreboardType)
        try container.encodeIfPresent(defaultHomeTeamName, forKey: .defaultHomeTeamName)
        try container.encodeIfPresent(defaultAwayTeamName, forKey: .defaultAwayTeamName)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try container.encode(cameraZoomFactor, forKey: .cameraZoomFactor)
        try container.encode(boardCalibration, forKey: .boardCalibration)
        try container.encodeIfPresent(profileName, forKey: .profileName)
        try container.encode(gameClockDirection, forKey: .gameClockDirection)
        try container.encodeIfPresent(defaultHomeLogoFileName, forKey: .defaultHomeLogoFileName)
        try container.encodeIfPresent(defaultAwayLogoFileName, forKey: .defaultAwayLogoFileName)
        try container.encodeIfPresent(broadcastScoreboardSettings, forKey: .broadcastScoreboardSettings)
        try container.encode(calibrationCameraProfile, forKey: .calibrationCameraProfile)
        try container.encode(ocrColourProfiles, forKey: .ocrColourProfiles)
        try container.encodeIfPresent(scoreboardTemplate, forKey: .scoreboardTemplate)
    }
}

extension String {
    var normalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Optional where Wrapped == String {
    var normalized: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}


#endif
