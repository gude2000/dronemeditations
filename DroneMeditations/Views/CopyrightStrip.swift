import SwiftUI

/// Thin horizontal row that lives at the very bottom of the visible chrome:
/// copyright text on the left, a tappable Manual capsule on the right.
///
/// Designed to be embedded **inside** the bottom of either the full
/// `ControlsOverlay` (below `TransportView`) or the slim `ChladniMiniControls`
/// strip — never as a free-floating overlay. That used to cause the row to
/// stack on top of either the transport or the mini-osc bar in different
/// portrait/landscape modes; inlining it lets the surrounding `Spacer()`
/// + safe-area padding push it cleanly to the screen edge with no overlap.
///
/// Width is `infinity` so it always spans its container; the actual
/// horizontal max is set by the parent (typically 900pt to match the iPad
/// strip cap).
struct CopyrightStrip: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("© 2026 Jose Gude MD")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Link(destination: URL(string: "https://dronemeditations.com/manual.html")!) {
                HStack(spacing: 4) {
                    Image(systemName: "book")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Manual")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.80))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    CopyrightStrip()
        .background(Color.black)
}
