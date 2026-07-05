import AppKit
import SwiftUI

/// Shared design tokens so the floating panel and the Settings window read as
/// one family: a frosted, appearance-adaptive surface with a single violet
/// accent and a quiet hairline.
enum Theme {
    /// Violet accent — the hairline sweep, progress, and tinted controls.
    /// Slightly brighter in dark mode so it holds up on the dark frost.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.67, green: 0.61, blue: 1.0, alpha: 1)   // #AB9DFF (dark)
            : NSColor(srgbRed: 0.48, green: 0.42, blue: 0.94, alpha: 1)  // #7A6CF0 (light)
    })

    /// Quiet 1pt hairline that adapts to light/dark.
    static let hairline = Color.primary.opacity(0.14)
}
