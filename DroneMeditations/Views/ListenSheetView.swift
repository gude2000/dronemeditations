import SwiftUI

/// Modal sheet that listens via the microphone and shows the detected
/// pitch + cents-off-nearest-note in real time. "Set as Root" snaps the
/// chord generator's key + octave to the detected pitch.
struct ListenSheetView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var didStart = false

    private var detectedNote: DetectedNote? {
        if let hz = vm.micPitch.detectedHz { return freqToNote(hz) }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                VStack(spacing: 4) {
                    Text(detectedNote.map { "\($0.name)\($0.octave)" } ?? "—")
                        .font(.system(size: 80, weight: .bold, design: .default))
                        .foregroundStyle(.primary)
                        .frame(minHeight: 80)
                        .monospacedDigit()
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

                Text("Hold a steady tone — voice, instrument, tuning fork. We'll detect the nearest note and snap the chord root to match.")
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
                    await vm.micPitch.start()
                }
            }
        }
        // Refresh whenever the detector publishes a new pitch (or an error).
        .onReceive(vm.micPitch.$detectedHz) { _ in /* triggers redraw */ }
        .onReceive(vm.micPitch.$lastError) { _ in /* triggers redraw */ }
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
        return "Listening"
    }

    private func applyDetectedRoot() {
        guard let note = detectedNote else { return }
        // pitchClassId is 0..11 with C=0; PitchClass.allCases also has C=0.
        if note.pitchClassId >= 0 && note.pitchClassId < PitchClass.allCases.count {
            vm.setKey(PitchClass.allCases[note.pitchClassId])
        }
        vm.setOctave(max(1, min(6, note.octave)))
        dismiss()
    }
}
