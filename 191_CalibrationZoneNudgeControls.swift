// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

struct CalibrationZoneNudgeControls: View {
    let onNudge: (CGFloat, CGFloat) -> Void

    @State private var step: CGFloat = 0.005

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Nudge step", selection: $step) {
                Text("Fine").tag(CGFloat(0.0025))
                Text("Normal").tag(CGFloat(0.005))
                Text("Coarse").tag(CGFloat(0.015))
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button { onNudge(0, -step) } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button { onNudge(-step, 0) } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.borderedProminent)

                Button { onNudge(0, step) } label: {
                    Image(systemName: "arrow.down")
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.borderedProminent)

                Button { onNudge(step, 0) } label: {
                    Image(systemName: "arrow.right")
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#endif
