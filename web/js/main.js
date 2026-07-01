// Bootstrap — owns app state, glues UI + audio + visualizations together.

// v1 cache-bust on ALL module imports. Bumping the version in
// index.html's <script src="./js/main.js?v=N"> alone only invalidates
// main.js — the browser still serves cached versions of any module
// imported with no query string, so ui.js / audio.js / etc. fixes
// can sit invisibly behind stale cache for hours. Keeping the v in
// sync with index.html on every release fixes that.
import {
  CHORDS, PRESETS, WAVEFORMS, JOURNEYS, journeyTotalSeconds, PITCH_CLASSES, TUNING_SYSTEMS,
  pitchToFrequency, chordFrequencies, FREQ_MIN, FREQ_MAX
} from "./music.js?v=44";
import { AudioEngine } from "./audio.js?v=43";
import { initUI, renderAll } from "./ui.js?v=48";
import {
  exportUserPresetDownload, importUserPresetFromFile
} from "./preset-sharing.js?v=46";
import { initVisualizations, setChladniVisible, setSpectrumVisible } from "./visualizations.js?v=43";
import {
  loadUserPresets, saveUserPresets, newPresetId, newSampleId,
  loadVoicePresets, saveVoicePresets, newVoicePresetId,
  loadUserJourneys, saveUserJourneys, newUserJourneyId,
  loadLibrarySamples, saveLibrarySamples,
  loadAutomationSetups, saveAutomationSetups, newAutomationSetupId,
  putSample, getSample, deleteSample
} from "./storage.js?v=44";

// ──────────────────────────────────────────────────
// State.
// ──────────────────────────────────────────────────
// Each oscillator has 4 LFOs and 1 filter.
//   Default LFO 1: sine  → pan
//   Default LFO 2: S&H   → amp
//   Default LFO 3: sine  → cutoff
//   Default LFO 4: sine  → pitch (vibrato)
// `shape` and `target` are user-editable per LFO; `depth: 0` disables the LFO.
/// Best-effort MIME type from a sample filename — used when the server
/// didn't supply a content-type header (GitHub Pages sometimes doesn't
/// on .ogg / .flac).
function guessMimeFromName(name = "") {
  const ext = name.toLowerCase().split(".").pop();
  return {
    wav: "audio/wav", mp3: "audio/mpeg", m4a: "audio/mp4",
    aac: "audio/aac", ogg: "audio/ogg", oga: "audio/ogg",
    flac: "audio/flac", opus: "audio/opus", webm: "audio/webm"
  }[ext] || "audio/*";
}

/// v1: each LFO can opt into BPM rate sync. Optional fields default
/// off when missing so old presets are unchanged. Mirrors the iOS
/// LfoState.rateSyncEnabled / rateDenomination.
const defaultLfos = () => ([
  // v1.1 multi-target: targets is a SET (array) of destinations.
  { shape: "sine", targets: ["pan"],    rateHz: 0.25, depth: 0 },
  { shape: "sh",   targets: ["amp"],    rateHz: 0.50, depth: 0 },
  { shape: "sine", targets: ["cutoff"], rateHz: 0.30, depth: 0 },
  { shape: "sine", targets: ["pitch"],  rateHz: 0.30, depth: 0 }
]);
const defaultFilter = () => ({ type: "lowpass", cutoffHz: 4000, q: 0.7 });
const defaultReverb = () => ({ decaySec: 2.0, mix: 0 });
// Stereo chorus — two short delay lines modulated by a 90°-offset LFO so the
// L/R copies move in counter-phase, giving width without flanging artifacts.
const defaultChorus = () => ({
  rateHz: 0.5,   // 0.05 – 6 Hz, log
  depth: 0.4,   // 0 – 1, scales delay modulation 1 – 15 ms peak-to-peak
  width: 0.7,   // 0 – 1, L/R LFO phase separation (1.0 = full 180°)
  mix: 0        // 0 – 1, dry→wet blend; default 0 = chorus off until user opens it
});
// Cross-osc FM. `sourceIndex` is the index of one of the OTHER three voices
// whose raw oscillator output is routed into this voice's frequency param.
// `index` is the modulation index in Hz (peak frequency excursion).
const defaultFM = () => ({
  sourceIndex: -1,  // -1 = off; otherwise 0..3 (must differ from carrier index)
  index: 0          // 0 – 800 Hz, log; 0 = no modulation
});
// Granular synth defaults. Only audible when waveform === "granular"
// or sampleGranular === true on a sample voice.
const defaultGrain  = () => ({
  sizeMs: 80,        // 5..500 ms (log slider)
  densityHz: 8,      // 0.5..50 grains/sec (log slider, used when sync off)
  jitter: 0.6,       // 0..1 — randomizes inter-grain timing
  panSpread: 0.5,    // 0..1 — random per-grain stereo placement
  // v1 BPM sync. When true the engine reads from BPM × denomination
  // instead of densityHz. Mirrors the iOS GrainState fields.
  densitySyncEnabled: false,
  densityDenomination: "sixteenth",  // "half" .. "thirtySecondT"
  // v1 grain overlap toggle. When false (default), the scheduler
  // clamps the inter-grain gap up to grain length — one grain
  // finishes before the next starts. When true, big grains overlap
  // themselves and the trigger rate honors the density / BPM
  // division literally. Mirrors iOS GrainState.allowOverlap.
  allowOverlap: false
});
// v1: musical subdivisions for BPM-synced grain density. Beat counts
// match iOS GrainDenomination.beats so the two platforms compute
// identical effective Hz from the same BPM.
const GRAIN_DENOMS = [
  { id: "half",          label: "1/2",   beats: 2.0 },
  { id: "quarter",       label: "1/4",   beats: 1.0 },
  { id: "quarterT",      label: "1/4T",  beats: 2.0 / 3.0 },
  { id: "eighth",        label: "1/8",   beats: 0.5 },
  { id: "eighthT",       label: "1/8T",  beats: 1.0 / 3.0 },
  { id: "sixteenth",     label: "1/16",  beats: 0.25 },
  { id: "sixteenthT",    label: "1/16T", beats: 1.0 / 6.0 },
  { id: "thirtySecond",  label: "1/32",  beats: 0.125 },
  { id: "thirtySecondT", label: "1/32T", beats: 1.0 / 12.0 }
];
function grainDenomBeats(id) {
  const d = GRAIN_DENOMS.find((x) => x.id === id);
  return d ? d.beats : 0.25;
}
function grainSyncHz(bpm, id) {
  return 1.0 / Math.max(1e-4, grainDenomBeats(id) * 60 / Math.max(1, bpm));
}

/// v1: route a voice's grain density to the engine, picking BPM-synced
/// or free Hz based on the per-voice grain.densitySyncEnabled flag.
/// Called from every entry point that can change the effective rate
/// (slider drag, sync toggle, denomination pick, BPM change,
/// preset load). Keeps the audio engine path identical to before —
/// the engine still consumes a Hz value.
function pushEffectiveGrainDensity(oscIndex) {
  const o = state.oscillators[oscIndex];
  if (!o || !o.grain) return;
  let hz;
  if (o.grain.densitySyncEnabled) {
    hz = grainSyncHz(state.bpm, o.grain.densityDenomination || "sixteenth");
  } else {
    hz = Math.max(0.5, Math.min(50, o.grain.densityHz || 8));
  }
  engine.setGrainDensity(oscIndex, hz);
}

/// v1: per-LFO BPM rate-sync push. Mirrors pushEffectiveGrainDensity.
/// Reads rateSyncEnabled + rateDenomination from the LFO state and
/// pushes the resolved Hz to the engine. Called whenever anything
/// that can change the effective rate moves (slider, toggle,
/// denomination pick, BPM change, preset load).
function pushEffectiveLfoRate(oscIndex, lfoIndex) {
  const o = state.oscillators[oscIndex];
  if (!o || !o.lfos || !o.lfos[lfoIndex]) return;
  const lfo = o.lfos[lfoIndex];
  let hz;
  if (lfo.rateSyncEnabled) {
    // grainSyncHz returns the trigger-rate Hz for a given musical
    // subdivision at BPM. For LFOs the same math applies — one full
    // cycle equals the chosen subdivision.
    hz = grainSyncHz(state.bpm, lfo.rateDenomination || "sixteenth");
  } else {
    hz = Math.max(0.02, Math.min(8, lfo.rateHz || 0.5));
  }
  engine.setLfoRate(oscIndex, lfoIndex, hz);
}

const defaultDelay  = () => ({
  timeSec: 0.30,
  feedback: 0.40,
  mix: 0,
  mode: "mono",       // "mono" | "stereo" | "pingPong"
  timing: "free"      // "free" | "1/2" | "1/3" | "1/3t" | "1/4" | "1/4t" | "1/8" | "1/8t" | "1/16" | "1/16t"
});

// Default tempo for musical-division delay timings. Now exposed to UI
// via the state.bpm field below. v1.1.
const DEFAULT_BPM = 80;
// Common BPM presets shown in the master-row picker. Covers the
// meditative range (40-100) plus standard music tempos.
export const BPM_CHOICES = [40, 60, 72, 80, 90, 100, 120, 140];

// Beats-per-bar fractions per timing label. Triplets are 2/3 of the
// corresponding regular value.
export const DELAY_TIMINGS = [
  { id: "free",  label: "Free" },
  { id: "1/2",   label: "1/2"  , beats: 2.0   },
  { id: "1/3",   label: "1/3"  , beats: 4/3   },
  { id: "1/3t",  label: "1/3T" , beats: 8/9   },
  { id: "1/4",   label: "1/4"  , beats: 1.0   },
  { id: "1/4t",  label: "1/4T" , beats: 2/3   },
  { id: "1/8",   label: "1/8"  , beats: 0.5   },
  { id: "1/8t",  label: "1/8T" , beats: 1/3   },
  { id: "1/16",  label: "1/16" , beats: 0.25  },
  { id: "1/16t", label: "1/16T", beats: 1/6   }
];
export function delayTimeForTiming(timingId, bpm = DEFAULT_BPM) {
  const t = DELAY_TIMINGS.find((x) => x.id === timingId);
  if (!t || t.beats == null) return null;
  return t.beats * 60 / bpm;
}
export const DELAY_MODES = [
  { id: "mono",     label: "Mono",      hint: "Single tap, centered" },
  { id: "stereo",   label: "Stereo",    hint: "Slight L/R offset for width" },
  { id: "pingPong", label: "Ping-Pong", hint: "Bounces L ↔ R per repeat" }
];
// Per-voice drift config. Tick reads these directly; scenes are just
// templates that bulk-set them across all 4 voices.
const defaultDrift  = () => ({
  pitchMode: "static",  // "static" | "up" | "down" | "upDown" | "downUp" | "wave" | "glacial"
  pitchAmount: 1.0,     // octaves
  pitchPhase: 0,        // 0..1 modular phase offset
  panMode: "static",    // "static" | "sweepLR" | "sweepRL" | "pendulum" | "antiPendulum" | "glacial"
  panAmount: 1.0,
  panPhase: 0,
  // v1.1 quantize-to-scale: when true, the voice's final pitch
  // (drift + LFO + FM combined) snaps to the nearest chord note
  // across 2 octaves. Turns continuous motion into arpeggio-like
  // jumps along the current chord.
  quantizeToScale: false
});

const state = {
  oscillators: [
    { id: 0, frequencyHz: 110.00, waveform: "sine", amplitude: 0.6,  pan: -0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, replayCount: 1, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0, sampleGranular: false, grainSamplePosFrac: 0.5, grainSamplePosJitter: 0.2 },
    { id: 1, frequencyHz: 165.00, waveform: "sine", amplitude: 0.6,  pan:  0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, replayCount: 1, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0, sampleGranular: false, grainSamplePosFrac: 0.5, grainSamplePosJitter: 0.2 },
    { id: 2, frequencyHz: 220.00, waveform: "sine", amplitude: 0.55, pan: -0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, replayCount: 1, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0, sampleGranular: false, grainSamplePosFrac: 0.5, grainSamplePosJitter: 0.2 },
    { id: 3, frequencyHz: 277.18, waveform: "sine", amplitude: 0.5,  pan:  0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, replayCount: 1, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0, sampleGranular: false, grainSamplePosFrac: 0.5, grainSamplePosJitter: 0.2 }
  ],
  keyId: 9,         // A
  octave: 3,
  chordId: "maj",
  tuningId: "equal12",
  masterVolume: 0.30,
  showControls: true,
  showChladni: true,
  showSpectrum: false,
  activePresetName: null,
  // Id of the user-library preset currently loaded (null for built-ins or
  // a fresh patch). When set, automation edits auto-sync back into this
  // stored preset so Share/export always sends the current timeline.
  activeUserPresetId: null,

  // Randomize-all snapshot (single-level undo). Captured by
  // actions.randomizeAll just before it rolls; consumed by
  // actions.undoRandomize and then cleared.
  preRandomizeSnapshot: null,
  canUndoRandomize: false,

  // Global tempo (v1.1). Drives every voice's delay-time when its
  // timing is sync'd to a musical division. 80 BPM = resting-heart-
  // rate territory, meditative without being sluggish.
  bpm: DEFAULT_BPM,

  // v1: metronome click toggle. Audible verification of BPM-quantized
  // grain density + delay-time sync. Routed post-master so the click
  // stays at a steady level regardless of master volume.
  metronomeOn: false,

  // Transport
  transportState: "stopped",  // "stopped" | "playing" | "paused"
  sessionDuration: 15 * 60,   // 0 means open
  elapsed: 0,
  isRecording: false,         // mirrors engine.isRecording() for the UI
  driftSceneId: "off",        // id from DRIFT_SCENES below
  activeJourneyId: null,      // null when not on a journey
  journeyStageIndex: 0,       // which stage of the active journey
  journeyStageEndsAt: 0,      // Date.now() ms when the current stage ends

  // User-saved presets
  userPresets: loadUserPresets(),

  // Per-voice presets — capture/restore a single oscillator's full state
  // (freq, waveform, pan, amp, filter, reverb, delay, LFOs, drift) so the
  // user can mix-and-match favorite voices across slots.
  voicePresets: loadVoicePresets(),

  // Reusable automation setups — a local library of named Automation
  // Timelines you can save the current one into and load onto any patch.
  automationSetups: loadAutomationSetups(),

  // User-defined journeys — scripted multi-stage meditation sessions the
  // user has composed. Same shape as built-in JOURNEYS but persisted in
  // localStorage and shown above the factory list in the journey sheet.
  userJourneys: loadUserJourneys(),

  // ─── Morph between two presets ─────────────────────────────
  // Pick a "From" preset and a "To" preset, then drag a 0–100% slider
  // to interpolate every per-voice parameter continuously between them.
  // morphAmount = 0 → exactly preset A; = 1 → exactly preset B; in
  // between → log-interp on frequencies/cutoff/decay, linear on mix/
  // depth/pan/drive, discrete swap on waveform/filter type/LFO
  // shape+target/FM source/drift modes at the 0.5 boundary.
  morphFromId: null,
  morphToId: null,
  morphAmount: 0,

  // Auto-morph: drive morphAmount from 0→1 over morphDurationSec. When
  // ping-pong is on, it bounces back to 0 after reaching 1 and keeps going.
  // The timer keeps ticking when the sheet is closed so the user can watch
  // Chladni evolve through a long slow morph in Performance mode.
  morphDurationSec: 300,  // 5 min default
  morphIsRunning: false,
  morphIsPingPong: false,
  morphDirection: 1       // 1 = forward (0→1), -1 = reverse (1→0)
};

// Auto-morph driver — wall-clock based so pause/resume picks up where it
// left off without drift.
let morphIntervalId = null;
let morphLastTickMs = 0;

// Per-voice in-memory cache of loaded sample blobs (for save-current-as-preset).
const sampleCache = [null, null, null, null];  // each: { id, name, blob, type, source } | null

/**
 * Peak-normalize an AudioBuffer in place — find the absolute max
 * sample across all channels, then scale so that max sits at
 * `targetPeak` (default 0.89 ≈ -1 dBFS, leaves a safety lid below
 * 0 dBFS for any FX chain headroom). Returns a NEW AudioBuffer; the
 * input is left untouched so callers can still cache the original
 * if they want.
 *
 * Used by the per-osc Record feature where autoGainControl is
 * disabled on getUserMedia — raw mic is typically -30…-15 dBFS, way
 * too quiet without this rescue. iOS gets the same behavior for free
 * via AVAudioRecorder's hardware AGC.
 */
function peakNormalize(ctx, buffer, targetPeak = 0.89) {
  const channels = buffer.numberOfChannels;
  const length = buffer.length;
  let peak = 0;
  for (let c = 0; c < channels; c++) {
    const data = buffer.getChannelData(c);
    for (let i = 0; i < length; i++) {
      const v = Math.abs(data[i]);
      if (v > peak) peak = v;
    }
  }
  // Empty / silent buffer → no scaling needed; just return as-is to
  // avoid divide-by-zero blowing up the gain calculation.
  if (peak <= 1e-6) return buffer;
  const gain = targetPeak / peak;
  const out = ctx.createBuffer(channels, length, buffer.sampleRate);
  for (let c = 0; c < channels; c++) {
    const src = buffer.getChannelData(c);
    const dst = out.getChannelData(c);
    for (let i = 0; i < length; i++) dst[i] = src[i] * gain;
  }
  return out;
}

const engine = new AudioEngine();
let tickTimer = null;
let lastTickTime = 0;

// ──────────────────────────────────────────────────
// Actions — UI dispatches into these.
// ──────────────────────────────────────────────────
const actions = {
  setFrequency(index, hz) {
    const clamped = Math.max(FREQ_MIN, Math.min(FREQ_MAX, hz));
    state.oscillators[index].frequencyHz = clamped;
    state.activePresetName = null;
    engine.setFrequency(index, clamped);
    renderAll();
  },
  setAmplitude(index, amp) {
    state.oscillators[index].amplitude = clamp01(amp);
    engine.setAmplitude(index, state.oscillators[index].amplitude);
    renderAll();
  },
  setPan(index, pan) {
    state.oscillators[index].pan = Math.max(-1, Math.min(1, pan));
    engine.setPan(index, state.oscillators[index].pan);
    renderAll();
  },
  setWaveform(index, waveform) {
    state.oscillators[index].waveform = waveform;
    engine.setWaveform(index, waveform);
    renderAll();
  },
  toggleMute(index) {
    state.oscillators[index].isMuted = !state.oscillators[index].isMuted;
    engine.setMute(index, state.oscillators[index].isMuted);
    renderAll();
  },
  toggleSolo(index) {
    state.oscillators[index].isSoloed = !state.oscillators[index].isSoloed;
    engine.setSolo(index, state.oscillators[index].isSoloed);
    renderAll();
  },

  setKey(id)     { state.keyId = id;          applyChord(); },
  setOctave(o)   { state.octave = Math.max(1, Math.min(6, o)); applyChord(); },
  setChord(id)   { state.chordId = id;        applyChord(); },
  setTuning(id)  { state.tuningId = id;       applyChord(); },

  applyPreset(id) {
    const p = PRESETS.find((x) => x.id === id); if (!p) return;
    // Built-in presets carry no automation timeline — clear any imported
    // one and reset the baseline so it doesn't bleed into this patch.
    delete state._automation;
    automationPlayer.invalidate();
    state.activeUserPresetId = null;   // no user-library preset is active now
    for (let i = 0; i < 4; i++) {
      const v = p.voices[i];
      const hz = Math.max(FREQ_MIN, Math.min(FREQ_MAX, v.hz));
      state.oscillators[i].frequencyHz = hz;
      state.oscillators[i].pan = v.pan;
      // Mute the "silent" padding slots so 2/3-tone presets are clean.
      state.oscillators[i].isMuted = !!v._silent;
      engine.setFrequency(i, hz);
      engine.setPan(i, v.pan);
      engine.setMute(i, state.oscillators[i].isMuted);

      // Full clean slate BEFORE the preset's fields apply below (mirrors iOS
      // resetVoiceForPresetLoad). Anything the incoming preset DOESN'T specify
      // falls back to a default instead of inheriting the previous patch —
      // sample, waveform, drive, filter, FM, chorus, reverb, delay feedback,
      // grain, LFO depth, drift, timing. The `if`-blocks below then override
      // only what THIS preset defines. The user's quantize-to-scale toggle is
      // deliberately preserved.
      actions.clearSample(i);
      actions.setSampleGranular(i, false);
      state.oscillators[i].sampleRef = null;
      state.oscillators[i].sampleStartFrac = 0;
      state.oscillators[i].sampleEndFrac = 1;
      state.oscillators[i].sampleFadeInSec = 0;
      state.oscillators[i].sampleFadeOutSec = 0;
      state.oscillators[i].grainSamplePosFrac = 0.5;
      state.oscillators[i].grainSamplePosJitter = 0.2;
      state.oscillators[i].waveform = "sine";
      engine.setWaveform(i, "sine");
      const _defAmp = [0.6, 0.6, 0.55, 0.5][i];
      state.oscillators[i].amplitude = _defAmp;
      engine.setAmplitude(i, _defAmp);
      state.oscillators[i].drive = 1.0;
      engine.setDrive(i, 1.0);
      state.oscillators[i].startDelaySec = 0;
      state.oscillators[i].playDurationSec = 0;
      state.oscillators[i].replayCount = 1;
      engine.setStartDelay(i, 0);
      engine.setPlayDuration(i, 0);
      engine.setReplayCount(i, 1);
      {
        const _f = defaultFilter();
        state.oscillators[i].filter = _f;
        engine.setFilterType(i, _f.type);
        engine.setFilterCutoff(i, _f.cutoffHz);
        engine.setFilterQ(i, _f.q);
        const _fm = defaultFM();
        state.oscillators[i].fm = _fm;
        engine.setFMSource(i, _fm.sourceIndex);
        engine.setFMIndex(i, _fm.index);
        const _ch = defaultChorus();
        state.oscillators[i].chorus = _ch;
        engine.setChorusRate(i, _ch.rateHz);
        engine.setChorusDepth(i, _ch.depth);
        engine.setChorusWidth(i, _ch.width);
        engine.setChorusMix(i, _ch.mix);
        const _rv = defaultReverb();
        state.oscillators[i].reverb = _rv;
        engine.setReverbDecay(i, _rv.decaySec);
        engine.setReverbMix(i, _rv.mix);
        const _dl = defaultDelay();
        state.oscillators[i].delay = _dl;
        engine.setDelayTime(i, _dl.timeSec);
        engine.setDelayFeedback(i, _dl.feedback);
        engine.setDelayMix(i, _dl.mix);
        engine.setDelayMode(i, _dl.mode);
        const _gr = defaultGrain();
        state.oscillators[i].grain = _gr;
        engine.setGrainSize(i, _gr.sizeMs);
        pushEffectiveGrainDensity(i);
        engine.setGrainJitter(i, _gr.jitter);
        engine.setGrainPanSpread(i, _gr.panSpread);
        engine.setGrainAllowOverlap(i, !!_gr.allowOverlap);
        state.oscillators[i].lfos = defaultLfos().map((l) => ({ ...l }));
        for (let k = 0; k < 4 && k < state.oscillators[i].lfos.length; k++) {
          const _lf = state.oscillators[i].lfos[k];
          engine.setLfoShape(i, k, _lf.shape);
          engine.setLfoTargets(i, k, _lf.targets);
          pushEffectiveLfoRate(i, k);
          engine.setLfoDepth(i, k, 0);   // depth 0 = inaudible, kills carryover
        }
        const _keepQ = state.oscillators[i].drift?.quantizeToScale ?? false;
        const _dr = { ...defaultDrift(), quantizeToScale: _keepQ };
        state.oscillators[i].drift = _dr;
        if (engine.voices && engine.voices[i]) engine.voices[i].pitchQuantizeToScale = !!_keepQ;
        setVoicePitchDrift(i, _dr.pitchMode);
        setVoicePanDrift(i, _dr.panMode);
      }

      // ─── Optional rich-voice fields (used by Drone Artists presets) ───
      // Each block is no-op when the preset's voice didn't specify it,
      // so simple presets (just hz + pan) keep their old behavior of
      // leaving the user's per-voice tone untouched.
      if (v.wave != null) {
        state.oscillators[i].waveform = v.wave;
        engine.setWaveform(i, v.wave);
      }
      if (v.amp != null) {
        state.oscillators[i].amplitude = v.amp;
        engine.setAmplitude(i, v.amp);
      }
      if (v.filter) {
        const f = { ...defaultFilter(), ...v.filter };
        state.oscillators[i].filter = f;
        engine.setFilterType(i, f.type);
        engine.setFilterCutoff(i, f.cutoffHz);
        engine.setFilterQ(i, f.q);
      }
      if (v.drive != null) {
        state.oscillators[i].drive = v.drive;
        engine.setDrive(i, v.drive);
      }
      // Per-voice timing envelope — only applies if specified, so simple
      // presets keep their always-on behavior. Treat missing as "play
      // immediately, play forever" which matches the default state.
      const startDelay = (v.startDelaySec != null) ? v.startDelaySec : 0;
      const playDur    = (v.playDurationSec != null) ? v.playDurationSec : 0;
      const replayCount = (v.replayCount != null) ? v.replayCount : 1;
      state.oscillators[i].startDelaySec = startDelay;
      state.oscillators[i].playDurationSec = playDur;
      state.oscillators[i].replayCount = replayCount;
      engine.setStartDelay(i, startDelay);
      engine.setPlayDuration(i, playDur);
      engine.setReplayCount(i, replayCount);
      if (v.reverb) {
        const r = { ...defaultReverb(), ...v.reverb };
        state.oscillators[i].reverb = r;
        engine.setReverbDecay(i, r.decaySec);
        engine.setReverbMix(i, r.mix);
      }
      if (v.delay) {
        const d = { ...defaultDelay(), ...v.delay };
        state.oscillators[i].delay = d;
        engine.setDelayTime(i, d.timeSec);
        engine.setDelayFeedback(i, d.feedback);
        engine.setDelayMix(i, d.mix);
        engine.setDelayMode(i, d.mode);
      }
      if (v.chorus) {
        const ch = { ...defaultChorus(), ...v.chorus };
        state.oscillators[i].chorus = ch;
        engine.setChorusRate(i, ch.rateHz);
        engine.setChorusDepth(i, ch.depth);
        engine.setChorusWidth(i, ch.width);
        engine.setChorusMix(i, ch.mix);
      }
      if (v.fm) {
        const fm = { ...defaultFM(), ...v.fm };
        state.oscillators[i].fm = fm;
        engine.setFMSource(i, fm.sourceIndex);
        engine.setFMIndex(i, fm.index);
      }
      if (v.grain) {
        const gr = { ...defaultGrain(), ...v.grain };
        state.oscillators[i].grain = gr;
        engine.setGrainSize(i, gr.sizeMs);
        // v1: sync-aware density push — honors the preset's
        // densitySyncEnabled / densityDenomination if present, otherwise
        // falls back to the raw densityHz (same as before).
        pushEffectiveGrainDensity(i);
        engine.setGrainJitter(i, gr.jitter);
        engine.setGrainPanSpread(i, gr.panSpread);
        engine.setGrainAllowOverlap(i, !!gr.allowOverlap);
      }
      if (Array.isArray(v.lfos)) {
        // The preset may supply nulls for "leave this LFO alone" — only
        // overwrite the indexes it specified explicitly.
        for (let k = 0; k < v.lfos.length && k < 4; k++) {
          const lfo = v.lfos[k];
          if (!lfo) continue;
          const merged = { ...state.oscillators[i].lfos[k], ...lfo };
          state.oscillators[i].lfos[k] = merged;
          engine.setLfoShape(i, k, merged.shape);
          engine.setLfoTarget(i, k, merged.target);
          // v1: sync-aware. The merged LFO carries rateSyncEnabled +
          // rateDenomination if the preset set them; the helper picks
          // the right effective Hz.
          pushEffectiveLfoRate(i, k);
          engine.setLfoDepth(i, k, merged.depth);
        }
      }
      if (v.drift) {
        // Preserve the user's per-voice quantize-to-scale toggle across
        // preset loads — quantize is a "post-process" choice that's
        // orthogonal to the drift motion the preset is specifying.
        // Preset can still explicitly turn it on by including the flag.
        const existingQuantize = state.oscillators[i].drift?.quantizeToScale ?? false;
        const dr = { ...defaultDrift(), ...v.drift };
        if (v.drift.quantizeToScale === undefined) dr.quantizeToScale = existingQuantize;
        state.oscillators[i].drift = dr;
        // Mirror quantize state down to the audio engine (the drift
        // setters below don't touch this — it's a separate per-voice
        // DSP flag in the engine).
        if (engine.voices && engine.voices[i]) {
          engine.voices[i].pitchQuantizeToScale = !!dr.quantizeToScale;
        }
        // Push through the public setters so the drift timer reconciles itself.
        setVoicePitchDrift(i, dr.pitchMode);
        setVoicePanDrift(i, dr.panMode);
      }
    }
    // Derive the chord-pill KEY + OCTAVE from OSC 1's Hz on every built-in
    // preset load — mirrors iOS applyPreset. Without this the pill kept the
    // previous patch's key (INIT after a G♯ Lydian patch stayed G♯ instead
    // of snapping to A). Direct assignment (not setKey/setOctave) so we
    // don't recompute/override the preset's explicit voice frequencies.
    const firstHz = p.voices[0]?.hz;
    if (firstHz != null && firstHz > 0) {
      const midi = Math.round(69 + 12 * Math.log2(firstHz / 440));
      state.keyId = ((midi % 12) + 12) % 12;
      state.octave = Math.max(1, Math.min(6, Math.floor(midi / 12) - 1));
    }
    // Snap the chord template: a preset's own chordId if it names one, else
    // default to Major. Bundled presets are raw frequencies with no chord of
    // their own, so without this the previous patch's MODE carried over — e.g.
    // Lydian Dream → Solfeggio 417 kept "Lydian" (key changed, mode stuck).
    // Defaulting to Major makes every load self-consistent (no carryover).
    state.chordId = (p.chordId != null) ? p.chordId : "maj";
    state.activePresetName = p.name;
    renderAll();
  },

  // ─── Morph ──────────────────────────────────────────────
  setMorphFrom(presetId) {
    state.morphFromId = presetId || null;
    if (state.morphFromId && state.morphToId) applyMorph(state.morphAmount);
    renderAll();
  },
  setMorphTo(presetId) {
    state.morphToId = presetId || null;
    if (state.morphFromId && state.morphToId) applyMorph(state.morphAmount);
    renderAll();
  },
  setMorphAmount(t) {
    state.morphAmount = Math.max(0, Math.min(1, t));
    if (state.morphFromId && state.morphToId) applyMorph(state.morphAmount);
    renderAll();
  },
  clearMorph() {
    stopMorphTimer();
    state.morphFromId = null;
    state.morphToId = null;
    state.morphAmount = 0;
    state.morphIsRunning = false;
    state.morphDirection = 1;
    renderAll();
  },

  // ── Auto-morph ──
  setMorphDuration(sec) {
    state.morphDurationSec = Math.max(1, sec);
    renderAll();
  },
  setMorphPingPong(on) {
    state.morphIsPingPong = !!on;
    renderAll();
  },
  startMorph() {
    if (!state.morphFromId || !state.morphToId) return;
    // If at the end of travel, restart from the opposite end so Play always
    // does something visible.
    if (state.morphDirection === 1 && state.morphAmount >= 1 - 1e-6) {
      state.morphAmount = 0;
    } else if (state.morphDirection === -1 && state.morphAmount <= 1e-6) {
      state.morphDirection = 1;
    }
    state.morphIsRunning = true;
    morphLastTickMs = performance.now();
    if (morphIntervalId) clearInterval(morphIntervalId);
    morphIntervalId = setInterval(tickMorph, 100);  // 10 Hz
    renderAll();
  },
  pauseMorph() {
    state.morphIsRunning = false;
    stopMorphTimer();
    renderAll();
  },
  resetMorphPosition() {
    stopMorphTimer();
    state.morphIsRunning = false;
    state.morphDirection = 1;
    state.morphAmount = 0;
    if (state.morphFromId && state.morphToId) applyMorph(0);
    renderAll();
  },

  setMasterVolume(v) {
    state.masterVolume = clamp01(v);
    // v1 fix: only ramp the live master gain when transport is playing.
    // Otherwise the user dragging the master slider — or worse, a
    // freshly-loaded preset (whose masterVolume usually defaults to
    // 0.3) — would push audio through a "stopped" transport, making
    // the sample audible immediately AND leaving the Stop button
    // unresponsive (Stop early-returns when transportState ===
    // "stopped"). When stopped/paused, just stage the value into
    // engine.masterTarget so the next Play's fadeInMaster ramps up to
    // the right target. engine.setMasterVolume already updates target
    // itself, so we mirror that path directly for the staged case.
    if (state.transportState === "playing") {
      engine.setMasterVolume(state.masterVolume);
    } else {
      engine.masterTarget = state.masterVolume;
    }
    renderAll();
  },

  togglePlay() {
    if (state.transportState === "playing") {
      // Quick fade-down on pause so the suspend doesn't click.
      engine.fadeOutMaster(0.4);
      setTimeout(() => engine.suspend(), 500);
      state.transportState = "paused";
      stopTicker();
      automationPlayer.pause();   // freeze the timeline at its current phase
    } else {
      // Resume from "stopped" gets a full 3s meditation-fade; resume from
      // "paused" gets a snappier 1s ramp.
      const fromStopped = state.transportState === "stopped";
      engine.ensureStarted(state.oscillators);
      engine.resume();
      for (let i = 0; i < 4; i++) {
        engine.setFrequency(i, state.oscillators[i].frequencyHz);
        engine.setAmplitude(i, state.oscillators[i].amplitude);
        engine.setPan(i, state.oscillators[i].pan);
        engine.setWaveform(i, state.oscillators[i].waveform);
        engine.setMute(i, state.oscillators[i].isMuted);
        engine.setSolo(i, state.oscillators[i].isSoloed);
      }
      // CRITICAL bug fix: engine.stop() closes the AudioContext + clears
      // voices, so on the next Play after Stop, ensureStarted creates a
      // fresh engine WITHOUT any loaded samples. ANY voice on
      // waveform === "sample" went silent on subsequent plays. Re-load
      // every cached sample blob now so the recording / uploaded WAV
      // survives stop+play cycles for the lifetime of the page. Fired
      // in the background — fadeInMaster runs immediately so the user
      // doesn't perceive lag waiting for the decode.
      if (fromStopped) {
        for (let i = 0; i < 4; i++) {
          const o = state.oscillators[i];
          const cache = sampleCache[i];
          if (o.waveform === "sample" && cache && cache.blob) {
            const isRec = cache.source === "recording";
            cache.blob.arrayBuffer()
              .then((buf) => engine.ctx.decodeAudioData(buf.slice(0)))
              .then((audioBuffer) => {
                // Recordings need the same peak-normalize the
                // initial loadRecordedSample applied, otherwise the
                // restored buffer plays at raw mic level.
                const ab = isRec ? peakNormalize(engine.ctx, audioBuffer, 0.89) : audioBuffer;
                engine.loadSample(i, ab);
              })
              .catch((err) => console.warn("[sample restore]", err));
          }
        }
      }
      engine.fadeInMaster(fromStopped ? 3.0 : 1.0);
      // Initialize transportElapsed so the per-voice timing envelope can
      // start computing immediately (otherwise the engine tick would see
      // NaN until the first transport tick fires ~250 ms later, and any
      // voice with startDelaySec == 0 would briefly silence then jump up).
      engine.transportElapsed = state.elapsed;
      // v1: anchor metronome + grain phases to the Play moment so beat 1
      // of the click and grain 1 of every BPM-quantized voice land on the
      // same audio sample. The user perceives "the metronome and the
      // granular texture started together, locked, downbeat aligned."
      if (engine.resetMetronomePhase) engine.resetMetronomePhase();
      if (engine.resetGrainPhases) engine.resetGrainPhases();
      // v1 fix (Jun 2026): engine.stop() clears this.voices entirely on
      // teardown, so every Play that follows a Stop creates BRAND NEW
      // voice objects in ensureStarted(). Those new objects are
      // populated from state.oscillators[i] at construction time,
      // which carries the "free fallback" values for rate-sync'd
      // LFOs / grain density — NOT the BPM-derived effective values
      // the sync helpers would push. As a result, every fresh-voice
      // scenario silently loses sync: LFOs run at the slider Hz, not
      // at the requested musical subdivision; grain density runs at
      // the slider Hz, not the BPM denomination. The user's pitch
      // S&H at "1/4" would tick at ~0.5 Hz (the default fallback)
      // instead of the ~1.33 Hz a 1/4 at 80 BPM should produce.
      // Same root cause as the quantize-to-scale fix above; re-push
      // every per-voice piece of "derived" state on every Play.
      for (let i = 0; i < state.oscillators.length && engine.voices && i < engine.voices.length; i++) {
        if (!engine.voices[i]) continue;
        // Quantize-to-scale flag + scale cache (covered already).
        const qts = !!(state.oscillators[i].drift && state.oscillators[i].drift.quantizeToScale);
        engine.voices[i].pitchQuantizeToScale = qts;
        // LFO rate-sync. Every LFO that has sync on needs to push
        // the BPM-derived Hz; LFOs without sync just re-write the
        // slider Hz (no-op if nothing changed). Both are cheap.
        const lfos = state.oscillators[i].lfos || [];
        for (let k = 0; k < lfos.length; k++) {
          pushEffectiveLfoRate(i, k);
        }
        // Grain density sync — same story for granular voices.
        if (state.oscillators[i].grain && state.oscillators[i].grain.densitySyncEnabled) {
          pushEffectiveGrainDensity(i);
        }
      }
      if (typeof recomputeQuantizeScale === "function") recomputeQuantizeScale();
      state.transportState = "playing";
      startTicker();
      // v1.2: drive the Automation Timeline. fromStopped → fresh start
      // (restore/capture baseline + reset cursor); resume from pause keeps
      // the timeline position.
      automationPlayer.onPlay(fromStopped);
    }
    renderAll();
  },

  async stop() {
    if (state.transportState === "stopped") return;
    // v1: Stop also kills the metronome so the click doesn't keep
    // ticking through the fade-out into stopped silence.
    if (state.metronomeOn) {
      state.metronomeOn = false;
      if (engine && engine.setMetronomeOn) engine.setMetronomeOn(false);
    }
    // Update UI state immediately; audio fades over 8s, then tears down.
    state.transportState = "stopped";
    state.elapsed = 0;
    // Mark transport stopped so the per-voice timing envelope reverts
    // to its idle behavior (no fade-in math while the engine isn't
    // playing — that's the master fade-out's job).
    if (engine.ctx) engine.transportElapsed = NaN;
    stopTicker();
    automationPlayer.reset();   // clear cursor; baseline restored on next Play
    // Stop a journey if one is running so it doesn't keep advancing
    // through preset changes while transport is silent.
    if (state.activeJourneyId) stopJourney();
    renderAll();
    // If a recording is in progress, stop it before tearing down audio so
    // the captured fade-out is included in the final file.
    if (engine.isRecording && engine.isRecording()) {
      await actions.toggleRecord();
    }
    await engine.fadeOutMaster(8.0);
    // v1: if the user re-engaged the metronome during the 8 s
    // fade-out, keep the AudioContext alive so the click can keep
    // ticking. Closing the ctx here used to be the bug: metronome
    // clicked for a few seconds then went silent forever when this
    // teardown ran behind the user's back.
    if (!state.metronomeOn) {
      await engine.stop();
    }
  },

  /// Toggles session recording. On start: spins up the MediaRecorder and
  /// flashes the record button. On stop: gathers the captured blob and
  /// prompts a download with a timestamped filename.
  async toggleRecord() {
    if (!engine.ctx) return;  // audio not initialized yet
    if (engine.isRecording()) {
      const blob = await engine.stopRecording();
      state.isRecording = false;
      renderAll();
      if (blob && blob.size > 0) {
        const ext = blob.type.includes("webm") ? "webm"
                  : blob.type.includes("ogg")  ? "ogg"
                  : "audio";
        const now = new Date();
        const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2,"0")}-${String(now.getDate()).padStart(2,"0")}_${String(now.getHours()).padStart(2,"0")}${String(now.getMinutes()).padStart(2,"0")}${String(now.getSeconds()).padStart(2,"0")}`;
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = `drone-meditations-${stamp}.${ext}`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(() => URL.revokeObjectURL(url), 1000);
      }
    } else {
      const ok = engine.startRecording();
      if (ok) {
        state.isRecording = true;
        renderAll();
      }
    }
  },

  setDuration(seconds) {
    state.sessionDuration = seconds;
    if (state.sessionDuration > 0 && state.elapsed >= state.sessionDuration) {
      actions.stop();
    } else {
      renderAll();
    }
  },

  toggleControls() {
    state.showControls = !state.showControls;
    renderAll();
  },
  setShowControls(on) {
    state.showControls = !!on;
    renderAll();
  },
  toggleChladni() {
    state.showChladni = !state.showChladni;
    setChladniVisible(state.showChladni);
    renderAll();
  },
  toggleSpectrum() {
    state.showSpectrum = !state.showSpectrum;
    setSpectrumVisible(state.showSpectrum);
    renderAll();
  },

  setLfoRate(oscIndex, lfoIndex, hz) {
    state.oscillators[oscIndex].lfos[lfoIndex].rateHz = Math.max(0.02, Math.min(8, hz));
    // When sync is on, the slider just updates the "free fallback"
    // value and the engine stays on BPM-derived rate. When sync is
    // off, push the new rate live.
    pushEffectiveLfoRate(oscIndex, lfoIndex);
    renderAll();
  },
  /// v1: per-LFO BPM rate-sync setters. Mirrors the grain-density
  /// sync pattern. When sync is on, effective Hz = BPM × denomination.
  setLfoRateSync(oscIndex, lfoIndex, on) {
    state.oscillators[oscIndex].lfos[lfoIndex].rateSyncEnabled = !!on;
    pushEffectiveLfoRate(oscIndex, lfoIndex);
    renderAll();
  },
  setLfoRateDenomination(oscIndex, lfoIndex, denomId) {
    state.oscillators[oscIndex].lfos[lfoIndex].rateDenomination = denomId;
    if (state.oscillators[oscIndex].lfos[lfoIndex].rateSyncEnabled) {
      pushEffectiveLfoRate(oscIndex, lfoIndex);
    }
    renderAll();
  },
  setLfoDepth(oscIndex, lfoIndex, depth) {
    const d = clamp01(depth);
    const wasActive = state.oscillators[oscIndex].lfos[lfoIndex].depth > 0;
    state.oscillators[oscIndex].lfos[lfoIndex].depth = d;
    engine.setLfoDepth(oscIndex, lfoIndex, d);
    if (wasActive && d === 0) restoreLfoTargetBase(oscIndex, state.oscillators[oscIndex].lfos[lfoIndex].target);
    renderAll();
  },
  // ── Automation Timeline editing (web editor, v1.1) ──
  // These mutate state._automation in the iOS-Codable shape so timelines
  // round-trip through .dronepreset. Each edit invalidates the player's
  // baseline so the next Play captures fresh patch state.
  setAutomationBars(barsOrNull) {
    const tl = ensureAutomation();
    tl.totalBars = (barsOrNull == null) ? null : Math.max(0, barsOrNull);
    tl.loop = tl.totalBars != null && tl.totalBars > 0;
    automationPlayer.invalidate();
    persistAutomationToActivePreset();
    renderAll();
  },
  setAutomationLoopCount(n) {
    const tl = ensureAutomation();
    tl.loopCount = Math.max(0, n | 0);
    automationPlayer.invalidate();
    persistAutomationToActivePreset();
    renderAll();
  },
  upsertAutomationEvent(ev) {
    const tl = ensureAutomation();
    const i = tl.events.findIndex((e) => e.id === ev.id);
    if (i >= 0) tl.events[i] = ev; else tl.events.push(ev);
    automationPlayer.invalidate();
    persistAutomationToActivePreset();
    renderAll();
  },
  deleteAutomationEvent(id) {
    const tl = ensureAutomation();
    tl.events = tl.events.filter((e) => e.id !== id);
    automationPlayer.invalidate();
    persistAutomationToActivePreset();
    renderAll();
  },

  // ── Automation setups library (reusable named timelines) ──
  saveAutomationSetup(name) {
    const trimmed = (name || "").trim();
    if (!trimmed) return null;
    const tl = state._automation;
    if (!tl || !Array.isArray(tl.events) || tl.events.length === 0) return null;
    const setup = {
      id: newAutomationSetupId(),
      name: trimmed,
      createdAt: new Date().toISOString(),
      timeline: JSON.parse(JSON.stringify(tl)),
    };
    state.automationSetups = [setup, ...(state.automationSetups || [])];
    saveAutomationSetups(state.automationSetups);
    renderAll();
    return setup.id;
  },
  loadAutomationSetup(id) {
    const s = (state.automationSetups || []).find((x) => x.id === id);
    if (!s || !s.timeline) return;
    state._automation = JSON.parse(JSON.stringify(s.timeline));
    automationPlayer.invalidate();
    persistAutomationToActivePreset();   // sync onto the loaded preset, if any
    renderAll();
  },
  deleteAutomationSetup(id) {
    state.automationSetups = (state.automationSetups || []).filter((x) => x.id !== id);
    saveAutomationSetups(state.automationSetups);
    renderAll();
  },

  setLfoShape(oscIndex, lfoIndex, shape) {
    state.oscillators[oscIndex].lfos[lfoIndex].shape = shape;
    engine.setLfoShape(oscIndex, lfoIndex, shape);
    renderAll();
  },
  /// v1.0 compat: setting "the" target wraps it into a one-element
  /// targets array. Used by preset load + the randomize path.
  setLfoTarget(oscIndex, lfoIndex, target) {
    const lfo = state.oscillators[oscIndex].lfos[lfoIndex];
    const prevTargets = currentTargets(lfo);
    lfo.targets = [target];
    delete lfo.target;
    if (engine.setLfoTargets) engine.setLfoTargets(oscIndex, lfoIndex, lfo.targets);
    // Restore any target the LFO is no longer driving so the
    // parameter doesn't stay stuck at the LFO's last output.
    for (const t of prevTargets) {
      if (!lfo.targets.includes(t) && !anyOtherLfoUsesTarget(oscIndex, lfoIndex, t)) {
        restoreLfoTargetBase(oscIndex, t);
      }
    }
    renderAll();
  },

  /// v1.1 multi-target: toggle membership of `target` in the LFO's
  /// target set. Restores the underlying slider value if removing the
  /// target left no other LFO on this voice still driving it.
  toggleLfoTarget(oscIndex, lfoIndex, target) {
    // v1.1: pad state.oscillators[].lfos to 5 entries on first touch
    // (old 4-LFO presets load shorter). Mirrors audio.js's _padLfos.
    const osc = state.oscillators[oscIndex];
    while (osc.lfos.length < 5) {
      osc.lfos.push({ shape: "sine", targets: ["grainDensity"], rateHz: 0.30, depth: 0 });
    }
    const lfo = osc.lfos[lfoIndex];
    const set = new Set(currentTargets(lfo));
    const wasOn = set.has(target);
    if (wasOn) set.delete(target); else set.add(target);
    lfo.targets = Array.from(set);
    delete lfo.target;
    if (engine.setLfoTargets) engine.setLfoTargets(oscIndex, lfoIndex, lfo.targets);
    if (wasOn && !anyOtherLfoUsesTarget(oscIndex, lfoIndex, target)) {
      restoreLfoTargetBase(oscIndex, target);
    }
    renderAll();
  },

  setFilterType(oscIndex, type) {
    state.oscillators[oscIndex].filter.type = type;
    engine.setFilterType(oscIndex, type);
    renderAll();
  },
  setFilterCutoff(oscIndex, hz) {
    const clamped = Math.max(20, Math.min(8000, hz));
    state.oscillators[oscIndex].filter.cutoffHz = clamped;
    engine.setFilterCutoff(oscIndex, clamped);
    renderAll();
  },
  setDrive(oscIndex, d) {
    const clamped = Math.max(1.0, Math.min(12.0, d));
    state.oscillators[oscIndex].drive = clamped;
    engine.setDrive(oscIndex, clamped);
    renderAll();
  },
  setStartDelay(oscIndex, sec) {
    const clamped = Math.max(0, Math.min(60 * 60, sec || 0));
    state.oscillators[oscIndex].startDelaySec = clamped;
    engine.setStartDelay(oscIndex, clamped);
    renderAll();
  },
  setPlayDuration(oscIndex, sec) {
    const clamped = Math.max(0, Math.min(60 * 60, sec || 0));
    state.oscillators[oscIndex].playDurationSec = clamped;
    engine.setPlayDuration(oscIndex, clamped);
    renderAll();
  },
  /// Replay cycles for the timing envelope. 1 = play once (the default),
  /// 2/3/5/10 = repeat N times, 0 = ∞. Only meaningful when playDur > 0.
  setReplayCount(oscIndex, count) {
    const clamped = Math.max(0, Math.min(99, Math.floor(count ?? 1)));
    state.oscillators[oscIndex].replayCount = clamped;
    engine.setReplayCount(oscIndex, clamped);
    renderAll();
  },

  // ── Granular (only audible when waveform === "granular") ──
  setGrainSize(oscIndex, ms) {
    const clamped = Math.max(5, Math.min(500, ms));
    if (!state.oscillators[oscIndex].grain) state.oscillators[oscIndex].grain = defaultGrain();
    state.oscillators[oscIndex].grain.sizeMs = clamped;
    engine.setGrainSize(oscIndex, clamped);
    renderAll();
  },
  setGrainDensity(oscIndex, hz) {
    const clamped = Math.max(0.5, Math.min(50, hz));
    if (!state.oscillators[oscIndex].grain) state.oscillators[oscIndex].grain = defaultGrain();
    state.oscillators[oscIndex].grain.densityHz = clamped;
    pushEffectiveGrainDensity(oscIndex);
    renderAll();
  },
  setGrainDensitySync(oscIndex, on) {
    if (!state.oscillators[oscIndex].grain) state.oscillators[oscIndex].grain = defaultGrain();
    state.oscillators[oscIndex].grain.densitySyncEnabled = !!on;
    pushEffectiveGrainDensity(oscIndex);
    renderAll();
  },
  setGrainDensityDenomination(oscIndex, denomId) {
    if (!state.oscillators[oscIndex].grain) state.oscillators[oscIndex].grain = defaultGrain();
    state.oscillators[oscIndex].grain.densityDenomination = denomId;
    if (state.oscillators[oscIndex].grain.densitySyncEnabled) {
      pushEffectiveGrainDensity(oscIndex);
    }
    renderAll();
  },
  setGrainJitter(oscIndex, j) {
    const clamped = Math.max(0, Math.min(1, j));
    if (!state.oscillators[oscIndex].grain) state.oscillators[oscIndex].grain = defaultGrain();
    state.oscillators[oscIndex].grain.jitter = clamped;
    engine.setGrainJitter(oscIndex, clamped);
    renderAll();
  },
  setGrainPanSpread(oscIndex, s) {
    const clamped = Math.max(0, Math.min(1, s));
    if (!state.oscillators[oscIndex].grain) state.oscillators[oscIndex].grain = defaultGrain();
    state.oscillators[oscIndex].grain.panSpread = clamped;
    engine.setGrainPanSpread(oscIndex, clamped);
    renderAll();
  },
  /// v1: per-voice grain overlap toggle. Off (default) = scheduler
  /// clamps gap to grain length so one grain finishes before the
  /// next. On = honor the requested density gap literally, so big
  /// grains will overlap themselves at the requested rate.
  setGrainAllowOverlap(oscIndex, on) {
    if (!state.oscillators[oscIndex].grain) state.oscillators[oscIndex].grain = defaultGrain();
    state.oscillators[oscIndex].grain.allowOverlap = !!on;
    // Push to engine params.grain so the scheduler picks it up even
    // when state.grain has been reassigned (e.g. after a built-in
    // preset apply replaces the whole grain object reference).
    engine.setGrainAllowOverlap(oscIndex, !!on);
    renderAll();
  },

  // v1 granular SAMPLING — only audible when waveform === "sample".
  setSampleGranular(oscIndex, on) {
    state.oscillators[oscIndex].sampleGranular = !!on;
    engine.setSampleGranular(oscIndex, !!on);
    renderAll();
  },
  setGrainSamplePos(oscIndex, frac) {
    const clamped = Math.max(0, Math.min(1, frac));
    state.oscillators[oscIndex].grainSamplePosFrac = clamped;
    engine.setGrainSamplePos(oscIndex, clamped);
    renderAll();
  },
  setGrainSamplePosJitter(oscIndex, frac) {
    const clamped = Math.max(0, Math.min(1, frac));
    state.oscillators[oscIndex].grainSamplePosJitter = clamped;
    engine.setGrainSamplePosJitter(oscIndex, clamped);
    renderAll();
  },

  // ── Sample play-window (only audible when waveform === "sample") ──
  // v1 fix: never early-return on the start/end clamp. The slider's
  // input event fires per-pixel of drag; if the setter rejects a
  // value, the slider's internal `value` keeps tracking the user's
  // mouse (browser-native) while state stays at the LAST accepted
  // value. Result: ball drifts visually away from --fill, eventually
  // off-screen — user reported "WINDOW end slider loses the ball
  // when going down past the midline." Now we clamp to a min/max
  // window with a 0.01 gap between start and end, and ALWAYS write
  // back + renderAll so the slider tracks state at all times.
  setSampleStart(oscIndex, frac) {
    const o = state.oscillators[oscIndex];
    const end = o.sampleEndFrac ?? 1;
    const clamped = Math.max(0, Math.min(end - 0.01, frac));
    o.sampleStartFrac = clamped;
    engine.setSampleWindow(oscIndex, clamped, end);
    renderAll();
  },
  setSampleEnd(oscIndex, frac) {
    const o = state.oscillators[oscIndex];
    const start = o.sampleStartFrac ?? 0;
    const clamped = Math.max(start + 0.01, Math.min(1, frac));
    o.sampleEndFrac = clamped;
    engine.setSampleWindow(oscIndex, start, clamped);
    renderAll();
  },
  setSampleFadeIn(oscIndex, sec) {
    const clamped = Math.max(0, Math.min(10, sec));
    state.oscillators[oscIndex].sampleFadeInSec = clamped;
    engine.setSampleFadeIn(oscIndex, clamped);
    renderAll();
  },
  setSampleFadeOut(oscIndex, sec) {
    const clamped = Math.max(0, Math.min(10, sec));
    state.oscillators[oscIndex].sampleFadeOutSec = clamped;
    engine.setSampleFadeOut(oscIndex, clamped);
    renderAll();
  },
  setFilterQ(oscIndex, q) {
    const clamped = Math.max(0.3, Math.min(20, q));
    state.oscillators[oscIndex].filter.q = clamped;
    engine.setFilterQ(oscIndex, clamped);
    renderAll();
  },

  /// Load a sample from the bundled `web/samples/` folder by URL.
  /// `entry` is a row from samples/index.json with .file + .name. We
  /// fetch the blob and route through the existing decode + cache path
  /// so it persists across user-preset saves like any user upload.
  async loadBundledSample(oscIndex, entry) {
    if (!entry || !entry.file) return;
    engine.ensureStarted(state.oscillators);
    engine.resume();
    try {
      const url = `./samples/${entry.file}`;
      const resp = await fetch(url);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const arrayBuffer = await resp.arrayBuffer();
      const audioBuffer = await engine.ctx.decodeAudioData(arrayBuffer.slice(0));
      engine.loadSample(oscIndex, audioBuffer);
      state.oscillators[oscIndex].sampleName = entry.name || entry.file;
      state.oscillators[oscIndex].waveform = "sample";
      engine.setWaveform(oscIndex, "sample");
      const mime = resp.headers.get("content-type") || guessMimeFromName(entry.file);
      sampleCache[oscIndex] = {
        id: null,
        name: entry.name || entry.file,
        blob: new Blob([arrayBuffer], { type: mime }),
        type: mime,
        source: "bundled"
      };
      renderAll();
    } catch (err) {
      console.error("Bundled sample load failed:", err);
      alert(`Couldn't load bundled sample "${entry.name || entry.file}".`);
    }
  },

  async loadSampleFile(oscIndex, file) {
    if (!file) return;
    engine.ensureStarted(state.oscillators);
    engine.resume();
    try {
      const arrayBuffer = await file.arrayBuffer();
      // decodeAudioData consumes the buffer; clone for re-persistence later.
      const audioBuffer = await engine.ctx.decodeAudioData(arrayBuffer.slice(0));
      engine.loadSample(oscIndex, audioBuffer);
      state.oscillators[oscIndex].sampleName = file.name;
      state.oscillators[oscIndex].waveform = "sample";
      engine.setWaveform(oscIndex, "sample");
      // Cache the raw blob so saveCurrentAsUserPreset / saveSampleToLibrary
      // can persist it. `source: "upload"` flags the cache so the UI knows
      // whether the 🔖 button should be offered (only for fresh uploads —
      // bundled + library-loaded samples are already persistent).
      sampleCache[oscIndex] = {
        id: null,
        name: file.name,
        blob: new Blob([arrayBuffer], { type: file.type || "audio/*" }),
        type: file.type || "audio/*",
        source: "upload"
      };
      renderAll();
    } catch (err) {
      console.error("Sample decode failed:", err);
      alert(`Could not decode "${file.name}". Try a different format (mp3/wav/m4a/ogg).`);
    }
  },

  /// v1 per-osc Record. Load a fresh mic-captured Blob into the voice
  /// AS IF it had been file-imported. The UI side has already
  /// recorded the audio via MediaRecorder; we own the decode + load +
  /// state-update + cache step so saveCurrentAsUserPreset can persist
  /// the recording in user presets and so the .dronepreset exporter
  /// embeds it inline. The recording inherits a synthetic
  /// "Recording N" filename so it shows up in the strip's sample
  /// row label.
  async loadRecordedSample(oscIndex, blob, mime) {
    if (!(blob instanceof Blob) || blob.size === 0) {
      throw new Error("Empty recording");
    }
    engine.ensureStarted(state.oscillators);
    engine.resume();
    const arrayBuffer = await blob.arrayBuffer();
    const decoded = await engine.ctx.decodeAudioData(arrayBuffer.slice(0));
    // Peak-normalize the recording to -1 dBFS so it sits at a usable
    // level regardless of mic gain. We deliberately disabled
    // autoGainControl in the getUserMedia constraints to keep the
    // capture transparent, so raw mic input is typically -30…-15 dBFS;
    // without this normalization the user has to crank LVL to 1.0 just
    // to hear themselves. We re-bake the normalized PCM into a fresh
    // AudioBuffer so the engine reads it directly.
    const normalizedBuffer = peakNormalize(engine.ctx, decoded, 0.89);
    // v1 unity-pitch on recording load. Pin sampleBaseFreqHz to the
    // OSC's CURRENT freq so playback at the same freq plays at native
    // rate. The freq slider then acts as a pitch shift from the
    // recorded pitch (move it up = pitch up, down = pitch down).
    // Previously we'd reset freq to 220 — felt wrong because the
    // user's chord pitch jumped to 220 every time they recorded.
    const baseFreq = state.oscillators[oscIndex].frequencyHz;
    state.oscillators[oscIndex].sampleBaseFreqHz = baseFreq;
    engine.setSampleBaseFreqHz(oscIndex, baseFreq);
    engine.loadSample(oscIndex, normalizedBuffer);
    const label = `Recording (OSC ${oscIndex + 1})`;
    state.oscillators[oscIndex].sampleName = label;
    state.oscillators[oscIndex].waveform = "sample";
    engine.setWaveform(oscIndex, "sample");
    // Auto-persist the recording to the user's browser library so it
    // appears in the Bundled ▾ picker's new "Recorded" section AND
    // survives page reloads. The blob lives in IndexedDB (samples
    // store), a small metadata row sits in localStorage with
    // category: "recording" so the picker can group entries.
    const recId = newSampleId();
    const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
    const libraryName = `OSC ${oscIndex + 1} — ${stamp}`;
    const cacheBlob = new Blob([arrayBuffer], { type: mime || blob.type || "audio/webm" });
    const cacheType = mime || blob.type || "audio/webm";
    try {
      await putSample(recId, cacheBlob, libraryName, cacheType);
      const lib = loadLibrarySamples();
      lib.unshift({
        id: recId,
        name: libraryName,
        addedAt: new Date().toISOString(),
        category: "recording"
      });
      saveLibrarySamples(lib);
    } catch (err) {
      // Persistence failure isn't fatal — the recording still plays
      // from the in-memory cache until the page is reloaded.
      console.warn("[recording persist] failed:", err);
    }
    // Cache the ORIGINAL (un-normalized) blob so saveCurrentAsUserPreset
    // and the .dronepreset exporter persist the source — anyone who
    // imports it gets to apply their own normalization (or none). The
    // engine works with the normalized in-memory copy.
    sampleCache[oscIndex] = {
      id: recId,                                  // points at IndexedDB row
      name: label,
      blob: cacheBlob,
      type: cacheType,
      source: "recording"
    };
    state.activePresetName = null;
    renderAll();
  },

  /// Save the currently-loaded sample on the given oscillator to the user's
  /// browser library so the Bundled ▾ picker can list it on subsequent
  /// visits. No-op if no upload is loaded or if it's already saved.
  /// The blob goes into IndexedDB; a small metadata row goes into
  /// localStorage so the picker can list entries without loading blobs.
  async saveSampleToLibrary(oscIndex) {
    const cache = sampleCache[oscIndex];
    if (!cache || !cache.blob) return;
    // Already saved? (id assigned + present in library list)
    const lib = loadLibrarySamples();
    if (cache.id && lib.some((e) => e.id === cache.id)) return;

    const id = cache.id || newSampleId();
    await putSample(id, cache.blob, cache.name, cache.type);
    cache.id = id;
    cache.source = "library";  // no longer needs the 🔖 prompt

    // Strip the file extension for a nicer display name.
    const displayName = (cache.name || "Sample").replace(/\.[a-z0-9]+$/i, "");
    lib.push({ id, name: displayName, addedAt: Date.now() });
    saveLibrarySamples(lib);
    renderAll();
  },

  /// Remove an entry from the user's browser library. Deletes the
  /// IndexedDB blob too if no user preset references it (samples shared
  /// with presets stay alive so deleting from library doesn't break the
  /// preset's audio).
  async removeFromLibrary(sampleId) {
    const lib = loadLibrarySamples().filter((e) => e.id !== sampleId);
    saveLibrarySamples(lib);
    // Is any user preset still pointing at this id?
    const presets = loadUserPresets();
    const stillUsed = presets.some((p) =>
      p.oscillators && p.oscillators.some(
        (o) => o.sampleRef && o.sampleRef.id === sampleId
      )
    );
    if (!stillUsed) await deleteSample(sampleId);
    renderAll();
  },

  /// Load a sample from the user's browser library by id. Mirrors
  /// loadBundledSample's flow — fetch blob from IndexedDB, decode,
  /// hand to engine, mark cache as 'library' (so the 🔖 button stays
  /// suppressed since the sample is already persistent).
  async loadLibrarySample(oscIndex, libraryEntry) {
    if (!libraryEntry || !libraryEntry.id) return;
    engine.ensureStarted(state.oscillators);
    engine.resume();
    try {
      const rec = await getSample(libraryEntry.id);
      if (!rec || !rec.blob) {
        alert(`Library sample "${libraryEntry.name}" is missing its audio data.`);
        return;
      }
      const arrayBuffer = await rec.blob.arrayBuffer();
      const audioBuffer = await engine.ctx.decodeAudioData(arrayBuffer.slice(0));
      engine.loadSample(oscIndex, audioBuffer);
      state.oscillators[oscIndex].sampleName = libraryEntry.name || rec.name;
      state.oscillators[oscIndex].waveform = "sample";
      engine.setWaveform(oscIndex, "sample");
      sampleCache[oscIndex] = {
        id: libraryEntry.id,
        name: libraryEntry.name || rec.name,
        blob: rec.blob,
        type: rec.type || "audio/*",
        source: "library"
      };
      renderAll();
    } catch (err) {
      console.error("Library sample load failed:", err);
      alert(`Couldn't load library sample "${libraryEntry.name}".`);
    }
  },

  setReverbDecay(oscIndex, sec) {
    const clamped = Math.max(0.1, Math.min(10, sec));
    state.oscillators[oscIndex].reverb.decaySec = clamped;
    engine.setReverbDecay(oscIndex, clamped);
    renderAll();
  },
  setReverbMix(oscIndex, mix) {
    const clamped = clamp01(mix);
    state.oscillators[oscIndex].reverb.mix = clamped;
    engine.setReverbMix(oscIndex, clamped);
    renderAll();
  },
  setDelayTime(oscIndex, sec) {
    const clamped = Math.max(0.02, Math.min(2.0, sec));
    state.oscillators[oscIndex].delay.timeSec = clamped;
    engine.setDelayTime(oscIndex, clamped);
    renderAll();
  },
  setDelayFeedback(oscIndex, fb) {
    const clamped = Math.max(0, Math.min(0.95, fb));
    state.oscillators[oscIndex].delay.feedback = clamped;
    engine.setDelayFeedback(oscIndex, clamped);
    renderAll();
  },
  setDelayMix(oscIndex, mix) {
    const clamped = clamp01(mix);
    state.oscillators[oscIndex].delay.mix = clamped;
    engine.setDelayMix(oscIndex, clamped);
    renderAll();
  },
  setDelayMode(oscIndex, mode) {
    state.oscillators[oscIndex].delay.mode = mode;
    engine.setDelayMode(oscIndex, mode);
    renderAll();
  },
  /// Update the global tempo (v1.1). Recomputes every voice's delay
  /// time for voices whose timing is sync'd to a musical division.
  /// Free-mode delays are left alone — they keep their absolute ms
  /// value.
  setBPM(newBPM) {
    const clamped = Math.max(30, Math.min(240, newBPM));
    if (Math.abs(clamped - state.bpm) < 0.5) return;
    state.bpm = clamped;
    for (let i = 0; i < state.oscillators.length; i++) {
      const timing = state.oscillators[i].delay.timing;
      const sec = delayTimeForTiming(timing, clamped);
      if (sec != null) {
        state.oscillators[i].delay.timeSec = sec;
        engine.setDelayTime(i, sec);
      }
      // v1: BPM-synced grain density. When sync is on, the effective
      // Hz depends on BPM × denomination — recompute and push.
      if (state.oscillators[i].grain && state.oscillators[i].grain.densitySyncEnabled) {
        pushEffectiveGrainDensity(i);
      }
      // v1: BPM-synced LFO rates — same recompute story per LFO.
      const lfos = state.oscillators[i].lfos || [];
      for (let k = 0; k < lfos.length; k++) {
        if (lfos[k] && lfos[k].rateSyncEnabled) {
          pushEffectiveLfoRate(i, k);
        }
      }
    }
    // v1: keep the metronome locked to the user's tempo. Already-
    // scheduled clicks fire at their old times (no jarring re-anchor)
    // and subsequent beats use the new value.
    if (engine && engine.setMetronomeBPM) engine.setMetronomeBPM(clamped);
    renderAll();
  },
  /// v1: metronome click — short sine ping on every quarter, accent
  /// on beat 1 of 4, post-master so it stays audible regardless of
  /// master volume. Verifies BPM sync by ear.
  setMetronomeOn(on) {
    state.metronomeOn = !!on;
    if (on && engine && engine.ensureStarted) {
      // Pre-Play case: the audio context may not exist yet (browser
      // policy: AudioContext is created/resumed by a user gesture).
      // The toggle click IS the gesture, so ensureStarted here both
      // creates the ctx and resumes it. Voices stay silent because
      // master gain is 0; the metronome bus connects to ctx.destination
      // directly so the click plays anyway.
      engine.ensureStarted(state.oscillators);
    }
    if (engine && engine.setMetronomeOn) {
      // Make sure the BPM is in sync the first time it starts.
      if (engine.setMetronomeBPM) engine.setMetronomeBPM(state.bpm);
      engine.setMetronomeOn(!!on);
    }
    renderAll();
  },
  setDelayTiming(oscIndex, timingId) {
    state.oscillators[oscIndex].delay.timing = timingId;
    // If a musical division was picked, compute and apply the time. "free"
    // leaves the time slider as the source of truth.
    const sec = delayTimeForTiming(timingId, state.bpm);
    if (sec != null) {
      state.oscillators[oscIndex].delay.timeSec = sec;
      engine.setDelayTime(oscIndex, sec);
    }
    renderAll();
  },

  // Chorus
  // v1 fix: every dispatch setter that writes to a slider-backed
  // field needs renderAll() at the end so the --fill CSS var and
  // label catch up with the new state. Without it, the slider's
  // thumb moves natively but the colored fill bar stays frozen at
  // its last render — user saw "balls and bars desynced" on the
  // chorus row (rate / depth / width / mix). All four were missing
  // renderAll. setDrive + setFMIndex below got the same treatment
  // for the same reason.
  setChorusRate(oscIndex, rate) {
    const clamped = Math.max(0.05, Math.min(6.0, rate));
    state.oscillators[oscIndex].chorus.rateHz = clamped;
    engine.setChorusRate(oscIndex, clamped);
    renderAll();
  },
  setChorusDepth(oscIndex, depth) {
    const clamped = Math.max(0, Math.min(1, depth));
    state.oscillators[oscIndex].chorus.depth = clamped;
    engine.setChorusDepth(oscIndex, clamped);
    renderAll();
  },
  setChorusWidth(oscIndex, width) {
    const clamped = Math.max(0, Math.min(1, width));
    state.oscillators[oscIndex].chorus.width = clamped;
    engine.setChorusWidth(oscIndex, clamped);
    renderAll();
  },
  setChorusMix(oscIndex, mix) {
    const clamped = Math.max(0, Math.min(1, mix));
    state.oscillators[oscIndex].chorus.mix = clamped;
    engine.setChorusMix(oscIndex, clamped);
    renderAll();
  },

  // FM (cross-osc): sourceIndex = -1 disables; otherwise must differ from carrier.
  setFMSource(oscIndex, sourceIndex) {
    const src = sourceIndex === oscIndex ? -1 : sourceIndex;
    state.oscillators[oscIndex].fm.sourceIndex = src;
    engine.setFMSource(oscIndex, src);
    renderAll();
  },
  setFMIndex(oscIndex, idx) {
    const clamped = Math.max(0, Math.min(800, idx));
    state.oscillators[oscIndex].fm.index = clamped;
    engine.setFMIndex(oscIndex, clamped);
    renderAll();
  },

  clearSample(oscIndex) {
    engine.clearSample(oscIndex);
    state.oscillators[oscIndex].sampleName = null;
    sampleCache[oscIndex] = null;
    if (state.oscillators[oscIndex].waveform === "sample") {
      state.oscillators[oscIndex].waveform = "sine";
      engine.setWaveform(oscIndex, "sine");
    }
    renderAll();
  },

  /// UI helpers: read-only inspectors so ui.js doesn't have to import
  /// sampleCache or storage helpers directly. The sample source decides
  /// whether the 🔖 button shows ("upload" → yes; "bundled" / "library"
  /// → no, already persistent). The library list feeds the My Library
  /// section in the Bundled picker.
  getSampleSource(oscIndex) {
    return sampleCache[oscIndex]?.source || null;
  },
  getLibrarySamples() {
    return loadLibrarySamples();
  },

  async saveCurrentAsUserPreset(name) {
    const trimmed = (name || "").trim();
    if (!trimmed) return;
    const oscillators = await Promise.all(state.oscillators.map(async (o, i) => {
      let sampleRef = null;
      if (o.sampleName && sampleCache[i]) {
        if (!sampleCache[i].id) sampleCache[i].id = newSampleId();
        await putSample(sampleCache[i].id, sampleCache[i].blob, sampleCache[i].name, sampleCache[i].type);
        sampleRef = { id: sampleCache[i].id, name: sampleCache[i].name };
      }
      return {
        frequencyHz: o.frequencyHz, waveform: o.waveform, amplitude: o.amplitude,
        pan: o.pan, isMuted: o.isMuted, isSoloed: o.isSoloed,
        filter: { ...o.filter },
        drive: o.drive,
        fm:     { ...o.fm },
        chorus: { ...o.chorus },
        reverb: { ...o.reverb }, delay: { ...o.delay },
        lfos: o.lfos.map((l) => ({ ...l })),
        startDelaySec: o.startDelaySec || 0,
        playDurationSec: o.playDurationSec || 0,
        replayCount: (o.replayCount != null) ? o.replayCount : 1,
        // v1 fix: round-trip granular state + grain row + drift + sample
        // window. Previously these were dropped on save, so toggling
        // Grainy + dragging POS/SCAN + saving lost the settings on
        // reload. Now matches iOS UserPreset schema.
        grain: o.grain ? { ...o.grain } : undefined,
        sampleGranular: !!o.sampleGranular,
        grainSamplePosFrac: o.grainSamplePosFrac,
        grainSamplePosJitter: o.grainSamplePosJitter,
        drift: o.drift ? { ...o.drift } : undefined,
        sampleStartFrac: o.sampleStartFrac,
        sampleEndFrac: o.sampleEndFrac,
        sampleFadeInSec: o.sampleFadeInSec,
        sampleFadeOutSec: o.sampleFadeOutSec,
        sampleBaseFreqHz: o.sampleBaseFreqHz,        // v1: record-time pitch baseline
        sampleNativeBaseFreq: o.sampleBaseFreqHz,    // alias for iOS-shaped reads
        sampleRef
      };
    }));
    const preset = {
      id: newPresetId(), name: trimmed, createdAt: new Date().toISOString(),
      keyId: state.keyId, octave: state.octave, chordId: state.chordId,
      tuningId: state.tuningId, masterVolume: state.masterVolume,
      oscillators,
      // v1.1 Automation Timeline. Preserved from whatever was last
      // loaded — web v1.1 doesn't expose a UI to edit timelines, so we
      // just round-trip the field. iOS users can save patches with
      // automation and share them via .dronepreset; if a web user opens
      // and resaves such a patch, the timeline stays intact for the
      // next iOS recipient. Phase D / v1.2 will add a web editor.
      ...(state._automation ? { automation: state._automation } : {}),
    };
    state.userPresets = [preset, ...state.userPresets];
    saveUserPresets(state.userPresets);
    state.activePresetName = preset.name;
    // The just-saved preset is now active — later automation edits sync here.
    state.activeUserPresetId = preset.id;
    renderAll();
  },

  async loadUserPreset(id) {
    const preset = state.userPresets.find((p) => p.id === id);
    if (!preset) return;
    // This preset is now the active one — automation edits sync back here.
    state.activeUserPresetId = id;
    engine.ensureStarted(state.oscillators);
    engine.resume();
    state.keyId = preset.keyId ?? state.keyId;
    state.octave = preset.octave ?? state.octave;
    state.chordId = preset.chordId ?? state.chordId;
    state.tuningId = preset.tuningId ?? state.tuningId;
    // v1.1 Automation Timeline. iOS-edited timelines round-trip through
    // .dronepreset and are preserved by the web app for cross-device
    // continuity. Full automation playback + UI on web lands in v1.2;
    // for v1.1 the field is just stored so it's not lost when a web
    // user saves a patch they got from iOS.
    if (preset.automation) {
      // Deep-clone so live edits don't mutate the stored preset until the
      // auto-sync writes them back explicitly.
      state._automation = JSON.parse(JSON.stringify(preset.automation));
    } else {
      delete state._automation;
    }
    // New patch → next Play snapshots a fresh automation baseline.
    automationPlayer.invalidate();
    if (preset.masterVolume != null) actions.setMasterVolume(preset.masterVolume);
    for (let i = 0; i < 4; i++) {
      const o = preset.oscillators[i]; if (!o) continue;
      actions.setFrequency(i, o.frequencyHz);
      actions.setAmplitude(i, o.amplitude);
      actions.setPan(i, o.pan);
      if (state.oscillators[i].isMuted !== o.isMuted)   actions.toggleMute(i);
      if (state.oscillators[i].isSoloed !== o.isSoloed) actions.toggleSolo(i);
      actions.setFilterType(i, o.filter.type);
      actions.setFilterCutoff(i, o.filter.cutoffHz);
      actions.setFilterQ(i, o.filter.q);
      // FM + Chorus + Drive migration — older presets won't have these; merge with defaults.
      const fm     = { ...defaultFM(),     ...(o.fm     || {}) };
      const chorus = { ...defaultChorus(), ...(o.chorus || {}) };
      actions.setDrive(i, (o.drive != null) ? o.drive : 1.0);
      actions.setStartDelay(i,    o.startDelaySec   || 0);
      actions.setPlayDuration(i,  o.playDurationSec || 0);
      actions.setReplayCount(i,   (o.replayCount != null) ? o.replayCount : 1);
      actions.setFMSource(i, fm.sourceIndex);
      actions.setFMIndex(i, fm.index);
      actions.setChorusRate(i, chorus.rateHz);
      actions.setChorusDepth(i, chorus.depth);
      actions.setChorusWidth(i, chorus.width);
      actions.setChorusMix(i, chorus.mix);
      actions.setReverbDecay(i, o.reverb.decaySec);
      actions.setReverbMix(i, o.reverb.mix);
      actions.setDelayTime(i, o.delay.timeSec);
      actions.setDelayFeedback(i, o.delay.feedback);
      actions.setDelayMix(i, o.delay.mix);
      // Pad with default LFO 4 (sine→pitch) for presets saved before LFO 4 existed.
      const lfos = o.lfos.slice();
      while (lfos.length < 4) lfos.push({ shape: "sine", targets: ["pitch"], rateHz: 0.30, depth: 0 });
      for (let k = 0; k < 4; k++) {
        actions.setLfoShape(i, k, lfos[k].shape);
        // v1 fix: read whichever target form is present. Older
        // presets carry `target: "pan"`; v1.1+ carries
        // `targets: ["pan", ...]`. Falling back to the singular
        // `target` only — what we did before — passed undefined for
        // any preset saved post-v1.1 with the array form only, and
        // setLfoTarget(undefined) left lfo.targets = [undefined].
        // The next Save then stringified that as [null] in JSON, and
        // the strict iOS decoder rejected the imported envelope with
        // "value not found String at preset.oscillators[N].lfos[M].targets[0]".
        // currentTargets() returns the v1.1 array directly, falling
        // back to the legacy singular form if needed.
        const targetsToApply = currentTargets(lfos[k]);
        if (targetsToApply.length > 0) {
          // Use toggleLfoTarget to build up the multi-target set
          // rather than setLfoTarget which truncates to one. Clear
          // the LFO's current targets first so the toggles end up
          // with exactly the saved set.
          for (const t of currentTargets(state.oscillators[i].lfos[k])) {
            actions.toggleLfoTarget(i, k, t);
          }
          for (const t of targetsToApply) {
            actions.toggleLfoTarget(i, k, t);
          }
        }
        // v1: restore sync flags BEFORE setLfoRate so the rate
        // helper picks up the right path. Old saves without these
        // fields leave them undefined (treated as off).
        if (lfos[k].rateSyncEnabled !== undefined) {
          state.oscillators[i].lfos[k].rateSyncEnabled = !!lfos[k].rateSyncEnabled;
        }
        if (lfos[k].rateDenomination !== undefined) {
          state.oscillators[i].lfos[k].rateDenomination = lfos[k].rateDenomination;
        }
        actions.setLfoRate(i, k, lfos[k].rateHz);
        actions.setLfoDepth(i, k, lfos[k].depth);
      }
      actions.clearSample(i);
      if (o.sampleRef && o.sampleRef.id) {
        const rec = await getSample(o.sampleRef.id);
        if (rec && rec.blob) {
          try {
            const ab = await rec.blob.arrayBuffer();
            const audioBuffer = await engine.ctx.decodeAudioData(ab.slice(0));
            engine.loadSample(i, audioBuffer);
            state.oscillators[i].sampleName = rec.name || o.sampleRef.name;
            state.oscillators[i].waveform = "sample";
            engine.setWaveform(i, "sample");
            sampleCache[i] = { id: o.sampleRef.id, name: rec.name, blob: rec.blob, type: rec.type || "audio/*" };
          } catch (e) { console.error("Failed to reload sample", e); }
        }
      } else if (o.waveform !== "sample") {
        actions.setWaveform(i, o.waveform);
      }
      // v1 fix: restore granular state + grain row + drift + sample
      // window. These were saved but never re-applied on load, so
      // toggling Grainy on then saving lost the state.
      if (o.grain) {
        actions.setGrainSize(i, o.grain.sizeMs);
        // v1: restore BPM-sync fields BEFORE density so the density
        // setter routes through the right path. When sync is on, the
        // raw densityHz from the preset becomes the "free fallback"
        // value — the engine reads BPM × denomination instead.
        if (o.grain.densityDenomination != null) {
          actions.setGrainDensityDenomination(i, o.grain.densityDenomination);
        }
        if (o.grain.densitySyncEnabled != null) {
          actions.setGrainDensitySync(i, !!o.grain.densitySyncEnabled);
        }
        actions.setGrainDensity(i, o.grain.densityHz);
        actions.setGrainJitter(i, o.grain.jitter);
        actions.setGrainPanSpread(i, o.grain.panSpread);
        // v1: restore allowOverlap if the preset specified it. Old
        // presets without this field default to false (the historical
        // clamping behavior), which is what they had at save time.
        if (o.grain.allowOverlap != null) {
          actions.setGrainAllowOverlap(i, !!o.grain.allowOverlap);
        }
      }
      if (o.sampleGranular != null) {
        actions.setSampleGranular(i, !!o.sampleGranular);
      }
      if (o.grainSamplePosFrac != null) {
        actions.setGrainSamplePos(i, o.grainSamplePosFrac);
      }
      if (o.grainSamplePosJitter != null) {
        actions.setGrainSamplePosJitter(i, o.grainSamplePosJitter);
      }
      if (o.sampleStartFrac != null) actions.setSampleStart(i, o.sampleStartFrac);
      if (o.sampleEndFrac != null)   actions.setSampleEnd(i, o.sampleEndFrac);
      if (o.sampleFadeInSec != null) actions.setSampleFadeIn(i, o.sampleFadeInSec);
      if (o.sampleFadeOutSec != null) actions.setSampleFadeOut(i, o.sampleFadeOutSec);
      // v1 fix (Jun 2026): restore drift state including quantizeToScale.
      // Previously the load path completely skipped drift, so the
      // toggle's checkbox showed whatever was already on screen rather
      // than the saved preset's intent, AND the audio engine voice's
      // pitchQuantizeToScale flag was left at whatever it was before
      // (or undefined when engine.stop had cleared the voices). User
      // symptom: load a preset saved with quantize on, see the
      // checkbox checked, hear no snap — until untick+retick.
      // Routes through the public setter when present so the scale
      // cache is recomputed and the engine flag is pushed coherently.
      if (o.drift) {
        const dr = { ...defaultDrift(), ...o.drift };
        // Preserve other drift fields (mode, amount, period) directly;
        // route the boolean through the public setter which both
        // writes the engine flag AND recomputes scaleNotesHz.
        state.oscillators[i].drift = { ...dr, quantizeToScale: false };
        actions.setVoiceQuantizeToScale(i, !!dr.quantizeToScale);
      }
      // v1 restore: sample unity-pitch baseline. Accept either the
      // web key or the iOS alias so a .dronepreset round-trips
      // either direction. Old saves without either field default to
      // 220 (the historical baseline for bundled / uploaded samples).
      const base = (o.sampleBaseFreqHz != null) ? o.sampleBaseFreqHz
                 : (o.sampleNativeBaseFreq != null) ? o.sampleNativeBaseFreq
                 : null;
      if (base != null) {
        state.oscillators[i].sampleBaseFreqHz = base;
        engine.setSampleBaseFreqHz(i, base);
      }
    }
    state.activePresetName = preset.name;
    renderAll();
  },

  async deleteUserPreset(id) {
    const preset = state.userPresets.find((p) => p.id === id);
    if (!preset) return;
    const sampleIds = preset.oscillators.map((o) => o.sampleRef?.id).filter(Boolean);
    state.userPresets = state.userPresets.filter((p) => p.id !== id);
    saveUserPresets(state.userPresets);
    const stillUsed = new Set(state.userPresets.flatMap((p) =>
      p.oscillators.map((o) => o.sampleRef?.id).filter(Boolean)));
    for (const sid of sampleIds) {
      if (!stillUsed.has(sid)) { try { await deleteSample(sid); } catch {} }
    }
    if (state.activePresetName === preset.name) state.activePresetName = null;
    renderAll();
  },

  // v1.1: cross-device preset sharing.

  /// Pack a saved preset (+ any embedded sample audio) and trigger a
  /// browser download of the .dronepreset file. Returns true on
  /// success — the UI uses the return value to surface a toast.
  async exportUserPreset(id) {
    return await exportUserPresetDownload(id);
  },

  /// Decode a .dronepreset file the user picked, materialize embedded
  /// samples into IndexedDB, and append the preset to userPresets.
  /// Refreshes the state mirror + re-renders. Throws on a malformed
  /// file (the UI catches and toasts the localized message).
  async importUserPresetFile(file) {
    const name = await importUserPresetFromFile(file);
    state.userPresets = loadUserPresets();
    renderAll();
    return name;
  },

  setDriftScene(sceneId) {
    if (sceneId === "off") {
      stopDrift();
    } else {
      startDrift(sceneId);
    }
  },

  startJourney(id) { startJourney(id); },
  stopJourney()    { stopJourney(); },

  // ─── User journeys (composer) ──────────────────────────
  saveUserJourney(spec) {
    const cleaned = sanitizeUserJourney(spec);
    if (!cleaned) return false;
    state.userJourneys.unshift(cleaned);
    saveUserJourneys(state.userJourneys);
    renderAll();
    return true;
  },
  deleteUserJourney(id) {
    state.userJourneys = state.userJourneys.filter((j) => j.id !== id);
    saveUserJourneys(state.userJourneys);
    if (state.activeJourneyId === id) stopJourney();
    renderAll();
  },

  // ─── Per-voice presets ──────────────────────────────────
  saveCurrentVoiceAsPreset(oscIndex, name) {
    const o = state.oscillators[oscIndex];
    if (!o) return;
    const voice = {
      frequencyHz: o.frequencyHz,
      waveform: o.waveform,
      amplitude: o.amplitude,
      pan: o.pan,
      filter: { ...o.filter },
      drive:  o.drive,
      fm:     { ...o.fm },
      chorus: { ...o.chorus },
      reverb: { ...o.reverb },
      delay:  { ...o.delay },
      lfos:   o.lfos.map((l) => ({ ...l })),
      drift:  { ...o.drift },
      startDelaySec:    o.startDelaySec || 0,
      playDurationSec:  o.playDurationSec || 0
    };
    const cleanName = (name || "").trim() ||
      `${waveformLabel(voice.waveform)} ${voice.frequencyHz.toFixed(1)} Hz`;
    state.voicePresets.unshift({
      id: newVoicePresetId(),
      name: cleanName,
      voice,
      createdAt: Date.now()
    });
    saveVoicePresets(state.voicePresets);
    renderAll();
  },

  loadVoicePreset(oscIndex, presetId) {
    const p = state.voicePresets.find((x) => x.id === presetId);
    if (!p) return;
    const v = p.voice;
    const o = state.oscillators[oscIndex];
    if (!o) return;
    // Copy fields with defensive defaults so older presets (saved before
    // drift was a field) still load cleanly.
    o.frequencyHz = v.frequencyHz;
    o.waveform = v.waveform;
    o.amplitude = v.amplitude;
    o.pan = v.pan;
    o.filter = { ...defaultFilter(), ...(v.filter || {}) };
    o.drive  = (v.drive != null) ? v.drive : 1.0;
    o.startDelaySec   = v.startDelaySec   || 0;
    o.playDurationSec = v.playDurationSec || 0;
    o.fm     = { ...defaultFM(),     ...(v.fm     || {}) };
    o.chorus = { ...defaultChorus(), ...(v.chorus || {}) };
    o.reverb = { ...defaultReverb(), ...(v.reverb || {}) };
    o.delay  = { ...defaultDelay(),  ...(v.delay  || {}) };
    o.lfos   = (v.lfos || defaultLfos()).map((l) => ({ ...l }));
    o.drift  = { ...defaultDrift(),  ...(v.drift  || {}) };
    // Push everything to the engine.
    engine.setFrequency(oscIndex, o.frequencyHz);
    engine.setWaveform(oscIndex, o.waveform);
    engine.setAmplitude(oscIndex, o.amplitude);
    engine.setPan(oscIndex, o.pan);
    engine.setFilterType(oscIndex, o.filter.type);
    engine.setFilterCutoff(oscIndex, o.filter.cutoffHz);
    engine.setFilterQ(oscIndex, o.filter.q);
    engine.setDrive(oscIndex, o.drive);
    engine.setStartDelay(oscIndex, o.startDelaySec);
    engine.setPlayDuration(oscIndex, o.playDurationSec);
    engine.setReplayCount(oscIndex, (o.replayCount != null) ? o.replayCount : 1);
    engine.setFMSource(oscIndex, o.fm.sourceIndex);
    engine.setFMIndex(oscIndex, o.fm.index);
    engine.setChorusRate(oscIndex, o.chorus.rateHz);
    engine.setChorusDepth(oscIndex, o.chorus.depth);
    engine.setChorusWidth(oscIndex, o.chorus.width);
    engine.setChorusMix(oscIndex, o.chorus.mix);
    engine.setReverbDecay(oscIndex, o.reverb.decaySec);
    engine.setReverbMix(oscIndex, o.reverb.mix);
    engine.setDelayTime(oscIndex, o.delay.timeSec);
    engine.setDelayFeedback(oscIndex, o.delay.feedback);
    engine.setDelayMix(oscIndex, o.delay.mix);
    for (let i = 0; i < o.lfos.length; i++) {
      engine.setLfoShape(oscIndex, i, o.lfos[i].shape);
      engine.setLfoTarget(oscIndex, i, o.lfos[i].target);
      engine.setLfoRate(oscIndex, i, o.lfos[i].rateHz);
      engine.setLfoDepth(oscIndex, i, o.lfos[i].depth);
    }
    // Drift may have flipped from static to active or vice versa.
    reconcileDriftRunning();
    state.activePresetName = null;
    state.driftSceneId = sceneIdForCurrentVoices();
    renderAll();
  },

  deleteVoicePreset(presetId) {
    state.voicePresets = state.voicePresets.filter((p) => p.id !== presetId);
    saveVoicePresets(state.voicePresets);
    renderAll();
  },
  setVoicePitchDrift(voiceIndex, mode) { setVoicePitchDrift(voiceIndex, mode); },
  setVoicePanDrift(voiceIndex, mode)   { setVoicePanDrift(voiceIndex, mode); },

  /// v1.1 quantize-to-scale per voice. Mirror of iOS
  /// setVoiceQuantizeToScale. Recomputes the scale cache on the
  /// engine on first enable so the snap can take effect immediately.
  setVoiceQuantizeToScale(voiceIndex, on) {
    if (!state.oscillators[voiceIndex]) return;
    state.oscillators[voiceIndex].drift.quantizeToScale = !!on;
    if (engine && engine.voices && engine.voices[voiceIndex]) {
      engine.voices[voiceIndex].pitchQuantizeToScale = !!on;
    }
    if (on) recomputeQuantizeScale();
    renderAll();
  },

  /// Randomize this oscillator's parameters — everything except level so
  /// the voice doesn't suddenly blast or vanish. Touches frequency,
  /// waveform (non-sample), pan, filter type/cutoff/Q, reverb decay/mix,
  /// delay time/feedback/mix, and all four LFOs (shape/target/rate/depth).
  randomizeOscillator(index) {
    const o = state.oscillators[index];
    if (!o) return;

    const rand = (lo, hi) => lo + Math.random() * (hi - lo);
    const choose = (arr) => arr[Math.floor(Math.random() * arr.length)];

    // Frequency — log-uniform across the meditation drone range (60–800 Hz)
    // so we don't get harsh top-end or sub-audible bass.
    const lo = Math.log2(60), hi = Math.log2(800);
    const newFreq = Math.pow(2, lo + Math.random() * (hi - lo));
    actions.setFrequency(index, newFreq);

    // Don't randomize to "sample" — most slots have no sample loaded and
    // it'd just silence the voice.
    actions.setWaveform(index, choose(["sine", "triangle", "sawtooth", "square"]));

    actions.setPan(index, rand(-0.85, 0.85));

    // Filter — random type, log-uniform cutoff in a musical range.
    actions.setFilterType(index, choose(["lowpass", "highpass", "bandpass"]));
    const fLo = Math.log2(200), fHi = Math.log2(6000);
    actions.setFilterCutoff(index, Math.pow(2, fLo + Math.random() * (fHi - fLo)));
    actions.setFilterQ(index, rand(0.5, 3.0));

    // Reverb + delay — favor lush but not chaotic settings.
    actions.setReverbDecay(index, rand(0.5, 6.0));
    actions.setReverbMix(index, rand(0, 0.5));
    actions.setDelayTime(index, rand(0.08, 0.8));
    actions.setDelayFeedback(index, rand(0, 0.5));
    actions.setDelayMix(index, rand(0, 0.4));

    // Chorus — 40% chance of "off" (mix=0), otherwise musical defaults.
    if (Math.random() < 0.4) {
      actions.setChorusMix(index, 0);
    } else {
      actions.setChorusRate(index, rand(0.2, 2.5));
      actions.setChorusDepth(index, rand(0.2, 0.7));
      actions.setChorusWidth(index, rand(0.4, 1.0));
      actions.setChorusMix(index, rand(0.15, 0.55));
    }

    // FM — 50% off, otherwise pick one of the other 3 voices with a small index.
    if (Math.random() < 0.5) {
      actions.setFMSource(index, -1);
      actions.setFMIndex(index, 0);
    } else {
      const others = [0, 1, 2, 3].filter((j) => j !== index);
      actions.setFMSource(index, choose(others));
      // Log-musical index: mostly small (5-80 Hz), occasionally bell-like (200+).
      actions.setFMIndex(index, Math.random() < 0.8 ? rand(5, 80) : rand(150, 400));
    }

    // LFOs — random shape + target per LFO, slow rate, modest depth.
    const shapes = ["sine", "triangle", "square", "sh"];
    const targets = ["pan", "amp", "cutoff", "pitch"];
    for (let lfo = 0; lfo < o.lfos.length; lfo++) {
      actions.setLfoShape(index, lfo, choose(shapes));
      actions.setLfoTarget(index, lfo, choose(targets));
      actions.setLfoRate(index, lfo, rand(0.05, 1.5));
      actions.setLfoDepth(index, lfo, rand(0, 0.6));
    }

    // Drift — random pitch + pan motion. 35% chance of static for either
    // dimension so a randomize roll often produces a partially-quiet voice
    // mixed with movement, rather than 4 voices all wildly drifting.
    const pitchDriftModes = ["static", "static", "up", "down", "upDown", "downUp", "wave", "ocean", "glacial"];
    const panDriftModes   = ["static", "static", "sweepLR", "sweepRL", "pendulum", "antiPendulum", "glacial"];
    o.drift.pitchAmount = rand(0.25, 1.5);
    o.drift.pitchPhase  = Math.random();
    o.drift.panAmount   = rand(0.5, 1.0);
    o.drift.panPhase    = Math.random();
    // Use the public setters so the drift timer reconciles itself and the
    // header pill flips to "Custom" if voices no longer match a scene.
    actions.setVoicePitchDrift(index, choose(pitchDriftModes));
    actions.setVoicePanDrift(index, choose(panDriftModes));

    // Clear preset selection — randomization makes us "dirty".
    state.activePresetName = null;
    renderAll();
  },

  /// Randomize ALL four voices in one tap, then pick a fresh chord — the
  /// "dice next to OSC pills" feature. Preserves master amplitudes so the
  /// mix doesn't suddenly blast or vanish. Snapshots the entire pre-roll
  /// state into `state.preRandomizeSnapshot` so `undoRandomize` can
  /// restore it byte-for-byte. Single-level undo (one snapshot — the
  /// most recent randomize).
  randomizeAll() {
    // Deep-snapshot oscillators + chord/key so undo restores exactly
    // what was here a moment ago. JSON round-trip is fine — no
    // functions, no DOM refs in the snapshot.
    state.preRandomizeSnapshot = {
      oscillators: JSON.parse(JSON.stringify(state.oscillators)),
      keyId: state.keyId,
      chordId: state.chordId,
      octave: state.octave
    };
    state.canUndoRandomize = true;
    // Preserve master amps across the dice roll.
    const savedAmps = state.oscillators.map((o) => o.amplitude);
    for (let i = 0; i < state.oscillators.length; i++) {
      actions.randomizeOscillator(i);
      actions.setAmplitude(i, savedAmps[i]);
    }
    // Pick a new chord (random root + chord type) — gives the whole
    // patch a fresh tonal context to match the rolled FX/LFO settings.
    // Restrict to the musical "Triads & 7ths" + a few Extensions so
    // we don't land on diminished / half-diminished / chromatic
    // clusters that fight any random FX roll.
    const newRoot = Math.floor(Math.random() * 12);   // 0..11 matches KEYS[id]
    const goodChordIds = ["maj","min","sus2","sus4","maj7","min7","mMaj7","add9","min_add9","6","min6"];
    const newChordId = goodChordIds[Math.floor(Math.random() * goodChordIds.length)];
    actions.setKey(newRoot);
    actions.setChord(newChordId);
    renderAll();
  },

  /// Restore the snapshot captured by the most recent `randomizeAll`.
  /// Single-level — taking undo clears the snapshot, so undoing twice
  /// is a no-op. Mirrors the iOS DroneViewModel.undoRandomize behavior.
  undoRandomize() {
    if (!state.canUndoRandomize || !state.preRandomizeSnapshot) return;
    const snap = state.preRandomizeSnapshot;
    // Restore each voice's full state by pushing every field through
    // the public setters so the engine reconciles.
    for (let i = 0; i < snap.oscillators.length; i++) {
      const o = snap.oscillators[i];
      state.oscillators[i] = JSON.parse(JSON.stringify(o));
      actions.setFrequency(i, o.frequencyHz);
      actions.setWaveform(i, o.waveform);
      actions.setAmplitude(i, o.amplitude);
      actions.setPan(i, o.pan);
      actions.setFilterType(i, o.filter.type);
      actions.setFilterCutoff(i, o.filter.cutoffHz);
      actions.setFilterQ(i, o.filter.q);
      actions.setDrive(i, o.drive ?? 1.0);
      actions.setReverbDecay(i, o.reverb.decaySec);
      actions.setReverbMix(i, o.reverb.mix);
      actions.setDelayTime(i, o.delay.timeSec);
      actions.setDelayFeedback(i, o.delay.feedback);
      actions.setDelayMix(i, o.delay.mix);
      actions.setChorusRate(i, o.chorus.rateHz);
      actions.setChorusDepth(i, o.chorus.depth);
      actions.setChorusWidth(i, o.chorus.width);
      actions.setChorusMix(i, o.chorus.mix);
      actions.setFMSource(i, o.fm.sourceIndex);
      actions.setFMIndex(i, o.fm.index);
      actions.setStartDelay(i, o.startDelaySec || 0);
      actions.setPlayDuration(i, o.playDurationSec || 0);
      actions.setReplayCount(i, (o.replayCount != null) ? o.replayCount : 1);
      for (let lfo = 0; lfo < o.lfos.length; lfo++) {
        actions.setLfoShape(i, lfo, o.lfos[lfo].shape);
        actions.setLfoTarget(i, lfo, (o.lfos[lfo].targets || ["pan"])[0]);
        actions.setLfoRate(i, lfo, o.lfos[lfo].rateHz);
        actions.setLfoDepth(i, lfo, o.lfos[lfo].depth);
      }
      actions.setVoicePitchDrift(i, o.drift.pitchMode || "static");
      actions.setVoicePanDrift(i, o.drift.panMode || "static");
    }
    // Restore the chord / key / octave too.
    if (snap.keyId != null)    actions.setKey(snap.keyId);
    if (snap.chordId != null)  actions.setChord(snap.chordId);
    if (snap.octave != null && typeof actions.setOctave === "function") {
      actions.setOctave(snap.octave);
    }
    // Single-level undo — clear the snapshot after applying it.
    state.preRandomizeSnapshot = null;
    state.canUndoRandomize = false;
    renderAll();
  }
};

// ──────────────────────────────────────────────────
// Drift scenes — per-voice pitch + pan motion over the session.
//
// Each scene assigns a (pitchMode, pitchAmount, pitchPhase) and
// (panMode, panAmount, panPhase) per voice. Pitch is measured in
// octaves from baseline; pan is -1..1 absolute.
//
// pitchMode:
//   static  — hold baseline
//   up      — climb pitchAmount octaves linearly over session
//   down    — descend pitchAmount octaves linearly
//   upDown  — ^ shape: ascend by mid-session, return to baseline by end
//   downUp  — V shape: descend then return
//   wave    — full sine over session (±pitchAmount octaves)
//   glacial — random walk around baseline (the old "Glacial" behavior)
//
// panMode:
//   static          — hold baseline pan
//   sweepLR         — −1 → +1 linearly
//   sweepRL         — +1 → −1 linearly
//   pendulum        — 2 full sine cycles per session
//   antiPendulum    — same with inverted phase
//   glacial         — random walk around baseline
//
// phase (0..1) shifts each voice's progress modularly so multi-voice scenes
// can stagger phases (e.g. "Breathing" runs the same downUp on all 4 voices
// at evenly-spaced phase offsets, creating a breathing polyrhythm).
const DRIFT_SCENES = [
  // ─── Singles ───
  { id: "off",     name: "Off",         hint: "No drift",
    voices: [ {}, {}, {}, {} ] },
  { id: "glacial", name: "Glacial",     hint: "Gentle random wander on all voices",
    voices: [
      { pitchMode: "glacial", panMode: "glacial" },
      { pitchMode: "glacial", panMode: "glacial" },
      { pitchMode: "glacial", panMode: "glacial" },
      { pitchMode: "glacial", panMode: "glacial" },
    ]},
  { id: "ascend",  name: "All Ascend",  hint: "Every voice climbs an octave",
    voices: Array.from({length: 4}, () => ({ pitchMode: "up", pitchAmount: 1 })) },
  { id: "descend", name: "All Descend", hint: "Every voice falls an octave",
    voices: Array.from({length: 4}, () => ({ pitchMode: "down", pitchAmount: 1 })) },
  { id: "downUp",  name: "All Down/Up", hint: "Every voice falls then returns",
    voices: Array.from({length: 4}, () => ({ pitchMode: "downUp", pitchAmount: 1 })) },
  { id: "upDown",  name: "All Up/Down", hint: "Every voice rises then returns",
    voices: Array.from({length: 4}, () => ({ pitchMode: "upDown", pitchAmount: 1 })) },

  // ─── Coordinated scenes ───
  { id: "divergence",  name: "Divergence",     hint: "2 voices up, 2 voices down",
    voices: [
      { pitchMode: "up",   pitchAmount: 1 },
      { pitchMode: "down", pitchAmount: 1 },
      { pitchMode: "up",   pitchAmount: 1 },
      { pitchMode: "down", pitchAmount: 1 },
    ]},
  { id: "convergence", name: "Convergence",    hint: "Outer voices drift toward middle",
    voices: [
      { pitchMode: "down", pitchAmount: 0.5 },
      { pitchMode: "static" },
      { pitchMode: "static" },
      { pitchMode: "up",   pitchAmount: 0.5 },
    ]},
  { id: "crossing",    name: "Crossing Paths", hint: "Pairs of V and ^ that cross at session mid",
    voices: [
      { pitchMode: "downUp", pitchAmount: 1 },
      { pitchMode: "upDown", pitchAmount: 1 },
      { pitchMode: "downUp", pitchAmount: 1, pitchPhase: 0.25 },
      { pitchMode: "upDown", pitchAmount: 1, pitchPhase: 0.25 },
    ]},
  { id: "pendulum",    name: "Pendulum",       hint: "Outer voices swing pan + pitch; inner pair holds center",
    voices: [
      { pitchMode: "up",   pitchAmount: 0.5, panMode: "pendulum" },
      { pitchMode: "static", panMode: "static" },
      { pitchMode: "static", panMode: "static" },
      { pitchMode: "down", pitchAmount: 0.5, panMode: "antiPendulum" },
    ]},
  { id: "breathing",   name: "Breathing",      hint: "Down/Up on all voices, staggered phases",
    voices: [
      { pitchMode: "downUp", pitchAmount: 0.5, pitchPhase: 0.00 },
      { pitchMode: "downUp", pitchAmount: 0.5, pitchPhase: 0.25 },
      { pitchMode: "downUp", pitchAmount: 0.5, pitchPhase: 0.50 },
      { pitchMode: "downUp", pitchAmount: 0.5, pitchPhase: 0.75 },
    ]},
  { id: "spiral",      name: "Spiral",         hint: "Up/Down with varying depths — voices spiral around the root",
    voices: [
      { pitchMode: "upDown", pitchAmount: 1.00 },
      { pitchMode: "upDown", pitchAmount: 0.75, pitchPhase: 0.125 },
      { pitchMode: "upDown", pitchAmount: 0.50, pitchPhase: 0.25 },
      { pitchMode: "upDown", pitchAmount: 0.25, pitchPhase: 0.375 },
    ]},
  { id: "aurora",      name: "Aurora",         hint: "Glacial pitch + opposite slow pan sweeps",
    voices: [
      { pitchMode: "glacial", panMode: "sweepLR" },
      { pitchMode: "glacial", panMode: "sweepRL" },
      { pitchMode: "glacial", panMode: "pendulum" },
      { pitchMode: "glacial", panMode: "antiPendulum" },
    ]},
  { id: "tidal",       name: "Tidal",          hint: "Slow sine wave on pitch, opposite pans for swelling space",
    voices: [
      { pitchMode: "wave", pitchAmount: 0.5, panMode: "sweepLR" },
      { pitchMode: "wave", pitchAmount: 0.5, panMode: "sweepRL", pitchPhase: 0.5 },
      { pitchMode: "wave", pitchAmount: 0.5, panMode: "sweepLR", pitchPhase: 0.25 },
      { pitchMode: "wave", pitchAmount: 0.5, panMode: "sweepRL", pitchPhase: 0.75 },
    ]},
];

const DRIFT_SCENE_BY_ID = Object.fromEntries(DRIFT_SCENES.map((s) => [s.id, s]));

let driftIntervalId = null;
let driftStartMs = 0;
const driftVoices = [];   // per-osc {baseFreq, basePan, baseAmp, freqTarget, panTarget, ampTarget, nextRetargetAt}

function startDrift(sceneId) {
  // Sceneid === "off" means stop everything. Anything else: apply the
  // scene's per-voice config to the oscillators, then start the timer.
  if (sceneId === "off") { stopDrift(); return; }
  const scene = DRIFT_SCENE_BY_ID[sceneId];
  if (!scene) return;

  driftVoices.length = 0;
  for (let i = 0; i < state.oscillators.length; i++) {
    const o = state.oscillators[i];
    driftVoices.push({
      baseFreq: o.frequencyHz, basePan: o.pan, baseAmp: o.amplitude,
      freqTarget: o.frequencyHz, panTarget: o.pan, ampTarget: o.amplitude,
      nextRetargetAt: 0
    });
    // Apply the scene's voice config into the oscillator's drift state.
    // Preserve the user's per-voice quantize-to-scale toggle across
    // scene changes — quantize is independent of the drift motion the
    // scene is specifying (the scene only describes pitch/pan motion).
    const cfg = scene.voices[i] || {};
    const existingQuantize = o.drift?.quantizeToScale ?? false;
    o.drift = {
      pitchMode:   cfg.pitchMode   || "static",
      pitchAmount: cfg.pitchAmount != null ? cfg.pitchAmount : 1,
      pitchPhase:  cfg.pitchPhase  || 0,
      panMode:     cfg.panMode     || "static",
      panAmount:   cfg.panAmount   != null ? cfg.panAmount   : 1,
      panPhase:    cfg.panPhase    || 0,
      quantizeToScale: existingQuantize,
    };
  }
  state.driftSceneId = sceneId;
  driftStartMs = Date.now();
  if (driftIntervalId) clearInterval(driftIntervalId);
  driftIntervalId = setInterval(driftTick, 1000);
  renderAll();
}

function stopDrift() {
  state.driftSceneId = "off";
  driftVoices.length = 0;
  // Reset each voice's drift motion to static — but preserve the
  // per-voice quantize-to-scale flag (it's an independent setting).
  for (const o of state.oscillators) {
    const existingQuantize = o.drift?.quantizeToScale ?? false;
    o.drift = defaultDrift();
    o.drift.quantizeToScale = existingQuantize;
  }
  if (driftIntervalId) clearInterval(driftIntervalId);
  driftIntervalId = null;
  renderAll();
}

// True if any voice has a non-static drift mode (pitch OR pan). When all
// voices are static, the drift timer can sleep without effect.
function anyVoiceDrifting() {
  return state.oscillators.some((o) =>
    o.drift && (
      (o.drift.pitchMode && o.drift.pitchMode !== "static") ||
      (o.drift.panMode   && o.drift.panMode   !== "static")
    )
  );
}

// Public: change one voice's pitch drift mode without touching others. If
// drift wasn't running, this starts it; if every voice becomes static, this
// stops it.
function setVoicePitchDrift(voiceIndex, mode) {
  const o = state.oscillators[voiceIndex];
  if (!o) return;
  if (!o.drift) o.drift = defaultDrift();
  o.drift.pitchMode = mode;
  reconcileDriftRunning();
  state.driftSceneId = sceneIdForCurrentVoices();
  renderAll();
}
function setVoicePanDrift(voiceIndex, mode) {
  const o = state.oscillators[voiceIndex];
  if (!o) return;
  if (!o.drift) o.drift = defaultDrift();
  o.drift.panMode = mode;
  reconcileDriftRunning();
  state.driftSceneId = sceneIdForCurrentVoices();
  renderAll();
}

// If any voice is drifting and the timer isn't running, start it (and
// snapshot baselines). If no voice is drifting, stop the timer.
function reconcileDriftRunning() {
  if (anyVoiceDrifting()) {
    if (!driftIntervalId) {
      driftVoices.length = 0;
      for (const o of state.oscillators) {
        driftVoices.push({
          baseFreq: o.frequencyHz, basePan: o.pan, baseAmp: o.amplitude,
          freqTarget: o.frequencyHz, panTarget: o.pan, ampTarget: o.amplitude,
          nextRetargetAt: 0
        });
      }
      driftStartMs = Date.now();
      driftIntervalId = setInterval(driftTick, 1000);
    }
  } else {
    if (driftIntervalId) clearInterval(driftIntervalId);
    driftIntervalId = null;
    driftVoices.length = 0;
  }
}

// Returns the scene id whose template matches the current per-voice drift
// state, or "custom" if no scene matches exactly. Used to keep the header
// pill's label in sync after manual edits.
function sceneIdForCurrentVoices() {
  for (const scene of DRIFT_SCENES) {
    let matches = true;
    for (let i = 0; i < state.oscillators.length; i++) {
      const cfg = scene.voices[i] || {};
      const d = state.oscillators[i].drift || defaultDrift();
      if ((cfg.pitchMode || "static") !== d.pitchMode) { matches = false; break; }
      if ((cfg.panMode   || "static") !== d.panMode)   { matches = false; break; }
      const cA = cfg.pitchAmount != null ? cfg.pitchAmount : 1;
      if (Math.abs(cA - d.pitchAmount) > 0.001) { matches = false; break; }
    }
    if (matches) return scene.id;
  }
  return "custom";
}

function driftTick() {
  if (!anyVoiceDrifting()) {
    // All voices went static — stop the timer cleanly.
    if (driftIntervalId) { clearInterval(driftIntervalId); driftIntervalId = null; }
    return;
  }

  const sessionSec = state.sessionDuration > 0 ? state.sessionDuration : 15 * 60;
  const rawProgress = Math.min(1, Math.max(0, (Date.now() - driftStartMs) / (sessionSec * 1000)));

  for (let i = 0; i < driftVoices.length; i++) {
    const v = driftVoices[i];
    const osc = state.oscillators[i];
    if (!v || !osc) continue;
    const cfg = osc.drift || defaultDrift();

    // ─── Pitch ───
    if (cfg.pitchMode === "glacial") {
      glacialPitchVoice(i, v, osc);
    } else if (cfg.pitchMode === "ocean") {
      // Ocean: subtle slow sine wave around the base pitch.
      // Defaults: ±0.25 semi, 90 s period. Per-voice overrides
      // (pitchSemitones, pitchPeriodSec) take precedence if set.
      const oceanPeriod = (cfg.pitchPeriodSec != null) ? cfg.pitchPeriodSec : 90.0;
      let amplitudeOctaves;
      if (cfg.pitchSemitones != null) {
        amplitudeOctaves = cfg.pitchSemitones / 12;
      } else {
        const amount = cfg.pitchAmount != null ? cfg.pitchAmount : 1;
        amplitudeOctaves = (0.25 / 12) * amount;
      }
      const t = (Date.now() - driftStartMs) / 1000;
      const phase = ((t / oceanPeriod) + (cfg.pitchPhase || 0)) % 1;
      const octaveOffset = Math.sin(phase * Math.PI * 2) * amplitudeOctaves;
      const target = v.baseFreq * Math.pow(2, octaveOffset);
      const newFreq = osc.frequencyHz + (target - osc.frequencyHz) * 0.30;
      osc.frequencyHz = newFreq;
      engine.setFrequency(i, newFreq);
    } else if (cfg.pitchMode && cfg.pitchMode !== "static") {
      // Phase: absolute-time period if override set, else session-progress.
      let phase;
      if (cfg.pitchPeriodSec != null && cfg.pitchPeriodSec > 0) {
        const t = (Date.now() - driftStartMs) / 1000;
        phase = ((t / cfg.pitchPeriodSec) + (cfg.pitchPhase || 0)) % 1;
      } else {
        phase = (rawProgress + (cfg.pitchPhase || 0)) % 1;
      }
      // Amplitude: semitones override if set, else pitchAmount * 1 octave.
      let amplitudeOctaves;
      if (cfg.pitchSemitones != null) {
        amplitudeOctaves = cfg.pitchSemitones / 12;
      } else {
        amplitudeOctaves = cfg.pitchAmount != null ? cfg.pitchAmount : 1;
      }
      const octaveOffset = pitchShape(cfg.pitchMode, phase) * amplitudeOctaves;
      const target = v.baseFreq * Math.pow(2, octaveOffset);
      const newFreq = osc.frequencyHz + (target - osc.frequencyHz) * 0.30;
      osc.frequencyHz = newFreq;
      engine.setFrequency(i, newFreq);
    }

    // ─── Pan ───
    if (cfg.panMode === "glacial") {
      glacialPanVoice(i, v, osc);
    } else if (cfg.panMode && cfg.panMode !== "static") {
      const p = (rawProgress + (cfg.panPhase || 0)) % 1;
      const amount = cfg.panAmount != null ? cfg.panAmount : 1;
      const target = Math.max(-1, Math.min(1, panShape(cfg.panMode, p) * amount));
      const newPan = osc.pan + (target - osc.pan) * 0.20;
      osc.pan = newPan;
      engine.setPan(i, newPan);
    }
  }

  renderAll();
}

function pitchShape(mode, p) {
  switch (mode) {
    case "up":     return  p;
    case "down":   return -p;
    case "upDown": return p < 0.5 ?  p * 2          :  1 - (p - 0.5) * 2;
    case "downUp": return p < 0.5 ? -p * 2          : -1 + (p - 0.5) * 2;
    case "wave":   return Math.sin(p * Math.PI * 2);
    default:       return 0;
  }
}
function panShape(mode, p) {
  switch (mode) {
    case "sweepLR":     return -1 + p * 2;
    case "sweepRL":     return  1 - p * 2;
    case "pendulum":    return Math.sin(p * Math.PI * 4);
    case "antiPendulum":return -Math.sin(p * Math.PI * 4);
    default:            return 0;
  }
}

// Per-voice random walk for the "glacial" pitch/pan modes. Re-targets every
// 30–60 s, lerps slowly between targets — wandering, not chaotic.
function glacialPitchVoice(i, v, osc) {
  const now = Date.now();
  if (now >= v.nextRetargetAt) {
    const cents = (Math.random() - 0.5) * 100;
    v.freqTarget = v.baseFreq * Math.pow(2, cents / 1200);
    v.ampTarget  = Math.max(0.1, Math.min(1, v.baseAmp + (Math.random() - 0.5) * 0.3));
    v.nextRetargetAt = now + 30000 + Math.random() * 30000;
  }
  const lerp = 0.05;
  const newFreq = osc.frequencyHz + (v.freqTarget - osc.frequencyHz) * lerp;
  const newAmp  = osc.amplitude   + (v.ampTarget  - osc.amplitude)   * lerp;
  osc.frequencyHz = newFreq;
  osc.amplitude = newAmp;
  engine.setFrequency(i, newFreq);
  engine.setAmplitude(i, newAmp);
}
function glacialPanVoice(i, v, osc) {
  // Re-target on the same cadence as glacialPitch but for pan only.
  // (Sharing nextRetargetAt is fine — both modes can stay in sync.)
  const now = Date.now();
  if (now >= v.nextRetargetAt) {
    v.panTarget = Math.max(-1, Math.min(1, v.basePan + (Math.random() - 0.5) * 0.8));
  }
  const newPan = osc.pan + (v.panTarget - osc.pan) * 0.05;
  osc.pan = newPan;
  engine.setPan(i, newPan);
}

function waveformLabel(id) {
  const wf = WAVEFORMS.find((w) => w.id === id);
  return wf ? wf.name : "Voice";
}

function restoreLfoTargetBase(oscIndex, target) {
  const o = state.oscillators[oscIndex];
  if (target === "pan")         engine.setPan(oscIndex, o.pan);
  else if (target === "amp")    engine.setAmplitude(oscIndex, o.amplitude);
  else if (target === "cutoff") engine.setFilterCutoff(oscIndex, o.filter.cutoffHz);
  else if (target === "pitch")  engine.setFrequency(oscIndex, o.frequencyHz);
  else if (target === "q")      engine.setFilterQ(oscIndex, o.filter.q);
  else if (target === "fm")     engine.setFMIndex(oscIndex, o.fm.index);
}

/// v1.1 multi-target helpers. v1.0 lfos store `target: "X"` (string);
/// v1.1 stores `targets: ["X", "Y", ...]`. currentTargets() reads
/// whichever form is present; anyOtherLfoUsesTarget() lets the
/// toggle action know whether to restore the slider's base when
/// removing a target (only restore if no other LFO is keeping it
/// modulated on this voice).
function currentTargets(lfo) {
  if (Array.isArray(lfo.targets)) return lfo.targets;
  if (lfo.target) return [lfo.target];
  return [];
}
function anyOtherLfoUsesTarget(oscIndex, exceptLfoIndex, target) {
  const lfos = state.oscillators[oscIndex].lfos;
  for (let i = 0; i < lfos.length; i++) {
    if (i === exceptLfoIndex) continue;
    if (currentTargets(lfos[i]).includes(target)) return true;
  }
  return false;
}

// ──────────────────────────────────────────────────
// Helpers.
// ──────────────────────────────────────────────────
function applyChord() {
  const chord = CHORDS.find((c) => c.id === state.chordId);
  const rootHz = pitchToFrequency(state.keyId, state.octave);
  const freqs = chordFrequencies(chord, rootHz, state.tuningId);
  for (let i = 0; i < 4; i++) {
    const hz = Math.max(FREQ_MIN, Math.min(FREQ_MAX, freqs[i]));
    state.oscillators[i].frequencyHz = hz;
    engine.setFrequency(i, hz);
  }
  state.activePresetName = null;
  recomputeQuantizeScale();
  renderAll();
}

/// Cache of chord-note frequencies spanning 2 octaves up from the
/// current chord root. Pushed into the engine so any voice with
/// `drift.quantizeToScale` true snaps to the nearest note. Recomputed
/// whenever chord / tuning / key / octave changes.
function recomputeQuantizeScale() {
  const chord = CHORDS.find((c) => c.id === state.chordId);
  if (!chord) return;
  const rootHz = pitchToFrequency(state.keyId, state.octave);
  // v1 (Jun 2026): if the chord carries a `scale` (the full 7-note
  // mode for Modal entries), use that for snapping instead of the
  // 4-note chord intervals. The 4-note version produces very sparse
  // pitch variety with S&H+pitch+quantize at high depth (Lydian's
  // 5-semi gap from 5 to next root made ~58% of S&H values snap to
  // the root). The full mode fills those gaps so a high-depth LFO
  // steps through ~7 unique notes per octave. Non-modal chords
  // (Common / Extended / Cymatic / Solfeggio / etc.) have no
  // `scale` field and fall through to the chord-tone snap, which
  // is the right behaviour for harmonic patches (a Maj7 chord
  // should snap to its 4 chord tones, not a scale).
  let freqs;
  if (Array.isArray(chord.scale)) {
    freqs = chord.scale.map((c) => rootHz * Math.pow(2, c / 1200));
  } else {
    freqs = chordFrequencies(chord, rootHz, state.tuningId);
  }
  const set = new Set();
  for (const n of freqs) {
    if (n > 0) {
      set.add(n / 2);   // -1 octave (so LFO swing down still snaps)
      set.add(n);       // root
      set.add(n * 2);   // +1 octave
      set.add(n * 4);   // +2 octaves
    }
  }
  engine.scaleNotesHz = Array.from(set).sort((a, b) => a - b);
}

function startTicker() {
  lastTickTime = performance.now();
  if (tickTimer) clearInterval(tickTimer);
  tickTimer = setInterval(() => {
    const now = performance.now();
    const dt = (now - lastTickTime) / 1000;
    lastTickTime = now;
    state.elapsed += dt;
    // Push transport elapsed to the engine so per-voice timing envelopes
    // (startDelaySec + playDurationSec) can shape volume over the session.
    if (engine.ctx) engine.transportElapsed = state.elapsed;
    if (state.sessionDuration > 0 && state.elapsed >= state.sessionDuration) {
      actions.stop();
      return;
    }
    renderAll();
  }, 250);
}

function stopTicker() {
  if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
}

function clamp01(v) { return Math.max(0, Math.min(1, v)); }

// ══════════════════════════════════════════════════
// Automation Timeline playback — iOS parity.
// ══════════════════════════════════════════════════
// Mirrors the native DroneViewModel.dispatchAutomation +
// AutomationDispatcher. A patch's `_automation` timeline (chord changes,
// fades, waveform/sample, level, mute, LFO rate/depth) animates on the
// web exactly as it does on iOS, so a preset shared from the app plays
// its automation here too.
//
// Design notes:
//  • Runs on its OWN ~30 Hz clock (not the coarse 250 ms UI ticker) so
//    beat-precise events land. Elapsed is accumulated from
//    performance.now() deltas and only advances while playing, so pause
//    freezes it cleanly.
//  • Positions are tempo-relative: each event's gridSixteenth (1/16-bar
//    steps) is resolved to seconds at the LIVE BPM at Play, so changing
//    tempo keeps the structure in proportion (same fix as iOS).
//  • Chord changes TRANSPOSE each voice relative to the captured baseline
//    (preserving non-triadic voicings) rather than respelling a triad.
//  • A baseline of the patch state is captured on first Play and restored
//    on every replay so loops/replays start clean.

const SEC_PER_BAR_4_4 = (bpm) => 4 * 60 / Math.max(1, bpm);
function secPerSixteenthNow() { return SEC_PER_BAR_4_4(state.bpm) / 16; }

/// Both encodings of VoiceFilter are tolerated: "all" / {all:{}} and
/// {oscillator:{_0:i}}.
function parseVoiceFilter(v) {
  if (v === "all") return { all: true };
  if (v && typeof v === "object") {
    if ("all" in v) return { all: true };
    if (v.oscillator && typeof v.oscillator === "object") {
      const idx = v.oscillator._0;
      return { osc: typeof idx === "number" ? idx : 0 };
    }
  }
  return { all: true };
}

/// Swift's synthesized enum Codable encodes a no-payload case either as a
/// bare string ("muteToggle") or as {muteToggle:{}}; payload cases as
/// {caseName:{...}}. Handle all forms.
function parseAutomationAction(a) {
  if (a == null) return null;
  if (typeof a === "string") return { type: a };
  const key = Object.keys(a)[0];
  const p = a[key] || {};
  switch (key) {
    case "chordChange": return { type: "chordChange", keyRaw: p.keyRaw, chordId: p.chordId };
    case "fadeIn":      return { type: "fadeIn",  durationSec: p.durationSec };
    case "fadeOut":     return { type: "fadeOut", durationSec: p.durationSec };
    case "waveformSet": return { type: "waveformSet", waveformRaw: p.waveformRaw };
    case "levelSet":    return { type: "levelSet", level: p.level };
    case "muteToggle":  return { type: "muteToggle" };
    case "lfoRate":     return { type: "lfoRate",  lfoIndex: p.lfoIndex, rateHz: p.rateHz };
    case "lfoDepth":    return { type: "lfoDepth", lfoIndex: p.lfoIndex, depth: p.depth };
    default: return null;
  }
}

function voiceIndicesFor(filter) {
  if (filter.all) return [0, 1, 2, 3];
  if (filter.osc != null && filter.osc >= 0 && filter.osc < state.oscillators.length) {
    return [filter.osc];
  }
  return [];
}

function captureAutomationBaseline() {
  return {
    keyId: state.keyId,
    octave: state.octave,
    chordId: state.chordId,
    voices: state.oscillators.map((o) => ({
      frequencyHz: o.frequencyHz,
      waveform: o.waveform,
      amplitude: o.amplitude,
      isMuted: o.isMuted,
      lfoRates: (o.lfos || []).map((l) => l.rateHz),
      lfoDepths: (o.lfos || []).map((l) => l.depth),
    })),
  };
}

/// Direct-assign restore (no applyChord — that would overwrite the per-
/// voice voicing with the chord template). Mirrors applyAutomationBaseline.
function restoreAutomationBaseline(b) {
  if (!b) return;
  state.keyId = b.keyId;
  state.octave = b.octave;
  state.chordId = b.chordId;
  for (let i = 0; i < state.oscillators.length; i++) {
    const v = b.voices[i];
    if (!v) continue;
    const o = state.oscillators[i];
    o.frequencyHz = v.frequencyHz; engine.setFrequency(i, v.frequencyHz);
    o.amplitude = v.amplitude;     engine.setAmplitude(i, v.amplitude);
    if (o.waveform !== v.waveform) { o.waveform = v.waveform; engine.setWaveform(i, v.waveform); }
    if (o.isMuted !== v.isMuted)   { o.isMuted = v.isMuted;   engine.setMute(i, v.isMuted); }
    const lfos = o.lfos || [];
    for (let k = 0; k < lfos.length; k++) {
      if (v.lfoRates[k]  != null) lfos[k].rateHz = v.lfoRates[k];
      if (v.lfoDepths[k] != null) { lfos[k].depth = v.lfoDepths[k]; engine.setLfoDepth(i, k, v.lfoDepths[k]); }
    }
    for (let k = 0; k < lfos.length; k++) pushEffectiveLfoRate(i, k);
  }
  if (typeof recomputeQuantizeScale === "function") recomputeQuantizeScale();
}

let _autoSampleManifest = null;
async function loadAutomationSample(oscIndex, name) {
  try {
    if (!_autoSampleManifest) {
      const resp = await fetch("./samples/index.json", { cache: "no-cache" });
      const data = resp.ok ? await resp.json() : { samples: [] };
      _autoSampleManifest = Array.isArray(data.samples) ? data.samples : [];
    }
    const entry = _autoSampleManifest.find((s) => s.name === name);
    if (entry) await actions.loadBundledSample(oscIndex, entry);
    else actions.setWaveform(oscIndex, "sample");   // best-effort: flip mode
  } catch (_e) {
    actions.setWaveform(oscIndex, "sample");
  }
}

/// Fire one event. `fades` is the active-fade map; `elapsedNow` is the
/// player's clock at fire time (fade start anchor).
function dispatchAutomationEvent(ev, fades, elapsedNow) {
  const a = ev.action;
  const affected = voiceIndicesFor(ev.voice);
  switch (a.type) {
    case "chordChange": {
      const isPatchWide = !!ev.voice.all;
      const baseKey = automationPlayer.baseline ? automationPlayer.baseline.keyId : state.keyId;
      if (a.keyRaw != null) {
        const up = (((a.keyRaw - baseKey) % 12) + 12) % 12;   // 0…11
        const down = up === 0 ? 0 : up - 12;                  // −11…0
        let steps;
        if (ev.direction === "up") steps = up;
        else if (ev.direction === "down") steps = down;
        else steps = Math.abs(up) <= Math.abs(down) ? up : down;
        const ratio = Math.pow(2, steps / 12);
        affected.forEach((i) => {
          const anchor = (automationPlayer.baseline && automationPlayer.baseline.voices[i])
            ? automationPlayer.baseline.voices[i].frequencyHz
            : state.oscillators[i].frequencyHz;
          actions.setFrequency(i, anchor * ratio);
        });
        if (isPatchWide) state.keyId = a.keyRaw;
      }
      if (isPatchWide) {
        // iOS ChordType.id is the chord NAME; web CHORDS use slugs. Match
        // either. Chord is cosmetic (pitch came from the transpose above).
        const chord = CHORDS.find((c) => c.id === a.chordId || c.name === a.chordId);
        if (chord) state.chordId = chord.id;
        if (typeof recomputeQuantizeScale === "function") recomputeQuantizeScale();
      }
      break;
    }
    case "fadeIn":
    case "fadeOut": {
      const dur = Math.max(0, Math.min(15, a.durationSec || 0));
      affected.forEach((i) => {
        const startAmp = state.oscillators[i].amplitude;
        if (a.type === "fadeIn") {
          const target = Math.max(startAmp, 0.0001);
          state.oscillators[i].amplitude = 0; engine.setAmplitude(i, 0);   // snap to 0 first
          if (dur <= 0) { state.oscillators[i].amplitude = target; engine.setAmplitude(i, target); delete fades[i]; }
          else fades[i] = { from: 0, to: target, start: elapsedNow, dur };
        } else {
          if (dur <= 0) { state.oscillators[i].amplitude = 0; engine.setAmplitude(i, 0); delete fades[i]; }
          else fades[i] = { from: startAmp, to: 0, start: elapsedNow, dur };
        }
      });
      break;
    }
    case "waveformSet": {
      const wf = a.waveformRaw;
      affected.forEach((i) => {
        if (wf === "sample" && ev.sampleName) loadAutomationSample(i, ev.sampleName);
        else actions.setWaveform(i, wf);
      });
      break;
    }
    case "levelSet": {
      const lvl = clamp01(a.level);
      affected.forEach((i) => { delete fades[i]; actions.setAmplitude(i, lvl); });
      break;
    }
    case "muteToggle":
      affected.forEach((i) => actions.toggleMute(i));
      break;
    case "lfoRate":
      affected.forEach((i) => actions.setLfoRate(i, a.lfoIndex, a.rateHz));
      break;
    case "lfoDepth":
      affected.forEach((i) => actions.setLfoDepth(i, a.lfoIndex, a.depth));
      break;
  }
}

/// Advance any in-flight amplitude fades. Returns true while any is active.
function tickAutomationFades(fades, elapsedNow) {
  const keys = Object.keys(fades);
  if (keys.length === 0) return false;
  let active = false;
  keys.forEach((k) => {
    const i = +k;
    const f = fades[k];
    const t = f.dur > 0 ? (elapsedNow - f.start) / f.dur : 1;
    if (t >= 1) {
      state.oscillators[i].amplitude = f.to; engine.setAmplitude(i, f.to);
      delete fades[k];
    } else {
      const amp = f.from + (f.to - f.from) * Math.max(0, t);
      state.oscillators[i].amplitude = amp; engine.setAmplitude(i, amp);
      active = true;
    }
  });
  return active;
}

/// Lazily create a default (empty) timeline on state._automation. Used by
/// the web editor's first edit. Shape matches the iOS Codable timeline so
/// it round-trips through .dronepreset.
function ensureAutomation() {
  if (!state._automation || typeof state._automation !== "object") {
    state._automation = {
      schemaVersion: 1, totalDurationSec: 0,
      loop: false, totalBars: null, loopCount: 0, events: [],
    };
  }
  if (!Array.isArray(state._automation.events)) state._automation.events = [];
  return state._automation;
}

/// Auto-sync: when a user-library preset is loaded, write automation edits
/// straight back into that stored preset (and localStorage) so Share/export
/// always ships the current timeline — no manual "Save current…" needed.
/// No-op for built-ins / fresh patches (no active user preset).
function persistAutomationToActivePreset() {
  const id = state.activeUserPresetId;
  if (!id) return;
  const list = state.userPresets || [];
  const i = list.findIndex((p) => p.id === id);
  if (i < 0) return;
  const tl = state._automation;
  if (tl && Array.isArray(tl.events) && tl.events.length > 0) {
    list[i] = { ...list[i], automation: JSON.parse(JSON.stringify(tl)) };
  } else {
    const { automation, ...rest } = list[i];   // emptied timeline → drop the field
    list[i] = rest;
  }
  state.userPresets = list;
  saveUserPresets(list);
}

const automationPlayer = {
  timer: null,
  events: [],
  nextIndex: 0,
  elapsed: 0,
  lastNow: 0,
  cycleSec: 0,
  loop: false,
  loopCount: 0,
  currentCycle: 0,
  loopOffset: 0,
  baseline: null,
  fades: {},

  /// Drop the captured baseline — call on preset load / timeline change so
  /// the next Play snapshots fresh patch state.
  invalidate() { this.baseline = null; },

  _resolveEvents() {
    const tl = state._automation;
    if (!tl || !Array.isArray(tl.events)) return [];
    const sps = secPerSixteenthNow();
    return tl.events
      .map((ev) => {
        const grid = ev.gridSixteenth != null ? Math.max(0, ev.gridSixteenth) : null;
        const timeSec = grid != null ? grid * sps : Math.max(0, ev.timeSec || 0);
        return {
          timeSec,
          voice: parseVoiceFilter(ev.voice),
          action: parseAutomationAction(ev.action),
          sampleName: ev.sampleName || null,
          direction: ev.transposeDirection || "nearest",
        };
      })
      .filter((e) => e.action)
      .sort((x, y) => x.timeSec - y.timeSec);
  },

  /// Called from togglePlay. fromStopped=true → fresh start (restore/capture
  /// baseline, reset cursor); false → resume from pause (keep position).
  onPlay(fromStopped) {
    const tl = state._automation;
    const hasEvents = tl && Array.isArray(tl.events) && tl.events.length > 0;
    if (!hasEvents) { this._stopTimer(); return; }
    if (!fromStopped) {                       // resume from pause
      this.lastNow = performance.now();
      this._startTimer();
      return;
    }
    if (this.baseline) restoreAutomationBaseline(this.baseline);
    else this.baseline = captureAutomationBaseline();
    this.events = this._resolveEvents();
    this.nextIndex = 0;
    this.elapsed = 0;
    this.loopOffset = 0;
    this.currentCycle = 0;
    this.fades = {};
    this.cycleSec = (tl.totalBars != null ? tl.totalBars : 0) * SEC_PER_BAR_4_4(state.bpm);
    this.loop = this.cycleSec > 0;
    this.loopCount = tl.loopCount || 0;
    this.lastNow = performance.now();
    this._startTimer();
    renderAll();
  },

  pause() { this._stopTimer(); },

  reset() {
    this._stopTimer();
    this.events = [];
    this.nextIndex = 0;
    this.elapsed = 0;
    this.loopOffset = 0;
    this.currentCycle = 0;
    this.fades = {};
    // Baseline is preserved across Stop (restored on next Play), like iOS.
  },

  _startTimer() {
    this._stopTimer();
    this.timer = setInterval(() => this._tick(), 30);   // ~33 Hz
  },
  _stopTimer() {
    if (this.timer) { clearInterval(this.timer); this.timer = null; }
  },

  _tick() {
    const now = performance.now();
    this.elapsed += (now - this.lastNow) / 1000;
    this.lastNow = now;
    // Loop wrap — same accounting as the native dispatcher (subtract whole
    // cycles via loopOffset rather than rewinding the clock).
    if (this.loop && this.cycleSec > 0) {
      while (this.elapsed - this.loopOffset >= this.cycleSec) {
        if (this.loopCount > 0 && this.currentCycle + 1 >= this.loopCount) {
          this._stopTimer();
          return;
        }
        this.loopOffset += this.cycleSec;
        this.currentCycle += 1;
        this.nextIndex = 0;
      }
    }
    const phase = this.elapsed - this.loopOffset;
    let didFire = false;
    while (this.nextIndex < this.events.length && this.events[this.nextIndex].timeSec <= phase) {
      dispatchAutomationEvent(this.events[this.nextIndex], this.fades, this.elapsed);
      this.nextIndex += 1;
      didFire = true;
    }
    const stillFading = tickAutomationFades(this.fades, this.elapsed);
    if (this.nextIndex >= this.events.length && !this.loop && !stillFading) {
      this._stopTimer();
    }
    if (didFire || stillFading) renderAll();
  },
};

// ──────────────────────────────────────────────────
// Boot.
// ──────────────────────────────────────────────────
function getState() { return state; }
initUI(getState, actions);
initVisualizations(getState, () => engine);
renderAll();

// Debug handle — read-only inspection from devtools / preview_eval.
// Safe to leave in; no UI/audio behavior depends on it.
window.__drone = { state, engine, actions, DRIFT_SCENES, JOURNEYS };

// ──────────────────────────────────────────────────
// Meditation journey runner. A journey is a list of stages — each stage
// applies a preset + drift scene for its duration, then auto-advances to
// the next. When the final stage ends, the journey completes (and we let
// the existing session auto-stop fade-out take care of the audio).
// ──────────────────────────────────────────────────
let journeyAdvanceTimer = null;

/// Resolve a journey by id, searching built-in JOURNEYS first then user
/// journeys. Exported for UI to render unified Start/Stop labels.
export function findJourney(id) {
  if (!id) return null;
  return JOURNEYS.find((x) => x.id === id) ||
         state.userJourneys.find((x) => x.id === id) || null;
}
// Expose to UI without an import cycle.
window.__drone = window.__drone || {};
window.__drone.findJourney = findJourney;

/// Validate + normalize a user-journey draft. Returns the sanitized spec
/// (with a fresh id, createdAt, and totalSeconds) or null if invalid.
function sanitizeUserJourney(spec) {
  if (!spec || typeof spec.name !== "string") return null;
  const name = spec.name.trim();
  if (!name) return null;
  const description = (spec.description || "").trim();
  const stages = Array.isArray(spec.stages) ? spec.stages : [];
  if (stages.length === 0) return null;
  const cleanStages = [];
  for (const s of stages) {
    const dur = Number(s.durationSec);
    if (!Number.isFinite(dur) || dur < 30 || dur > 90 * 60) continue;
    const preset = PRESETS.find((p) => p.id === s.presetId);
    if (!preset) continue;
    const drift = s.driftSceneId || "off";
    cleanStages.push({
      durationSec: Math.round(dur),
      presetId: preset.id,
      driftSceneId: String(drift),
      hint: (s.hint || `${preset.name} · ${drift}`).slice(0, 80)
    });
  }
  if (cleanStages.length === 0) return null;
  return {
    id: newUserJourneyId(),
    name: name.slice(0, 60),
    description: description.slice(0, 200) || "Custom journey",
    createdAt: Date.now(),
    isUser: true,
    stages: cleanStages
  };
}

// ──────────────────────────────────────────────────
// Morph — interpolate every per-voice parameter between two presets at
// a continuous 0..1 amount. Called by setMorphAmount whenever the slider
// moves; also re-triggered whenever From/To is repicked.
// ──────────────────────────────────────────────────

/// Resolve a morph source by id. Checks built-in PRESETS first, then
/// adapts user-saved presets into the V({...}) shape the morph applier
/// expects. Returns null if no match.
function morphSourceFor(id) {
  if (!id) return null;
  const builtIn = PRESETS.find((p) => p.id === id);
  if (builtIn) return builtIn;
  const user = state.userPresets?.find((p) => p.id === id);
  if (!user) return null;
  // Adapter: user presets store full state per voice; the morph applier
  // reads va.hz / va.wave / va.amp / va.filter / etc. as optional overrides.
  return {
    id: user.id, name: user.name,
    voices: (user.oscillators || []).map((o) => ({
      hz: o.frequencyHz, pan: o.pan,
      wave: o.waveform, amp: o.amplitude,
      drive: o.drive,
      startDelaySec: o.startDelaySec,
      playDurationSec: o.playDurationSec,
      filter: o.filter, reverb: o.reverb,
      delay: o.delay, chorus: o.chorus,
      fm: o.fm, grain: o.grain,
      lfos: o.lfos,
      _silent: o.isMuted === true
    }))
  };
}

/// Stop the wall-clock interval that drives auto-morph. Used on pause,
/// reset, and clear.
function stopMorphTimer() {
  if (morphIntervalId) {
    clearInterval(morphIntervalId);
    morphIntervalId = null;
  }
  morphLastTickMs = 0;
}

/// Advance morphAmount by (elapsed/duration) on each tick. Reverses
/// direction at endpoints when ping-pong is on; otherwise stops at the
/// end of travel.
function tickMorph() {
  if (!state.morphIsRunning) return;
  const now = performance.now();
  const dtSec = (now - morphLastTickMs) / 1000;
  morphLastTickMs = now;
  const step = dtSec / Math.max(1, state.morphDurationSec);
  let next = state.morphAmount + state.morphDirection * step;
  if (next >= 1) {
    if (state.morphIsPingPong) {
      next = 1;
      state.morphDirection = -1;
    } else {
      next = 1;
      state.morphIsRunning = false;
      stopMorphTimer();
    }
  } else if (next <= 0) {
    if (state.morphIsPingPong) {
      next = 0;
      state.morphDirection = 1;
    } else {
      next = 0;
      state.morphIsRunning = false;
      stopMorphTimer();
    }
  }
  state.morphAmount = next;
  applyMorph(next);
  renderAll();
}

function applyMorph(t) {
  const A = morphSourceFor(state.morphFromId);
  const B = morphSourceFor(state.morphToId);
  if (!A || !B) return;
  const tClamped = Math.max(0, Math.min(1, t));

  // Linear, log, and discrete interpolation helpers. Discrete picks A
  // until t=0.5 then B. To hide the abrupt swap, we also compute a notch
  // amp multiplier that dips voices through silence around t=0.5 ONLY
  // for voices that have a discrete change (waveform / filter type /
  // FM source) between A and B.
  const lerp = (a, b, u) => a + (b - a) * u;
  const logLerp = (a, b, u) => {
    if (a <= 0 || b <= 0) return lerp(a, b, u);
    return Math.exp(lerp(Math.log(a), Math.log(b), u));
  };
  const pick = (a, b, u) => (u < 0.5 ? a : b);

  // 8 s window around the discrete swap, expressed in morph-amount units.
  // For very short morph durations we clamp so the notch can't consume
  // more than the middle ±45 % of the morph.
  const FADE_WINDOW_SEC = 8.0;
  const halfWidth = Math.min(0.45,
    FADE_WINDOW_SEC / Math.max(8.0, state.morphDurationSec || 300) / 2.0);
  const dist = Math.abs(tClamped - 0.5);
  const notchMul = (dist >= halfWidth || halfWidth <= 0)
    ? 1.0
    : 0.5 - 0.5 * Math.cos(Math.PI * dist / halfWidth);

  for (let i = 0; i < 4; i++) {
    const va = A.voices[i] || {};
    const vb = B.voices[i] || {};
    // Fall back to current oscillator state for fields the preset didn't
    // specify, so simple presets (hz + pan only) still morph cleanly into
    // rich ones (everything specified) without snapping to defaults.
    const o = state.oscillators[i];
    const A_hz   = va.hz   ?? o.frequencyHz;
    const B_hz   = vb.hz   ?? o.frequencyHz;
    const A_pan  = va.pan  ?? o.pan;
    const B_pan  = vb.pan  ?? o.pan;
    const A_wave = va.wave ?? o.waveform;
    const B_wave = vb.wave ?? o.waveform;
    const A_amp  = (va.amp  != null) ? va.amp  : o.amplitude;
    const B_amp  = (vb.amp  != null) ? vb.amp  : o.amplitude;
    const A_drv  = (va.drive != null) ? va.drive : (o.drive || 1.0);
    const B_drv  = (vb.drive != null) ? vb.drive : (o.drive || 1.0);

    // Apply the discrete-change notch only when this voice actually has
    // a discrete change between A and B. Voices that only differ in
    // continuous params stay at the smoothly-lerped amplitude.
    const va_fm = (va.fm || {});
    const vb_fm = (vb.fm || {});
    const a_ftype = ((va.filter || {}).type) || o.filter.type;
    const b_ftype = ((vb.filter || {}).type) || o.filter.type;
    const a_fmSrc = (va_fm.sourceIndex != null) ? va_fm.sourceIndex : (o.fm?.sourceIndex ?? -1);
    const b_fmSrc = (vb_fm.sourceIndex != null) ? vb_fm.sourceIndex : (o.fm?.sourceIndex ?? -1);
    const hasDiscreteChange = (A_wave !== B_wave) || (a_ftype !== b_ftype) || (a_fmSrc !== b_fmSrc);
    const voiceAmpMul = hasDiscreteChange ? notchMul : 1.0;

    actions.setFrequency(i, logLerp(A_hz, B_hz, tClamped));
    actions.setPan(i, lerp(A_pan, B_pan, tClamped));
    actions.setAmplitude(i, lerp(A_amp, B_amp, tClamped) * voiceAmpMul);
    actions.setDrive(i, lerp(A_drv, B_drv, tClamped));
    // Mute follows the chosen side discretely so silent-slot presets
    // don't suddenly half-bleed in at the midpoint.
    const aMuted = !!va._silent;
    const bMuted = !!vb._silent;
    const wantMuted = pick(aMuted, bMuted, tClamped);
    if (o.isMuted !== wantMuted) actions.toggleMute(i);

    // Waveform is discrete. Skip when From and To agree, otherwise swap
    // at t=0.5.
    const wantWave = pick(A_wave, B_wave, tClamped);
    if (o.waveform !== wantWave) actions.setWaveform(i, wantWave);

    // Filter — log on cutoff/q, discrete on type.
    const A_f = { ...(o.filter || {}), ...(va.filter || {}) };
    const B_f = { ...(o.filter || {}), ...(vb.filter || {}) };
    const wantType = pick(A_f.type, B_f.type, tClamped);
    if (o.filter.type !== wantType) actions.setFilterType(i, wantType);
    actions.setFilterCutoff(i, logLerp(A_f.cutoffHz || 4000, B_f.cutoffHz || 4000, tClamped));
    actions.setFilterQ(i, logLerp(A_f.q || 0.7, B_f.q || 0.7, tClamped));

    // Reverb — log on decay, linear on mix.
    const A_r = { ...(o.reverb || {}), ...(va.reverb || {}) };
    const B_r = { ...(o.reverb || {}), ...(vb.reverb || {}) };
    actions.setReverbDecay(i, logLerp(A_r.decaySec || 2, B_r.decaySec || 2, tClamped));
    actions.setReverbMix(i, lerp(A_r.mix || 0, B_r.mix || 0, tClamped));

    // Delay — log on time, linear on mix/feedback, discrete on mode.
    const A_d = { ...(o.delay || {}), ...(va.delay || {}) };
    const B_d = { ...(o.delay || {}), ...(vb.delay || {}) };
    actions.setDelayTime(i, logLerp(A_d.timeSec || 0.3, B_d.timeSec || 0.3, tClamped));
    actions.setDelayFeedback(i, lerp(A_d.feedback || 0, B_d.feedback || 0, tClamped));
    actions.setDelayMix(i, lerp(A_d.mix || 0, B_d.mix || 0, tClamped));
    const wantDlyMode = pick(A_d.mode || "mono", B_d.mode || "mono", tClamped);
    if (o.delay.mode !== wantDlyMode) actions.setDelayMode(i, wantDlyMode);

    // Chorus — log on rate, linear on depth/width/mix.
    const A_c = { ...(o.chorus || {}), ...(va.chorus || {}) };
    const B_c = { ...(o.chorus || {}), ...(vb.chorus || {}) };
    actions.setChorusRate(i,  logLerp(A_c.rateHz || 0.5, B_c.rateHz || 0.5, tClamped));
    actions.setChorusDepth(i, lerp(A_c.depth   || 0, B_c.depth   || 0, tClamped));
    actions.setChorusWidth(i, lerp(A_c.width   || 0, B_c.width   || 0, tClamped));
    actions.setChorusMix(i,   lerp(A_c.mix     || 0, B_c.mix     || 0, tClamped));

    // FM — discrete on source, log on index (linear below 1 Hz).
    const A_fm = { ...(o.fm || {}), ...(va.fm || {}) };
    const B_fm = { ...(o.fm || {}), ...(vb.fm || {}) };
    const wantFMSrc = pick(A_fm.sourceIndex ?? -1, B_fm.sourceIndex ?? -1, tClamped);
    if (o.fm.sourceIndex !== wantFMSrc) actions.setFMSource(i, wantFMSrc);
    const Ai = A_fm.index || 0, Bi = B_fm.index || 0;
    const idx = (Ai > 1 && Bi > 1) ? logLerp(Ai, Bi, tClamped) : lerp(Ai, Bi, tClamped);
    actions.setFMIndex(i, idx);

    // Granular — log on size + density, linear on jitter + panSpread. Only
    // audibly affects the voice when waveform is .granular.
    const A_g = { ...defaultGrain(), ...(o.grain || {}), ...(va.grain || {}) };
    const B_g = { ...defaultGrain(), ...(o.grain || {}), ...(vb.grain || {}) };
    actions.setGrainSize(i,      logLerp(A_g.sizeMs,    B_g.sizeMs,    tClamped));
    actions.setGrainDensity(i,   logLerp(A_g.densityHz, B_g.densityHz, tClamped));
    actions.setGrainJitter(i,    lerp(A_g.jitter,       B_g.jitter,    tClamped));
    actions.setGrainPanSpread(i, lerp(A_g.panSpread,    B_g.panSpread, tClamped));

    // LFOs — interpolate rate (log) + depth (linear) where defined;
    // discrete shape + target at midpoint.
    const A_lfos = Array.isArray(va.lfos) ? va.lfos : [];
    const B_lfos = Array.isArray(vb.lfos) ? vb.lfos : [];
    for (let k = 0; k < 4; k++) {
      const al = A_lfos[k] || o.lfos[k];
      const bl = B_lfos[k] || o.lfos[k];
      if (!al || !bl) continue;
      actions.setLfoRate(i, k, logLerp(al.rateHz, bl.rateHz, tClamped));
      actions.setLfoDepth(i, k, lerp(al.depth, bl.depth, tClamped));
      const wantShape = pick(al.shape, bl.shape, tClamped);
      if (o.lfos[k].shape !== wantShape) actions.setLfoShape(i, k, wantShape);
      const wantTarget = pick(al.target, bl.target, tClamped);
      if (o.lfos[k].target !== wantTarget) actions.setLfoTarget(i, k, wantTarget);
    }
  }
  // Morphing is its own state, not a "named preset" — clear the active
  // preset label so the user knows they're in a hybrid space.
  state.activePresetName = `${A.name} → ${B.name} (${Math.round(tClamped * 100)}%)`;
}

function startJourney(id) {
  const j = findJourney(id);
  if (!j) return;
  // Cancel any previous journey *without* fully stopping the transport.
  // The full stop() schedules an 8-second master fadeOut + engine.stop()
  // task; if we then immediately togglePlay() (which fades back IN over
  // 3s), the orphan fadeOut Task wakes up ~8 s later and calls
  // engine.stop(), cutting audio after about 6 seconds of play. So:
  // just kill the scheduler and reset journey state — don't touch the
  // transport here.
  if (journeyAdvanceTimer) clearTimeout(journeyAdvanceTimer);
  journeyAdvanceTimer = null;
  state.activeJourneyId = id;
  state.journeyStageIndex = -1;
  state.journeyStageEndsAt = 0;
  // Total journey duration becomes the session length so the existing
  // auto-stop logic + 8s fade-out at the end happen automatically.
  actions.setDuration(journeyTotalSeconds(j));
  // Make sure transport is playing.
  if (state.transportState !== "playing") actions.togglePlay();
  advanceJourneyStage();
}

function stopJourney() {
  if (journeyAdvanceTimer) clearTimeout(journeyAdvanceTimer);
  journeyAdvanceTimer = null;
  state.activeJourneyId = null;
  state.journeyStageIndex = 0;
  state.journeyStageEndsAt = 0;
  // The journey *is* the user's listening context, so stopping it should
  // fade audio out — otherwise tapping Stop gives no audible feedback and
  // the user assumes the button is broken. We clear our state FIRST so the
  // transport's own stop()→stopJourney() guard sees no active journey and
  // doesn't recurse.
  if (state.transportState !== "stopped") {
    actions.stop();
  } else {
    renderAll();
  }
}

function advanceJourneyStage() {
  const j = findJourney(state.activeJourneyId);
  if (!j) return;
  state.journeyStageIndex += 1;
  if (state.journeyStageIndex >= j.stages.length) {
    // Journey complete — leave transport running; sessionDuration auto-stops.
    state.activeJourneyId = null;
    renderAll();
    return;
  }
  const stage = j.stages[state.journeyStageIndex];
  // Apply this stage.
  actions.applyPreset(stage.presetId);
  actions.setDriftScene(stage.driftSceneId || "off");
  state.journeyStageEndsAt = Date.now() + stage.durationSec * 1000;
  // Schedule next advance.
  journeyAdvanceTimer = setTimeout(advanceJourneyStage, stage.durationSec * 1000);
  renderAll();
}

// ──────────────────────────────────────────────────
// Pop-out Chladni window sync
// Broadcast the minimal visualization-relevant slice of state at ~15 fps so
// the popup window (if open) tracks live changes without coupling to our
// internal mutation paths. Also reply to "request-state" messages so the
// popup can resync immediately on open.
// ──────────────────────────────────────────────────
const chladniChannel = typeof BroadcastChannel !== "undefined"
  ? new BroadcastChannel("drone-meditations-chladni")
  : null;

function broadcastChladniState() {
  if (!chladniChannel) return;
  chladniChannel.postMessage({
    type: "state",
    oscillators: state.oscillators.map((o, i) => {
      // Use the engine's live (pitch-LFO-modulated) freq when available so
      // the pop-out window shows real-time vibrato just like the main canvas.
      const liveFreq = (engine.voices && engine.voices[i] && engine.voices[i]._effectiveFreq)
        ? engine.voices[i]._effectiveFreq
        : o.frequencyHz;
      return {
        frequencyHz: liveFreq,
        amplitude: o.amplitude,
        isMuted: o.isMuted,
        isSoloed: o.isSoloed
      };
    })
  });
}

if (chladniChannel) {
  chladniChannel.addEventListener("message", (e) => {
    const msg = e.data;
    if (!msg) return;
    if (msg.type === "request-state") {
      broadcastChladniState();
    } else if (msg.type === "command") {
      // Commands posted by the pop-out window's mini-controls strip.
      // Dispatch through the same actions the in-app UI uses so audio + state
      // stay in sync.
      switch (msg.cmd) {
        case "setFrequency": actions.setFrequency(msg.oscIndex, msg.value); break;
        case "toggleSolo":   actions.toggleSolo(msg.oscIndex);              break;
        case "toggleMute":   actions.toggleMute(msg.oscIndex);              break;
      }
    }
  });
  // Tick at ~15 fps. Lightweight (object copy + serialize, no DOM work).
  setInterval(broadcastChladniState, 66);
}

// Expose the "open popup" action for the UI to wire up.
window.__drone.popOutChladni = () => {
  const features = "popup=1,width=900,height=900,scrollbars=no,location=no,menubar=no,toolbar=no,status=no";
  const w = window.open("chladni-popup.html", "drone-chladni-popup", features);
  if (w) w.focus();
  // Send state immediately so the new window has data on first paint.
  setTimeout(broadcastChladniState, 200);
  setTimeout(broadcastChladniState, 600);
};
