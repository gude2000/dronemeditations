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
  isRecording: false,         // mirrors engine.isRecording() for the UI
  driftEnabled: false,        // generative slow-drift mode

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

  toggleDrift() {
    if (state.driftEnabled) {
      stopDrift();
    } else {
      startDrift();
    }
  }
};

// ──────────────────────────────────────────────────
// Generative drift — bounded random walks on freq/pan/amp over minutes.
// Snapshots baselines at start so the wander stays musically close to
// where the user left things. Lerp + slow retargeting → meditative, not
// chaotic.
// ──────────────────────────────────────────────────
let driftIntervalId = null;
const driftVoices = [];   // per-osc {baseFreq, basePan, baseAmp, freqTarget, panTarget, ampTarget, nextRetargetAt}

function startDrift() {
  if (state.driftEnabled) return;
  driftVoices.length = 0;
  for (const o of state.oscillators) {
    driftVoices.push({
      baseFreq: o.frequencyHz,
      basePan: o.pan,
      baseAmp: o.amplitude,
      freqTarget: o.frequencyHz,
      panTarget: o.pan,
      ampTarget: o.amplitude,
      nextRetargetAt: 0
    });
  }
  state.driftEnabled = true;
  driftIntervalId = setInterval(driftTick, 1000);
  renderAll();
}

function stopDrift() {
  state.driftEnabled = false;
  if (driftIntervalId) clearInterval(driftIntervalId);
  driftIntervalId = null;
  renderAll();
}

function driftTick() {
  const now = Date.now();
  // Lerp coefficient — small → glacial, smooth motion.
  const lerp = 0.05;
  for (let i = 0; i < driftVoices.length; i++) {
    const v = driftVoices[i];
    const osc = state.oscillators[i];
    if (!v || !osc) continue;

    if (now >= v.nextRetargetAt) {
      // Wander ±half-semitone from baseline; ±0.3 pan; ±0.15 amp.
      const cents = (Math.random() - 0.5) * 100;          // ±50 cents
      v.freqTarget = v.baseFreq * Math.pow(2, cents / 1200);
      v.panTarget  = Math.max(-1, Math.min(1, v.basePan + (Math.random() - 0.5) * 0.6));
      v.ampTarget  = Math.max(0.1, Math.min(1, v.baseAmp + (Math.random() - 0.5) * 0.3));
      // 30–60s until next retarget — keeps motion patient.
      v.nextRetargetAt = now + 30000 + Math.random() * 30000;
    }

    const newFreq = osc.frequencyHz + (v.freqTarget - osc.frequencyHz) * lerp;
    const newPan  = osc.pan         + (v.panTarget  - osc.pan)         * lerp;
    const newAmp  = osc.amplitude   + (v.ampTarget  - osc.amplitude)   * lerp;

    // Use the engine setters directly (skip actions.setFrequency etc) so we
    // don't clear activePresetName or trigger full renderAll on every tick.
    osc.frequencyHz = newFreq;
    osc.pan = newPan;
    osc.amplitude = newAmp;
    engine.setFrequency(i, newFreq);
    engine.setPan(i, newPan);
    engine.setAmplitude(i, newAmp);
  }
  // One UI sync per tick for slider readouts; lightweight.
  renderAll();
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
window.__drone = { state, engine, actions };

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
