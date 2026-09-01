// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import UIKit
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import CoreImage
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

struct PlusMinusValueControl: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            Button {
                value = max(range.lowerBound, value - 1)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Text("\(value)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 34)

            Button {
                value = min(range.upperBound, value + 1)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }
}

struct WheelIntPicker: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var width: CGFloat = 84
    var height: CGFloat = 96

    var body: some View {
        Picker("Value", selection: $value) {
            ForEach(Array(range), id: \.self) { number in
                Text(number == 0 ? "--" : "\(number)").tag(number)
            }
        }
        .pickerStyle(.wheel)
        .frame(width: width, height: height)
        .clipped()
    }
}

struct ClockWheelPicker: View {
    @Binding var minute: Int
    @Binding var second: Int
    var maxMinutes: Int = 20
    var allowDash: Bool = false
    var height: CGFloat = 96

    var body: some View {
        HStack(spacing: 4) {
            Picker("Minutes", selection: $minute) {
                if allowDash {
                    Text("--").tag(-1)
                }
                ForEach(0...maxMinutes, id: \.self) { value in
                    Text(String(format: "%02d", value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 80, height: height)
            .clipped()

            Text(":")
                .font(.headline)

            Picker("Seconds", selection: $second) {
                if allowDash {
                    Text("--").tag(-1)
                }
                ForEach(0...59, id: \.self) { value in
                    Text(String(format: "%02d", value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 80, height: height)
            .clipped()
        }
    }
}

struct PeriodOptionWheelPicker: View {
    @Binding var selection: String
    private let options = ["1", "2", "3", "4", "5", "OT", "SO"]

    var body: some View {
        Picker("Period", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .pickerStyle(.wheel)
        .frame(width: 90, height: 84)
        .clipped()
    }
}

struct CalibrationSliderTray: View {
    @Binding var layout: ScoreboardOCRLayout
    @Binding var selectedKey: OCRRegionKey
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Calibration Controls")
                    .font(.caption.bold())
                Spacer()
                Button(expanded ? "Hide" : "Show") {
                    expanded.toggle()
                }
                .font(.caption)
            }

            if expanded {
                Picker("Region", selection: $selectedKey) {
                    ForEach(OCRRegionKey.calibrationCases) { key in Text(key.rawValue).tag(key) }
                }
                .pickerStyle(.menu)

                RegionRow(title: "X", value: selectedBinding(\.x))
                RegionRow(title: "Y", value: selectedBinding(\.y))
                RegionRow(title: "W", value: selectedBinding(\.width))
                RegionRow(title: "H", value: selectedBinding(\.height))
                RegionRotationRow(value: selectedBinding(\.rotationDegrees))
            }
        }
        .padding(10)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }

    private func selectedBinding(_ keyPath: WritableKeyPath<OCRRegion, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { layout[selectedKey][keyPath: keyPath] },
            set: { newValue in
                var region = layout[selectedKey]
                region[keyPath: keyPath] = newValue
                region.x = clamp(region.x, min: 0, max: 1 - region.width)
                region.y = clamp(region.y, min: 0, max: 1 - region.height)
                // v0.8.1.7i: calibration sliders must respect crop-box sizing,
                // not old text-overlay minimums.
                region.width = clamp(region.width, min: 0.005, max: 1 - region.x)
                region.height = clamp(region.height, min: 0.005, max: 1 - region.y)
                region.rotationDegrees = clamp(region.rotationDegrees, min: -15, max: 15)
                layout[selectedKey] = region
            }
        )
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

private struct RegionRow: View {
    let title: String
    @Binding var value: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2.bold())
                    .frame(width: 18, alignment: .leading)
                Text(value, format: .number.precision(.fractionLength(3)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = CGFloat($0) }
                ),
                in: 0...1
            )
        }
    }
}

private struct RegionRotationRow: View {
    @Binding var value: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Rot")
                    .font(.caption2.bold())
                    .frame(width: 28, alignment: .leading)
                Text("\(value, specifier: "%.1f")°")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("0°") { value = 0 }
                    .font(.caption2.bold())
                    .buttonStyle(.bordered)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = CGFloat($0) }
                ),
                in: -15...15
            )
        }
    }
}

struct CalibrationZoomSlider: View {
    @Binding var zoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat

    private var safeMinZoom: CGFloat {
        guard minZoom.isFinite else { return 1.0 }
        return Swift.max(0.1, minZoom)
    }

    private var safeMaxZoom: CGFloat {
        guard maxZoom.isFinite else { return safeMinZoom }
        return Swift.max(safeMinZoom, maxZoom)
    }

    private var safeRange: CGFloat {
        Swift.max(0, safeMaxZoom - safeMinZoom)
    }

    private var hasUsableZoomRange: Bool {
        // Do not create a SwiftUI Slider here. Some external/USB camera states can
        // briefly report a tiny-but-non-zero zoom span during reconnect/dropout.
        // SwiftUI Slider normalisation can assert on those ranges before the app
        // can recover, so calibration zoom uses explicit +/- buttons instead.
        safeRange >= 0.10
    }

    private var clampedZoom: CGFloat {
        Swift.min(Swift.max(zoom.isFinite ? zoom : safeMinZoom, safeMinZoom), safeMaxZoom)
    }

    private var zoomStep: CGFloat {
        Swift.min(0.25, Swift.max(0.05, safeRange / 20.0))
    }

    var body: some View {
        VStack(spacing: 8) {
            if hasUsableZoomRange {
                Text("\(clampedZoom, specifier: "%.1f")x")
                    .font(.caption.bold())
                    .frame(minWidth: 46)

                Text("max \(safeMaxZoom, specifier: "%.1f")x")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    setZoom(clampedZoom + zoomStep)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Increase calibration zoom")

                Rectangle()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 3, height: 74)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(.primary.opacity(0.65))
                            .frame(width: 3, height: markerHeight)
                    }
                    .clipShape(Capsule())
                    .accessibilityHidden(true)

                Button {
                    setZoom(clampedZoom - zoomStep)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decrease calibration zoom")

                Text("min \(safeMinZoom, specifier: "%.1f")x")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.caption.bold())
                    Text("Zoom")
                        .font(.caption.bold())
                    Text("Fixed")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(safeMinZoom, specifier: "%.1f")x")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 58, height: 118)
                .accessibilityLabel("Camera zoom unavailable for this device")
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { setZoom(clampedZoom) }
        .onChange(of: minZoom) { _, _ in setZoom(clampedZoom) }
        .onChange(of: maxZoom) { _, _ in setZoom(clampedZoom) }
    }

    private var markerHeight: CGFloat {
        guard safeRange > 0 else { return 0 }
        let normalised = Swift.min(Swift.max((clampedZoom - safeMinZoom) / safeRange, 0), 1)
        return Swift.max(6, 74 * normalised)
    }

    private func setZoom(_ value: CGFloat) {
        let resolved = Swift.min(Swift.max(value.isFinite ? value : safeMinZoom, safeMinZoom), safeMaxZoom)
        if abs(zoom - resolved) > 0.0001 {
            zoom = resolved
        }
    }
}

struct CameraHealthPill: View {
    let title: String
    @ObservedObject var service: HockeyCameraService

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(service.hasReceivedFrames ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption2.bold())
                    if service.stationaryHardwareLockActive {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                    }
                }
                Text(service.selectedResolutionFPS)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                Text(service.lastLifecycleEventText)
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.75)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.45), in: Capsule())
        .foregroundStyle(.white)
    }
}



// MARK: - Build 682 stable action popover

/// A fixed-width replacement for SwiftUI `Menu` in live camera and calibration
/// views. System menus can be dismissed/recreated whenever an observed camera or
/// diagnostics object publishes, which looks like a flash and can leave the hit
/// target unresponsive during capture recovery. This popover owns only local
/// presentation state and closes before running the selected action.
struct RinkLensStableMenuAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isSelected: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    init(
        id: String? = nil,
        title: String,
        systemImage: String,
        isSelected: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isDestructive = isDestructive
        self.action = action
    }
}

struct RinkLensStableActionMenu<Label: View>: View {
    var title: String? = nil
    var width: CGFloat = 360
    let actions: [RinkLensStableMenuAction]
    private let label: () -> Label
    @State private var isPresented = false

    init(
        title: String? = nil,
        width: CGFloat = 360,
        actions: [RinkLensStableMenuAction],
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.title = title
        self.width = width
        self.actions = actions
        self.label = label
    }

    private var resolvedTitle: String? {
        guard let title, !title.isEmpty else { return nil }
        // Build 751: this legacy OCR-screen heading was physically rejected twice.
        // Suppress it at the shared presentation boundary as well as the caller so
        // a stale incremental source copy or persisted rollout value cannot revive it.
        if title == "Scoreboard Input" { return nil }
        return title
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 5) {
                if let resolvedTitle {
                    Text(resolvedTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 3)
                }

                ForEach(actions) { item in
                    Button {
                        isPresented = false
                        // Let the popover disappear before opening a sheet/dialog
                        // or mutating a camera/profile object.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            item.action()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.systemImage)
                                .frame(width: 22)
                            Text(item.title)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if item.isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item.isDestructive ? Color.red : Color.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(width: max(280, width), alignment: .leading)
            .background(Color.black.opacity(0.94))
            .presentationCompactAdaptation(.popover)
        }
    }
}

#endif
