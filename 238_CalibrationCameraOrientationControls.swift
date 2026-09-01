// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - v0.9.1p Calibration Camera Orientation Controls

struct CalibrationCameraOrientationCard: View {
    let viewModel: HockeyScoreboardViewModel

    private var currentDegrees: Int {
        Int(viewModel.ocrPreviewRotationOffsetDegrees.rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BroadcastMenuSectionTitle("Image Orientation", systemImage: "rotate.right")

            Text("Use this when the calibration or external camera image is sideways or upside down. This applies to the OCR/Calibration preview and OCR crop mapping together.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                orientationButton(title: "Normal", degrees: 0)
                orientationButton(title: "Rotate 90°", degrees: 90)
                orientationButton(title: "Rotate 180°", degrees: 180)
                orientationButton(title: "Rotate 270°", degrees: 270)
            }

            CalibrationActionGrid {
                CalibrationHubActionButton(title: "Rotate Left", systemImage: "rotate.left") {
                    viewModel.rotateOCRPreviewCounterClockwise()
                }

                CalibrationHubActionButton(title: "Rotate Right", systemImage: "rotate.right", prominent: true) {
                    viewModel.rotateOCRPreviewClockwise()
                }
            }

            CalibrationInfoRow(label: "Current orientation", value: "\(currentDegrees)°")
        }
        .calibrationHubCard()
    }

    private func orientationButton(title: String, degrees: CGFloat) -> some View {
        let selected = currentDegrees == Int(degrees.rounded())
        return Button {
            viewModel.setOCRPreviewRotationDegrees(degrees)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.caption.weight(.bold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CalibrationHubButtonStyle(prominent: selected, destructive: false))
    }
}
#endif
