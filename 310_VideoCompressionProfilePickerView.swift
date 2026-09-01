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

struct VideoCompressionProfilePickerView: View {
    @ObservedObject var cameraService: HockeyCameraService

    var body: some View {
        List {
            if cameraService.isReconfiguring {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Changing video format profile…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(HockeyCameraService.VideoCompressionProfile.allCases, id: \.self) { profile in
                Button {
                    cameraService.selectCompressionProfile(profile)
                } label: {
                    HStack {
                        Text(profile.rawValue)
                        Spacer()
                        if cameraService.selectedCompressionProfile == profile {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(cameraService.isReconfiguring || cameraService.selectedCompressionProfile == profile)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(HockeyCameraService.VideoCompressionProfile.highEfficiency.detailText)
                Text(HockeyCameraService.VideoCompressionProfile.mostCompatible.detailText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
        .navigationTitle("Video Format")
    }
}


#endif
