// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

// MARK: - Shared Color RGBA String Helper

/// Shared colour serialisation helper used by broadcast layout settings,
/// template storage and diagnostics panels.
///
/// Keep this helper internal so it is available across Swift files in the
/// app target without exposing it outside the module.
extension Color {
    init?(rgbaString: String) {
        let parts = rgbaString.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        self = Color(.sRGB, red: parts[0], green: parts[1], blue: parts[2], opacity: parts[3])
    }

    var rgbaString: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return "\(Double(red)),\(Double(green)),\(Double(blue)),\(Double(alpha))"
    }
}
#endif
