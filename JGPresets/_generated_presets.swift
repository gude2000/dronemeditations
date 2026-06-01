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
