import SwiftUI
import UniformTypeIdentifiers

struct OscillatorStrip: View {
    @EnvironmentObject var vm: DroneViewModel
    let index: Int

    @State private var showingFreqEditor = false
    @State private var freqInput = ""
    @State private var showingFilePicker = false
    @State private var loadError: String? = nil

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }
    /// True on iPad (regular horizontal size class in any orientation).
    /// Used to scale up button sizes, font sizes, and vertical spacing
    /// so one OSC strip visibly breathes on the larger canvas rather
    /// than looking like a postage stamp at iPhone scale.
    private var isPad: Bool { horizontalSizeClass == .regular }

    private var osc: OscillatorState { vm.oscillators[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: isPad ? 14 : 8) {
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
                // Waveform picker — segmented control. iPad uses
                // controlSize(.large) which physically grows the
                // segments (including their icons) and reserves
                // correct layout space — unlike scaleEffect, which
                // only scales pixels and would visually overflow into
                // the PAN slider.
                Picker("Waveform", selection: Binding(
                    get: { osc.waveform },
                    set: { vm.setWaveform($0, for: index) }
                )) {
                    ForEach(Waveform.allCases) { wf in
                        Image(systemName: wf.symbol).tag(wf)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(isPad ? .large : .regular)
                .frame(maxWidth: isPad ? 300 : 168)

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
            // Granular row, only visible when waveform == .granular. Shown
            // here (right under the waveform picker) so it lives in the same
            // visual region as the sample row — same "shape" of contextual
            // expansion.
            if osc.waveform == .granular {
                Divider().background(Color.white.opacity(0.06))
                granularSection
            }

            // Filter row.
            Divider().background(Color.white.opacity(0.06))
            filterSection

            // FX rows — user-requested vertical order: FM → Chorus → Delay → Reverb.
            fmSection
            chorusSection
            delaySection
            reverbSection

            // 4 LFO rows.
            VStack(spacing: isPad ? 12 : 6) {
                lfoSection(0)
                lfoSection(1)
                lfoSection(2)
                lfoSection(3)
            }
            .padding(.top, isPad ? 6 : 2)
        }
        .padding(.horizontal, isCompact ? 10 : (isPad ? 20 : 14))
        .padding(.vertical, isCompact ? 6 : (isPad ? 18 : 10))
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
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            // Bundled samples picker — shows entries discovered in the
            // app bundle's Samples folder at launch. Tapping one loads
            // it directly (no Files-app round-trip). Hidden when there
            // are no bundled samples present so the row isn't cluttered.
            if !BundledSampleStore.all.isEmpty {
                Menu {
                    let groups = Dictionary(grouping: BundledSampleStore.all) { $0.category }
                    ForEach(groups.keys.sorted(), id: \.self) { cat in
                        Section(cat) {
                            ForEach(groups[cat] ?? []) { entry in
                                Button(entry.name) {
                                    vm.loadBundledSample(entry, for: index)
                                }
                            }
                        }
                    }
                } label: {
                    Text("Bundled ▾")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.white.opacity(0.10))
                        )
                        .foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
            }

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

        // Play-window sub-row: only shown when a sample is actually loaded.
        // Lets the user trim the start/end of the sample and add
        // fade-in/fade-out at the loop boundary for seamless ambient loops.
        if osc.sampleName != nil {
            sampleWindowRow
        }
    }

    // MARK: - Sample play-window row (shown when a sample is loaded)

    @ViewBuilder
    private var sampleWindowRow: some View {
        // All four values are direct 0..1 (start/end) or 0..10 (fades)
        // sliders. Showing two pairs on one row keeps the visual footprint
        // compact while still being clearly self-explanatory.
        HStack(spacing: 10) {
            Text("WINDOW")
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(Color(red: 0.97, green: 0.79, blue: 0.28))
                .frame(width: 56, alignment: .leading)

            // Start (0..1)
            VStack(alignment: .leading, spacing: 2) {
                Text("start · \(Int(osc.sampleStartFrac * 100))%")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { osc.sampleStartFrac },
                    set: { vm.setSampleStart(min($0, osc.sampleEndFrac - 0.01), for: index) }
                ), in: 0...1)
                .tint(Color(red: 0.97, green: 0.79, blue: 0.28))
            }

            // End (0..1)
            VStack(alignment: .leading, spacing: 2) {
                Text("end · \(Int(osc.sampleEndFrac * 100))%")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { osc.sampleEndFrac },
                    set: { vm.setSampleEnd(max($0, osc.sampleStartFrac + 0.01), for: index) }
                ), in: 0...1)
                .tint(Color(red: 0.97, green: 0.79, blue: 0.28))
            }

            // Fade-in (0..10s)
            VStack(alignment: .leading, spacing: 2) {
                Text("fade-in · \(String(format: "%.1fs", osc.sampleFadeInSec))")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { osc.sampleFadeInSec },
                    set: { vm.setSampleFadeIn($0, for: index) }
                ), in: 0...10)
                .tint(Color(red: 0.97, green: 0.79, blue: 0.28))
            }

            // Fade-out (0..10s)
            VStack(alignment: .leading, spacing: 2) {
                Text("fade-out · \(String(format: "%.1fs", osc.sampleFadeOutSec))")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { osc.sampleFadeOutSec },
                    set: { vm.setSampleFadeOut($0, for: index) }
                ), in: 0...10)
                .tint(Color(red: 0.97, green: 0.79, blue: 0.28))
            }
        }
    }

    // MARK: - Granular row (shown only when waveform == .granular)

    @ViewBuilder
    private var granularSection: some View {
        let g = osc.grain
        // Density (log) — geiger ≈ 1, rain ≈ 30
        let densT = log(max(GrainState.densityMin, g.densityHz) / GrainState.densityMin) /
                    log(GrainState.densityMax / GrainState.densityMin)
        let sizeT = log(max(GrainState.sizeMinMs, g.sizeMs) / GrainState.sizeMinMs) /
                    log(GrainState.sizeMaxMs / GrainState.sizeMinMs)

        HStack(spacing: 10) {
            Text("GRAIN")
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(Color(red: 0.72, green: 0.86, blue: 1.0))
                .frame(width: 56, alignment: .leading)

            // Size slider (log scale)
            VStack(alignment: .leading, spacing: 2) {
                Text("size · \(Int(g.sizeMs)) ms")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { sizeT },
                    set: { t in
                        let ms = GrainState.sizeMinMs *
                                 pow(GrainState.sizeMaxMs / GrainState.sizeMinMs, t)
                        vm.setGrainSize(ms, for: index)
                    }
                ), in: 0...1)
                .tint(Color(red: 0.72, green: 0.86, blue: 1.0))
            }

            // Density slider (log scale)
            VStack(alignment: .leading, spacing: 2) {
                Text("density · \(formatDensity(g.densityHz))")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { densT },
                    set: { t in
                        let hz = GrainState.densityMin *
                                 pow(GrainState.densityMax / GrainState.densityMin, t)
                        vm.setGrainDensity(hz, for: index)
                    }
                ), in: 0...1)
                .tint(Color(red: 0.72, green: 0.86, blue: 1.0))
            }

            // Jitter slider (linear 0..1)
            VStack(alignment: .leading, spacing: 2) {
                Text("jitter · \(Int(g.jitter * 100))")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { g.jitter },
                    set: { vm.setGrainJitter($0, for: index) }
                ), in: 0...1)
                .tint(Color(red: 0.72, green: 0.86, blue: 1.0))
            }

            // Pan-spread slider (linear 0..1)
            VStack(alignment: .leading, spacing: 2) {
                Text("spread · \(Int(g.panSpread * 100))")
                    .font(.system(size: isPad ? 13 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { g.panSpread },
                    set: { vm.setGrainPanSpread($0, for: index) }
                ), in: 0...1)
                .tint(Color(red: 0.72, green: 0.86, blue: 1.0))
            }
        }
    }

    /// Format density as "N/s" for ≥1 grain/sec or "N/min" for sparser
    /// values so the sparse range (geiger-style) reads correctly.
    private func formatDensity(_ hz: Double) -> String {
        if hz >= 1.0 { return "\(Int(hz.rounded()))/s" }
        let perMin = Int((hz * 60).rounded())
        return "\(perMin)/min"
    }

    // MARK: - Filter row

    @ViewBuilder
    private var filterSection: some View {
        let f = osc.filter
        // Bigger row spacing on iPad — the segmented picker + sliders
        // need cushion between them so the picker's rendered edge
        // doesn't kiss the CUTOFF slider track.
        HStack(spacing: isPad ? 16 : 8) {
            Text("FILT")
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(.secondary)
                .frame(width: isPad ? 44 : 36, alignment: .leading)

            // Type segmented picker — controlSize(.large) on iPad.
            // Wider frame (240pt) so the picker has room and there's
            // breathing room before the CUTOFF slider.
            Picker("Filter type", selection: Binding(
                get: { f.type },
                set: { vm.setFilterType($0, for: index) }
            )) {
                ForEach(FilterState.FilterType.allCases) { t in
                    Text(t.shortLabel).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(isPad ? .large : .regular)
            .frame(width: isPad ? 240 : 116)

            VStack(alignment: .leading, spacing: 0) {
                Text(cutoffLabel(f.cutoffHz))
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
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
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
                FilterQSlider(
                    q: Binding(
                        get: { f.q },
                        set: { vm.setFilterQ($0, for: index) }
                    )
                )
            }

            // Per-voice drive (1.0 = clean, 12.0 = heavy tanh saturation).
            // Shares the filter row since drive shapes the raw oscillator
            // signal that the filter then carves.
            VStack(alignment: .leading, spacing: 0) {
                Text(osc.drive <= 1.01
                     ? "DRIVE clean"
                     : String(format: "DRIVE %.1fx", osc.drive))
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(osc.drive > 1.01 ? Color.accentColor : .secondary)
                Slider(
                    value: Binding(
                        get: { osc.drive },
                        set: { vm.setDrive($0, for: index) }
                    ),
                    in: 1.0...12.0
                ).tint(.white.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func timingStartButton(label: String, sec: Double) -> some View {
        Button {
            vm.setStartDelay(sec, for: index)
        } label: {
            if abs(osc.startDelaySec - sec) < 0.5 {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
    @ViewBuilder
    private func timingPlayButton(label: String, sec: Double) -> some View {
        Button {
            vm.setPlayDuration(sec, for: index)
        } label: {
            if abs(osc.playDurationSec - sec) < 0.5 {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// "Amount" chip in the drift menu. Tapping sets the per-voice pitch
    /// drift amplitude in semitones (nil = use mode default).
    @ViewBuilder
    private func driftSemitoneButton(label: String, semis: Double?) -> some View {
        let isActive: Bool = {
            if let s = semis {
                return osc.drift.pitchSemitones.map { abs($0 - s) < 0.05 } ?? false
            }
            return osc.drift.pitchSemitones == nil
        }()
        Button {
            vm.setVoicePitchSemitones(index, semitones: semis)
        } label: {
            if isActive {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    /// "Period" chip in the drift menu. Tapping sets the per-voice pitch
    /// drift period in seconds (nil = whole session length).
    @ViewBuilder
    private func driftPeriodButton(label: String, sec: Double?) -> some View {
        let isActive: Bool = {
            if let s = sec {
                return osc.drift.pitchPeriodSec.map { abs($0 - s) < 0.5 } ?? false
            }
            return osc.drift.pitchPeriodSec == nil
        }()
        Button {
            vm.setVoicePitchPeriodSec(index, sec: sec)
        } label: {
            if isActive {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func cutoffLabel(_ hz: Double) -> String {
        hz < 1000 ? String(format: "CUTOFF %.0fHz", hz)
                  : String(format: "CUTOFF %.2fk", hz / 1000)
    }

    // MARK: - FM row (cross-osc)

    @ViewBuilder
    private var fmSection: some View {
        let fm = osc.fm
        let active = fm.isActive
        HStack(spacing: 8) {
            Text("FM")
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            // Source picker — Off + the other 3 oscillators.
            Menu {
                Button {
                    vm.setFMSource(-1, for: index)
                } label: {
                    if fm.sourceIndex < 0 { Label("Off", systemImage: "checkmark") }
                    else { Text("Off") }
                }
                ForEach(Array(0..<4).filter { $0 != index }, id: \.self) { j in
                    Button {
                        vm.setFMSource(j, for: index)
                    } label: {
                        if fm.sourceIndex == j { Label("Osc \(j + 1)", systemImage: "checkmark") }
                        else                   { Text("Osc \(j + 1)") }
                    }
                }
            } label: {
                Text(fm.sourceIndex < 0 ? "Off" : "Osc \(fm.sourceIndex + 1)")
                    .font(.system(size: isPad ? 13 : 9, weight: .semibold))
                    .padding(.horizontal, isPad ? 12 : 6)
                    .padding(.vertical, isPad ? 7 : 3)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)

            VStack(alignment: .leading, spacing: 0) {
                Text(fm.index < 10
                     ? String(format: "INDEX %.1f", fm.index)
                     : String(format: "INDEX %d", Int(fm.index)))
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
                LogScaleSlider(
                    value: Binding(
                        get: { max(0.01, fm.index) }, // log slider can't include 0
                        set: { vm.setFMIndex($0, for: index) }
                    ),
                    minValue: 0.01,
                    maxValue: FMState.indexMax
                )
                .disabled(fm.sourceIndex < 0)
            }
        }
        .opacity(active ? 1.0 : 0.7)
    }

    // MARK: - Chorus row

    @ViewBuilder
    private var chorusSection: some View {
        let ch = osc.chorus
        let active = ch.mix > 0.001
        HStack(spacing: 8) {
            Text("CHO")
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(ch.rateHz < 1
                     ? String(format: "RATE %.2fHz", ch.rateHz)
                     : String(format: "RATE %.1fHz", ch.rateHz))
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
                LogScaleSlider(
                    value: Binding(
                        get: { ch.rateHz },
                        set: { vm.setChorusRate($0, for: index) }
                    ),
                    minValue: ChorusState.rateMin,
                    maxValue: ChorusState.rateMax
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("DEPTH \(Int(ch.depth * 100))")
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { ch.depth },
                        set: { vm.setChorusDepth($0, for: index) }
                    ),
                    in: 0.0...1.0
                ).tint(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("WIDTH \(Int(ch.width * 100))")
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { ch.width },
                        set: { vm.setChorusWidth($0, for: index) }
                    ),
                    in: 0.0...1.0
                ).tint(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("MIX \(Int(ch.mix * 100))")
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { ch.mix },
                        set: { vm.setChorusMix($0, for: index) }
                    ),
                    in: 0.0...1.0
                ).tint(.white.opacity(0.7))
            }
        }
        .opacity(active ? 1.0 : 0.7)
    }

    // MARK: - Reverb row

    @ViewBuilder
    private var reverbSection: some View {
        let rv = osc.reverb
        let active = rv.mix > 0.001
        HStack(spacing: 8) {
            Text("REV")
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(rv.decaySec < 1
                     ? String(format: "DECAY %.2fs", rv.decaySec)
                     : String(format: "DECAY %.1fs", rv.decaySec))
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
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
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
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
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            // Mode picker (mono / stereo / ping-pong). Stored on iOS but
            // audio rework for stereo/ping-pong is pending — web has it.
            Menu {
                ForEach(DelayState.Mode.allCases) { m in
                    Button {
                        vm.setDelayMode(m, for: index)
                    } label: {
                        if m == dl.mode { Label(m.label, systemImage: "checkmark") }
                        else            { Text(m.label) }
                    }
                }
            } label: {
                Text(dl.mode.label)
                    .font(.system(size: isPad ? 13 : 9, weight: .semibold))
                    .padding(.horizontal, isPad ? 12 : 6)
                    .padding(.vertical, isPad ? 7 : 3)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)

            // Musical-timing picker. Free = manual; the rest compute
            // delayTime from the global default tempo (120 BPM).
            Menu {
                ForEach(DelayState.Timing.allCases) { t in
                    Button {
                        vm.setDelayTiming(t, for: index)
                    } label: {
                        if t == dl.timing { Label(t.label, systemImage: "checkmark") }
                        else              { Text(t.label) }
                    }
                }
            } label: {
                Text(dl.timing.label)
                    .font(.system(size: isPad ? 13 : 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, isPad ? 12 : 6)
                    .padding(.vertical, isPad ? 7 : 3)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)

            VStack(alignment: .leading, spacing: 0) {
                Text(dl.timeSec < 1
                     ? String(format: "TIME %.0fms", dl.timeSec * 1000)
                     : String(format: "TIME %.2fs", dl.timeSec))
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
                    .foregroundStyle(.secondary)
                LogScaleSlider(
                    value: Binding(
                        get: { dl.timeSec },
                        set: { vm.setDelayTime($0, for: index) }
                    ),
                    minValue: DelayState.timeMin,
                    maxValue: DelayState.timeMax
                )
                .disabled(dl.timing != .free)
                .opacity(dl.timing == .free ? 1.0 : 0.5)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("FB \(Int(dl.feedback * 100))")
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
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
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
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
                .font(.system(size: isPad ? 12 : 9, weight: .heavy))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 36, alignment: .leading)

            // Shape picker — inline row of small toggleable icon
            // buttons (matches the web layout). One shape is active at
            // a time; tapping switches. SF Symbol icon, filled when
            // active. Compact enough that 6 fit on iPhone in portrait.
            HStack(spacing: isPad ? 5 : 3) {
                ForEach(LfoState.Shape.allCases) { s in
                    let isOn = (s == lfo.shape)
                    Button {
                        vm.setLfoShape(s, for: index, lfoIndex: lfoIndex)
                    } label: {
                        Image(systemName: s.sfSymbol)
                            .font(.system(size: isPad ? 14 : 9, weight: .semibold))
                            .frame(width: isPad ? 32 : 20, height: isPad ? 32 : 20)
                            .background(
                                RoundedRectangle(cornerRadius: isPad ? 6 : 4)
                                    .fill(isOn ? Color.white.opacity(0.85) : Color.white.opacity(0.10))
                            )
                            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }

            // v1.1 multi-target row — inline toggleable text buttons,
            // one per target. Tapping any target adds or removes it
            // from the LFO's target SET (not radio-select). All active
            // targets are driven simultaneously by the one LFO. Filled
            // accent background = active.
            HStack(spacing: isPad ? 5 : 3) {
                ForEach(LfoState.Target.allCases) { t in
                    let isOn = lfo.targets.contains(t)
                    Button {
                        vm.toggleLfoTarget(t, for: index, lfoIndex: lfoIndex)
                    } label: {
                        Text(t.shortLabel)
                            .font(.system(size: isPad ? 13 : 9, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, isPad ? 8 : 4)
                            .padding(.vertical, isPad ? 7 : 3)
                            .background(
                                RoundedRectangle(cornerRadius: isPad ? 6 : 4)
                                    .fill(isOn ? Color.accentColor : Color.white.opacity(0.10))
                            )
                            .foregroundStyle(isOn ? .white : .white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 0) {
                Text(rateLabel(lfo.rateHz))
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
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
                    .font(.system(size: isPad ? 12 : 9, weight: .bold))
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

    /// Sheet state for the rename/save-name prompt.
    @State private var showingVoiceNamePrompt = false
    @State private var voiceNameDraft: String = ""

    private var soloMuteCluster: some View {
        HStack(spacing: 8) {
            // Per-voice preset menu — save current voice as a preset, or
            // load any previously saved preset into THIS slot.
            Menu {
                Button {
                    voiceNameDraft = "\(osc.waveform.displayName) \(String(format: "%.1f", osc.frequencyHz)) Hz"
                    showingVoiceNamePrompt = true
                } label: {
                    Label("Save OSC \(index + 1) as preset…", systemImage: "square.and.arrow.down")
                }
                if !vm.voicePresets.isEmpty {
                    Section("Load into this voice") {
                        ForEach(vm.voicePresets) { p in
                            Button {
                                vm.loadVoicePreset(index, presetId: p.id)
                            } label: {
                                Label(p.name, systemImage: "star")
                            }
                        }
                    }
                    Section("Delete preset") {
                        ForEach(vm.voicePresets) { p in
                            Button(role: .destructive) {
                                vm.deleteVoicePreset(p.id)
                            } label: {
                                Label(p.name, systemImage: "trash")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "star.circle")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            // Use a SwiftUI sheet rather than a system .alert() with
            // TextField — alerts with text input force iOS to rebind
            // the audio session (the keyboard claims an input route),
            // which produces an audible crackle/glitch through the
            // playing drone. Sheet stays in-process and is silent.
            .sheet(isPresented: $showingVoiceNamePrompt) {
                SaveVoicePresetSheet(
                    voiceIndex: index,
                    name: $voiceNameDraft
                ) {
                    vm.saveCurrentVoiceAsPreset(index, name: voiceNameDraft)
                }
                .presentationDetents([.height(260)])
            }

            // Per-voice drift menu — pitch + pan motion for just this voice,
            // plus optional amount-in-semitones + period-in-seconds overrides
            // (the "Ocean" mode demonstrates this — slow ±¼-semi wave).
            Menu {
                // Quantize-to-scale toggle (v1.1). Snaps the voice's
                // final pitch (drift + LFO + FM) to the nearest chord
                // note across 2 octaves. Turns continuous motion into
                // arpeggio-like jumps along the current chord.
                Section {
                    Button {
                        vm.setVoiceQuantizeToScale(!osc.drift.quantizeToScale, for: index)
                    } label: {
                        if osc.drift.quantizeToScale {
                            Label("Quantize to scale", systemImage: "checkmark")
                        } else {
                            Text("Quantize to scale")
                        }
                    }
                }

                Section("OSC \(index + 1) · Pitch") {
                    ForEach(DriftVoiceConfig.PitchMode.allCases) { mode in
                        Button {
                            vm.setVoicePitchDrift(index, mode: mode)
                        } label: {
                            if mode == osc.drift.pitchMode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
                Section("OSC \(index + 1) · Amount") {
                    driftSemitoneButton(label: "Default", semis: nil)
                    driftSemitoneButton(label: "± ¼ semi", semis: 0.25)
                    driftSemitoneButton(label: "± ½ semi", semis: 0.5)
                    driftSemitoneButton(label: "± 1 semi", semis: 1)
                    driftSemitoneButton(label: "± 2 semi", semis: 2)
                    driftSemitoneButton(label: "± ½ oct",  semis: 6)
                    driftSemitoneButton(label: "± 1 oct",  semis: 12)
                    driftSemitoneButton(label: "± 2 oct",  semis: 24)
                }
                Section("OSC \(index + 1) · Period") {
                    driftPeriodButton(label: "Whole session", sec: nil)
                    driftPeriodButton(label: "30 s",  sec: 30)
                    driftPeriodButton(label: "1 min", sec: 60)
                    driftPeriodButton(label: "2 min", sec: 120)
                    driftPeriodButton(label: "5 min", sec: 300)
                    driftPeriodButton(label: "10 min", sec: 600)
                    driftPeriodButton(label: "20 min", sec: 1200)
                }
                Section("OSC \(index + 1) · Pan") {
                    ForEach(DriftVoiceConfig.PanMode.allCases) { mode in
                        Button {
                            vm.setVoicePanDrift(index, mode: mode)
                        } label: {
                            if mode == osc.drift.panMode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: osc.drift.isActive ? "wind.circle.fill" : "wind.circle")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(
                            osc.drift.isActive
                                ? Color(red: 0.55, green: 0.76, blue: 1.0).opacity(0.30)
                                : Color.white.opacity(0.10)
                        )
                    )
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)

            // Per-voice timing envelope menu (start delay + play duration).
            // Quick-pick chips for common values; tap any to apply. The
            // icon glows amber when an envelope is active so the user can
            // see at a glance which voices are timed.
            Menu {
                Section("OSC \(index + 1) · Start after") {
                    timingStartButton(label: "Now",     sec: 0)
                    timingStartButton(label: "15 s",    sec: 15)
                    timingStartButton(label: "30 s",    sec: 30)
                    timingStartButton(label: "1 min",   sec: 60)
                    timingStartButton(label: "2 min",   sec: 120)
                    timingStartButton(label: "5 min",   sec: 300)
                    timingStartButton(label: "10 min",  sec: 600)
                }
                Section("OSC \(index + 1) · Play duration") {
                    timingPlayButton(label: "Forever",  sec: 0)
                    timingPlayButton(label: "1 min",    sec: 60)
                    timingPlayButton(label: "3 min",    sec: 180)
                    timingPlayButton(label: "5 min",    sec: 300)
                    timingPlayButton(label: "10 min",   sec: 600)
                    timingPlayButton(label: "15 min",   sec: 900)
                    timingPlayButton(label: "20 min",   sec: 1200)
                }
            } label: {
                let active = osc.startDelaySec > 0 || osc.playDurationSec > 0
                Image(systemName: active ? "clock.fill" : "clock")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(
                            active
                                ? Color(red: 1.0, green: 0.78, blue: 0.45).opacity(0.30)
                                : Color.white.opacity(0.10)
                        )
                    )
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)

            Button {
                vm.randomizeOscillator(index)
            } label: {
                Image(systemName: "dice")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

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

/// Compact modal sheet for naming a new per-voice preset. Replaces
/// the system .alert() with TextField — alerts force a Core Audio
/// session rebind (because the keyboard claims an input route),
/// causing an audible crackle/glitch through the playing drone.
/// Mirrors the SavePresetSheet pattern from PresetPickerView.swift.
private struct SaveVoicePresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let voiceIndex: Int
    @Binding var name: String
    let onSave: () -> Void
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preset name", text: $name)
                        .focused($nameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } footer: {
                    Text("Saves OSC \(voiceIndex + 1)'s waveform, frequency, level, pan, filter, FX, LFOs, and drift.")
                }
            }
            .navigationTitle("Save OSC \(voiceIndex + 1) Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { nameFieldFocused = true }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave()
        dismiss()
    }
}
