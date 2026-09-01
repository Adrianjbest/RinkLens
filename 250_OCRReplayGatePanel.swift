// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

struct OCRReplayGatePanel: View {
    @ObservedObject var controller: RinkLensOCRReplayGateController = .shared

    var body: some View {
        DiagnosticsCard(title: "OCR Replay Gate", systemImage: "arrow.triangle.2.circlepath.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Captures exact production field crops and transaction stages. The standing gate also runs known-session and deliberately adversarial combined scenarios through the production control plane, publication safety, MatchState reducer and event detector.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)

                HStack(spacing: 10) {
                    Button(controller.captureEnabled ? "Stop Replay Capture" : "Start Replay Capture") {
                        if controller.captureEnabled {
                            controller.stopCapture()
                        } else {
                            controller.startCapture(reason: "Advanced Engineering Tools")
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Run Standing Gate") {
                        controller.runStandingRegressionGate()
                    }
                    .buttonStyle(.bordered)
                }

                Text(controller.statusText)
                    .font(RinkLensDesignSystem.font(.caption))

                Text("Active bounded transactions: \(controller.activeTransactionCount)")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(controller.activeTransactionCount == 0 ? RinkLensDesignSystem.secondaryText : .orange)

                if let url = controller.lastSessionURL {
                    ShareLink(item: url) {
                        Label("Share Latest Replay Bundle", systemImage: "square.and.arrow.up")
                    }
                    .font(RinkLensDesignSystem.font(.caption))
                }

                ForEach(controller.gateResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(result.scenario, systemImage: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(result.passed ? .green : .red)
                        Text(result.summary)
                            .font(RinkLensDesignSystem.font(.caption))
                        Text(result.finalState)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(RinkLensDesignSystem.secondaryText)
                        ForEach(result.failures, id: \.self) { failure in
                            Text("• \(failure)")
                                .font(RinkLensDesignSystem.font(.caption))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(8)
                    .background(.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if !controller.recentFaults.isEmpty {
                    Text("Bounded transaction faults")
                        .font(RinkLensDesignSystem.font(.caption))
                        .fontWeight(.semibold)
                    ForEach(controller.recentFaults, id: \.self) { fault in
                        Text("• \(fault)")
                            .font(RinkLensDesignSystem.font(.caption))
                            .foregroundStyle(.red)
                    }
                }

                Text("Replay passing is required but not sufficient. Camera glare, thermal pressure, frame cadence and MainActor contention still require the physical iPad acceptance run.")
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.secondaryText)
            }
        }
    }
}
#endif
