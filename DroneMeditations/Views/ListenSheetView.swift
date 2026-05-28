import SwiftUI

/// Modal sheet that listens via the microphone and shows the detected
/// pitch + cents-off-nearest-note in real time. "Set as Root" snaps the
/// chord generator's key + octave to the detected pitch.
struct ListenSheetView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var didStart = false
    // Bumped on every objectWillChange from the mic detector. The body
    // reads this so SwiftUI knows it depends on it — that's what forces
    // a re-render when the nested ObservableObject changes. The empty
    // .onReceive closures from before were no-ops because they didn't
    // mutate any state the view tracks.
    @State private var redrawTick: Int = 0

    private var detectedNote: DetectedNote? {
        if let hz = vm.micPitch.detectedHz { return freqToNote(hz) }
        return nil
    }

    var body: some View {
        // Reading redrawTick here registers this view's dependency on it.
        // When the onReceive subscriptions below bump redrawTick, SwiftUI
        // re-runs body, which re-reads vm.micPitch.isListening / detectedHz
        // / lastError and updates the displayed status line accordingly.
        let _ = redrawTick
        return NavigationStack {
            VStack(spacing: 14) {
                Text(statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                VStack(spacing: 4) {
                    ZStack(alignment: .topTrailing) {
                        Text(detectedNote.map { "\($0.name)\($0.octave)" } ?? "—")
                            .font(.system(size: 80, weight: .bold, design: .default))
                            .foregroundStyle(.primary)
                            .frame(minHeight: 80)
                            .monospacedDigit()
                            .opacity(vm.micPitch.isHolding ? 0.6 : 1.0)
                        // "held" badge when the displayed pitch is sticky
                        // (mic went quiet but we're keeping the last value).
                        if vm.micPitch.isHolding {
                            Text("HELD")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.10 * 9)
                                .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.55))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.15))
                                )
                                .offset(x: 4, y: 14)
                        }
                    }
                    Text(vm.micPitch.detectedHz.map { String(format: "%.2f Hz", $0) } ?? "— Hz")
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                    Text(detectedNote.map {
                        String(format: "%@%.0f cents", $0.cents >= 0 ? "+" : "", $0.cents)
                    } ?? "— cents")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)

                // Live audio-level meter so the user can confirm the mic
                // is being heard even when no stable pitch is detected.
                levelMeter

                HStack(spacing: 8) {
                    Button {
                        applyDetectedRoot()
                    } label: {
                        Text("Set as Root")
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(detectedNote == nil ? Color.gray.opacity(0.30) : Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(detectedNote == nil)

                    Button {
                        vm.micPitch.clearHeldPitch()
                    } label: {
                        Text("Reset")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.10))
                            .foregroundStyle(.white.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(detectedNote == nil)
                }

                // When an init error is set (e.g. mic AU never settled),
                // give the user a way to retry without dismissing the
                // sheet. Otherwise the only escape was tap Done →
                // re-open Listen, which most users won't think to do.
                if vm.micPitch.lastError != nil {
                    Button {
                        retryListen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Try again")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }

                Text("Hold a steady tone — voice, instrument, tuning fork. The last detected pitch is held on screen until you tap Reset or sing a new one — so you don't have to race the readout.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .navigationTitle("Tune to Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if !didStart {
                    didStart = true
                    // Cancel any in-flight pause/stop fade tasks on the
                    // controller BEFORE starting the mic. Otherwise a
                    // scheduled engine.pause() (from a recent pause
                    // button tap) can fire mid-Listen, suspending the
                    // I/O render loop and starving the mic tap of
                    // audio → "Listening — hold a steady tone" forever,
                    // or in the worst case an NSException crash from
                    // modifying the audio graph while a tap is active.
                    vm.controller.prepareForListen()
                    await vm.micPitch.start()
                }
            }
        }
        // Bump redrawTick on EVERY @Published change from the nested mic
        // detector. The body reads redrawTick (above) so this actually
        // forces a re-render. Previously the closures were empty no-ops,
        // which meant the view never updated when the detector's
        // isListening / detectedHz / etc. changed — status text stayed
        // stuck on "Requesting microphone…" forever.
        .onReceive(vm.micPitch.objectWillChange) { _ in
            redrawTick &+= 1
        }
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                let pct = levelPercent
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.55, green: 0.76, blue: 1.0),
                                     Color(red: 0.78, green: 0.55, blue: 1.0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * CGFloat(pct)))
                    .animation(.linear(duration: 0.07), value: pct)
            }
        }
        .frame(height: 8)
        .padding(.vertical, 4)
    }

    /// 0…1 mic level mapped logarithmically (−60 dB → 0, 0 dB → 1).
    private var levelPercent: Double {
        let l = Double(vm.micPitch.inputLevel)
        if l <= 0 { return 0 }
        let dB = 20.0 * log10(l)
        return min(1, max(0, (dB + 60.0) / 60.0))
    }

    private var statusLine: String {
        if let err = vm.micPitch.lastError { return err }
        if !vm.micPitch.isListening { return "Requesting microphone…" }
        if vm.micPitch.detectedHz == nil { return "Listening — hold a steady tone" }
        if vm.micPitch.isHolding { return "Held — tap Set as Root, or sing a new note" }
        return "Listening"
    }

    /// Re-invoke MicPitchDetector.start() so the user can recover from
    /// a transient init failure (e.g. "Microphone format unavailable")
    /// without dismissing the sheet. The detector's lastError clears on
    /// each start() invocation, so a successful retry transitions the
    /// status line out of the error state automatically.
    private func retryListen() {
        Task { @MainActor in
            await vm.micPitch.start()
        }
    }

    private func applyDetectedRoot() {
        guard let note = detectedNote else { return }
        // pitchClassId is 0..11 with C=0; PitchClass.allCases also has C=0.
        if note.pitchClassId >= 0 && note.pitchClassId < PitchClass.allCases.count {
            vm.setKey(PitchClass.allCases[note.pitchClassId])
        }
        vm.setOctave(max(1, min(6, note.octave)))
        // Dismiss without SwiftUI's default sheet-slide animation so
        // the user can tap Play on the main UI immediately. With the
        // default animation, the sheet takes ~400 ms to slide out and
        // touches on the parent are ignored during that window —
        // makes the Play button feel unresponsive right after Set as Root.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dismiss()
        }
    }
}
