// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import CoreImage
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

// MARK: - v0.9.1o Calibration Single Zone Resize Handle Gesture Ownership Fix

/// Calibration edit mode shown by the on-screen zone editor.
///
/// v0.9.1k keeps the existing single-zone and penalty-group model, but changes
/// the gesture ownership rules below so the editable zone layer, not background
/// diagnostics, owns drag/tap handling while zones are visible.
enum CalibrationZoneEditMode: String, CaseIterable, Identifiable {
    case single
    case penaltyGroup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "Single Zone"
        case .penaltyGroup: return "Penalty Group"
        }
    }
}

enum PenaltyZoneGroupID: String, CaseIterable, Identifiable {
    case homePenalty1
    case homePenalty2
    case awayPenalty1
    case awayPenalty2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homePenalty1: return "Home P1"
        case .homePenalty2: return "Home P2"
        case .awayPenalty1: return "Away P1"
        case .awayPenalty2: return "Away P2"
        }
    }

    var fullTitle: String {
        switch self {
        case .homePenalty1: return "Home Penalty 1"
        case .homePenalty2: return "Home Penalty 2"
        case .awayPenalty1: return "Away Penalty 1"
        case .awayPenalty2: return "Away Penalty 2"
        }
    }

    var playerKey: OCRRegionKey {
        switch self {
        case .homePenalty1: return .homePenalty1Player
        case .homePenalty2: return .homePenalty2Player
        case .awayPenalty1: return .awayPenalty1Player
        case .awayPenalty2: return .awayPenalty2Player
        }
    }

    var timeKey: OCRRegionKey {
        switch self {
        case .homePenalty1: return .homePenalty1Time
        case .homePenalty2: return .homePenalty2Time
        case .awayPenalty1: return .awayPenalty1Time
        case .awayPenalty2: return .awayPenalty2Time
        }
    }

    var isHome: Bool {
        switch self {
        case .homePenalty1, .homePenalty2: return true
        case .awayPenalty1, .awayPenalty2: return false
        }
    }

    func contains(_ key: OCRRegionKey) -> Bool {
        key == playerKey || key == timeKey
    }
}


// One stateless transaction helper is shared by flat and perspective Calibration overlays.
// Views may keep an in-flight gesture draft, but only the final rectangle is committed through
// the existing RinkLensCalibrationStore-backed layout binding.
enum CalibrationZoneEditTransaction {
    static func resolvedPinchRegion(
        from start: OCRRegion,
        scale rawScale: CGFloat,
        minimumSize: CGFloat = 0.005
    ) -> OCRRegion {
        let scale = max(0.08, min(8, rawScale))
        let centreX = start.x + start.width / 2
        let centreY = start.y + start.height / 2
        let maxWidth = min(1.0, centreX * 2, (1 - centreX) * 2)
        let maxHeight = min(1.0, centreY * 2, (1 - centreY) * 2)
        let newWidth = max(minimumSize, min(maxWidth, start.width * scale))
        let newHeight = max(minimumSize, min(maxHeight, start.height * scale))

        var resolved = start
        resolved.width = newWidth
        resolved.height = newHeight
        resolved.x = max(0, min(1 - newWidth, centreX - newWidth / 2))
        resolved.y = max(0, min(1 - newHeight, centreY - newHeight / 2))
        return resolved
    }

    static func recordCommit(
        key: OCRRegionKey,
        operation: String,
        event: String,
        start: OCRRegion,
        resolved: OCRRegion,
        source: String,
        reason: String
    ) {
        RinkLensOCREvidenceJournal.shared.recordZoneEdit(
            field: key.rawValue,
            operation: operation,
            before: .init(start),
            after: .init(resolved),
            detail: reason
        )
        RinkLensStructuredEventLogger.shared.record(
            domain: .calibration,
            event: event,
            entityID: key.rawValue,
            previous: values(for: start),
            next: values(for: resolved),
            source: source,
            reason: reason
        )
        MainThreadStallMonitor.shared.notePublish(source: "zone edit committed once")
        MainThreadStallMonitor.shared.markContext("zone \(operation) committed: \(key.rawValue)")
    }

    static func recordGroupCommit(
        groupID: PenaltyZoneGroupID,
        operation: String,
        event: String,
        startPlayer: OCRRegion,
        startTime: OCRRegion,
        resolvedPlayer: OCRRegion,
        resolvedTime: OCRRegion,
        source: String,
        reason: String
    ) {
        let correlationID = UUID().uuidString
        RinkLensOCREvidenceJournal.shared.recordZoneEdit(
            field: groupID.playerKey.rawValue,
            operation: operation,
            before: .init(startPlayer),
            after: .init(resolvedPlayer),
            correlationID: correlationID,
            detail: reason
        )
        RinkLensOCREvidenceJournal.shared.recordZoneEdit(
            field: groupID.timeKey.rawValue,
            operation: operation,
            before: .init(startTime),
            after: .init(resolvedTime),
            correlationID: correlationID,
            detail: reason
        )
        var previousValues = values(for: startPlayer, prefix: "player")
        previousValues.merge(values(for: startTime, prefix: "time")) { current, _ in current }
        var nextValues = values(for: resolvedPlayer, prefix: "player")
        nextValues.merge(values(for: resolvedTime, prefix: "time")) { current, _ in current }
        RinkLensStructuredEventLogger.shared.record(
            domain: .calibration,
            event: event,
            entityID: groupID.rawValue,
            previous: previousValues,
            next: nextValues,
            source: source,
            reason: reason
        )
        MainThreadStallMonitor.shared.notePublish(source: "penalty group edit committed once")
        MainThreadStallMonitor.shared.markContext("zone \(operation) committed: \(groupID.rawValue)")
    }

    private static func values(for region: OCRRegion, prefix: String? = nil) -> [String: String] {
        func key(_ field: String) -> String {
            guard let prefix else { return field }
            return "\(prefix).\(field)"
        }
        return [
            key("x"): String(format: "%.4f", Double(region.x)),
            key("y"): String(format: "%.4f", Double(region.y)),
            key("width"): String(format: "%.4f", Double(region.width)),
            key("height"): String(format: "%.4f", Double(region.height)),
            key("rotationDegrees"): String(format: "%.3f", Double(region.rotationDegrees))
        ]
    }
}

struct EditableRegionOverlay: View {
    @Binding var layout: ScoreboardOCRLayout
    @Binding var selectedKey: OCRRegionKey
    @Binding var zoneEditMode: CalibrationZoneEditMode
    @Binding var selectedPenaltyGroup: PenaltyZoneGroupID
    let previewText: [OCRRegionKey: String]
    let recognizerByRegion: [OCRRegionKey: RecognitionStrategy]
    let fieldConfidence: [OCRRegionKey: OCRFieldConfidence]
    let displayOptions: OCRDiagnosticDisplayOptions
    let detectionStates: [OCRRegionKey: OCRRegionDetectionState]
    let interactionEpoch: Int
    let isEditable: Bool
    let lockedKeys: Set<OCRRegionKey>
    let onReassign: (OCRRegionKey, OCRRegionKey) -> Void

    @State private var pinchKey: OCRRegionKey?
    @State private var pinchStartRegion: OCRRegion?
    @State private var pinchPreviewScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .allowsHitTesting(false)

                ForEach(orderedKeys) { key in
                    RegionBox(
                        key: key,
                        region: binding(for: key),
                        selectedKey: $selectedKey,
                        zoneEditMode: $zoneEditMode,
                        proxySize: proxy.size,
                        previewText: previewText[key] ?? "--",
                        recognizer: recognizerByRegion[key] ?? .vision,
                        confidence: fieldConfidence[key],
                        displayOptions: displayOptions,
                        detectionState: detectionStates[key] ?? .none,
                        interactionEpoch: interactionEpoch,
                        isEditable: isEditable,
                        isLocked: lockedKeys.contains(key),
                        onReassign: onReassign,
                        previewScale: selectedKey == key ? pinchPreviewScale : 1,
                        externalPinchActive: pinchStartRegion != nil && pinchKey == key
                    )
                }

                if zoneEditMode == .penaltyGroup {
                    let groupID = selectedPenaltyGroup
                    PenaltyZoneGroupBox(
                        groupID: groupID,
                        playerRegion: binding(for: groupID.playerKey),
                        timeRegion: binding(for: groupID.timeKey),
                        selectedKey: $selectedKey,
                        selectedPenaltyGroup: $selectedPenaltyGroup,
                        proxySize: proxy.size,
                        displayOptions: displayOptions,
                        interactionEpoch: interactionEpoch,
                        isEditable: isEditable,
                        isLocked: lockedKeys.contains(groupID.playerKey) || lockedKeys.contains(groupID.timeKey),
                        onCommit: { player, time in
                            commitPenaltyGroup(groupID, player: player, time: time)
                        }
                    )
                    .zIndex(50)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(selectedZonePinchGesture)
            .allowsHitTesting(isEditable && displayOptions.showOCRBoxes)
            .onAppear {
                MainThreadStallMonitor.shared.markContext("zone editor shown")
                MainThreadStallMonitor.shared.trace("calibration overlay hit testing enabled")
            }
            .onDisappear {
                MainThreadStallMonitor.shared.markContext("zone editor hidden")
                MainThreadStallMonitor.shared.trace("calibration overlay hit testing disabled")
            }
        }
    }

    private var selectedZonePinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isEditable,
                      displayOptions.showOCRBoxes,
                      zoneEditMode == .single,
                      !lockedKeys.contains(selectedKey) else { return }
                if pinchStartRegion == nil {
                    pinchKey = selectedKey
                    pinchStartRegion = layout[selectedKey]
                    MainThreadStallMonitor.shared.markContext("zone pinch draft started: \(selectedKey.rawValue)")
                }
                pinchPreviewScale = max(0.08, min(8, CGFloat(value)))
            }
            .onEnded { value in
                let key = pinchKey
                let start = pinchStartRegion
                pinchKey = nil
                pinchStartRegion = nil
                pinchPreviewScale = 1
                guard let key, let start else { return }
                let resolved = CalibrationZoneEditTransaction.resolvedPinchRegion(
                    from: start,
                    scale: CGFloat(value)
                )
                guard !start.isApproximatelyEqual(to: resolved) else { return }
                binding(for: key).wrappedValue = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "pinch-resize",
                    event: "calibration_zone_pinch_committed",
                    start: start,
                    resolved: resolved,
                    source: "EditableRegionOverlay.selectedZonePinchGesture",
                    reason: "Operator pinched the selected calibration zone; local visual draft committed once to RinkLensCalibrationStore"
                )
            }
    }

    private var orderedKeys: [OCRRegionKey] {
        let allKeys = OCRRegionKey.calibrationCases
        let selectedGroupKeys: Set<OCRRegionKey> = zoneEditMode == .penaltyGroup
            ? [selectedPenaltyGroup.playerKey, selectedPenaltyGroup.timeKey]
            : []
        let visibleKeys = allKeys.filter { !selectedGroupKeys.contains($0) }
        // Keep the selected item last so it wins overlapping hit-test regions.
        return visibleKeys.filter { $0 != selectedKey } + visibleKeys.filter { $0 == selectedKey }
    }

    private func binding(for key: OCRRegionKey) -> Binding<OCRRegion> {
        Binding(
            get: { layout[key] },
            set: { newValue in
                guard !lockedKeys.contains(key) else {
                    MainThreadStallMonitor.shared.markContext("overlay write blocked: locked zone \(key.rawValue)")
                    return
                }
                guard !layout[key].isApproximatelyEqual(to: newValue) else { return }
                MainThreadStallMonitor.shared.markContext("overlay write path: \(key.rawValue)")
                var updatedLayout = layout
                updatedLayout[key] = newValue
                layout = updatedLayout
            }
        )
    }

    private func commitPenaltyGroup(_ groupID: PenaltyZoneGroupID, player: OCRRegion, time: OCRRegion) {
        guard !lockedKeys.contains(groupID.playerKey), !lockedKeys.contains(groupID.timeKey) else { return }
        guard !layout[groupID.playerKey].isApproximatelyEqual(to: player)
                || !layout[groupID.timeKey].isApproximatelyEqual(to: time) else { return }
        var updatedLayout = layout
        updatedLayout[groupID.playerKey] = player
        updatedLayout[groupID.timeKey] = time
        layout = updatedLayout
    }
}

struct RegionBox: View {
    let key: OCRRegionKey
    @Binding var region: OCRRegion
    @Binding var selectedKey: OCRRegionKey
    @Binding var zoneEditMode: CalibrationZoneEditMode
    let proxySize: CGSize
    let previewText: String
    let recognizer: RecognitionStrategy
    let confidence: OCRFieldConfidence?
    let displayOptions: OCRDiagnosticDisplayOptions
    let detectionState: OCRRegionDetectionState
    let interactionEpoch: Int
    let isEditable: Bool
    let isLocked: Bool
    let onReassign: (OCRRegionKey, OCRRegionKey) -> Void
    let previewScale: CGFloat
    let externalPinchActive: Bool

    @State private var dragStartRegion: OCRRegion?
    @State private var dragDraftRegion: OCRRegion?
    @State private var resizeStartRegion: OCRRegion?
    @State private var resizeDraftRegion: OCRRegion?
    @State private var isResizingSingleZone = false
    @State private var rotationStartDegrees: CGFloat?
    @State private var rotationDraftRegion: OCRRegion?
    @State private var lastDragTraceAt: CFAbsoluteTime = 0

    private let minimumRegionSize: CGFloat = 0.005
    private let maximumRotationDegrees: CGFloat = 30
    private let minimumVisualSize: CGFloat = 8
    private let minimumFingerHitSize: CGFloat = 48

    var body: some View {
        let frame = scaledFrame
        let visualWidth = max(frame.width, minimumVisualSize)
        let visualHeight = max(frame.height, minimumVisualSize)
        let hitWidth = max(visualWidth, minimumFingerHitSize)
        let hitHeight = max(visualHeight, minimumFingerHitSize)

        ZStack(alignment: .center) {
            ZStack(alignment: .bottomTrailing) {
                if displayOptions.showOCRBoxes {
                    Rectangle()
                        .stroke(borderColor, lineWidth: selectedKey == key ? 3 : 2)
                        .background(selectedKey == key ? Color.yellow.opacity(0.08) : Color.clear)
                        .overlay(
                            Rectangle()
                                .stroke(detectionBorderColor, lineWidth: detectionBorderLineWidth)
                                .background(detectionBackgroundColor)
                                .padding(-4)
                        )
                }

                if displayOptions.showOCRBoxes {
                    // UX13t: keep the zones visually identifiable, but do not
                    // duplicate live OCR values inside every OCR box. The single
                    // source for clock/home/away/period/hash/raw/accepted/displayed
                    // values is now CalibrationLiveOCRDiagnosticsPill above the
                    // bottom selector.
                    minimalZoneNameLabel
                        .frame(width: max(0, visualWidth - 4), alignment: .leading)
                        .offset(x: 3, y: 3)
                        .clipped()
                        .allowsHitTesting(false)
                }

                if displayOptions.showOCRBoxes && isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(4)
                        .background(.black.opacity(0.72), in: Circle())
                        .offset(x: -3, y: -3)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: visualWidth, height: visualHeight)
            .rotationEffect(.degrees(displayedRegion.rotationDegrees))
            .allowsHitTesting(false)

            if displayOptions.showOCRBoxes && isEditable && !isLocked && zoneEditMode == .single && selectedKey == key {
                singleZoneResizeHandle
                    // Match the penalty-group handle placement: the centre sits slightly
                    // inside the bottom-right corner and the hit target hangs out over
                    // the corner, instead of sitting fully inside the OCR box.
                    .offset(x: visualWidth / 2 - 22, y: visualHeight / 2 - 22)
                    .highPriorityGesture(resizeGesture)
                    .zIndex(60)
            }
        }
        .frame(width: hitWidth, height: hitHeight)
        .position(x: frame.midX, y: frame.midY)
        .scaleEffect(previewScale)
        .contentShape(Rectangle())
        .zIndex(selectedKey == key ? 20 : 10)
        .simultaneousGesture(doubleTapResetRotationGesture)
        // Match grouped-zone gesture ownership: tap/selection is high priority,
        // movement is a normal drag, and the resize handle keeps high priority.
        // This stops the zero-distance move drag from stealing resize touches.
        .highPriorityGesture(selectionTapGesture)
        .gesture(dragGesture)
        .simultaneousGesture(rotationGesture)
        .allowsHitTesting(isEditable && displayOptions.showOCRBoxes)
        .task(id: interactionEpoch) {
            await Task.yield()
            dragStartRegion = nil
            dragDraftRegion = nil
            resizeStartRegion = nil
            resizeDraftRegion = nil
            isResizingSingleZone = false
            rotationStartDegrees = nil
            rotationDraftRegion = nil
            MainThreadStallMonitor.shared.traceRenderPreviewToggle("zone interaction epoch reset completed: \(key.rawValue)")
        }
        .onChange(of: externalPinchActive) { _, active in
            guard active else { return }
            dragStartRegion = nil
            dragDraftRegion = nil
            resizeStartRegion = nil
            resizeDraftRegion = nil
            rotationStartDegrees = nil
            rotationDraftRegion = nil
            isResizingSingleZone = false
        }
    }

    private var displayedRegion: OCRRegion {
        rotationDraftRegion ?? resizeDraftRegion ?? dragDraftRegion ?? region
    }

    private var scaledFrame: CGRect {
        CGRect(
            x: displayedRegion.x * max(1, proxySize.width),
            y: displayedRegion.y * max(1, proxySize.height),
            width: displayedRegion.width * max(1, proxySize.width),
            height: displayedRegion.height * max(1, proxySize.height)
        )
    }

    private var doubleTapResetRotationGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                guard isEditable, !isLocked, displayOptions.showOCRBoxes else { return }
                zoneEditMode = .single
                selectedKey = key
                let start = region
                var resolved = start
                resolved.rotationDegrees = 0
                guard !start.isApproximatelyEqual(to: resolved) else { return }
                region = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "rotation-reset",
                    event: "calibration_zone_rotation_reset",
                    start: start,
                    resolved: resolved,
                    source: "RegionBox.doubleTapResetRotationGesture",
                    reason: "Operator reset the selected calibration-zone rotation; one final value committed to RinkLensCalibrationStore"
                )
            }
    }

    private var minimalZoneNameLabel: some View {
        Text(shortRegionLabel)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.50), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(selectedKey == key ? Color.blue.opacity(0.95) : Color.white.opacity(0.28), lineWidth: 0.7)
            )
            .accessibilityLabel("\(key.likelyTitle) OCR zone")
    }

    private var shortRegionLabel: String {
        switch key {
        case .clock: return "CLK"
        case .homeScore: return "H"
        case .awayScore: return "A"
        case .period: return "PER"
        case .homePenalty1Player: return "HP1"
        case .homePenalty1Time: return "HT1"
        case .homePenalty2Player: return "HP2"
        case .homePenalty2Time: return "HT2"
        case .awayPenalty1Player: return "AP1"
        case .awayPenalty1Time: return "AT1"
        case .awayPenalty2Player: return "AP2"
        case .awayPenalty2Time: return "AT2"
        default:
            return key.likelyTitle
        }
    }

    private var isDetectionActiveForDisplay: Bool {
        switch detectionState {
        case .none:
            return false
        case .hashingActive, .ocrScheduled, .safetyResync, .failed:
            return true
        }
    }

    private var detectionBorderColor: Color {
        switch detectionState {
        case .none:
            return .gray.opacity(0.75)
        case .hashingActive:
            return .cyan.opacity(0.95)
        case .ocrScheduled:
            return .green.opacity(0.95)
        case .safetyResync:
            return .orange.opacity(0.95)
        case .failed:
            return .red.opacity(0.95)
        }
    }

    private var detectionBorderLineWidth: CGFloat {
        switch detectionState {
        case .none:
            return 5
        case .hashingActive, .ocrScheduled, .safetyResync, .failed:
            return 4
        }
    }

    private var detectionBackgroundColor: Color {
        switch detectionState {
        case .none:
            return .gray.opacity(0.08)
        case .hashingActive:
            return .cyan.opacity(0.06)
        case .ocrScheduled:
            return .green.opacity(0.06)
        case .safetyResync:
            return .orange.opacity(0.06)
        case .failed:
            return .red.opacity(0.06)
        }
    }

    private var borderColor: Color {
        if selectedKey == key { return .blue.opacity(0.95) }
        guard isDetectionActiveForDisplay else { return .gray.opacity(0.85) }
        guard displayOptions.showRecogniserColours else { return .white.opacity(0.9) }
        return recognizerColor
    }

    private var singleZoneResizeHandle: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.96))
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.38), radius: 7, x: 0, y: 2)

            Circle()
                .stroke(.white.opacity(0.86), lineWidth: 2)
                .frame(width: 42, height: 42)

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 68, height: 68)
        .contentShape(Circle())
        .accessibilityLabel("Resize \(key.likelyTitle) zone")
    }

    private var recognizerColor: Color {
        switch recognizer {
        case .none:
            return .gray
        case .vision:
            return .blue
        case .mlKit:
            return .green
        case .segmented:
            return .purple
        case .templateDigits:
            return .orange
        }
    }

    private var selectionTapGesture: some Gesture {
        TapGesture(count: 1)
            .onEnded {
                guard isEditable, displayOptions.showOCRBoxes, !isResizingSingleZone else { return }
                if zoneEditMode != .single {
                    zoneEditMode = .single
                    MainThreadStallMonitor.shared.markContext("zone edit mode: single")
                }
                selectedKey = key
                MainThreadStallMonitor.shared.markContext("zone hit test tap: \(key.rawValue)")
                MainThreadStallMonitor.shared.markContext("zone selected: \(key.rawValue)")
                MainThreadStallMonitor.shared.notePublish(source: "calibration zone selected")
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard isEditable, !isLocked, displayOptions.showOCRBoxes,
                      !isResizingSingleZone, !externalPinchActive else { return }
                if zoneEditMode != .single {
                    zoneEditMode = .single
                    MainThreadStallMonitor.shared.markContext("zone edit mode: single")
                }
                if selectedKey != key {
                    selectedKey = key
                    MainThreadStallMonitor.shared.markContext("zone selected: \(key.rawValue)")
                    MainThreadStallMonitor.shared.notePublish(source: "calibration zone selected")
                }
                if dragStartRegion == nil {
                    dragStartRegion = region
                    MainThreadStallMonitor.shared.markContext("zone drag started: \(key.rawValue)")
                }
                guard let start = dragStartRegion else { return }

                let dx = value.translation.width / max(1, proxySize.width)
                let dy = value.translation.height / max(1, proxySize.height)
                var updated = start
                updated.x = clamp(start.x + dx, min: 0, max: 1 - start.width)
                updated.y = clamp(start.y + dy, min: 0, max: 1 - start.height)
                dragDraftRegion = updated

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastDragTraceAt > 0.25 {
                    lastDragTraceAt = now
                    MainThreadStallMonitor.shared.trace(
                        String(format: "zone drag draft: %@ x=%.4f y=%.4f", key.rawValue, Double(updated.x), Double(updated.y))
                    )
                }
            }
            .onEnded { _ in
                let start = dragStartRegion
                let resolved = dragDraftRegion
                dragStartRegion = nil
                dragDraftRegion = nil
                guard let start, let resolved, !start.isApproximatelyEqual(to: resolved) else { return }
                region = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "move",
                    event: "calibration_zone_move_committed",
                    start: start,
                    resolved: resolved,
                    source: "RegionBox.dragGesture",
                    reason: "Operator moved a calibration zone; local draft committed once to RinkLensCalibrationStore"
                )
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                guard isEditable, !isLocked, displayOptions.showOCRBoxes, !externalPinchActive else { return }
                isResizingSingleZone = true
                if zoneEditMode != .single { zoneEditMode = .single }
                selectedKey = key
                if resizeStartRegion == nil {
                    resizeStartRegion = region
                    MainThreadStallMonitor.shared.markContext("zone resize started: \(key.rawValue)")
                }
                guard let start = resizeStartRegion else { return }
                var updated = start
                updated.width = clamp(
                    start.width + value.translation.width / max(1, proxySize.width),
                    min: minimumRegionSize,
                    max: 1 - start.x
                )
                updated.height = clamp(
                    start.height + value.translation.height / max(1, proxySize.height),
                    min: minimumRegionSize,
                    max: 1 - start.y
                )
                resizeDraftRegion = updated

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastDragTraceAt > 0.25 {
                    lastDragTraceAt = now
                    MainThreadStallMonitor.shared.trace(
                        String(
                            format: "zone resize draft: %@ x=%.4f y=%.4f w=%.4f h=%.4f",
                            key.rawValue,
                            Double(updated.x),
                            Double(updated.y),
                            Double(updated.width),
                            Double(updated.height)
                        )
                    )
                }
            }
            .onEnded { _ in
                let start = resizeStartRegion
                let resolved = resizeDraftRegion
                resizeStartRegion = nil
                resizeDraftRegion = nil
                isResizingSingleZone = false
                guard let start, let resolved, !start.isApproximatelyEqual(to: resolved) else { return }
                region = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "resize",
                    event: "calibration_zone_resize_committed",
                    start: start,
                    resolved: resolved,
                    source: "RegionBox.resizeGesture",
                    reason: "Operator resized a calibration zone with the corner handle; local draft committed once to RinkLensCalibrationStore"
                )
            }
    }


    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard isEditable, !isLocked, displayOptions.showOCRBoxes, !externalPinchActive else { return }
                selectedKey = key
                if rotationStartDegrees == nil {
                    rotationStartDegrees = region.rotationDegrees
                    MainThreadStallMonitor.shared.markContext("zone rotation started: \(key.rawValue)")
                }
                let startDegrees = rotationStartDegrees ?? 0
                var updated = region
                updated.rotationDegrees = clamp(
                    startDegrees + CGFloat(value.degrees),
                    min: -maximumRotationDegrees,
                    max: maximumRotationDegrees
                )
                rotationDraftRegion = updated
            }
            .onEnded { _ in
                let startDegrees = rotationStartDegrees
                let resolved = rotationDraftRegion
                rotationStartDegrees = nil
                rotationDraftRegion = nil
                guard let startDegrees, let resolved else { return }
                var start = region
                start.rotationDegrees = startDegrees
                guard !start.isApproximatelyEqual(to: resolved) else { return }
                region = resolved
                CalibrationZoneEditTransaction.recordCommit(
                    key: key,
                    operation: "rotation",
                    event: "calibration_zone_rotation_committed",
                    start: start,
                    resolved: resolved,
                    source: "RegionBox.rotationGesture",
                    reason: "Operator rotated a calibration zone; local draft committed once to RinkLensCalibrationStore"
                )
            }
    }


    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

struct PenaltyZoneGroupBox: View {
    let groupID: PenaltyZoneGroupID
    @Binding var playerRegion: OCRRegion
    @Binding var timeRegion: OCRRegion
    @Binding var selectedKey: OCRRegionKey
    @Binding var selectedPenaltyGroup: PenaltyZoneGroupID
    let proxySize: CGSize
    let displayOptions: OCRDiagnosticDisplayOptions
    let interactionEpoch: Int
    let isEditable: Bool
    let isLocked: Bool
    let onCommit: (OCRRegion, OCRRegion) -> Void

    @State private var dragStartPlayer: OCRRegion?
    @State private var dragStartTime: OCRRegion?
    @State private var dragDraftPlayer: OCRRegion?
    @State private var dragDraftTime: OCRRegion?
    @State private var resizeStartPlayer: OCRRegion?
    @State private var resizeStartTime: OCRRegion?
    @State private var resizeDraftPlayer: OCRRegion?
    @State private var resizeDraftTime: OCRRegion?
    @State private var isResizingGroup = false
    @State private var lastGroupDragTraceAt: CFAbsoluteTime = 0
    @State private var lastGroupResizeTraceAt: CFAbsoluteTime = 0

    private let minimumRegionSize: CGFloat = 0.005
    private let minimumFingerHitSize: CGFloat = 56

    var body: some View {
        let playerFrame = scaledFrame(for: displayedPlayerRegion)
        let timeFrame = scaledFrame(for: displayedTimeRegion)
        let groupFrame = playerFrame.union(timeFrame).insetBy(dx: -10, dy: -10)
        let visualWidth = max(groupFrame.width, minimumFingerHitSize)
        let visualHeight = max(groupFrame.height, minimumFingerHitSize)
        let isSelected = selectedPenaltyGroup == groupID

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(groupColor, style: StrokeStyle(lineWidth: isSelected ? 4 : 2, dash: isSelected ? [] : [8, 5]))
                .background(groupColor.opacity(isSelected ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(isSelected ? 0.72 : 0.25), lineWidth: isSelected ? 1.5 : 1)
                )

            label
                .offset(x: 8, y: -26)
                .allowsHitTesting(false)

            childBox(title: "Player", frame: playerFrame, groupFrame: groupFrame)
            childBox(title: "Time", frame: timeFrame, groupFrame: groupFrame)

            if isEditable && !isLocked && displayOptions.showOCRBoxes && isSelected {
                groupResizeHandle
                    .position(x: visualWidth - 22, y: visualHeight - 22)
                    .highPriorityGesture(resizeGesture)
            }
        }
        .frame(width: visualWidth, height: visualHeight)
        .position(x: groupFrame.midX, y: groupFrame.midY)
        .contentShape(Rectangle())
        .highPriorityGesture(selectionTapGesture)
        .gesture(dragGesture)
        .allowsHitTesting(isEditable && displayOptions.showOCRBoxes)
        .task(id: interactionEpoch) {
            await Task.yield()
            dragStartPlayer = nil
            dragStartTime = nil
            dragDraftPlayer = nil
            dragDraftTime = nil
            resizeStartPlayer = nil
            resizeStartTime = nil
            resizeDraftPlayer = nil
            resizeDraftTime = nil
            isResizingGroup = false
            MainThreadStallMonitor.shared.traceRenderPreviewToggle("zone group interaction epoch reset completed: \(groupID.rawValue)")
        }
    }

    private var displayedPlayerRegion: OCRRegion {
        resizeDraftPlayer ?? dragDraftPlayer ?? playerRegion
    }

    private var displayedTimeRegion: OCRRegion {
        resizeDraftTime ?? dragDraftTime ?? timeRegion
    }

    private var selectionTapGesture: some Gesture {
        TapGesture(count: 1)
            .onEnded {
                guard isEditable, displayOptions.showOCRBoxes else { return }
                selectedPenaltyGroup = groupID
                selectedKey = groupID.playerKey
                MainThreadStallMonitor.shared.markContext("zone hit test tap: \(groupID.rawValue)")
                MainThreadStallMonitor.shared.markContext("zone selected: \(groupID.rawValue)")
                MainThreadStallMonitor.shared.notePublish(source: "penalty group selected")
            }
    }

    private var label: some View {
        Text("\(groupID.fullTitle.uppercased()) GROUP")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(groupColor.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 1))
    }

    private func childBox(title: String, frame: CGRect, groupFrame: CGRect) -> some View {
        let local = CGRect(
            x: frame.minX - groupFrame.minX,
            y: frame.minY - groupFrame.minY,
            width: frame.width,
            height: frame.height
        )
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(.white.opacity(0.8), lineWidth: 1.5)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(3),
                alignment: .topLeading
            )
            .frame(width: Swift.max(CGFloat(10), local.width), height: Swift.max(CGFloat(10), local.height))
            .position(x: local.midX, y: local.midY)
            .allowsHitTesting(false)
    }

    private var groupColor: Color {
        groupID.isHome ? .blue : .orange
    }

    private var groupResizeHandle: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.96))
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.38), radius: 7, x: 0, y: 2)

            Circle()
                .stroke(.white.opacity(0.86), lineWidth: 2)
                .frame(width: 42, height: 42)

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: 68, height: 68)
        .contentShape(Circle())
        .accessibilityLabel("Resize \(groupID.fullTitle) group")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard isEditable, !isLocked, displayOptions.showOCRBoxes, !isResizingGroup else { return }
                if dragStartPlayer == nil {
                    dragStartPlayer = playerRegion
                    MainThreadStallMonitor.shared.markContext("zone drag started: \(groupID.rawValue)")
                }
                if dragStartTime == nil { dragStartTime = timeRegion }
                guard let startPlayer = dragStartPlayer, let startTime = dragStartTime else { return }

                let dx = value.translation.width / Swift.max(CGFloat(1), proxySize.width)
                let dy = value.translation.height / Swift.max(CGFloat(1), proxySize.height)
                var updatedPlayer = startPlayer
                var updatedTime = startTime
                updatedPlayer.x = clamp(startPlayer.x + dx, min: 0, max: 1 - startPlayer.width)
                updatedPlayer.y = clamp(startPlayer.y + dy, min: 0, max: 1 - startPlayer.height)
                updatedTime.x = clamp(startTime.x + dx, min: 0, max: 1 - startTime.width)
                updatedTime.y = clamp(startTime.y + dy, min: 0, max: 1 - startTime.height)
                dragDraftPlayer = updatedPlayer
                dragDraftTime = updatedTime
                selectedPenaltyGroup = groupID
                selectedKey = groupID.playerKey

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastGroupDragTraceAt > 0.25 {
                    lastGroupDragTraceAt = now
                    MainThreadStallMonitor.shared.trace(
                        String(format: "zone group move draft: %@ player=(%.4f,%.4f) time=(%.4f,%.4f)", groupID.rawValue, Double(updatedPlayer.x), Double(updatedPlayer.y), Double(updatedTime.x), Double(updatedTime.y))
                    )
                }
            }
            .onEnded { _ in
                guard !isResizingGroup else { return }
                let startPlayer = dragStartPlayer
                let startTime = dragStartTime
                let resolvedPlayer = dragDraftPlayer
                let resolvedTime = dragDraftTime
                dragStartPlayer = nil
                dragStartTime = nil
                dragDraftPlayer = nil
                dragDraftTime = nil
                guard let startPlayer, let startTime, let resolvedPlayer, let resolvedTime else { return }
                guard !startPlayer.isApproximatelyEqual(to: resolvedPlayer)
                        || !startTime.isApproximatelyEqual(to: resolvedTime) else { return }
                onCommit(resolvedPlayer, resolvedTime)
                CalibrationZoneEditTransaction.recordGroupCommit(
                    groupID: groupID,
                    operation: "group-move",
                    event: "calibration_penalty_group_move_committed",
                    startPlayer: startPlayer,
                    startTime: startTime,
                    resolvedPlayer: resolvedPlayer,
                    resolvedTime: resolvedTime,
                    source: "PenaltyZoneGroupBox.dragGesture",
                    reason: "Operator moved a penalty group; both local drafts committed atomically to RinkLensCalibrationStore"
                )
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                guard isEditable, !isLocked, displayOptions.showOCRBoxes else { return }
                isResizingGroup = true
                if resizeStartPlayer == nil {
                    resizeStartPlayer = playerRegion
                    MainThreadStallMonitor.shared.markContext("zone resize started: \(groupID.rawValue)")
                }
                if resizeStartTime == nil { resizeStartTime = timeRegion }
                guard let startPlayer = resizeStartPlayer, let startTime = resizeStartTime else { return }

                let startPlayerFrame = scaledFrame(for: startPlayer)
                let startTimeFrame = scaledFrame(for: startTime)
                let startGroup = startPlayerFrame.union(startTimeFrame).insetBy(dx: -10, dy: -10)
                let proposedWidth = Swift.max(CGFloat(20), startGroup.width + value.translation.width)
                let proposedHeight = Swift.max(CGFloat(20), startGroup.height + value.translation.height)
                let scaleX = proposedWidth / Swift.max(CGFloat(1), startGroup.width)
                let scaleY = proposedHeight / Swift.max(CGFloat(1), startGroup.height)

                let updatedPlayer = scaledRegion(startPlayer, startGroup: startGroup, scaleX: scaleX, scaleY: scaleY)
                let updatedTime = scaledRegion(startTime, startGroup: startGroup, scaleX: scaleX, scaleY: scaleY)
                resizeDraftPlayer = updatedPlayer
                resizeDraftTime = updatedTime
                selectedPenaltyGroup = groupID
                selectedKey = groupID.playerKey

                let now = CFAbsoluteTimeGetCurrent()
                if now - lastGroupResizeTraceAt > 0.25 {
                    lastGroupResizeTraceAt = now
                    MainThreadStallMonitor.shared.trace(
                        String(
                            format: "zone group resize draft: %@ scale=(%.3f,%.3f) player=(%.4f,%.4f,%.4f,%.4f) time=(%.4f,%.4f,%.4f,%.4f)",
                            groupID.rawValue,
                            Double(scaleX),
                            Double(scaleY),
                            Double(updatedPlayer.x),
                            Double(updatedPlayer.y),
                            Double(updatedPlayer.width),
                            Double(updatedPlayer.height),
                            Double(updatedTime.x),
                            Double(updatedTime.y),
                            Double(updatedTime.width),
                            Double(updatedTime.height)
                        )
                    )
                }
            }
            .onEnded { _ in
                let startPlayer = resizeStartPlayer
                let startTime = resizeStartTime
                let resolvedPlayer = resizeDraftPlayer
                let resolvedTime = resizeDraftTime
                resizeStartPlayer = nil
                resizeStartTime = nil
                resizeDraftPlayer = nil
                resizeDraftTime = nil
                isResizingGroup = false
                guard let startPlayer, let startTime, let resolvedPlayer, let resolvedTime else { return }
                guard !startPlayer.isApproximatelyEqual(to: resolvedPlayer)
                        || !startTime.isApproximatelyEqual(to: resolvedTime) else { return }
                onCommit(resolvedPlayer, resolvedTime)
                CalibrationZoneEditTransaction.recordGroupCommit(
                    groupID: groupID,
                    operation: "group-resize",
                    event: "calibration_penalty_group_resize_committed",
                    startPlayer: startPlayer,
                    startTime: startTime,
                    resolvedPlayer: resolvedPlayer,
                    resolvedTime: resolvedTime,
                    source: "PenaltyZoneGroupBox.resizeGesture",
                    reason: "Operator resized a penalty group; both local drafts committed atomically to RinkLensCalibrationStore"
                )
            }
    }

    private func scaledFrame(for region: OCRRegion) -> CGRect {
        CGRect(
            x: region.x * Swift.max(CGFloat(1), proxySize.width),
            y: region.y * Swift.max(CGFloat(1), proxySize.height),
            width: region.width * Swift.max(CGFloat(1), proxySize.width),
            height: region.height * Swift.max(CGFloat(1), proxySize.height)
        )
    }

    private func scaledRegion(_ source: OCRRegion, startGroup: CGRect, scaleX: CGFloat, scaleY: CGFloat) -> OCRRegion {
        let frame = scaledFrame(for: source)
        let localX = frame.minX - startGroup.minX
        let localY = frame.minY - startGroup.minY
        let newFrame = CGRect(
            x: startGroup.minX + localX * scaleX,
            y: startGroup.minY + localY * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY
        )

        var output = source
        output.width = clamp(newFrame.width / Swift.max(CGFloat(1), proxySize.width), min: minimumRegionSize, max: 1)
        output.height = clamp(newFrame.height / Swift.max(CGFloat(1), proxySize.height), min: minimumRegionSize, max: 1)
        output.x = clamp(newFrame.minX / Swift.max(CGFloat(1), proxySize.width), min: 0, max: 1 - output.width)
        output.y = clamp(newFrame.minY / Swift.max(CGFloat(1), proxySize.height), min: 0, max: 1 - output.height)
        return output
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

#endif
