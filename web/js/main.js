// Bootstrap — owns app state, glues UI + audio + visualizations together.

import {
  CHORDS, PRESETS, WAVEFORMS, JOURNEYS, journeyTotalSeconds, PITCH_CLASSES, TUNING_SYSTEMS,
  pitchToFrequency, chordFrequencies, FREQ_MIN, FREQ_MAX
} from "./music.js";
import { AudioEngine } from "./audio.js";
import { initUI, renderAll } from "./ui.js";
import { initVisualizations, setChladniVisible, setSpectrumVisible } from "./visualizations.js";
import {
  loadUserPresets, saveUserPresets, newPresetId, newSampleId,
  loadVoicePresets, saveVoicePresets, newVoicePresetId,
  loadUserJourneys, saveUserJourneys, newUserJourneyId,
  loadLibrarySamples, saveLibrarySamples,
  putSample, getSample, deleteSample
} from "./storage.js";

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
// Granular synth defaults. Only audible when waveform === "granular".
const defaultGrain  = () => ({
  sizeMs: 80,        // 5..500 ms (log slider)
  densityHz: 8,      // 0.5..50 grains/sec (log slider)
  jitter: 0.6,       // 0..1 — randomizes inter-grain timing
  panSpread: 0.5     // 0..1 — random per-grain stereo placement
});

const defaultDelay  = () => ({
  timeSec: 0.30,
  feedback: 0.40,
  mix: 0,
  mode: "mono",       // "mono" | "stereo" | "pingPong"
  timing: "free"      // "free" | "1/2" | "1/3" | "1/3t" | "1/4" | "1/4t" | "1/8" | "1/8t" | "1/16" | "1/16t"
});

// Default tempo for musical-division delay timings. Future: expose to UI.
const DEFAULT_BPM = 120;

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
    { id: 0, frequencyHz: 110.00, waveform: "sine", amplitude: 0.6,  pan: -0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0 },
    { id: 1, frequencyHz: 165.00, waveform: "sine", amplitude: 0.6,  pan:  0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0 },
    { id: 2, frequencyHz: 220.00, waveform: "sine", amplitude: 0.55, pan: -0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0 },
    { id: 3, frequencyHz: 277.18, waveform: "sine", amplitude: 0.5,  pan:  0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), drive: 1.0, fm: defaultFM(), chorus: defaultChorus(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), grain: defaultGrain(), sampleName: null, startDelaySec: 0, playDurationSec: 0, sampleStartFrac: 0, sampleEndFrac: 1, sampleFadeInSec: 0, sampleFadeOutSec: 0 }
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
const sampleCache = [null, null, null, null];  // each: { id, name, blob, type } | null

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
      state.oscillators[i].startDelaySec = startDelay;
      state.oscillators[i].playDurationSec = playDur;
      engine.setStartDelay(i, startDelay);
      engine.setPlayDuration(i, playDur);
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
        engine.setGrainDensity(i, gr.densityHz);
        engine.setGrainJitter(i, gr.jitter);
        engine.setGrainPanSpread(i, gr.panSpread);
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
          engine.setLfoRate(i, k, merged.rateHz);
          engine.setLfoDepth(i, k, merged.depth);
        }
      }
      if (v.drift) {
        const dr = { ...defaultDrift(), ...v.drift };
        state.oscillators[i].drift = dr;
        // Push through the public setters so the drift timer reconciles itself.
        setVoicePitchDrift(i, dr.pitchMode);
        setVoicePanDrift(i, dr.panMode);
      }
    }
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
    engine.setMasterVolume(state.masterVolume);
    renderAll();
  },

  togglePlay() {
    if (state.transportState === "playing") {
      // Quick fade-down on pause so the suspend doesn't click.
      engine.fadeOutMaster(0.4);
      setTimeout(() => engine.suspend(), 500);
      state.transportState = "paused";
      stopTicker();
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
      engine.fadeInMaster(fromStopped ? 3.0 : 1.0);
      // Initialize transportElapsed so the per-voice timing envelope can
      // start computing immediately (otherwise the engine tick would see
      // NaN until the first transport tick fires ~250 ms later, and any
      // voice with startDelaySec == 0 would briefly silence then jump up).
      engine.transportElapsed = state.elapsed;
      state.transportState = "playing";
      startTicker();
    }
    renderAll();
  },

  async stop() {
    if (state.transportState === "stopped") return;
    // Update UI state immediately; audio fades over 8s, then tears down.
    state.transportState = "stopped";
    state.elapsed = 0;
    // Mark transport stopped so the per-voice timing envelope reverts
    // to its idle behavior (no fade-in math while the engine isn't
    // playing — that's the master fade-out's job).
    if (engine.ctx) engine.transportElapsed = NaN;
    stopTicker();
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
    await engine.stop();
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
    engine.setLfoRate(oscIndex, lfoIndex, state.oscillators[oscIndex].lfos[lfoIndex].rateHz);
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
    const lfo = state.oscillators[oscIndex].lfos[lfoIndex];
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
    engine.setGrainDensity(oscIndex, clamped);
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

  // ── Sample play-window (only audible when waveform === "sample") ──
  setSampleStart(oscIndex, frac) {
    const clamped = Math.max(0, Math.min(0.999, frac));
    const o = state.oscillators[oscIndex];
    if (clamped >= (o.sampleEndFrac ?? 1) - 0.01) return;
    o.sampleStartFrac = clamped;
    engine.setSampleWindow(oscIndex, clamped, o.sampleEndFrac ?? 1);
    renderAll();
  },
  setSampleEnd(oscIndex, frac) {
    const clamped = Math.max(0.001, Math.min(1, frac));
    const o = state.oscillators[oscIndex];
    if (clamped <= (o.sampleStartFrac ?? 0) + 0.01) return;
    o.sampleEndFrac = clamped;
    engine.setSampleWindow(oscIndex, o.sampleStartFrac ?? 0, clamped);
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
  setDelayTiming(oscIndex, timingId) {
    state.oscillators[oscIndex].delay.timing = timingId;
    // If a musical division was picked, compute and apply the time. "free"
    // leaves the time slider as the source of truth.
    const sec = delayTimeForTiming(timingId);
    if (sec != null) {
      state.oscillators[oscIndex].delay.timeSec = sec;
      engine.setDelayTime(oscIndex, sec);
    }
    renderAll();
  },

  // Chorus
  setChorusRate(oscIndex, rate) {
    const clamped = Math.max(0.05, Math.min(6.0, rate));
    state.oscillators[oscIndex].chorus.rateHz = clamped;
    engine.setChorusRate(oscIndex, clamped);
  },
  setChorusDepth(oscIndex, depth) {
    const clamped = Math.max(0, Math.min(1, depth));
    state.oscillators[oscIndex].chorus.depth = clamped;
    engine.setChorusDepth(oscIndex, clamped);
  },
  setChorusWidth(oscIndex, width) {
    const clamped = Math.max(0, Math.min(1, width));
    state.oscillators[oscIndex].chorus.width = clamped;
    engine.setChorusWidth(oscIndex, clamped);
  },
  setChorusMix(oscIndex, mix) {
    const clamped = Math.max(0, Math.min(1, mix));
    state.oscillators[oscIndex].chorus.mix = clamped;
    engine.setChorusMix(oscIndex, clamped);
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
        sampleRef
      };
    }));
    const preset = {
      id: newPresetId(), name: trimmed, createdAt: new Date().toISOString(),
      keyId: state.keyId, octave: state.octave, chordId: state.chordId,
      tuningId: state.tuningId, masterVolume: state.masterVolume,
      oscillators
    };
    state.userPresets = [preset, ...state.userPresets];
    saveUserPresets(state.userPresets);
    state.activePresetName = preset.name;
    renderAll();
  },

  async loadUserPreset(id) {
    const preset = state.userPresets.find((p) => p.id === id);
    if (!preset) return;
    engine.ensureStarted(state.oscillators);
    engine.resume();
    state.keyId = preset.keyId ?? state.keyId;
    state.octave = preset.octave ?? state.octave;
    state.chordId = preset.chordId ?? state.chordId;
    state.tuningId = preset.tuningId ?? state.tuningId;
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
        actions.setLfoTarget(i, k, lfos[k].target);
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
    // Apply the scene's voice config into the oscillator's drift state,
    // overwriting any previous per-voice setting.
    const cfg = scene.voices[i] || {};
    o.drift = {
      pitchMode:   cfg.pitchMode   || "static",
      pitchAmount: cfg.pitchAmount != null ? cfg.pitchAmount : 1,
      pitchPhase:  cfg.pitchPhase  || 0,
      panMode:     cfg.panMode     || "static",
      panAmount:   cfg.panAmount   != null ? cfg.panAmount   : 1,
      panPhase:    cfg.panPhase    || 0,
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
  // Reset each voice's drift to static (no motion).
  for (const o of state.oscillators) o.drift = defaultDrift();
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
  const freqs = chordFrequencies(chord, rootHz, state.tuningId);
  const set = new Set();
  for (const n of freqs) {
    if (n > 0) {
      set.add(n);
      set.add(n * 2);   // +1 octave
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
