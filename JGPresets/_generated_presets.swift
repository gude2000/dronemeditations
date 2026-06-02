        // ── JG named presets (author-curated) ──

        Preset("JG Dub Wave", .developerPatches,
               subtitle: "Author recording · dubwise low end · Replay × 5 motion", [
                Voice(
                    hz: 329.66,
                    pan: -0.84,
                    wave: .sample,
                    amp: 0.04,
                    drive: 2.10,
                    startDelaySec: 15,
                    playDurationSec: 180,
                    replayCount: 2,
                    filter: FilterState(type: .lowpass, cutoffHz: 959, q: 1.84),
                    reverb: ReverbState(decaySec: 1.10, mix: 0.26),
                    delay: DelayState(timeSec: 0.52, feedback: 0.24, mix: 0.41),
                    chorus: ChorusState(rateHz: 0.46, depth: 0.37, width: 0.82, mix: 0.54),
                    grain: GrainState(sizeMs: 63, densityHz: 9.90, jitter: 0.54, panSpread: 0.77),
                    bundledSampleName: "JG Dub Wave",
                    grainSamplePosFrac: 0.69,
                    grainSamplePosJitter: 0.15
                ),
                Voice(
                    hz: 61.27,
                    pan: 0.10,
                    wave: .sine,
                    amp: 0.59,
                    drive: 1.38,
                    reverb: ReverbState(decaySec: 4.71, mix: 0.30),
                    delay: DelayState(timeSec: 0.30, feedback: 0.40, mix: 0.14),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.21)
                ),
                Voice(
                    hz: 123.47,
                    pan: -0.10,
                    wave: .sample,
                    amp: 0.99,
                    drive: 3.77,
                    startDelaySec: 30,
                    playDurationSec: 180,
                    replayCount: 3,
                    reverb: ReverbState(decaySec: 4.75, mix: 0.49),
                    delay: DelayState(timeSec: 0.70, feedback: 0.67, mix: 0.66),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.19),
                    bundledSampleName: "JG Dub Wave-2"
                ),
                Voice(
                    hz: 138.59,
                    pan: 0.30,
                    wave: .sine,
                    startDelaySec: 120,
                    playDurationSec: 60,
                    replayCount: 5,
                    reverb: ReverbState(decaySec: 2, mix: 0.66),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0)
                )
               ]),

        Preset("JG Interrupted", .developerPatches,
               subtitle: "Vocal granular at high pos jitter · pulsing delay · Aeolian", [
                Voice(
                    hz: 440,
                    pan: -0.30,
                    wave: .sample,
                    amp: 0.44,
                    drive: 1.76,
                    startDelaySec: 15,
                    playDurationSec: 60,
                    replayCount: 2,
                    filter: FilterState(type: .lowpass, cutoffHz: 4060, q: 2.09),
                    reverb: ReverbState(decaySec: 3.58, mix: 0.12),
                    delay: DelayState(timeSec: 0.09, feedback: 0.87, mix: 0.96),
                    chorus: ChorusState(rateHz: 0.21, depth: 0.21, width: 0.68, mix: 0.18),
                    grain: GrainState(sizeMs: 487, densityHz: 6.38, jitter: 0.44, panSpread: 0.78),
                    bundledSampleName: "JG Dub Wave",
                    sampleGranular: true,
                    grainSamplePosFrac: 0.70
                ),
                Voice(
                    hz: 105.84,
                    pan: 0.10,
                    wave: .sine,
                    amp: 0.13,
                    drive: 1.58,
                    playDurationSec: 180,
                    replayCount: 2,
                    delay: DelayState(timeSec: 0.30, feedback: 0.64, mix: 0.60),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.07)
                ),
                Voice(
                    hz: 113.22,
                    pan: -0.10,
                    wave: .sine,
                    amp: 0.14,
                    drive: 1.18,
                    startDelaySec: 30,
                    playDurationSec: 180,
                    replayCount: 2,
                    reverb: ReverbState(decaySec: 7.26, mix: 0.52),
                    delay: DelayState(timeSec: 0.97, feedback: 0.72, mix: 0.80),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.20)
                ),
                Voice(
                    hz: 122.25,
                    pan: 0.30,
                    wave: .triangle,
                    amp: 0.29,
                    drive: 1.98,
                    startDelaySec: 60,
                    playDurationSec: 60,
                    replayCount: 2,
                    filter: FilterState(type: .highpass, cutoffHz: 284, q: 4.71),
                    delay: DelayState(timeSec: 0.72, feedback: 0.65, mix: 0.29),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0)
                )
               ]),

        Preset("JG JoG", .developerPatches,
               subtitle: "Author recording · JoG sample-granular study", [
                Voice(
                    hz: 110,
                    pan: -0.30,
                    wave: .sample,
                    amp: 0.89,
                    drive: 1.63,
                    startDelaySec: 30,
                    playDurationSec: 180,
                    replayCount: 3,
                    filter: FilterState(type: .lowpass, cutoffHz: 4277, q: 3.98),
                    reverb: ReverbState(decaySec: 4.49, mix: 0.69),
                    delay: DelayState(timeSec: 0.19, feedback: 0.56, mix: 0.34),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0),
                    grain: GrainState(sizeMs: 80, densityHz: 2.67, jitter: 0, panSpread: 0.50),
                    bundledSampleName: "JG JoG",
                    sampleGranular: true
                ),
                Voice(
                    hz: 138.59,
                    pan: 0.10,
                    wave: .sawtooth,
                    amp: 0.44,
                    startDelaySec: 60,
                    playDurationSec: 60,
                    replayCount: 5,
                    reverb: ReverbState(decaySec: 3.26, mix: 0.30),
                    delay: DelayState(timeSec: 0.25, feedback: 0.47, mix: 0.61),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.08)
                ),
                Voice(
                    hz: 174.61,
                    pan: -0.10,
                    wave: .sine,
                    amp: 0.47,
                    drive: 1.20,
                    filter: FilterState(type: .lowpass, cutoffHz: 2002, q: 1.52),
                    reverb: ReverbState(decaySec: 5.73, mix: 0.43),
                    delay: DelayState(timeSec: 0.30, feedback: 0.40, mix: 0.22),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.19)
                ),
                Voice(
                    hz: 56.84,
                    pan: 0.30,
                    wave: .sawtooth,
                    amp: 0.50,
                    drive: 2.10,
                    filter: FilterState(type: .lowpass, cutoffHz: 471, q: 3.21),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.16)
                )
               ]),

        Preset("JG Ondulations", .developerPatches,
               subtitle: "Author recording · undulating sample-granular cloud", [
                Voice(
                    hz: 251.49,
                    pan: -0.27,
                    wave: .sample,
                    amp: 0.32,
                    drive: 1.76,
                    startDelaySec: 15,
                    playDurationSec: 180,
                    replayCount: 2,
                    filter: FilterState(type: .lowpass, cutoffHz: 644, q: 0.88),
                    reverb: ReverbState(decaySec: 2.04, mix: 0.24),
                    delay: DelayState(timeSec: 0.12, feedback: 0.02, mix: 0.38),
                    chorus: ChorusState(rateHz: 0.21, depth: 0.21, width: 0.68, mix: 0),
                    grain: GrainState(sizeMs: 213, densityHz: 21.52, jitter: 0.54, panSpread: 0.64),
                    bundledSampleName: "JG Dub Wave",
                    sampleGranular: true,
                    grainSamplePosFrac: 0.69,
                    grainSamplePosJitter: 0.15
                ),
                Voice(
                    hz: 61.27,
                    pan: 0.10,
                    wave: .sine,
                    amp: 0.59,
                    drive: 1.38,
                    reverb: ReverbState(decaySec: 4.71, mix: 0.30),
                    delay: DelayState(timeSec: 0.30, feedback: 0.40, mix: 0.14),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.21)
                ),
                Voice(
                    hz: 123.47,
                    pan: -0.10,
                    wave: .sample,
                    amp: 0.96,
                    drive: 2.73,
                    startDelaySec: 30,
                    playDurationSec: 180,
                    replayCount: 3,
                    reverb: ReverbState(decaySec: 4.75, mix: 0.37),
                    delay: DelayState(timeSec: 0.70, feedback: 0.67, mix: 0.57),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.19),
                    bundledSampleName: "JG Dub Wave-2"
                ),
                Voice(
                    hz: 138.59,
                    pan: 0.30,
                    wave: .sine,
                    startDelaySec: 120,
                    playDurationSec: 60,
                    replayCount: 5,
                    reverb: ReverbState(decaySec: 2, mix: 0.66),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0)
                )
               ]),

        Preset("JG Small Steps", .developerPatches,
               subtitle: "Author recording · small-steps sample-granular", [
                Voice(
                    hz: 220,
                    pan: -0.40,
                    wave: .granular,
                    amp: 0.55,
                    drive: 1.29,
                    playDurationSec: 120,
                    replayCount: 0,
                    filter: FilterState(type: .lowpass, cutoffHz: 4200, q: 0.76),
                    reverb: ReverbState(decaySec: 6.58, mix: 0.86),
                    delay: DelayState(timeSec: 1.22, feedback: 0.90, mix: 0.98),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.09),
                    grain: GrainState(sizeMs: 23, densityHz: 5.33, jitter: 0, panSpread: 0.99),
                    grainSamplePosJitter: 0.37
                ),
                Voice(
                    hz: 182.57,
                    pan: 0.40,
                    wave: .sample,
                    amp: 0.96,
                    drive: 1.77,
                    startDelaySec: 30,
                    playDurationSec: 120,
                    replayCount: 0,
                    filter: FilterState(type: .lowpass, cutoffHz: 2000, q: 2.06),
                    reverb: ReverbState(decaySec: 8, mix: 0.55),
                    delay: DelayState(timeSec: 0.75, feedback: 0.56, mix: 0.65),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.04),
                    grain: GrainState(sizeMs: 130, densityHz: 5.33, jitter: 0, panSpread: 0.85),
                    bundledSampleName: "JG Small Steps",
                    sampleGranular: true,
                    grainSamplePosJitter: 0.35
                ),
                Voice(
                    hz: 135.22,
                    pan: 0.90,
                    wave: .triangle,
                    amp: 0.20,
                    reverb: ReverbState(decaySec: 9.29, mix: 0.84),
                    delay: DelayState(timeSec: 0.53, feedback: 0.73, mix: 0.86),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.10)
                ),
                Voice(
                    hz: 535.47,
                    pan: -0.00,
                    wave: .triangle,
                    amp: 0.27,
                    drive: 1.41,
                    filter: FilterState(type: .lowpass, cutoffHz: 3961, q: 1.00),
                    reverb: ReverbState(decaySec: 3.19, mix: 0.22),
                    delay: DelayState(timeSec: 0.48, feedback: 0.28, mix: 0.27),
                    chorus: ChorusState(rateHz: 1.82, depth: 0.31, width: 0.88, mix: 0.19)
                )
               ]),

        Preset("JG WalK", .developerPatches,
               subtitle: "Author recording · slower JoG sample-granular", [
                Voice(
                    hz: 110,
                    pan: 0.01,
                    wave: .sample,
                    amp: 0.89,
                    drive: 1.63,
                    startDelaySec: 30,
                    playDurationSec: 180,
                    replayCount: 3,
                    filter: FilterState(type: .lowpass, cutoffHz: 4277, q: 3.98),
                    reverb: ReverbState(decaySec: 3.35, mix: 0.56),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0),
                    grain: GrainState(sizeMs: 76, densityHz: 1.33, jitter: 0, panSpread: 0.50),
                    bundledSampleName: "JG JoG",
                    sampleGranular: true
                ),
                Voice(
                    hz: 138.59,
                    pan: 0.10,
                    wave: .sawtooth,
                    amp: 0.60,
                    startDelaySec: 60,
                    playDurationSec: 60,
                    replayCount: 5,
                    reverb: ReverbState(decaySec: 3.26, mix: 0.30),
                    delay: DelayState(timeSec: 0.25, feedback: 0.47, mix: 0.61),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.08)
                ),
                Voice(
                    hz: 174.61,
                    pan: 0,
                    wave: .sine,
                    amp: 0.55,
                    reverb: ReverbState(decaySec: 4.37, mix: 0.23),
                    delay: DelayState(timeSec: 0.30, feedback: 0.40, mix: 0.26),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.13)
                ),
                Voice(
                    hz: 56.84,
                    pan: 0.30,
                    wave: .sine,
                    amp: 0.83,
                    drive: 1.51,
                    filter: FilterState(type: .lowpass, cutoffHz: 6636, q: 3.21),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.16)
                )
               ]),

        Preset("JG Whole Tone Wind", .developerPatches,
               subtitle: "Whole-tone stack · sample granular wind · Replay × 5", [
                Voice(
                    hz: 340.92,
                    pan: -0.33,
                    wave: .sample,
                    amp: 0.37,
                    drive: 1.76,
                    startDelaySec: 15,
                    playDurationSec: 180,
                    replayCount: 2,
                    filter: FilterState(type: .lowpass, cutoffHz: 644, q: 0.88),
                    reverb: ReverbState(decaySec: 2.04, mix: 0.24),
                    delay: DelayState(timeSec: 0.12, feedback: 0.02, mix: 0.38),
                    chorus: ChorusState(rateHz: 0.21, depth: 0.21, width: 0.68, mix: 0),
                    grain: GrainState(sizeMs: 213, densityHz: 21.52, jitter: 0.54, panSpread: 0.64),
                    bundledSampleName: "JG Dub Wave",
                    sampleGranular: true,
                    grainSamplePosFrac: 0.69,
                    grainSamplePosJitter: 0.15
                ),
                Voice(
                    hz: 110.00,
                    pan: 0.10,
                    wave: .sine,
                    amp: 0.49,
                    drive: 1.38,
                    reverb: ReverbState(decaySec: 4.71, mix: 0.30),
                    delay: DelayState(timeSec: 0.30, feedback: 0.40, mix: 0.14),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.21)
                ),
                Voice(
                    hz: 123.47,
                    pan: -0.10,
                    wave: .sample,
                    amp: 0.75,
                    drive: 2.73,
                    startDelaySec: 30,
                    playDurationSec: 180,
                    replayCount: 3,
                    reverb: ReverbState(decaySec: 4.75, mix: 0.37),
                    delay: DelayState(timeSec: 0.70, feedback: 0.67, mix: 0.57),
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0.19),
                    bundledSampleName: "JG Dub Wave-2"
                ),
                Voice(
                    hz: 138.59,
                    pan: 0.30,
                    wave: .sine,
                    startDelaySec: 120,
                    playDurationSec: 60,
                    replayCount: 5,
                    chorus: ChorusState(rateHz: 0.50, depth: 0.40, width: 0.70, mix: 0)
                )
               ]),
