import SwiftUI
import UniformTypeIdentifiers

struct OscillatorStrip: View {
    @EnvironmentObject var vm: DroneViewModel
    let index: Int

    @State private var showingFreqEditor = false
    @State private var freqInput = ""
    @State private var showingFilePicker = false
    @State private var loadError: String? = nil

    private var osc: OscillatorState { vm.oscillators[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("OSC \(index + 1)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Button {
                    freqInput = String(format: "%.2f", osc.frequencyHz)
                    showingFreqEditor = true
                } label: {
                    Text(frequencyLabel)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(minWidth: 86, alignment: .leading)
                }
                .buttonStyle(.plain)

                Spacer()

                soloMuteCluster
            }

            // Log-scaled frequency slider with sample-accurate updates.
            FrequencySlider(
                frequency: Binding(
                    get: { osc.frequencyHz },
                    set: { vm.setFrequency($0, for: index) }
                ),
                hue: osc.hue
            )

            HStack(spacing: 12) {
                // Waveform picker
                Picker("Waveform", selection: Binding(
                    get: { osc.waveform },
                    set: { vm.setWaveform($0, for: index) }
                )) {
                    ForEach(Waveform.allCases) { wf in
                        Image(systemName: wf.symbol).tag(wf)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 168)

                // Pan slider
                VStack(alignment: .leading, spacing: 2) {
                    Text("PAN \(panLabel)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { osc.pan },
                            set: { vm.setPan($0, for: index) }
                        ),
                        in: -1.0...1.0
                    )
                    .tint(.white.opacity(0.7))
                }

                // Gain slider
                VStack(alignment: .leading, spacing: 2) {
                    Text("LVL")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { osc.amplitude },
                            set: { vm.setAmplitude($0, for: index) }
                        ),
                        in: 0.0...1.0
                    )
                    .tint(Color(hue: osc.hue, saturation: 0.5, brightness: 0.9))
                }
            }

            // Sample row, only visible when waveform == .sample.
            if osc.waveform == .sample {
                Divider().background(Color.white.opacity(0.06))
                sampleSection
            }

            // Filter row.
            Divider().background(Color.white.opacity(0.06))
            filterSection

            // Reverb + Delay rows.
            reverbSection
            delaySection

            // 3 LFO rows.
            VStack(spacing: 6) {
                lfoSection(0)
                lfoSection(1)
                lfoSection(2)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(hue: osc.hue, saturation: 0.4, brightness: 0.9, opacity: 0.35), lineWidth: 1)
        )
        .opacity(opacityForMuteState)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do { try vm.loadSample(from: url, for: index) }
                catch { loadError = error.localizedDescription }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
        .alert("Couldn't load sample", isPresented: Binding(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .alert("OSC \(index + 1) Frequency", isPresented: $showingFreqEditor) {
            TextField("Hz", text: $freqInput)
                .keyboardType(.decimalPad)
            Button("Set") {
                if let v = Double(freqInput),
                   v >= OscillatorState.minFrequency,
                   v <= OscillatorState.maxFrequency {
                    vm.setFrequency(v, for: index)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a value between \(Int(OscillatorState.minFrequency)) and \(Int(OscillatorState.maxFrequency)) Hz (2-decimal precision).")
        }
    }

    private var opacityForMuteState: Double {
        let anySoloed = vm.oscillators.contains { $0.isSoloed }
        let silenced = (anySoloed && !osc.isSoloed) || osc.isMuted
        return silenced ? 0.55 : 1.0
    }

    private var frequencyLabel: String {
        String(format: "%.2f Hz", osc.frequencyHz)
    }

    private var panLabel: String {
        let p = osc.pan
        if abs(p) < 0.02 { return "C" }
        let pct = Int((abs(p) * 100).rounded())
        return p < 0 ? "L\(pct)" : "R\(pct)"
    }

    // MARK: - Sample row

    @ViewBuilder
    private var sampleSection: some View {
        HStack(spacing: 10) {
            Text("SAMPLE")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Button {
                showingFilePicker = true
            } label: {
                Text(osc.sampleName == nil ? "Load file…" : "Replace…")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.12))
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Text(osc.sampleName ?? "no file loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if osc.sampleName != nil {
                Button {
                    vm.clearSample(for: index)
                } label: {
                    Text("Clear")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.red.opacity(0.20))
                        )
                        .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.72))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Filter row

    @ViewBuilder
    private var filterSection: some View {
        let f = osc.filter
        HStack(spacing: 8) {
            Text("FILT")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            // Type segmented picker
            Picker("Filter type", selection: Binding(
                get: { f.type },
                set: { vm.setFilterType($0, for: index) }
            )) {
                ForEach(FilterState.FilterType.allCases) { t in
                    Text(t.shortLabel).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 116)

            VStack(alignment: .leading, spacing: 0) {
                Text(cutoffLabel(f.cutoffHz))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                FilterCutoffSlider(
                    cutoffHz: Binding(
                        get: { f.cutoffHz },
                        set: { vm.setFilterCutoff($0, for: index) }
                    )
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "Q %.2f", f.q))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                FilterQSlider(
                    q: Binding(
                        get: { f.q },
                        set: { vm.setFilterQ($0, for: index) }
                    )
                )
            }
        }
    }

    private func cutoffLabel(_ hz: Double) -> String {
        hz < 1000 ? String(format: "CUTOFF %.0fHz", hz)
                  : String(format: "CUTOFF %.2fk", hz / 1000)
    }

    // MARK: - Reverb row

    @ViewBuilder
    private var reverbSection: some View {
        let rv = osc.reverb
        let active = rv.mix > 0.001
        HStack(spacing: 8) {
            Text("REV")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(rv.decaySec < 1
                     ? String(format: "DECAY %.2fs", rv.decaySec)
                     : String(format: "DECAY %.1fs", rv.decaySec))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                LogScaleSlider(
                    value: Binding(
                        get: { rv.decaySec },
                        set: { vm.setReverbDecay($0, for: index) }
                    ),
                    minValue: ReverbState.decayMin,
                    maxValue: ReverbState.decayMax
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("MIX \(Int(rv.mix * 100))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { rv.mix },
                        set: { vm.setReverbMix($0, for: index) }
                    ),
                    in: 0.0...1.0
                ).tint(.white.opacity(0.7))
            }
        }
        .opacity(active ? 1.0 : 0.7)
    }

    // MARK: - Delay row

    @ViewBuilder
    private var delaySection: some View {
        let dl = osc.delay
        let active = dl.mix > 0.001
        HStack(spacing: 8) {
            Text("DLY")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(dl.timeSec < 1
                     ? String(format: "TIME %.0fms", dl.timeSec * 1000)
                     : String(format: "TIME %.2fs", dl.timeSec))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                LogScaleSlider(
                    value: Binding(
                        get: { dl.timeSec },
                        set: { vm.setDelayTime($0, for: index) }
                    ),
                    minValue: DelayState.timeMin,
                    maxValue: DelayState.timeMax
                )
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("FB \(Int(dl.feedback * 100))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { dl.feedback },
                        set: { vm.setDelayFeedback($0, for: index) }
                    ),
                    in: 0.0...DelayState.feedbackMax
                ).tint(.white.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("MIX \(Int(dl.mix * 100))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { dl.mix },
                        set: { vm.setDelayMix($0, for: index) }
                    ),
                    in: 0.0...1.0
                ).tint(.white.opacity(0.7))
            }
        }
        .opacity(active ? 1.0 : 0.7)
    }

    // MARK: - LFO row

    @ViewBuilder
    private func lfoSection(_ lfoIndex: Int) -> some View {
        let lfo = osc.lfos[lfoIndex]
        let active = lfo.depth > 0.001
        HStack(spacing: 8) {
            Text("LFO \(lfoIndex + 1)")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            // Shape picker
            Picker("Shape", selection: Binding(
                get: { lfo.shape },
                set: { vm.setLfoShape($0, for: index, lfoIndex: lfoIndex) }
            )) {
                ForEach(LfoState.Shape.allCases) { s in
                    Image(systemName: s == .sine ? "waveform.path" : "square.split.bottomrightquarter").tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 70)

            // Target picker
            Picker("Target", selection: Binding(
                get: { lfo.target },
                set: { vm.setLfoTarget($0, for: index, lfoIndex: lfoIndex) }
            )) {
                ForEach(LfoState.Target.allCases) { t in
                    Text(t.shortLabel).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)

            VStack(alignment: .leading, spacing: 0) {
                Text(rateLabel(lfo.rateHz))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                LfoRateSlider(
                    rateHz: Binding(
                        get: { lfo.rateHz },
                        set: { vm.setLfoRate($0, for: index, lfoIndex: lfoIndex) }
                    )
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("DEPTH \(Int(lfo.depth * 100))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { lfo.depth },
                        set: { vm.setLfoDepth($0, for: index, lfoIndex: lfoIndex) }
                    ),
                    in: 0.0...1.0
                )
                .tint(.white.opacity(0.7))
            }
        }
        .opacity(active ? 1.0 : 0.55)
    }

    private func rateLabel(_ hz: Double) -> String {
        if hz < 1.0 { return String(format: "RATE %.2fHz", hz) }
        return String(format: "RATE %.1fHz", hz)
    }

    private var soloMuteCluster: some View {
        HStack(spacing: 8) {
            Button {
                vm.toggleSolo(index)
            } label: {
                Text("S")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(osc.isSoloed ? Color.yellow : Color.white.opacity(0.10))
                    )
                    .foregroundStyle(osc.isSoloed ? .black : .white)
            }
            .buttonStyle(.plain)

            Button {
                vm.toggleMute(index)
            } label: {
                Text("M")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(osc.isMuted ? Color.red : Color.white.opacity(0.10))
                    )
                    .foregroundStyle(osc.isMuted ? .white : .white)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Generic log-scale slider for an arbitrary range.
private struct LogScaleSlider: View {
    @Binding var value: Double
    let minValue: Double
    let maxValue: Double
    var body: some View {
        let lo = log2(minValue)
        let hi = log2(maxValue)
        let binding = Binding<Double>(
            get: {
                let v = log2(max(minValue, value))
                return (v - lo) / (hi - lo)
            },
            set: { t in value = pow(2.0, lo + t * (hi - lo)) }
        )
        Slider(value: binding, in: 0.0...1.0).tint(.white.opacity(0.7))
    }
}

/// Log-scaled filter cutoff slider, 20–8000 Hz.
private struct FilterCutoffSlider: View {
    @Binding var cutoffHz: Double
    var body: some View {
        let lo = log2(FilterState.cutoffMin)
        let hi = log2(FilterState.cutoffMax)
        let binding = Binding<Double>(
            get: {
                let v = log2(max(FilterState.cutoffMin, cutoffHz))
                return (v - lo) / (hi - lo)
            },
            set: { t in
                cutoffHz = pow(2.0, lo + t * (hi - lo))
            }
        )
        Slider(value: binding, in: 0.0...1.0)
            .tint(.white.opacity(0.7))
    }
}

/// Log-scaled filter Q slider, 0.3–20.
private struct FilterQSlider: View {
    @Binding var q: Double
    var body: some View {
        let lo = log2(FilterState.qMin)
        let hi = log2(FilterState.qMax)
        let binding = Binding<Double>(
            get: {
                let v = log2(max(FilterState.qMin, q))
                return (v - lo) / (hi - lo)
            },
            set: { t in
                q = pow(2.0, lo + t * (hi - lo))
            }
        )
        Slider(value: binding, in: 0.0...1.0)
            .tint(.white.opacity(0.7))
    }
}

/// Log-scaled LFO rate slider, 0.02–8 Hz.
private struct LfoRateSlider: View {
    @Binding var rateHz: Double
    var body: some View {
        let lo = log2(LfoState.rateMin)
        let hi = log2(LfoState.rateMax)
        let binding = Binding<Double>(
            get: {
                let v = log2(max(LfoState.rateMin, rateHz))
                return (v - lo) / (hi - lo)
            },
            set: { t in
                rateHz = pow(2.0, lo + t * (hi - lo))
            }
        )
        Slider(value: binding, in: 0.0...1.0)
            .tint(.white.opacity(0.7))
    }
}

/// Logarithmic-frequency slider. Looks linear in pitch space, which matches musical intuition.
private struct FrequencySlider: View {
    @Binding var frequency: Double
    let hue: Double

    private let minHz: Double = OscillatorState.minFrequency
    private let maxHz: Double = OscillatorState.maxFrequency

    var body: some View {
        let lo = log2(minHz)
        let hi = log2(maxHz)
        let binding = Binding<Double>(
            get: {
                let v = log2(max(minHz, frequency))
                return (v - lo) / (hi - lo)
            },
            set: { t in
                let v = lo + t * (hi - lo)
                frequency = pow(2.0, v)
            }
        )
        Slider(value: binding, in: 0.0...1.0)
            .tint(Color(hue: hue, saturation: 0.65, brightness: 0.95))
    }
}
