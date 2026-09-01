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

struct TemplateSettingsPanel: View {
    let templates: [RinkTemplate]
    let activeTemplateID: UUID?
    let activeTemplateName: String?
    let defaultTemplateID: UUID?
    let hasUnsavedChanges: Bool
    let onApplyTemplate: (RinkTemplate) -> Void
    let onSaveActiveTemplate: (String?, String?, Data?) -> Void
    let onSaveAsNewTemplate: (String, String?, String?, Data?) -> Void
    let onRenameTemplate: (RinkTemplate, String) -> Void
    let onDuplicateTemplate: (RinkTemplate, String) -> Void
    let onDeleteTemplate: (RinkTemplate) -> Void
    let onSetDefaultTemplate: (RinkTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newTemplateName = ""
    @State private var renameTarget: RinkTemplate?
    @State private var renameInput = ""
    @State private var duplicateTarget: RinkTemplate?
    @State private var duplicateInput = ""
    @State private var deleteTarget: RinkTemplate?

    var body: some View {
        NavigationStack {
            ZStack {
                BroadcastMenuBackgroundView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        BroadcastMenuHeaderLabel(
                            title: "Zone Templates",
                            subtitle: "Load, save and manage scoreboard zone layouts only. Venue, notes and image upload have been removed from setup.",
                            systemImage: "folder"
                        )

                        activeTemplateCard
                        saveTemplateCard
                        templateListCard
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Zone Templates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .broadcastMenuText()
        .alert("Rename Template", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameInput)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let renameTarget { onRenameTemplate(renameTarget, renameInput) }
                renameTarget = nil
            }
        }
        .alert("Duplicate Template", isPresented: Binding(get: { duplicateTarget != nil }, set: { if !$0 { duplicateTarget = nil } })) {
            TextField("New name", text: $duplicateInput)
            Button("Cancel", role: .cancel) { duplicateTarget = nil }
            Button("Create") {
                if let duplicateTarget { onDuplicateTemplate(duplicateTarget, duplicateInput) }
                duplicateTarget = nil
            }
        }
        .alert("Delete template?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let deleteTarget { onDeleteTemplate(deleteTarget) }
                deleteTarget = nil
            }
        } message: {
            Text("This will remove the saved scoreboard-zone layout for this template.")
        }
    }

    private var activeTemplateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            BroadcastMenuSectionTitle("Active Layout", systemImage: "doc.text")
            CalibrationInfoRow(label: "Active template", value: activeTemplateName ?? "None")
            CalibrationInfoRow(label: "Saved templates", value: "\(templates.count)")
            if hasUnsavedChanges {
                Label("Unsaved zone changes", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
        }
        .calibrationHubCard()
    }

    private var saveTemplateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            BroadcastMenuSectionTitle("Save Current Zones", systemImage: "square.and.arrow.down")

            TextField("New template name", text: $newTemplateName)
                .textFieldStyle(.roundedBorder)

            CalibrationActionGrid {
                CalibrationHubActionButton(title: "Save Active", systemImage: "square.and.arrow.down", prominent: true) {
                    onSaveActiveTemplate(nil, nil, nil)
                }
                .disabled(activeTemplateID == nil)

                CalibrationHubActionButton(title: "Save As New", systemImage: "plus.square", prominent: true) {
                    let trimmed = newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSaveAsNewTemplate(trimmed.isEmpty ? defaultNewTemplateName : trimmed, nil, nil, nil)
                    newTemplateName = ""
                }
            }

            Text("This panel now manages zone layouts only. Save Active writes the current box positions to the active template; Save As New creates a new layout template.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
        }
        .calibrationHubCard()
    }

    private var templateListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            BroadcastMenuSectionTitle("Saved Zone Layouts", systemImage: "folder")

            if templates.isEmpty {
                Text("No saved zone templates yet.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(templates) { template in
                        templateRow(template)
                    }
                }
            }
        }
        .calibrationHubCard()
    }

    private func templateRow(_ template: RinkTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(template.name)
                    .font(.subheadline.bold())
                if template.id == activeTemplateID {
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
                if template.id == defaultTemplateID {
                    Text("DEFAULT")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                }
                Spacer()
            }

            Text("Modified \(template.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))

            CalibrationActionGrid {
                CalibrationHubActionButton(title: "Load", systemImage: "arrow.down.doc", prominent: template.id != activeTemplateID) {
                    onApplyTemplate(template)
                }
                CalibrationHubActionButton(title: "Default", systemImage: "star") {
                    onSetDefaultTemplate(template)
                }
                CalibrationHubActionButton(title: "Rename", systemImage: "pencil") {
                    renameTarget = template
                    renameInput = template.name
                }
                CalibrationHubActionButton(title: "Duplicate", systemImage: "doc.on.doc") {
                    duplicateTarget = template
                    duplicateInput = "\(template.name) Copy"
                }
                CalibrationHubActionButton(title: "Delete", systemImage: "trash", destructive: true, role: .destructive) {
                    deleteTarget = template
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var defaultNewTemplateName: String {
        "Zone Layout \(templates.count + 1)"
    }
}


struct SettingsPanel: View {
    let rawText: String?
    let debugHistory: [String]
    let state: ScoreboardState
    let fieldConfidence: [OCRRegionKey: OCRFieldConfidence]
    let trustSummary: OCRTrustSummary
    let gameClockDirection: GameClockDirection
    @Binding var scoreboardType: OCRScoreboardType
    @Binding var operatorMode: OCROperatorMode
    @Binding var autoOCRAssistEnabled: Bool
    @Binding var smartChangeDetectionEnabled: Bool
    @Binding var clockReadingPreset: OCRZoneReadingPreset
    @Binding var scoreReadingPreset: OCRZoneReadingPreset
    @Binding var penaltyReadingPreset: OCRZoneReadingPreset
    let tuningSnapshot: OCROperatorTuningSnapshot
    let ocrAssistStatusText: String
    @Binding var thresholds: OCRThresholds
    @Binding var enableSegmentedFallback: Bool
    @Binding var diagnosticOptions: OCRDiagnosticDisplayOptions
    @Binding var isDebugVisible: Bool
    @Binding var freezeDebugSnapshot: Bool
    @Binding var ocrIntervalSeconds: Double
    @Binding var postOCRSmoothingEnabled: Bool
    let onClearDebugHistory: () -> Void
    let onResetOCRTrustState: () -> Void
    let onOpenTemplateSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(isDebugVisible ? "Stop Debug" : "Start Debug") {
                            isDebugVisible.toggle()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Clear History") {
                            onClearDebugHistory()
                        }
                        .buttonStyle(.bordered)

                        Button("Reset Trust") {
                            onResetOCRTrustState()
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Freeze recognition debug snapshot", isOn: $freezeDebugSnapshot)
                            .font(.caption)

                        Text("Image Relay remains live while this diagnostic snapshot is frozen.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    operatorOCRSettingsSection

                    Button("Template Settings") {
                        onOpenTemplateSettings()
                    }
                    .buttonStyle(.bordered)

                    HStack {
                        ShareLink(item: debugExportText) {
                            Label("Export Debug", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }

                    Text("Clock and penalty timers are published by Image Relay. Their digit-isolation pipeline has no operator recognition mode or switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recognition diagnostics display")
                            .font(.caption.bold())
                        Toggle("Show Recognition Boxes", isOn: $diagnosticOptions.showOCRBoxes)
                        Toggle("Show Raw Recognition Values", isOn: $diagnosticOptions.showOCRRawValues)
                        Toggle("Show Recognition Confidence", isOn: $diagnosticOptions.showOCRConfidence)
                        Toggle("Show Recogniser Colours", isOn: $diagnosticOptions.showRecogniserColours)
                        Toggle("Show Accepted Values", isOn: $diagnosticOptions.showAcceptedValues)
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

                    OCRConfidenceSummaryView(
                        summary: trustSummary,
                        fieldConfidence: fieldConfidence,
                        compact: false
                    )

                    DisclosureGroup("Internal Recognition Details") {
                        Text("Only Period and the stable frozen Home penalty-player crop are retained recognition services.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        tuningRow("Period", tuningSnapshot.period)
                        tuningRow("Frozen Home player", tuningSnapshot.penaltyPlayer)
                        thresholdRow(title: "Period confidence", value: $thresholds.period)
                        thresholdRow(title: "Frozen Home player confidence", value: $thresholds.penaltyPlayer)
                    }
                    .font(.caption)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accepted internal recognition")
                            .font(.caption.bold())
                        Text("Period: \(state.period.map { String($0) } ?? "-")")
                    }
                    .font(.caption.monospaced())

                    Text("Latest recognition output")
                        .font(.caption.bold())
                    Text(rawText ?? "No recognition debug text available yet.")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)

                    Text("Recognition History (\(debugHistory.count))")
                        .font(.caption.bold())
                    Text(debugHistory.joined(separator: "\n\n"))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("Settings")
        }
    }


    // MARK: - Build 621 Internal Recognition Scope

    @ViewBuilder
    private var operatorOCRSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Internal Recognition")
                .font(.caption.bold())

            Text("There is no separate recognition operating mode. Image Relay remains the live scorebug source. Internal recognition is limited to Period and a stable frozen Home penalty-player crop used for roster-name enhancement.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("Period", systemImage: "number.square")
                Spacer()
                Text("Automatic in Image Relay")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Home penalty popup", systemImage: "person.text.rectangle")
                Spacer()
                Text("Frozen crop + roster match")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Guest penalty popup", systemImage: "rectangle.on.rectangle")
                Spacer()
                Text("Image Relay only")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func zonePresetRow(_ title: String, selection: Binding<OCRZoneReadingPreset>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2.bold())
                Spacer()
            }
            Picker(title, selection: selection) {
                ForEach(OCRZoneReadingPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            Text(help)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func tuningRow(_ title: String, _ tuning: OCRZoneTuning) -> some View {
        HStack {
            Text(title)
                .font(.caption2.bold())
            Spacer()
            Text("cadence \(String(format: "%.1fs", tuning.cadenceSeconds)) / confidence \(String(format: "%.2f", tuning.confidence)) / trust \(tuning.trust)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func thresholdRow(title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title): \(String(format: "%.2f", value.wrappedValue))")
                    .font(.caption.bold())
                Spacer()
                Button("-") { value.wrappedValue = max(0.30, value.wrappedValue - 0.02) }
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

    private var debugExportText: String {
        let thresholdsText = """
        sevenSegmentTimers=alwaysOn
        gameClockDirection=\(gameClockDirection.title)
        penaltyClockDirection=Count Down
        clock=\(thresholds.clock)
        score=\(thresholds.score)
        period=\(thresholds.period)
        shots=\(thresholds.shots)
        penaltyPlayer=\(thresholds.penaltyPlayer)
        penaltyTime=\(thresholds.penaltyTime)
        """
        let acceptedText = """
        clock=\(state.clock ?? "--:--")
        period=\(state.period.map { String($0) } ?? "-")
        homeScore=\(state.homeScore.map { String($0) } ?? "-")
        awayScore=\(state.awayScore.map { String($0) } ?? "-")
        """
        return """
        Hockey OCR Debug Export
        Generated: \(Date().formatted(date: .abbreviated, time: .standard))

        Thresholds:
        \(thresholdsText)

        Accepted Overlay Values:
        \(acceptedText)

        Latest OCR:
        \(rawText ?? "none")

        OCR History:
        \(debugHistory.joined(separator: "\n\n"))
        """
    }

}


#endif
