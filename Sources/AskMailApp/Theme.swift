import AppKit
import SwiftUI

/// Shared design tokens so the floating panel and the Settings window read as
/// one family: a frosted, appearance-adaptive surface that borrows the user's
/// macOS accent colour and a quiet hairline.
enum Theme {
    /// The user's system accent colour (System Settings ▸ Appearance ▸ Accent) —
    /// the hairline sweep, progress, and tinted controls. `controlAccentColor`
    /// already adapts to light/dark and honours a "multicolour" preference, so
    /// the whole app tracks whatever highlight colour the user picked.
    static let accent = Color(nsColor: .controlAccentColor)

    /// Quiet 1pt hairline that adapts to light/dark.
    static let hairline = Color.primary.opacity(0.14)
}
