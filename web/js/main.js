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
const defaultLfos = () => ([
  { shape: "sine", target: "pan",    rateHz: 0.25, depth: 0 },
  { shape: "sh",   target: "amp",    rateHz: 0.50, depth: 0 },
  { shape: "sine", target: "cutoff", rateHz: 0.30, depth: 0 },
  { shape: "sine", target: "pitch",  rateHz: 0.30, depth: 0 }
]);
const defaultFilter = () => ({ type: "lowpass", cutoffHz: 4000, q: 0.7 });
const defaultReverb = () => ({ decaySec: 2.0, mix: 0 });
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
  panPhase: 0
});

const state = {
  oscillators: [
    { id: 0, frequencyHz: 110.00, waveform: "sine", amplitude: 0.6,  pan: -0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), sampleName: null },
    { id: 1, frequencyHz: 165.00, waveform: "sine", amplitude: 0.6,  pan:  0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), sampleName: null },
    { id: 2, frequencyHz: 220.00, waveform: "sine", amplitude: 0.55, pan: -0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), sampleName: null },
    { id: 3, frequencyHz: 277.18, waveform: "sine", amplitude: 0.5,  pan:  0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), drift: defaultDrift(), sampleName: null }
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
  voicePresets: loadVoicePresets()
};

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
    }
    state.activePresetName = p.name;
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
  setLfoTarget(oscIndex, lfoIndex, target) {
    const prevTarget = state.oscillators[oscIndex].lfos[lfoIndex].target;
    state.oscillators[oscIndex].lfos[lfoIndex].target = target;
    engine.setLfoTarget(oscIndex, lfoIndex, target);
    // Restore the previous-target param to its base so it doesn't get stuck on the LFO's last value.
    if (prevTarget !== target) restoreLfoTargetBase(oscIndex, prevTarget);
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
  setFilterQ(oscIndex, q) {
    const clamped = Math.max(0.3, Math.min(20, q));
    state.oscillators[oscIndex].filter.q = clamped;
    engine.setFilterQ(oscIndex, clamped);
    renderAll();
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
      // Cache the raw blob so saveCurrentAsUserPreset can persist it.
      sampleCache[oscIndex] = {
        id: null,
        name: file.name,
        blob: new Blob([arrayBuffer], { type: file.type || "audio/*" }),
        type: file.type || "audio/*"
      };
      renderAll();
    } catch (err) {
      console.error("Sample decode failed:", err);
      alert(`Could not decode "${file.name}". Try a different format (mp3/wav/m4a/ogg).`);
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
        filter: { ...o.filter }, reverb: { ...o.reverb }, delay: { ...o.delay },
        lfos: o.lfos.map((l) => ({ ...l })),
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
      actions.setReverbDecay(i, o.reverb.decaySec);
      actions.setReverbMix(i, o.reverb.mix);
      actions.setDelayTime(i, o.delay.timeSec);
      actions.setDelayFeedback(i, o.delay.feedback);
      actions.setDelayMix(i, o.delay.mix);
      // Pad with default LFO 4 (sine→pitch) for presets saved before LFO 4 existed.
      const lfos = o.lfos.slice();
      while (lfos.length < 4) lfos.push({ shape: "sine", target: "pitch", rateHz: 0.30, depth: 0 });
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
      reverb: { ...o.reverb },
      delay:  { ...o.delay },
      lfos:   o.lfos.map((l) => ({ ...l })),
      drift:  { ...o.drift }
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
    const pitchDriftModes = ["static", "static", "up", "down", "upDown", "downUp", "wave", "glacial"];
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
    } else if (cfg.pitchMode && cfg.pitchMode !== "static") {
      const p = (rawProgress + (cfg.pitchPhase || 0)) % 1;
      const amount = cfg.pitchAmount != null ? cfg.pitchAmount : 1;
      const octaveOffset = pitchShape(cfg.pitchMode, p) * amount;
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
  renderAll();
}

function startTicker() {
  lastTickTime = performance.now();
  if (tickTimer) clearInterval(tickTimer);
  tickTimer = setInterval(() => {
    const now = performance.now();
    const dt = (now - lastTickTime) / 1000;
    lastTickTime = now;
    state.elapsed += dt;
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

function startJourney(id) {
  const j = JOURNEYS.find((x) => x.id === id);
  if (!j) return;
  stopJourney();  // cancel any previous
  state.activeJourneyId = id;
  state.journeyStageIndex = -1;
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
  const j = JOURNEYS.find((x) => x.id === state.activeJourneyId);
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
