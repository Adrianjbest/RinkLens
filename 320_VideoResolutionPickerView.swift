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

struct VideoResolutionPickerView: View {
    @ObservedObject var cameraService: HockeyCameraService
    let onSelectProfile: (String) -> Void

    init(
        cameraService: HockeyCameraService,
        onSelectProfile: @escaping (String) -> Void
    ) {
        self.cameraService = cameraService
        self.onSelectProfile = onSelectProfile
    }

    var body: some View {
        List {
            if cameraService.isLoadingVideoFormats {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading supported camera modes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if cameraService.capabilityProfiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No supported resolution modes loaded")
                        .font(.headline)
                    Text("Tap Refresh Formats to scan this camera. RinkLens only shows camera-supported 720p, 1080p, and 1440p modes at 30 or 60 fps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Refresh Formats") {
                        cameraService.refreshVideoFormats(force: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(cameraService.isLoadingVideoFormats || cameraService.isReconfiguring)
                }
                .padding(.vertical, 6)
            }

            if cameraService.isReconfiguring {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Changing video resolution…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(cameraService.capabilityProfiles) { profile in
                Button {
                    onSelectProfile(profile.id)
                } label: {
                    HStack {
                        Text(profile.displayLabel)
                        Spacer()
                        if cameraService.selectedCapabilityProfileID == profile.id {
                            Image(systemName: "checkmark")
                        } else if !profile.isAvailable {
                            Text("Unavailable")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!profile.isAvailable || cameraService.isReconfiguring || cameraService.selectedCapabilityProfileID == profile.id)
            }

            Text("Only modes actually supported by the selected camera are shown. A camera that cannot provide a particular resolution or frame rate will not display that option.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .navigationTitle("Video Resolution")
    }
}
#endif
