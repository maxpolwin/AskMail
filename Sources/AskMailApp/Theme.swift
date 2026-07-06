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

    /// Opacity for the 1pt hairline. Broken out as a pure function (rather
    /// than baked straight into `hairline`) so it's unit-testable without
    /// comparing `Color` values.
    static func hairlineOpacity(highContrast: Bool) -> Double {
        highContrast ? 0.55 : 0.14
    }

    /// Quiet 1pt hairline that adapts to light/dark. Pass `highContrast: true`
    /// for Settings ▸ Accessibility ▸ "Higher-contrast panel" — a much less
    /// subtle line in both appearances, closer to what macOS's system
    /// Increase Contrast setting expects.
    static func hairline(highContrast: Bool) -> Color {
        Color.primary.opacity(hairlineOpacity(highContrast: highContrast))
    }
}
