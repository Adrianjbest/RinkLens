// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
import Foundation

extension ClipEngine {

    /// Stage 7b3 compatibility helper.
    ///
    /// Provides the function signature used by RecordingEngine without
    /// editing the large ClipEngine file directly.
    func manualClipReadinessDiagnostic(seconds: Int) -> String {
        let requested = max(0, seconds)
        return "warming up — need \(requested)s of current PixelBuffer clip coverage before manual clips are ready"
    }
}
