// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import Foundation

struct OCRDiagnosticsPanel: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel
    @ObservedObject private var ocrDiagnostics: OCRDiagnosticsStore

    init(viewModel: HockeyScoreboardViewModel) {
        self.viewModel = viewModel
        self._ocrDiagnostics = ObservedObject(wrappedValue: viewModel.ocrDiagnostics)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiagnosticsCard(title: "Scoreboard Recognition", systemImage: "text.viewfinder") {
                DiagnosticsRow(title: "Scoreboard input mode", value: viewModel.operatingMode.title)
                DiagnosticsRow(title: "Image Relay", value: viewModel.imageRelayStatusText)
                DiagnosticsRow(title: "Image Relay detail", value: viewModel.imageRelayDiagnosticText)
                DiagnosticsRow(title: "Selected zone", value: selectedZoneDiagnosticsText)
                DiagnosticsRow(title: "Internal recognition", value: "Period + frozen Home penalty crop")
                DiagnosticsRow(title: "Recognition runtime", value: viewModel.ocrOperationalStatusText)
                DiagnosticsRow(title: "Physical slot hashing", value: ocrDiagnostics.ocrPixelHashingStatusText)
                DiagnosticsRow(title: "Hash detail", value: ocrDiagnostics.ocrPixelHashingDetailText)
                DiagnosticsRow(title: "Motion protection", value: viewModel.ocrMotionProtectionStatusText)
            }

            DiagnosticsCard(title: "Recognition Evidence", systemImage: "arrow.triangle.branch") {
                if ocrDiagnostics.orderedFieldPublicationDiagnostics.isEmpty {
                    DiagnosticsRow(title: "Fields", value: "No recognition decisions recorded")
                } else {
                    ForEach(ocrDiagnostics.orderedFieldPublicationDiagnostics) { diagnostic in
                        DiagnosticsRow(
                            title: diagnostic.key.likelyTitle,
                            value: diagnostic.compactText
                        )
                    }
                }
            }

            DiagnosticsCard(title: "Recognition Maintenance", systemImage: "arrow.clockwise") {
                Text("Image Relay cannot be stopped from this panel. These actions clear internal evidence only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset Recognition Evidence") {
                    viewModel.resetOCRTrustState()
                }
                .buttonStyle(.bordered)

                Button("Clear Recognition History") {
                    viewModel.clearDebugHistory()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var selectedZoneDiagnosticsText: String {
        let key = viewModel.selectedRegionKey
        let region = viewModel.ocrLayout[key]
        return String(
            format: "%@ x=%.4f y=%.4f w=%.4f h=%.4f",
            key.likelyTitle,
            Double(region.x),
            Double(region.y),
            Double(region.width),
            Double(region.height)
        )
    }
}
#endif
