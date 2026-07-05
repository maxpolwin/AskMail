import AppKit
import SwiftUI

/// A 1pt hairline that sits under the question bar. Idle, it is a quiet static
/// line; while `active` (the query is streaming), a soft accent highlight sweeps
/// across it — replacing the old spinner. Respects Reduce Motion.
struct AnimatedHairline: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    private static let base = Theme.hairline    // adapts both modes
    private static let accent = Theme.accent

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Rectangle()
                .fill(Self.base)
                .overlay(alignment: .leading) {
                    if active && !reduceMotion {
                        LinearGradient(colors: [.clear, Self.accent, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: w * 0.45)
                            // Sweeps fully off both edges; transparent ends make the loop seamless.
                            .offset(x: -w * 0.45 + phase * (w * 1.45))
                    } else if active {
                        Self.accent.opacity(0.45)  // reduce-motion: gentle static tint
                    }
                }
                .clipped()
        }
        .frame(height: 1)
        .onAppear { if active { start() } }
        .onChange(of: active) { _, on in on ? start() : stop() }
    }

    private func start() {
        phase = 0
        withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }

    private func stop() {
        withAnimation(.easeOut(duration: 0.2)) { phase = 0 }
    }
}
