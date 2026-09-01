// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreImage
import CoreVideo

// MARK: - v0.9.2 Stage 8 compatibility shim

// Retired duplicate definitions moved into
// 891_BroadcastRecordingPixelBufferFrameProvider.swift so there is one source of
// truth for BroadcastRecordingPixelBufferFrame and BroadcastPixelBufferFrameQualityAnalyser.
// Keep this file as a harmless overwrite shim for projects that still have the
// old Stage 3 file in the target.
#endif
