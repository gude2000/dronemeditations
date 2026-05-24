// Bootstrap — owns app state, glues UI + audio + visualizations together.

import {
  CHORDS, PRESETS, PITCH_CLASSES, TUNING_SYSTEMS,
  pitchToFrequency, chordFrequencies, FREQ_MIN, FREQ_MAX
} from "./music.js";
import { AudioEngine } from "./audio.js";
import { initUI, renderAll } from "./ui.js";
import { initVisualizations, setChladniVisible } from "./visualizations.js";
import {
  loadUserPresets, saveUserPresets, newPresetId, newSampleId,
  putSample, getSample, deleteSample
} from "./storage.js";

// ──────────────────────────────────────────────────
// State.
// ──────────────────────────────────────────────────
// Each oscillator has 3 LFOs and 1 filter.
//   Default LFO 1: sine  → pan
//   Default LFO 2: S&H   → amp
//   Default LFO 3: sine  → cutoff
// `shape` and `target` are user-editable per LFO; `depth: 0` disables the LFO.
const defaultLfos = () => ([
  { shape: "sine", target: "pan",    rateHz: 0.25, depth: 0 },
  { shape: "sh",   target: "amp",    rateHz: 0.50, depth: 0 },
  { shape: "sine", target: "cutoff", rateHz: 0.30, depth: 0 }
]);
const defaultFilter = () => ({ type: "lowpass", cutoffHz: 4000, q: 0.7 });
const defaultReverb = () => ({ decaySec: 2.0, mix: 0 });
const defaultDelay  = () => ({ timeSec: 0.30, feedback: 0.40, mix: 0 });

const state = {
  oscillators: [
    { id: 0, frequencyHz: 110.00, waveform: "sine", amplitude: 0.6,  pan: -0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), sampleName: null },
    { id: 1, frequencyHz: 165.00, waveform: "sine", amplitude: 0.6,  pan:  0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), sampleName: null },
    { id: 2, frequencyHz: 220.00, waveform: "sine", amplitude: 0.55, pan: -0.1, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), sampleName: null },
    { id: 3, frequencyHz: 277.18, waveform: "sine", amplitude: 0.5,  pan:  0.3, isMuted: false, isSoloed: false, filter: defaultFilter(), reverb: defaultReverb(), delay: defaultDelay(), lfos: defaultLfos(), sampleName: null }
  ],
  keyId: 9,         // A
  octave: 3,
  chordId: "maj",
  tuningId: "equal12",
  masterVolume: 0.30,
  showControls: true,
  showChladni: true,
  activePresetName: null,

  // Transport
  transportState: "stopped",  // "stopped" | "playing" | "paused"
  sessionDuration: 15 * 60,   // 0 means open
  elapsed: 0,

  // User-saved presets
  userPresets: loadUserPresets()
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
      state.transportState = "paused";
      engine.suspend();
      stopTicker();
    } else {
      // Start (or resume) audio.
      engine.ensureStarted(state.oscillators);
      engine.resume();
      // Re-push state in case it was modified before audio existed.
      for (let i = 0; i < 4; i++) {
        engine.setFrequency(i, state.oscillators[i].frequencyHz);
        engine.setAmplitude(i, state.oscillators[i].amplitude);
        engine.setPan(i, state.oscillators[i].pan);
        engine.setWaveform(i, state.oscillators[i].waveform);
        engine.setMute(i, state.oscillators[i].isMuted);
        engine.setSolo(i, state.oscillators[i].isSoloed);
      }
      engine.setMasterVolume(state.masterVolume);
      state.transportState = "playing";
      startTicker();
    }
    renderAll();
  },

  async stop() {
    stopTicker();
    state.transportState = "stopped";
    state.elapsed = 0;
    await engine.stop();
    renderAll();
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
  toggleChladni() {
    state.showChladni = !state.showChladni;
    setChladniVisible(state.showChladni);
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
      for (let k = 0; k < 3; k++) {
        actions.setLfoShape(i, k, o.lfos[k].shape);
        actions.setLfoTarget(i, k, o.lfos[k].target);
        actions.setLfoRate(i, k, o.lfos[k].rateHz);
        actions.setLfoDepth(i, k, o.lfos[k].depth);
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
  }
};

function restoreLfoTargetBase(oscIndex, target) {
  const o = state.oscillators[oscIndex];
  if (target === "pan")    engine.setPan(oscIndex, o.pan);
  else if (target === "amp")    engine.setAmplitude(oscIndex, o.amplitude);
  else if (target === "cutoff") engine.setFilterCutoff(oscIndex, o.filter.cutoffHz);
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
initVisualizations(getState);
renderAll();

// Debug handle — read-only inspection from devtools / preview_eval.
// Safe to leave in; no UI/audio behavior depends on it.
window.__drone = { state, engine, actions };
