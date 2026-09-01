// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreImage
import CoreVideo
import SwiftUI

// MARK: - v0.9.2 Stage 8 compatibility shim

// The Stage 6 provider duplicated BroadcastRecordingPixelBufferFrameProvider and
// caused ambiguous calls from BroadcastRecordingViews. The Stage 8 provider is
// deliberately renamed to BroadcastRecordingStage8PixelBufferFrameProvider so
// stale duplicate files cannot collide with the active recording path.
// This file intentionally declares no types or same-named methods so overwriting
// the old file removes the redeclaration without requiring a target edit.
#endif
