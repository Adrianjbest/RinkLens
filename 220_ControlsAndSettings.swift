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

// v0.8.5a Controls Modular Refactor
//
// This file is intentionally lightweight. The former large SwiftUI view tree
// has been split into focused files to avoid Swift type-check timeouts:
// - 221_CoreUIComponents.swift
// - 222_OCRCalibrationOverlays.swift
// - 223_OperatorHub.swift
// - 224_TemplateSettings.swift
// - 225_BroadcastRecoveryComponents.swift
//
// Keep this file for project ordering/backwards compatibility.

#endif
