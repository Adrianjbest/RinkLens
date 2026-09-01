// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
// Build 502 core reset: the discarded Build 500 OCR isolation ladder controls are intentionally absent.

/// Build 621 retained-service recognition diagnostics.
///
/// There is no operator recognition mode. This sheet exposes only Period and
/// stable frozen Home-player popup recognition evidence and thresholds.
@MainActor
struct AdvancedOCRSettingsSheet: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    modeSection
                    thresholdSection
                    diagnosticDisplaySection
                    tuningSnapshotSection
                }
                .padding()
            }
            .rinkLensScrollPerformance("AdvancedOCR")
            .navigationTitle("Recognition Diagnostics")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var modeSection: some View {
        AdvancedOCRCard(title: "Internal recognition scope", systemImage: "text.viewfinder") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recognition is not an operating mode and has no live-scorebug switch.")
                    .font(RinkLensDesignSystem.font(.caption))
                Text("Image Relay owns the live display. Recognition is limited to Period and bounded Home roster matching from a stable frozen penalty-player crop. Guest penalty popups always use Image Relay.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thresholdSection: some View {
        AdvancedOCRCard(title: "Confidence thresholds", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                thresholdRow(title: "Period", value: $viewModel.ocrThresholds.period)
                thresholdRow(title: "Frozen Home Player", value: $viewModel.ocrThresholds.penaltyPlayer)
            }
        }
    }

    private var diagnosticDisplaySection: some View {
        AdvancedOCRCard(title: "Recognition overlay display", systemImage: "eye") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show Recognition Boxes", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRBoxes)
                Toggle("Show Raw Values", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRRawValues)
                Toggle("Show Recognition Confidence", isOn: $viewModel.ocrDiagnosticDisplayOptions.showOCRConfidence)
                Toggle("Show Recogniser Colours", isOn: $viewModel.ocrDiagnosticDisplayOptions.showRecogniserColours)
                Toggle("Show Accepted Values", isOn: $viewModel.ocrDiagnosticDisplayOptions.showAcceptedValues)
            }
        }
    }

    private var tuningSnapshotSection: some View {
        AdvancedOCRCard(title: "Current tuning snapshot", systemImage: "timer") {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.ocrAssistStatusText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                tuningRow("Period", viewModel.ocrTuningSnapshot.period)
                tuningRow("Frozen Home player", viewModel.ocrTuningSnapshot.penaltyPlayer)
            }
        }
    }

    private func thresholdRow(title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title): \(String(format: "%.2f", value.wrappedValue))")
                    .font(RinkLensDesignSystem.font(.caption))
                Spacer()
                Button("−") { value.wrappedValue = max(0.30, value.wrappedValue - 0.02) }
                    .buttonStyle(.bordered)
                Button("+") { value.wrappedValue = min(0.95, value.wrappedValue + 0.02) }
                    .buttonStyle(.bordered)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: 0.30...0.95
            )
        }
    }

    private func tuningRow(_ title: String, _ tuning: OCRZoneTuning) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(RinkLensDesignSystem.font(.caption))
            Spacer()
            Text("cadence \(String(format: "%.1fs", tuning.cadenceSeconds)) / confidence \(String(format: "%.2f", tuning.confidence)) / trust \(tuning.trust)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct AdvancedOCRCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
#endif
