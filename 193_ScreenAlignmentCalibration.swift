// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import CoreGraphics
import Foundation

// MARK: - Build 666 screen alignment interaction

struct CalibrationScreenAlignmentToggleButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isActive ? "Done Aligning" : "Screen Align", systemImage: isActive ? "checkmark.rectangle.portrait" : "square.on.square.dashed")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(isActive ? Color.cyan.opacity(0.82) : Color.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.24), lineWidth: 1))
        .accessibilityHint("Creates a four-corner scoreboard frame. OCR and Image Relay zones follow the frame.")
    }
}

// MARK: - Perspective-aligned OCR zones

struct PerspectiveCalibrationZonesOverlay: View {
    @Binding var layout: ScoreboardOCRLayout
    @Binding var selectedKey: OCRRegionKey
    @Binding var zoneEditMode: CalibrationZoneEditMode
    @Binding var selectedPenaltyGroup: PenaltyZoneGroupID
    let boardCalibration: BoardCalibrationQuad
    let displayOptions: OCRDiagnosticDisplayOptions
    let isEditable: Bool
    let lockedKeys: Set<OCRRegionKey>

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear.allowsHitTesting(false)

                ForEach(orderedKeys) { key in
                    PerspectiveRegionBox(
                        key: key,
                        region: binding(for: key),
                        selectedKey: $selectedKey,
                        zoneEditMode: $zoneEditMode,
                        boardCalibration: boardCalibration,
                        proxySize: proxy.size,
                        isEditable: isEditable,
                        isLocked: lockedKeys.contains(key),
                        showBoxes: displayOptions.showOCRBoxes,
                        interactionEnabled: zoneEditMode == .single || !selectedPenaltyGroup.contains(key)
                    )
                }

                if zoneEditMode == .penaltyGroup {
                    let groupID = selectedPenaltyGroup
                    PerspectivePenaltyGroupBox(
                        groupID: groupID,
                        playerRegion: binding(for: groupID.playerKey),
                        timeRegion: binding(for: groupID.timeKey),
                        selectedKey: $selectedKey,
                        selectedPenaltyGroup: $selectedPenaltyGroup,
                        zoneEditMode: $zoneEditMode,
                        boardCalibration: boardCalibration,
                        proxySize: proxy.size,
                        isEditable: isEditable,
                        isLocked: lockedKeys.contains(groupID.playerKey) || lockedKeys.contains(groupID.timeKey),
                        showBoxes: displayOptions.showOCRBoxes,
                        onCommit: { player, time in
                            commitPenaltyGroup(groupID, player: player, time: time)
                        }
                    )
                    .zIndex(80)
                }
            }
            .allowsHitTesting(isEditable && displayOptions.showOCRBoxes)
        }
    }

    private var orderedKeys: [OCRRegionKey] {
        let keys = OCRRegionKey.calibrationCases
        let selectedGroupKeys: Set<OCRRegionKey> = zoneEditMode == .penaltyGroup
            ? [selectedPenaltyGroup.playerKey, selectedPenaltyGroup.timeKey]
            : []
        let visibleKeys = keys.filter { !selectedGroupKeys.contains($0) }
        return visibleKeys.filter { $0 != selectedKey } + visibleKeys.filter { $0 == selectedKey }
    }

    private func binding(for key: OCRRegionKey) -> Binding<OCRRegion> {
        Binding(
            get: { layout[key] },
            set: { value in
                guard !lockedKeys.contains(key) else { return }
                guard !layout[key].isApproximatelyEqual(to: value) else { return }
                var updated = layout
                updated[key] = value
                layout = updated
            }
        )
    }

    private func commitPenaltyGroup(_ groupID: PenaltyZoneGroupID, player: OCRRegion, time: OCRRegion) {
        guard !lockedKeys.contains(groupID.playerKey), !lockedKeys.contains(groupID.timeKey) else { return }
        guard !layout[groupID.playerKey].isApproximatelyEqual(to: player)
                || !layout[groupID.timeKey].isApproximatelyEqual(to: time) else { return }
        var updated = layout
        updated[groupID.playerKey] = player
        updated[groupID.timeKey] = time
        layout = updated
    }
}

private struct PerspectiveRegionBox: View {
    let key: OCRRegionKey
    @Binding var region: OCRRegion
    @Binding var selectedKey: OCRRegionKey
    @Binding var zoneEditMode: CalibrationZoneEditMode
    let boardCalibration: BoardCalibrationQuad
    let proxySize: CGSize
    let isEditable: Bool
    let isLocked: Bool
    let showBoxes: Bool
    let interactionEnabled: Bool

    @State private var moveStartRegion: OCRRegion?
    @State private var moveDraftRegion: OCRRegion?
    @State private var resizeStartRegion: OCRRegion?
    @State private var resizeDraftRegion: OCRRegion?
    @State private var pinchStartRegion: OCRRegion?
    @State private var pinchPreviewScale: CGFloat = 1
    @State private var pinchIsActive = false

    var body: some View {
        let points = projectedPixelPoints(for: displayedRegion)
        let frame = boundingPixelRect(points).insetBy(dx: -8, dy: -8)
        let local = points.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }

        ZStack {
            polygonPath(local)
                .fill(selectedKey == key ? Color.cyan.opacity(0.10) : Color.clear)
            polygonPath(local)
                .stroke(
                    isLocked ? Color.orange : (selectedKey == key ? Color.cyan : Color.white.opacity(0.68)),
                    style: StrokeStyle(lineWidth: selectedKey == key ? 3 : 1.5, dash: isLocked ? [5, 3] : [4, 3])
                )

            Text(shortLabel)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.68), in: Capsule())
                .position(centroid(local))
                .allowsHitTesting(false)

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                    .position(x: max(10, frame.width - 14), y: 14)
                    .allowsHitTesting(false)
            }

            if selectedKey == key, isEditable, !isLocked, zoneEditMode == .single {
                Circle()
                    .fill(Color.cyan)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 28, height: 28)
                    .position(local.count > 2 ? local[2] : CGPoint(x: frame.width - 10, y: frame.height - 10))
                    .contentShape(Circle())
                    .highPriorityGesture(resizeGesture)
                    .zIndex(20)
            }
        }
        .frame(width: max(20, frame.width), height: max(20, frame.height))
        .position(x: frame.midX, y: frame.midY)
        .scaleEffect(pinchPreviewScale)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEditable, showBoxes, interactionEnabled else { return }
            zoneEditMode = .single
            selectedKey = key
        }
        .gesture(moveGesture)
        .simultaneousGesture(pinchGesture)
        .allowsHitTesting(isEditable && showBoxes && interactionEnabled)
        .zIndex(selectedKey == key ? 40 : 20)
    }

    private var displayedRegion: OCRRegion {
        resizeDraftRegion ?? moveDraftRegion ?? region
    }

    private func projectedPixelPoints(for source: OCRRegion) -> [CGPoint] {
        let normalised = BoardPerspectiveMapper.projectedCorners(of: source.rect, through: boardCalibration) ?? []
        return normalised.map { CGPoint(x: $0.x * proxySize.width, y: $0.y * proxySize.height) }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard isEditable, interactionEnabled, !isLocked, zoneEditMode == .single, !pinchIsActive else { return }
                if moveStartRegion == nil {
                    moveStartRegion = region
                    selectedKey = key
                }
                guard let start = moveStartRegion else { return }
                let boardCentre = CGPoint(x: start.rect.midX, y: start.rect.midY)
                guard let sourceCentre = BoardPerspectiveMapper.project(boardCentre, through: boardCalibration) else { return }
                let sourceTarget = CGPoint(
                    x: sourceCentre.x + value.translation.width / max(1, proxySize.width),
                    y: sourceCentre.y + value.translation.height / max(1, proxySize.height)
                )
                guard let boardTarget = BoardPerspectiveMapper.unproject(sourceTarget, through: boardCalibration) else { return }
                var updated = start
                updated.x = clamp(start.x + boardTarget.x - boardCentre.x, 0, 1 - start.width)
                updated.y = clamp(start.y + boardTarget.y - boardCentre.y, 0, 1 - start.height)
                moveDraftRegion = updated
            }
            .onEnded { _ in
                let start = moveStartRegion
                let resolved = moveDraftRegion
                moveStartRegion = nil
                moveDraftRegion = nil
                guard let start, let resolved, !start.isApproximatelyEqual(to: resolved) else { return }
                region = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "move",
                    event: "calibration_zone_move_committed",
                    start: start,
                    resolved: resolved,
                    source: "PerspectiveRegionBox.moveGesture",
                    reason: "Operator moved a perspective-projected calibration zone; local board-space draft committed once to RinkLensCalibrationStore"
                )
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard isEditable, interactionEnabled, !isLocked, zoneEditMode == .single, !pinchIsActive else { return }
                if resizeStartRegion == nil { resizeStartRegion = region }
                guard let start = resizeStartRegion,
                      let startSource = BoardPerspectiveMapper.project(
                        CGPoint(x: start.rect.maxX, y: start.rect.maxY),
                        through: boardCalibration
                      ) else { return }
                let targetSource = CGPoint(
                    x: startSource.x + value.translation.width / max(1, proxySize.width),
                    y: startSource.y + value.translation.height / max(1, proxySize.height)
                )
                guard let boardTarget = BoardPerspectiveMapper.unproject(targetSource, through: boardCalibration) else { return }
                var updated = start
                updated.width = clamp(boardTarget.x - start.x, 0.004, 1 - start.x)
                updated.height = clamp(boardTarget.y - start.y, 0.004, 1 - start.y)
                resizeDraftRegion = updated
            }
            .onEnded { _ in
                let start = resizeStartRegion
                let resolved = resizeDraftRegion
                resizeStartRegion = nil
                resizeDraftRegion = nil
                guard let start, let resolved, !start.isApproximatelyEqual(to: resolved) else { return }
                region = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "resize",
                    event: "calibration_zone_resize_committed",
                    start: start,
                    resolved: resolved,
                    source: "PerspectiveRegionBox.resizeGesture",
                    reason: "Operator resized a perspective-projected calibration zone; local board-space draft committed once to RinkLensCalibrationStore"
                )
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isEditable, interactionEnabled, !isLocked, showBoxes else { return }
                zoneEditMode = .single
                selectedKey = key
                if pinchStartRegion == nil {
                    pinchStartRegion = region
                    moveStartRegion = nil
                    moveDraftRegion = nil
                    resizeStartRegion = nil
                    resizeDraftRegion = nil
                    MainThreadStallMonitor.shared.markContext("perspective zone pinch draft started: \(key.rawValue)")
                }
                pinchIsActive = true
                pinchPreviewScale = max(0.08, min(8, CGFloat(value)))
            }
            .onEnded { value in
                let start = pinchStartRegion
                pinchStartRegion = nil
                pinchIsActive = false
                pinchPreviewScale = 1
                guard let start else { return }
                let resolved = CalibrationZoneEditTransaction.resolvedPinchRegion(
                    from: start,
                    scale: CGFloat(value)
                )
                guard !start.isApproximatelyEqual(to: resolved) else { return }
                region = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "pinch-resize",
                    event: "calibration_zone_pinch_committed",
                    start: start,
                    resolved: resolved,
                    source: "PerspectiveRegionBox.pinchGesture",
                    reason: "Operator pinched a perspective-projected calibration zone; local board-space draft committed once to RinkLensCalibrationStore"
                )
            }
    }

    private var shortLabel: String {
        switch key {
        case .clock: return "CLK"
        case .period: return "PER"
        case .homeScore: return "H"
        case .awayScore: return "A"
        case .homePenalty1Player: return "HP1"
        case .homePenalty1Time: return "HT1"
        case .homePenalty2Player: return "HP2"
        case .homePenalty2Time: return "HT2"
        case .awayPenalty1Player: return "AP1"
        case .awayPenalty1Time: return "AT1"
        case .awayPenalty2Player: return "AP2"
        case .awayPenalty2Time: return "AT2"
        default: return key.likelyTitle
        }
    }
}

private struct PerspectivePenaltyGroupBox: View {
    let groupID: PenaltyZoneGroupID
    @Binding var playerRegion: OCRRegion
    @Binding var timeRegion: OCRRegion
    @Binding var selectedKey: OCRRegionKey
    @Binding var selectedPenaltyGroup: PenaltyZoneGroupID
    @Binding var zoneEditMode: CalibrationZoneEditMode
    let boardCalibration: BoardCalibrationQuad
    let proxySize: CGSize
    let isEditable: Bool
    let isLocked: Bool
    let showBoxes: Bool
    let onCommit: (OCRRegion, OCRRegion) -> Void

    @State private var startPlayer: OCRRegion?
    @State private var startTime: OCRRegion?
    @State private var draftPlayer: OCRRegion?
    @State private var draftTime: OCRRegion?

    var body: some View {
        let sourceRect = projectedGroupRect(player: displayedPlayer, time: displayedTime)
        let visualWidth = max(30, sourceRect.width)
        let visualHeight = max(30, sourceRect.height)
        let visualRect = CGRect(
            x: sourceRect.midX - visualWidth / 2,
            y: sourceRect.midY - visualHeight / 2,
            width: visualWidth,
            height: visualHeight
        )

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.08))
            RoundedRectangle(cornerRadius: 8)
                .stroke(isLocked ? Color.orange : Color.purple, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))

            projectedChildZone(
                key: groupID.playerKey,
                region: displayedPlayer,
                visualRect: visualRect,
                title: "PLAYER"
            )
            projectedChildZone(
                key: groupID.timeKey,
                region: displayedTime,
                visualRect: visualRect,
                title: "TIME"
            )

            Text(groupID.title)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.purple.opacity(0.86), in: Capsule())
                .padding(4)
                .allowsHitTesting(false)
        }
        .frame(width: visualWidth, height: visualHeight)
        .position(x: visualRect.midX, y: visualRect.midY)
        .contentShape(Rectangle())
        .highPriorityGesture(selectionTapGesture)
        .gesture(groupMoveGesture)
        .allowsHitTesting(isEditable && !isLocked && showBoxes)
    }

    private var displayedPlayer: OCRRegion { draftPlayer ?? playerRegion }
    private var displayedTime: OCRRegion { draftTime ?? timeRegion }

    private func projectedGroupRect(player: OCRRegion, time: OCRRegion) -> CGRect {
        let playerRect = BoardPerspectiveMapper.projectedBoundingRect(of: player.rect, through: boardCalibration) ?? .zero
        let timerRect = BoardPerspectiveMapper.projectedBoundingRect(of: time.rect, through: boardCalibration) ?? .zero
        let normalised = playerRect.union(timerRect).insetBy(dx: -0.008, dy: -0.008)
        return CGRect(
            x: normalised.minX * proxySize.width,
            y: normalised.minY * proxySize.height,
            width: normalised.width * proxySize.width,
            height: normalised.height * proxySize.height
        )
    }


    private func projectedChildZone(
        key: OCRRegionKey,
        region: OCRRegion,
        visualRect: CGRect,
        title: String
    ) -> some View {
        let localPoints = projectedLocalPoints(for: region, visualRect: visualRect)
        let labelPoint = centroid(localPoints)
        return ZStack {
            polygonPath(localPoints)
                .fill(Color.black.opacity(0.12))
            polygonPath(localPoints)
                .stroke(
                    key == groupID.playerKey ? Color.cyan : Color.yellow,
                    style: StrokeStyle(lineWidth: 2, dash: [5, 3])
                )
            Text(title)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.72), in: Capsule())
                .position(labelPoint)
        }
        .allowsHitTesting(false)
    }

    private func projectedLocalPoints(for region: OCRRegion, visualRect: CGRect) -> [CGPoint] {
        let projected = BoardPerspectiveMapper.projectedCorners(of: region.rect, through: boardCalibration) ?? []
        return projected.map {
            CGPoint(
                x: $0.x * proxySize.width - visualRect.minX,
                y: $0.y * proxySize.height - visualRect.minY
            )
        }
    }

    private func polygonPath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let total = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: total.x / CGFloat(points.count), y: total.y / CGFloat(points.count))
    }

    private var selectionTapGesture: some Gesture {
        TapGesture(count: 1)
            .onEnded {
                guard isEditable, !isLocked, showBoxes else { return }
                zoneEditMode = .penaltyGroup
                selectedPenaltyGroup = groupID
                selectedKey = groupID.playerKey
                MainThreadStallMonitor.shared.markContext("penalty group interaction owner selected: \(groupID.rawValue)")
                MainThreadStallMonitor.shared.notePublish(source: "perspective penalty group selected")
            }
    }

    private var groupMoveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if startPlayer == nil {
                    zoneEditMode = .penaltyGroup
                    startPlayer = playerRegion
                    startTime = timeRegion
                    selectedPenaltyGroup = groupID
                    selectedKey = groupID.playerKey
                }
                guard let playerStart = startPlayer, let timeStart = startTime else { return }
                let groupBoardRect = playerStart.rect.union(timeStart.rect)
                let boardCentre = CGPoint(x: groupBoardRect.midX, y: groupBoardRect.midY)
                guard let sourceCentre = BoardPerspectiveMapper.project(boardCentre, through: boardCalibration) else { return }
                let targetSource = CGPoint(
                    x: sourceCentre.x + value.translation.width / max(1, proxySize.width),
                    y: sourceCentre.y + value.translation.height / max(1, proxySize.height)
                )
                guard let targetBoard = BoardPerspectiveMapper.unproject(targetSource, through: boardCalibration) else { return }
                let dx = targetBoard.x - boardCentre.x
                let dy = targetBoard.y - boardCentre.y
                var player = playerStart
                var timer = timeStart
                let minX = min(playerStart.x, timeStart.x)
                let maxX = max(playerStart.rect.maxX, timeStart.rect.maxX)
                let minY = min(playerStart.y, timeStart.y)
                let maxY = max(playerStart.rect.maxY, timeStart.rect.maxY)
                let safeDX = clamp(dx, -minX, 1 - maxX)
                let safeDY = clamp(dy, -minY, 1 - maxY)
                player.x = playerStart.x + safeDX
                player.y = playerStart.y + safeDY
                timer.x = timeStart.x + safeDX
                timer.y = timeStart.y + safeDY
                draftPlayer = player
                draftTime = timer
            }
            .onEnded { _ in
                let playerStart = startPlayer
                let timeStart = startTime
                let resolvedPlayer = draftPlayer
                let resolvedTime = draftTime
                startPlayer = nil
                startTime = nil
                draftPlayer = nil
                draftTime = nil
                guard let playerStart, let timeStart, let resolvedPlayer, let resolvedTime else { return }
                guard !playerStart.isApproximatelyEqual(to: resolvedPlayer)
                        || !timeStart.isApproximatelyEqual(to: resolvedTime) else { return }
                onCommit(resolvedPlayer, resolvedTime)
                CalibrationZoneEditTransaction.recordGroupCommit(
                    groupID: groupID,
                    operation: "group-move",
                    event: "calibration_penalty_group_move_committed",
                    startPlayer: playerStart,
                    startTime: timeStart,
                    resolvedPlayer: resolvedPlayer,
                    resolvedTime: resolvedTime,
                    source: "PerspectivePenaltyGroupBox.groupMoveGesture",
                    reason: "Operator moved a perspective-projected penalty group; both local drafts committed atomically to RinkLensCalibrationStore"
                )
            }
    }
}

// MARK: - Four-corner scoreboard editor

enum BoardAlignmentCorner: String, CaseIterable, Identifiable {
    case topLeft = "TL"
    case topRight = "TR"
    case bottomRight = "BR"
    case bottomLeft = "BL"

    var id: String { rawValue }

    var spokenName: String {
        switch self {
        case .topLeft: return "top left"
        case .topRight: return "top right"
        case .bottomRight: return "bottom right"
        case .bottomLeft: return "bottom left"
        }
    }
}

enum BoardParallelogramConstraint {
    /// Build 670 retains this compatibility name, but no longer forces a
    /// parallelogram. It only fits a valid four-corner screen quad into the camera
    /// canvas. Each physical corner is therefore independently calibratable.
    static func normalized(_ quad: BoardCalibrationQuad) -> BoardCalibrationQuad {
        fitted(quad)
    }

    /// Move only the selected corner. Invalid/self-crossing shapes are rejected and
    /// the drag is progressively shortened so the handle stops at the nearest valid
    /// convex quadrilateral instead of jumping or moving adjacent corners.
    static func moving(
        corner: BoardAlignmentCorner,
        translation: CGSize,
        canvasSize: CGSize,
        from quad: BoardCalibrationQuad
    ) -> BoardCalibrationQuad? {
        let requested = CGPoint(
            x: translation.width / max(1, canvasSize.width),
            y: translation.height / max(1, canvasSize.height)
        )
        let original = point(for: corner, in: quad)
        let target = BoardPerspectiveMapper.clampedPoint(
            CGPoint(x: original.x + requested.x, y: original.y + requested.y),
            margin: 0.01
        )

        var direct = quad
        set(target, for: corner, in: &direct)
        direct.zonesFollowPerspective = quad.zonesFollowPerspective
        if isValidIndependentQuad(direct) { return direct }

        var lower: CGFloat = 0
        var upper: CGFloat = 1
        var best: BoardCalibrationQuad?
        for _ in 0..<14 {
            let fraction = (lower + upper) / 2
            let candidatePoint = CGPoint(
                x: original.x + (target.x - original.x) * fraction,
                y: original.y + (target.y - original.y) * fraction
            )
            var candidate = quad
            set(candidatePoint, for: corner, in: &candidate)
            candidate.zonesFollowPerspective = quad.zonesFollowPerspective
            if isValidIndependentQuad(candidate) {
                best = candidate
                lower = fraction
            } else {
                upper = fraction
            }
        }
        return best
    }

    private static func fitted(_ quad: BoardCalibrationQuad) -> BoardCalibrationQuad {
        let margin: CGFloat = 0.01
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        let minX = points.map(\.x).min() ?? margin
        let maxX = points.map(\.x).max() ?? (1 - margin)
        let minY = points.map(\.y).min() ?? margin
        let maxY = points.map(\.y).max() ?? (1 - margin)
        let dx = minX < margin ? margin - minX : (maxX > 1 - margin ? (1 - margin) - maxX : 0)
        let dy = minY < margin ? margin - minY : (maxY > 1 - margin ? (1 - margin) - maxY : 0)
        var adjusted = quad
        adjusted.topLeft.x += dx; adjusted.topLeft.y += dy
        adjusted.topRight.x += dx; adjusted.topRight.y += dy
        adjusted.bottomRight.x += dx; adjusted.bottomRight.y += dy
        adjusted.bottomLeft.x += dx; adjusted.bottomLeft.y += dy
        return isValidIndependentQuad(adjusted) ? adjusted : quad
    }

    private static func isValidIndependentQuad(_ quad: BoardCalibrationQuad) -> Bool {
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0.005 && $0.x <= 0.995 && $0.y >= 0.005 && $0.y <= 0.995 }) else { return false }

        let minimumEdge: CGFloat = 0.018
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            guard hypot(next.x - points[index].x, next.y - points[index].y) >= minimumEdge else { return false }
        }

        var signedCrosses: [CGFloat] = []
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let c = points[(index + 2) % points.count]
            signedCrosses.append((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
        }
        let positive = signedCrosses.allSatisfy { $0 > 0.000_01 }
        let negative = signedCrosses.allSatisfy { $0 < -0.000_01 }
        guard positive || negative else { return false }

        var signedArea: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            signedArea += points[index].x * next.y - next.x * points[index].y
        }
        let area = abs(signedArea) / 2
        return area >= 0.0025 && BoardPerspectiveMapper.isUsable(quad)
    }

    private static func point(for corner: BoardAlignmentCorner, in quad: BoardCalibrationQuad) -> CGPoint {
        switch corner {
        case .topLeft: return quad.topLeft
        case .topRight: return quad.topRight
        case .bottomRight: return quad.bottomRight
        case .bottomLeft: return quad.bottomLeft
        }
    }

    private static func set(_ point: CGPoint, for corner: BoardAlignmentCorner, in quad: inout BoardCalibrationQuad) {
        switch corner {
        case .topLeft: quad.topLeft = point
        case .topRight: quad.topRight = point
        case .bottomRight: quad.bottomRight = point
        case .bottomLeft: quad.bottomLeft = point
        }
    }
}

/// Build 670 gives every physical scoreboard corner independent movement. The selected
/// marker is orange and turns yellow while it is actually moving; invalid crossing or
/// collapsed quads are prevented without moving the other three corners.
struct BoardAlignmentEditorOverlay: View {
    @Binding var boardCalibration: BoardCalibrationQuad
    @Binding var selectedCorner: BoardAlignmentCorner

    @State private var frameMoveStartQuad: BoardCalibrationQuad?
    @State private var canvasCornerStartQuad: BoardCalibrationQuad?
    @State private var directCornerStartQuad: BoardCalibrationQuad?
    @State private var isDraggingSelectedCorner = false

    var body: some View {
        GeometryReader { proxy in
            let points = pixelPoints(size: proxy.size)

            ZStack {
                polygonPath(points)
                    .fill(Color.cyan.opacity(0.06))
                    .allowsHitTesting(false)

                polygonPath(points)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 3, dash: [10, 5]))
                    .allowsHitTesting(false)

                // This is the reliable movement surface. It deliberately covers the
                // complete video viewport, but sits beneath the corner markers and the
                // dedicated MOVE FRAME control.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(selectedCornerCanvasGesture(size: proxy.size), including: .all)
                    .zIndex(40)
                    .accessibilityLabel("Move selected screen alignment corner")
                    .accessibilityHint("Select TL, TR, BR or BL, then drag anywhere on the camera image.")

                moveFrameHandle(size: proxy.size)
                    .zIndex(180)

                ForEach(BoardAlignmentCorner.allCases) { corner in
                    alignmentHandle(corner, point: point(for: corner, in: boardCalibration), size: proxy.size)
                        .zIndex(selectedCorner == corner ? 300 : 240)
                }
            }
            .coordinateSpace(name: "Build667BoardAlignmentSpace")
        }
    }

    private func alignmentHandle(_ corner: BoardAlignmentCorner, point: CGPoint, size: CGSize) -> some View {
        let isSelected = selectedCorner == corner
        let markerColour: Color = isSelected
            ? (isDraggingSelectedCorner ? .yellow : .orange)
            : .cyan

        return ZStack {
            Color.clear

            if isSelected {
                Circle()
                    .fill(markerColour.opacity(0.24))
                    .frame(width: 56, height: 56)
            }

            ZStack {
                Circle().fill(markerColour)
                Circle().stroke(.white, lineWidth: isSelected ? 4 : 3)
                Text(corner.rawValue)
                    .font(.system(size: isSelected ? 12 : 10, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
            }
            .frame(width: isSelected ? 44 : 38, height: isSelected ? 44 : 38)
            .shadow(color: .black.opacity(0.68), radius: 5)
        }
        .frame(width: 76, height: 76)
        .position(x: point.x * size.width, y: point.y * size.height)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedCorner = corner
            MainThreadStallMonitor.shared.markContext("screen alignment selected corner: \(corner.rawValue)")
        }
        .highPriorityGesture(directCornerGesture(corner, size: size), including: .all)
        .accessibilityLabel("Screen alignment \(corner.spokenName) corner")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Tap to select. Drag this marker directly, or drag anywhere on the camera image after selecting it.")
    }

    private func selectedCornerCanvasGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if canvasCornerStartQuad == nil {
                    canvasCornerStartQuad = boardCalibration
                    isDraggingSelectedCorner = true
                    MainThreadStallMonitor.shared.markContext("screen alignment canvas drag began for \(selectedCorner.rawValue)")
                }
                guard let start = canvasCornerStartQuad else { return }
                applyCornerTranslation(
                    selectedCorner,
                    translation: value.translation,
                    size: size,
                    start: start
                )
            }
            .onEnded { _ in
                canvasCornerStartQuad = nil
                isDraggingSelectedCorner = false
                MainThreadStallMonitor.shared.notePublish(source: "screen alignment selected corner canvas drag committed")
            }
    }

    private func directCornerGesture(_ corner: BoardAlignmentCorner, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if directCornerStartQuad == nil {
                    selectedCorner = corner
                    directCornerStartQuad = boardCalibration
                    isDraggingSelectedCorner = true
                    MainThreadStallMonitor.shared.markContext("screen alignment direct drag began for \(corner.rawValue)")
                }
                guard let start = directCornerStartQuad else { return }
                applyCornerTranslation(
                    corner,
                    translation: value.translation,
                    size: size,
                    start: start
                )
            }
            .onEnded { _ in
                directCornerStartQuad = nil
                isDraggingSelectedCorner = false
                MainThreadStallMonitor.shared.notePublish(source: "screen alignment direct corner drag committed")
            }
    }

    private func applyCornerTranslation(
        _ corner: BoardAlignmentCorner,
        translation: CGSize,
        size: CGSize,
        start: BoardCalibrationQuad
    ) {
        if let candidate = BoardParallelogramConstraint.moving(
            corner: corner,
            translation: translation,
            canvasSize: size,
            from: start
        ) {
            boardCalibration = candidate
        }
    }

    private func moveFrameHandle(size: CGSize) -> some View {
        let centre = centroid(pixelPoints(size: size))
        return Label("MOVE FRAME", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 10, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(Color.cyan.opacity(0.92), lineWidth: 1.5))
            .position(centre)
            .contentShape(Capsule())
            .highPriorityGesture(moveFrameGesture(size: size), including: .all)
            .shadow(color: .black.opacity(0.55), radius: 4)
            .accessibilityHint("Drag to move the complete four-corner frame without changing its shape.")
    }

    private func moveFrameGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if frameMoveStartQuad == nil {
                    frameMoveStartQuad = boardCalibration
                }
                guard let start = frameMoveStartQuad else { return }
                let dx = value.translation.width / max(1, size.width)
                let dy = value.translation.height / max(1, size.height)
                let xs = [start.topLeft.x, start.topRight.x, start.bottomRight.x, start.bottomLeft.x]
                let ys = [start.topLeft.y, start.topRight.y, start.bottomRight.y, start.bottomLeft.y]
                let safeDX = clamp(dx, 0.01 - (xs.min() ?? 0), 0.99 - (xs.max() ?? 1))
                let safeDY = clamp(dy, 0.01 - (ys.min() ?? 0), 0.99 - (ys.max() ?? 1))
                var candidate = start
                candidate.topLeft.x += safeDX
                candidate.topLeft.y += safeDY
                candidate.topRight.x += safeDX
                candidate.topRight.y += safeDY
                candidate.bottomRight.x += safeDX
                candidate.bottomRight.y += safeDY
                candidate.bottomLeft.x += safeDX
                candidate.bottomLeft.y += safeDY
                boardCalibration = candidate
            }
            .onEnded { _ in
                frameMoveStartQuad = nil
                MainThreadStallMonitor.shared.notePublish(source: "screen alignment frame move committed")
            }
    }

    private func point(for corner: BoardAlignmentCorner, in quad: BoardCalibrationQuad) -> CGPoint {
        switch corner {
        case .topLeft: return quad.topLeft
        case .topRight: return quad.topRight
        case .bottomRight: return quad.bottomRight
        case .bottomLeft: return quad.bottomLeft
        }
    }

    private func set(_ point: CGPoint, for corner: BoardAlignmentCorner, in quad: inout BoardCalibrationQuad) {
        switch corner {
        case .topLeft: quad.topLeft = point
        case .topRight: quad.topRight = point
        case .bottomRight: quad.bottomRight = point
        case .bottomLeft: quad.bottomLeft = point
        }
    }

    private func constrainedPoint(_ rawPoint: CGPoint, for corner: BoardAlignmentCorner, in quad: BoardCalibrationQuad) -> CGPoint {
        let gap: CGFloat = 0.015
        var point = BoardPerspectiveMapper.clampedPoint(rawPoint, margin: 0.01)
        switch corner {
        case .topLeft:
            point.x = min(point.x, quad.topRight.x - gap)
            point.y = min(point.y, quad.bottomLeft.y - gap)
        case .topRight:
            point.x = max(point.x, quad.topLeft.x + gap)
            point.y = min(point.y, quad.bottomRight.y - gap)
        case .bottomRight:
            point.x = max(point.x, quad.bottomLeft.x + gap)
            point.y = max(point.y, quad.topRight.y + gap)
        case .bottomLeft:
            point.x = min(point.x, quad.bottomRight.x - gap)
            point.y = max(point.y, quad.topLeft.y + gap)
        }
        return BoardPerspectiveMapper.clampedPoint(point, margin: 0.01)
    }

    private func pixelPoints(size: CGSize) -> [CGPoint] {
        [boardCalibration.topLeft, boardCalibration.topRight, boardCalibration.bottomRight, boardCalibration.bottomLeft]
            .map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }
}

/// Controls remain outside the camera drag canvas. The corner selectors are therefore
/// always tappable even when a physical corner lies behind another overlay or close to
/// the edge of the video viewport.
struct BoardAlignmentControlBar: View {
    @Binding var selectedCorner: BoardAlignmentCorner
    let onReset: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Label("Screen Alignment", systemImage: "square.on.square.dashed")
                .font(.system(size: 11, weight: .black))

            HStack(spacing: 4) {
                ForEach(BoardAlignmentCorner.allCases) { corner in
                    Button {
                        selectedCorner = corner
                        MainThreadStallMonitor.shared.markContext("screen alignment selector pressed: \(corner.rawValue)")
                    } label: {
                        Text(corner.rawValue)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .frame(width: 30, height: 26)
                            .foregroundStyle(selectedCorner == corner ? Color.black : Color.white)
                            .background(
                                selectedCorner == corner ? Color.orange : Color.white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(selectedCorner == corner ? Color.white : Color.white.opacity(0.22), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(corner.spokenName) corner")
                    .accessibilityValue(selectedCorner == corner ? "Selected" : "Not selected")
                }
            }

            Text("Select a corner; each corner moves independently")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)

            Spacer(minLength: 6)

            Button("Reset", action: onReset)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.cyan)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.black.opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.24), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 5)
    }
}

// MARK: - Per-zone visible character colour sampling

struct OCRZoneColourDetection {
    let characterColour: OCRCharacterColour
    let backgroundColour: OCRBackgroundColour
    let pipeline: OCRColourPipeline
    let foregroundFraction: Double
    let sampledColour: OCRSampledColour
}

enum OCRZoneCharacterColourSampler {
    static func detect(in image: CGImage) -> OCRZoneColourDetection? {
        let width = image.width
        let height = image.height
        guard width >= 8, height >= 8 else { return nil }

        let maximumDimension = 320
        let scale = min(1.0, Double(maximumDimension) / Double(max(width, height)))
        let sampleWidth = max(8, Int((Double(width) * scale).rounded()))
        let sampleHeight = max(8, Int((Double(height) * scale).rounded()))
        let bytesPerRow = sampleWidth * 4
        var bytes = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colourSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return nil }

        var borderR: [UInt8] = []
        var borderG: [UInt8] = []
        var borderB: [UInt8] = []
        let borderThickness = max(1, min(sampleWidth, sampleHeight) / 10)
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth where x < borderThickness || x >= sampleWidth - borderThickness || y < borderThickness || y >= sampleHeight - borderThickness {
                let index = y * bytesPerRow + x * 4
                borderR.append(bytes[index])
                borderG.append(bytes[index + 1])
                borderB.append(bytes[index + 2])
            }
        }
        guard !borderR.isEmpty else { return nil }
        let backgroundR = Double(median(borderR))
        let backgroundG = Double(median(borderG))
        let backgroundB = Double(median(borderB))
        let backgroundLuma = luma(backgroundR, backgroundG, backgroundB)

        var foregroundCount = 0
        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var chromaticCount = 0
        let pixelCount = sampleWidth * sampleHeight
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let index = y * bytesPerRow + x * 4
                let r = Double(bytes[index])
                let g = Double(bytes[index + 1])
                let b = Double(bytes[index + 2])
                let colourDistance = sqrt(pow(r - backgroundR, 2) + pow(g - backgroundG, 2) + pow(b - backgroundB, 2))
                let luminanceDistance = abs(luma(r, g, b) - backgroundLuma)
                guard colourDistance >= 42 || luminanceDistance >= 34 else { continue }
                foregroundCount += 1
                sumR += r
                sumG += g
                sumB += b
                if max(r, g, b) - min(r, g, b) > 24 { chromaticCount += 1 }
            }
        }

        let fraction = Double(foregroundCount) / Double(max(1, pixelCount))
        guard foregroundCount >= 24, fraction >= 0.008, fraction <= 0.72 else { return nil }
        let averageR = sumR / Double(foregroundCount)
        let averageG = sumG / Double(foregroundCount)
        let averageB = sumB / Double(foregroundCount)
        let chromaticFraction = Double(chromaticCount) / Double(foregroundCount)
        let character = characterColour(r: averageR, g: averageG, b: averageB, chromaticFraction: chromaticFraction)
        let background = backgroundColour(r: backgroundR, g: backgroundG, b: backgroundB)
        return OCRZoneColourDetection(
            characterColour: character,
            backgroundColour: background,
            pipeline: pipeline(character: character, background: background),
            foregroundFraction: fraction,
            sampledColour: OCRSampledColour(red: averageR / 255, green: averageG / 255, blue: averageB / 255)
        )
    }

    /// Manual eyedropper used by Guided Calibration. The point is in the
    /// perspective-corrected upright loupe image. A 9x9 neighbourhood is averaged so
    /// individual LED scan lines do not produce a misleading colour.
    static func sample(in image: CGImage, normalizedPoint: CGPoint) -> OCRZoneColourDetection? {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth >= 4, sourceHeight >= 4 else { return nil }

        // Build 737: the eyedropper previously rasterised the full 8× loupe and
        // scanned every border pixel on the MainActor. Large guide images could
        // therefore produce a one-second UI heartbeat gap. Colour selection only
        // needs local and border evidence, so use a bounded analysis raster.
        let maximumDimension = 256
        let scale = min(1.0, Double(maximumDimension) / Double(max(sourceWidth, sourceHeight)))
        let width = max(8, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(8, Int((Double(sourceHeight) * scale).rounded()))
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colourSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        let centreX = max(0, min(width - 1, Int((normalizedPoint.x * CGFloat(width - 1)).rounded())))
        let centreY = max(0, min(height - 1, Int((normalizedPoint.y * CGFloat(height - 1)).rounded())))
        let radius = max(2, min(5, min(width, height) / 16))
        var foreground: [(Double, Double, Double)] = []
        for y in max(0, centreY - radius)...min(height - 1, centreY + radius) {
            for x in max(0, centreX - radius)...min(width - 1, centreX + radius) {
                let index = y * bytesPerRow + x * 4
                foreground.append((Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2])))
            }
        }
        guard !foreground.isEmpty else { return nil }

        let borderThickness = max(1, min(width, height) / 10)
        let borderStep = max(1, min(width, height) / 96)
        var borderR: [UInt8] = []
        var borderG: [UInt8] = []
        var borderB: [UInt8] = []
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if x < borderThickness || x >= width - borderThickness || y < borderThickness || y >= height - borderThickness {
                    let index = y * bytesPerRow + x * 4
                    borderR.append(bytes[index])
                    borderG.append(bytes[index + 1])
                    borderB.append(bytes[index + 2])
                }
                x += borderStep
            }
            y += borderStep
        }
        guard !borderR.isEmpty else { return nil }
        let backgroundR = Double(median(borderR))
        let backgroundG = Double(median(borderG))
        let backgroundB = Double(median(borderB))

        // Prefer the brightest/highest-colour-distance half of the pointer sample.
        let ranked = foreground.sorted { lhs, rhs in
            let ld = hypot(hypot(lhs.0 - backgroundR, lhs.1 - backgroundG), lhs.2 - backgroundB)
            let rd = hypot(hypot(rhs.0 - backgroundR, rhs.1 - backgroundG), rhs.2 - backgroundB)
            return ld > rd
        }
        let selected = Array(ranked.prefix(max(4, ranked.count / 2)))
        let r = selected.map { $0.0 }.reduce(0, +) / Double(selected.count)
        let g = selected.map { $0.1 }.reduce(0, +) / Double(selected.count)
        let b = selected.map { $0.2 }.reduce(0, +) / Double(selected.count)
        let distance = hypot(hypot(r - backgroundR, g - backgroundG), b - backgroundB)
        guard distance >= 24 else { return nil }
        let chromaticFraction = (max(r, g, b) - min(r, g, b)) > 24 ? 1.0 : 0.0
        let character = characterColour(r: r, g: g, b: b, chromaticFraction: chromaticFraction)
        let background = backgroundColour(r: backgroundR, g: backgroundG, b: backgroundB)
        return OCRZoneColourDetection(
            characterColour: character,
            backgroundColour: background,
            pipeline: pipeline(character: character, background: background),
            foregroundFraction: Double(selected.count) / Double(max(1, foreground.count)),
            sampledColour: OCRSampledColour(red: r / 255, green: g / 255, blue: b / 255)
        )
    }

    private static func characterColour(r: Double, g: Double, b: Double, chromaticFraction: Double) -> OCRCharacterColour {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        let luminance = luma(r, g, b)
        if luminance < 52 { return .dark }
        if delta < 24 || chromaticFraction < 0.18 {
            return luminance > 145 ? .white : .dark
        }

        let hue: Double
        if maximum == r {
            hue = 60 * (((g - b) / max(1, delta)).truncatingRemainder(dividingBy: 6))
        } else if maximum == g {
            hue = 60 * (((b - r) / max(1, delta)) + 2)
        } else {
            hue = 60 * (((r - g) / max(1, delta)) + 4)
        }
        let normalisedHue = hue < 0 ? hue + 360 : hue
        switch normalisedHue {
        case 0..<18, 345...360: return .red
        case 18..<38: return luminance > 145 ? .orange : .amber
        case 38..<72: return .yellow
        case 72..<165: return .green
        case 165..<205: return .cyan
        case 205..<285: return .blue
        default: return .red
        }
    }

    private static func backgroundColour(r: Double, g: Double, b: Double) -> OCRBackgroundColour {
        let luminance = luma(r, g, b)
        if luminance < 24 { return .black }
        if luminance < 65 {
            return b > r * 1.18 && b > g * 1.08 ? .darkBlue : .dark
        }
        if luminance < 145 { return .grey }
        if luminance > 222 { return .white }
        return .light
    }

    private static func pipeline(character: OCRCharacterColour, background: OCRBackgroundColour) -> OCRColourPipeline {
        if background.isLight {
            return .darkOnLight
        }
        switch character {
        case .red: return .redOnBlack
        case .yellow, .white: return .yellowWhiteOnBlack
        case .amber, .orange: return .amberOrangeOnBlack
        case .green: return .greenOnBlack
        case .blue, .cyan: return .blueCyanOnBlack
        case .black, .dark: return .darkOnLight
        case .auto: return .auto
        }
    }

    private static func median(_ values: [UInt8]) -> UInt8 {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: - Shared geometry helpers

private func polygonPath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() { path.addLine(to: point) }
    path.closeSubpath()
    return path
}

private func boundingPixelRect(_ points: [CGPoint]) -> CGRect {
    let minX = points.map(\.x).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
}

private func centroid(_ points: [CGPoint]) -> CGPoint {
    guard !points.isEmpty else { return .zero }
    let sum = points.reduce(CGPoint.zero) { partial, point in
        CGPoint(x: partial.x + point.x, y: partial.y + point.y)
    }
    return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    max(lower, min(upper, value))
}

#endif
