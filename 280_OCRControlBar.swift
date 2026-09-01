// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.
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

enum OperatingMode: String, CaseIterable, Identifiable {
    /// Legacy persisted value retained only so older settings decode safely.
    /// Build 621 migrates every request for this value to Image Relay and never
    /// exposes it as an operator-selectable mode.
    case ocr
    case imageRelay
    case manual

    static var allCases: [OperatingMode] { [.imageRelay, .manual] }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ocr: return "Image Relay"
        case .imageRelay: return "Image Relay"
        case .manual: return "Manual Mode"
        }
    }

    var broadcastStatusText: String {
        switch self {
        case .ocr: return "Image Relay Live"
        case .imageRelay: return "Image Relay Live"
        case .manual: return "Manual Mode"
        }
    }
}

typealias OverlayControlMode = OperatingMode

struct OCRControlBar: View {
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            actionButton(
                title: "Settings",
                systemImage: "gearshape.fill",
                action: onSettings
            )
        }
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(RinkLensDesignSystem.font(.bodyStrong))
                .frame(minWidth: 104)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .background(.black.opacity(0.6))
        .foregroundStyle(.white)
        .clipShape(Capsule())
    }
}

#endif
