import SwiftUI

/// First-launch tour. Shown automatically the first time the app opens
/// (gated by `@AppStorage("hasSeenOnboarding")`) and re-openable later
/// from a tiny "?" button in the header so returning users can refresh.
///
/// Five swipeable pages cover the major capabilities — the goal is not
/// to teach every feature, but to give context for what the user is
/// looking at so the dense per-osc controls don't feel like a wall.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var page: Int = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            symbol: "waveform",
            accent: Color(red: 0.81, green: 0.71, blue: 0.92),
            title: "Welcome to Drone Meditations",
            body: "A deep four-oscillator drone synthesizer for meditation, sound healing, and ambient composition. Inspired by Pauline Oliveros, Éliane Radigue, Stars of the Lid, Sunn O))) and other long-form drone masters.",
            hint: "Tap, swipe, or wait — there's no wrong way to use it."
        ),
        OnboardingPage(
            symbol: "music.note.list",
            accent: Color(red: 1.0, green: 0.85, blue: 0.55),
            title: "Start with a preset",
            body: "Pick from 80+ presets across Drone Artists, Solfeggio, Binaural, Cymatics, Mystic & Composers, and more. Each Drone Artists preset captures that artist's signature waveforms, FX, and tuning — not just their pitches.",
            hint: "Try \"Oliveros — Deep A Resonance\" or \"Basinski — Tape Decay Cycle\" first."
        ),
        OnboardingPage(
            symbol: "slider.horizontal.3",
            accent: Color(red: 0.55, green: 0.76, blue: 1.0),
            title: "Then make it yours",
            body: "Every oscillator has its own waveform, filter, drive, four LFOs, chorus, FM, delay, reverb, drift, granular synthesis, and timing envelope. Or just nudge the master volume — that's a valid path too.",
            hint: "Scroll the pill row at top for: Chord · Preset · Drift · Listen · Perform · Journey · Morph."
        ),
        OnboardingPage(
            symbol: "circles.hexagongrid",
            accent: Color(red: 0.72, green: 0.86, blue: 1.0),
            title: "Watch the cymatics",
            body: "Tap the hexagon icon to overlay live Chladni patterns — physically-calibrated mode shapes that respond to the actual playing frequency. Pinch to zoom. Tap the screen to hide the controls and watch fullscreen.",
            hint: "\"Perform\" mode hides everything for pure cymatic meditation."
        ),
        OnboardingPage(
            symbol: "sparkles",
            accent: Color(red: 0.97, green: 0.79, blue: 0.28),
            title: "Go further when you're ready",
            body: "Morph between any two presets over time. Run scripted multi-stage journeys. Tune the synth to your room with the mic. Record and share mastered .m4a sessions. Load any of 41 bundled field recordings or your own audio.",
            hint: "Settings are remembered between sessions. You can always reopen this tour from the ? button up top."
        )
    ]

    var body: some View {
        ZStack {
            // Dark gradient backdrop — matches the app's resting aesthetic.
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.10),
                    Color(red: 0.10, green: 0.06, blue: 0.16)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: Skip button on the right so users always have an exit.
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.trailing, 18)
                        .padding(.top, 12)
                }

                // Swipeable pages.
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        OnboardingPageView(page: pages[i])
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                // Bottom CTA — Next on early pages, Get Started on the last.
                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Next" : "Get Started")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(
                                Color(red: 0.55, green: 0.45, blue: 0.85).opacity(0.85)
                            )
                        )
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }

    private func finish() {
        hasSeenOnboarding = true
        dismiss()
    }
}

// MARK: - Page model + view

private struct OnboardingPage {
    let symbol: String
    let accent: Color
    let title: String
    let body: String
    let hint: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            // SF Symbol icon in a tinted glow circle.
            ZStack {
                Circle()
                    .fill(page.accent.opacity(0.18))
                    .frame(width: 160, height: 160)
                Circle()
                    .stroke(page.accent.opacity(0.35), lineWidth: 2)
                    .frame(width: 160, height: 160)
                Image(systemName: page.symbol)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(page.accent)
                    .shadow(color: page.accent.opacity(0.4), radius: 12)
            }

            // Title — large, rounded, white.
            Text(page.title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Body paragraph — softer for readability.
            Text(page.body)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 30)
                .frame(maxWidth: 540)

            // Small tip pill at the bottom of the page content.
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(page.accent)
                Text(page.hint)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Color.white.opacity(0.06))
            )
            .overlay(
                Capsule().stroke(page.accent.opacity(0.25), lineWidth: 1)
            )
            .padding(.horizontal, 24)

            Spacer()
        }
    }
}

#Preview {
    OnboardingView()
}
