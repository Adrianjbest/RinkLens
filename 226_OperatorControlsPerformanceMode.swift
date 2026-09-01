// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
import Foundation

// MARK: - v0.9.1s Operator Controls Performance Guard
//
// The Operator Controls sheet is a live match control surface, not a telemetry
// dashboard.  Earlier builds observed the full scoreboard/camera/recording
// objects from the sheet shell, so OCR/camera/recording publishes could redraw
// the whole segmented menu while the user was trying to change tabs.  This file
// keeps refreshes deliberate and small.

final class OperatorControlsRefreshDriver: ObservableObject {
    @Published private(set) var refreshID: Int = 0

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 0.90
    private var lastManualBumpAt: Date = .distantPast
    private let minimumManualBumpInterval: TimeInterval = 0.12

    func start() {
        guard timer == nil else { return }
        refreshID &+= 1

        let newTimer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshID &+= 1
            }
        }
        newTimer.tolerance = 0.25
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        MainThreadStallMonitor.shared.trace("operator controls refresh driver started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        MainThreadStallMonitor.shared.trace("operator controls refresh driver stopped")
    }

    func bump(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastManualBumpAt) >= minimumManualBumpInterval else { return }
        lastManualBumpAt = now
        refreshID &+= 1
        MainThreadStallMonitor.shared.trace("operator controls refresh: \(reason)")
    }
}

struct StableCameraSourcePickerView: View {
    let title: String
    let service: HockeyCameraService
    let refreshID: Int
    let framesReceivedText: String
    let noFramesText: String
    let onSelect: (String?) -> Void

    var body: some View {
        // The refreshID is intentionally read here.  This view samples camera
        // state at the OperatorControlsRefreshDriver cadence instead of
        // subscribing to every HockeyCameraService objectWillChange event.
        let _ = refreshID

        Picker(
            title,
            selection: Binding(
                get: { service.selectedCameraID ?? iceCastNoCameraSelectionID },
                set: { newID in
                    guard newID != iceCastNoCameraSelectionID else { return }
                    onSelect(newID)
                }
            )
        ) {
            Label("Choose a camera", systemImage: "camera")
                .tag(iceCastNoCameraSelectionID)

            ForEach(service.availableCameras, id: \.id) { camera in
                Text(camera.name)
                    .tag(camera.id)
            }
        }

        if service.selectedCameraID != nil {
            Button(role: .destructive) {
                onSelect(iceCastExplicitNoCameraSelectionID)
            } label: {
                Label("Set camera to None", systemImage: "nosign")
            }
        }

        if service.availableCameras.isEmpty {
            if service.cameraDiscoveryGeneration == 0 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Discovering cameras…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("No cameras found. Tap Refresh Cameras or check camera permission / USB-C connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if service.selectedCameraID == nil {
            Label("No camera selected for this role", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Text(service.cameraStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)

        Text(service.selectedCameraID == nil ? "Camera role disabled until a camera is selected" : (service.hasReceivedFrames ? framesReceivedText : noFramesText))
            .font(.caption2)
            .foregroundStyle(service.selectedCameraID == nil ? .orange : (service.hasReceivedFrames ? .green : .orange))
    }
}
#endif
