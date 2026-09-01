// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import Vision
import CoreMedia
import CoreGraphics
import PhotosUI
import Foundation
#if canImport(MLKitVision) && canImport(MLKitTextRecognition) && canImport(MLKitTextRecognitionLatin)
import MLKitVision
import MLKitTextRecognition
import MLKitTextRecognitionLatin
#endif

let iceCastNoCameraSelectionID = "__ICECAST_NO_CAMERA__"
let iceCastExplicitNoCameraSelectionID = "__ICECAST_EXPLICIT_NO_CAMERA__"

struct CameraSelectionSheet: View {
    @ObservedObject var viewModel: HockeyScoreboardViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Scoreboard / recognition camera") {
                    CameraSourcePickerView(
                        title: "Active OCR camera",
                        service: viewModel.ocrCameraService,
                        framesReceivedText: "Frames received from OCR camera",
                        noFramesText: "No OCR camera frames received yet",
                        onSelect: { viewModel.selectOCRCamera(id: $0) }
                    )

                    NavigationLink {
                        VideoResolutionPickerView(
                            cameraService: viewModel.ocrCameraService,
                            onSelectProfile: { viewModel.selectOCRCapabilityProfile(id: $0) }
                        )
                    } label: {
                        HStack {
                            Text("Scoreboard Video Resolution")
                            Spacer()
                            Text(viewModel.ocrCameraService.selectedResolutionLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Live / broadcast camera") {
                    CameraSourcePickerView(
                        title: "Active live camera",
                        service: viewModel.liveCameraService,
                        framesReceivedText: "Frames received from live camera",
                        noFramesText: "No live camera frames received yet",
                        onSelect: { viewModel.selectLiveCamera(id: $0) }
                    )

                    NavigationLink {
                        VideoResolutionPickerView(
                            cameraService: viewModel.liveCameraService,
                            onSelectProfile: { viewModel.selectLiveCapabilityProfile(id: $0) }
                        )
                    } label: {
                        HStack {
                            Text("Live Video Resolution")
                            Spacer()
                            Text(viewModel.liveCameraService.selectedResolutionLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Refresh Cameras") {
                        viewModel.refreshCameraLists()
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    Text("Use different physical cameras where possible. Scoreboard Setup normally uses the external scoreboard camera; Live/broadcast normally uses the iPad rear camera.")
                }
            }
            .navigationTitle("Camera Selection")
        }
    }

}

struct CameraSourcePickerView: View {
    let title: String
    @ObservedObject var service: HockeyCameraService
    let framesReceivedText: String
    let noFramesText: String
    let onSelect: (String?) -> Void

    var body: some View {
        Picker(
            title,
            selection: Binding(
                get: { service.selectedCameraID ?? iceCastNoCameraSelectionID },
                set: { newID in
                    CameraOwnershipTraceStore.record(.picker, owner: service.selectedCameraPosition == .back || service.selectedCameraPosition == .front ? .liveCamera : .ocrCamera, reason: "CameraSourcePicker setter service=\(service.diagnosticInstanceID) incoming=\(newID) published=\(service.selectedCameraID ?? "none") options=\(service.availableCameras.map { $0.id }.joined(separator: ","))")
                    // UX16c9: A SwiftUI menu can briefly publish its fallback tag
                    // while asynchronous rows refresh. Only real source IDs switch
                    // cameras; None is an explicit button below.
                    guard newID != iceCastNoCameraSelectionID else {
                        CameraOwnershipTraceStore.record(.picker, owner: .diagnostics, reason: "CameraSourcePicker transient fallback ignored service=\(service.diagnosticInstanceID)")
                        return
                    }
                    onSelect(newID)
                }
            )
        ) {
            Label("Choose a camera", systemImage: "camera")
                .tag(iceCastNoCameraSelectionID)

            if let selectedID = service.selectedCameraID,
               !service.availableCameras.contains(where: { $0.id == selectedID }) {
                Text("\(service.selectedCameraLabel) — reconnecting")
                    .tag(selectedID)
            }

            ForEach(service.availableCameras, id: \.id) { camera in
                Text(camera.name)
                    .tag(camera.id)
            }
        }

        if service.selectedCameraID != nil {
            Button(role: .destructive) {
                CameraOwnershipTraceStore.record(.picker, owner: .diagnostics, reason: "CameraSourcePicker EXPLICIT None tapped service=\(service.diagnosticInstanceID) current=\(service.selectedCameraID ?? "none")")
                onSelect(iceCastExplicitNoCameraSelectionID)
            } label: {
                Label("Set this role to None", systemImage: "nosign")
            }
            .disabled(service.isReconfiguring)
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
