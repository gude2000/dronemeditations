// UI render + event wiring.
// Reads from app state, writes through dispatcher callbacks supplied by main.js.

import {
  WAVEFORMS, PITCH_CLASSES, TUNING_SYSTEMS,
  CHORDS, CHORD_CATEGORIES, PRESETS, PRESET_CATEGORIES,
  JOURNEYS, journeyTotalSeconds,
  FREQ_MIN, FREQ_MAX, frequencyHue
} from "./music.js";
import { startListening, stopListening, freqToNote, listInputDevices, switchInputDevice } from "./pitch-detect.js";
import { initMIDI, midiToKeyOctave } from "./midi.js";

const WAVEFORM_SVG = {
  sine:     '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 12c3-7 7-7 10 0s7 7 10 0"/></svg>',
  triangle: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><path d="M2 20l5-16 5 16 5-16 5 16"/></svg>',
  sawtooth: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><path d="M2 20l5-16v16l5-16v16l5-16v16"/></svg>',
  square:   '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M2 18V8h6v10h6V8h6v10"/></svg>',
  sample:   '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 14l4-8 4 12 3-9 3 6 4-4"/></svg>'
};

let dispatch;
let getState;
let stripContainer;

export function initUI(state, actions) {
  getState = state;
  dispatch = actions;

  stripContainer = document.getElementById("oscillator-strips");

  // First render of strips (we re-render whole strips on state change — cheap, only 4).
  renderStrips();

  // Build modal sheet contents (static lists with selected-state toggling).
  buildKeyGrid();
  buildTuningGrid();
  buildChordList();
  buildPresetList();
  document.getElementById("save-preset-button").addEventListener("click", () => {
    const name = window.prompt("Name this preset:", "");
    if (name) dispatch.saveCurrentAsUserPreset(name);
  });

  // Wire static event handlers.
  document.getElementById("chord-pill").addEventListener("click", () => openSheet("chord-sheet"));
  document.getElementById("preset-pill").addEventListener("click", () => openSheet("preset-sheet"));
  document.getElementById("drift-pill").addEventListener("click", openDriftMenu);
  document.getElementById("listen-pill").addEventListener("click", openListenSheet);
  document.getElementById("performance-pill").addEventListener("click", enterPerformance);
  document.getElementById("journey-pill").addEventListener("click", openJourneySheet);

  // Try to initialize Web MIDI on first user gesture so we can listen for
  // note-on events from any connected controller. Fails silently in
  // browsers without MIDI support.
  document.addEventListener("click", initMIDIOnce, { once: true });
  document.getElementById("performance-exit").addEventListener("click", exitPerformance);
  // Esc exits Performance from anywhere on the page (in addition to the Exit button).
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && document.body.classList.contains("performance")) {
      exitPerformance();
    }
  });
  document.querySelectorAll(".sheet-done").forEach((b) =>
    b.addEventListener("click", () => closeSheet(b.dataset.close))
  );
  document.querySelectorAll(".sheet").forEach((s) =>
    s.addEventListener("click", (e) => { if (e.target === s) closeSheet(s.id); })
  );
  document.getElementById("listen-apply").addEventListener("click", applyDetectedRoot);

  document.getElementById("octave-down").addEventListener("click", () => dispatch.setOctave(getState().octave - 1));
  document.getElementById("octave-up").addEventListener("click", () => dispatch.setOctave(getState().octave + 1));

  document.getElementById("master-volume").addEventListener("input", (e) => {
    dispatch.setMasterVolume(parseFloat(e.target.value));
  });

  document.getElementById("play-pause").addEventListener("click", () => dispatch.togglePlay());
  document.getElementById("stop").addEventListener("click", () => dispatch.stop());
  document.getElementById("record").addEventListener("click", () => dispatch.toggleRecord());

  document.getElementById("chladni-toggle").addEventListener("click", () => {
    dispatch.toggleChladni();
  });
  document.getElementById("spectrum-toggle").addEventListener("click", () => {
    dispatch.toggleSpectrum();
  });

  document.getElementById("duration-button").addEventListener("click", openDurationMenu);

  document.getElementById("tap-layer").addEventListener("click", () => dispatch.toggleControls());

  // The "Pop out Chladni" link uses target="_blank" so the browser handles
  // it natively (no popup-blocker headaches). We only stop event propagation
  // so the background tap-to-hide handler on .controls doesn't also fire.
  document.getElementById("pop-out-chladni").addEventListener("click", (e) => {
    e.stopPropagation();
  });

  // Hide controls when the user clicks on empty space within the panel
  // (not on a button, slider, input, or open modal sheet).
  document.getElementById("controls").addEventListener("click", (e) => {
    if (e.target.closest("button, input, select, textarea, label, [role='button']")) return;
    if (e.target.closest(".sheet")) return;
    dispatch.toggleControls();
  });
}

// ──────────────────────────────────────────────────
// Render — called from main.js whenever state changes.
// ──────────────────────────────────────────────────

export function renderAll() {
  const s = getState();
  // Header subtitle, pills
  document.getElementById("header-subtitle").textContent = `${TUNING_SYSTEMS.find((t) => t.id === s.tuningId).name} · Oct ${s.octave}`;
  document.getElementById("chord-pill-value").textContent =
    `${PITCH_CLASSES[s.keyId].name} ${CHORDS.find((c) => c.id === s.chordId).name}`;
  document.getElementById("preset-pill-value").textContent = s.activePresetName || "—";
  const driftPill = document.getElementById("drift-pill");
  let sceneLabel = (window.__drone?.DRIFT_SCENES || []).find((sc) => sc.id === s.driftSceneId)?.name;
  if (!sceneLabel) sceneLabel = s.driftSceneId === "custom" ? "Custom" : "Off";
  document.getElementById("drift-pill-value").textContent = sceneLabel;
  driftPill.classList.toggle("active", s.driftSceneId !== "off");

  syncJourneyPill();

  document.getElementById("master-volume").value = s.masterVolume;
  document.getElementById("master-volume").style.setProperty("--fill", `${Math.round(s.masterVolume * 100)}%`);
  document.getElementById("master-volume-readout").textContent = Math.round(s.masterVolume * 100);

  // Sheets — sync selected state
  syncKeyGrid();
  syncTuningGrid();
  syncChordList();
  syncPresetList();
  syncUserPresetList();
  document.getElementById("octave-readout").textContent = s.octave;

  // Strips
  renderStrips();

  // Transport
  syncTransport();

  // Controls visibility
  const controls = document.getElementById("controls");
  controls.classList.toggle("hidden", !s.showControls);

  // Chladni toggle button state
  document.getElementById("chladni-toggle").classList.toggle("active", s.showChladni);
  document.getElementById("spectrum-toggle").classList.toggle("active", !!s.showSpectrum);
}

function renderStrips() {
  const s = getState();
  // Reuse existing DOM nodes when possible to avoid losing slider focus.
  const existing = stripContainer.querySelectorAll(".strip");
  if (existing.length !== 4) {
    stripContainer.innerHTML = "";
    for (let i = 0; i < 4; i++) {
      stripContainer.appendChild(buildStrip(i));
    }
  }
  for (let i = 0; i < 4; i++) {
    syncStrip(i, stripContainer.children[i]);
  }
}

// LFO rate range: 0.02–8 Hz, log-scaled.
const LFO_RATE_MIN = 0.02;
const LFO_RATE_MAX = 8.0;
// Reverb decay 0.1–10 s log; delay time 0.02–2 s log.
const REV_MIN = 0.1, REV_MAX = 10.0;
const DLY_MIN = 0.02, DLY_MAX = 2.0;
// Filter cutoff range, log-scaled.
const FILT_MIN = 20;
const FILT_MAX = 8000;
const Q_MIN = 0.3;
const Q_MAX = 20;

const LFO_ICON_SVG = {
  sine:     '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M1 6c2-5 4-5 6 0s4 5 6 0 4-5 6 0 4 5 4 0"/></svg>',
  triangle: '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 10l5-8 6 8 6-8 6 8"/></svg>',
  square:   '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 10h5V2h6v8h6V2h5"/></svg>',
  sh:       '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 9h4V3h5v6h4V5h4v4h4"/></svg>'
};
const LFO_SHAPES  = [
  {id: "sine",     label: "sine"},
  {id: "triangle", label: "triangle"},
  {id: "square",   label: "square"},
  {id: "sh",       label: "S&H"}
];
const LFO_TARGETS = [
  {id: "pan",    label: "pan"},
  {id: "amp",    label: "amp"},
  {id: "cutoff", label: "cut"},
  {id: "pitch",  label: "pitch"}
];
const FILTER_TYPES = [
  {id: "lowpass",  label: "LP"},
  {id: "highpass", label: "HP"},
  {id: "bandpass", label: "BP"}
];

function buildStrip(index) {
  const root = document.createElement("div");
  root.className = "strip";
  root.dataset.index = String(index);
  root.innerHTML = `
    <div class="strip-header">
      <span class="strip-label">OSC ${index + 1}</span>
      <input
        type="text"
        class="strip-freq-input"
        data-role="freq-input"
        inputmode="decimal"
        spellcheck="false"
        autocomplete="off"
        title="Tap to enter exact Hz"
      />
      <span class="strip-freq-unit">Hz</span>
      <div class="strip-buttons">
        <button class="sm-button" data-role="voice-preset" type="button" title="Save / load presets for this single voice" aria-label="Voice presets">★</button>
        <button class="sm-button" data-role="voice-drift" type="button" title="Drift this voice independently — pitch + pan motion over the session" aria-label="Voice drift mode">∿</button>
        <button class="sm-button" data-role="randomize" type="button" title="Randomize this oscillator's parameters (level is preserved)" aria-label="Randomize parameters">⚄</button>
        <button class="sm-button" data-role="solo" type="button">S</button>
        <button class="sm-button" data-role="mute" type="button">M</button>
      </div>
    </div>
    <input type="range" min="0" max="1" step="0.0001" data-role="freq-slider" />
    <div class="strip-controls">
      <div class="waveform-group" data-role="waveform">
        ${WAVEFORMS.map((w) => `
          <button data-waveform="${w.id}" type="button" title="${w.name}">${WAVEFORM_SVG[w.id]}</button>
        `).join("")}
      </div>
      <div class="small-control">
        <span class="small-control-label" data-role="pan-label">PAN C</span>
        <input type="range" min="-1" max="1" step="0.001" data-role="pan" />
      </div>
      <div class="small-control">
        <span class="small-control-label">LVL</span>
        <input type="range" min="0" max="1" step="0.001" data-role="level" />
      </div>
    </div>
    <div class="sample-row" data-role="sample-row" hidden>
      <span class="strip-label">SAMPLE</span>
      <input type="file" accept="audio/*" data-role="sample-input" hidden />
      <button type="button" class="sample-button" data-role="sample-load">Load file…</button>
      <span class="sample-name" data-role="sample-name" title="">—</span>
      <button type="button" class="sample-clear" data-role="sample-clear" hidden>Clear</button>
    </div>
    <div class="filter-row">
      <span class="strip-label">FILT</span>
      <div class="seg" data-role="filter-type">
        ${FILTER_TYPES.map((t) => `<button type="button" data-filter-type="${t.id}">${t.label}</button>`).join("")}
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="filter-cutoff-label">CUTOFF</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="filter-cutoff" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="filter-q-label">Q</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="filter-q" />
      </div>
    </div>
    <div class="fx-row" data-role="rev-row">
      <span class="strip-label">REV</span>
      <div class="mini-control">
        <span class="mini-label" data-role="rev-decay-label">DECAY</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="rev-decay" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="rev-mix-label">MIX</span>
        <input type="range" min="0" max="1" step="0.001" data-role="rev-mix" />
      </div>
    </div>
    <div class="fx-row" data-role="dly-row">
      <span class="strip-label">DLY</span>
      <select class="fx-select" data-role="dly-mode" title="Delay mode">
        <option value="mono">Mono</option>
        <option value="stereo">Stereo</option>
        <option value="pingPong">Ping-Pong</option>
      </select>
      <select class="fx-select" data-role="dly-timing" title="Delay timing (musical division at 120 BPM)">
        <option value="free">Free</option>
        <option value="1/2">1/2</option>
        <option value="1/3">1/3</option>
        <option value="1/3t">1/3T</option>
        <option value="1/4">1/4</option>
        <option value="1/4t">1/4T</option>
        <option value="1/8">1/8</option>
        <option value="1/8t">1/8T</option>
        <option value="1/16">1/16</option>
        <option value="1/16t">1/16T</option>
      </select>
      <div class="mini-control">
        <span class="mini-label" data-role="dly-time-label">TIME</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="dly-time" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="dly-fb-label">FB</span>
        <input type="range" min="0" max="0.95" step="0.001" data-role="dly-fb" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="dly-mix-label">MIX</span>
        <input type="range" min="0" max="1" step="0.001" data-role="dly-mix" />
      </div>
    </div>
    <div class="lfo-rows">
      ${[0, 1, 2, 3].map((k) => `
        <div class="lfo-control" data-lfo="${k}">
          <span class="lfo-label">LFO ${k + 1}</span>
          <div class="seg seg-tight" data-role="lfo-shape">
            ${LFO_SHAPES.map((s) => `<button type="button" data-shape="${s.id}" title="${s.label}">${LFO_ICON_SVG[s.id]}</button>`).join("")}
          </div>
          <div class="seg seg-tight" data-role="lfo-target">
            ${LFO_TARGETS.map((t) => `<button type="button" data-target="${t.id}">${t.label}</button>`).join("")}
          </div>
          <div class="mini-control">
            <span class="mini-label" data-role="lfo-rate-label">RATE</span>
            <input type="range" min="0" max="1" step="0.0001" data-role="lfo-rate" />
          </div>
          <div class="mini-control">
            <span class="mini-label" data-role="lfo-depth-label">DEPTH</span>
            <input type="range" min="0" max="1" step="0.001" data-role="lfo-depth" />
          </div>
        </div>
      `).join("")}
    </div>
  `;

  // Wire events
  const freqSlider = root.querySelector('[data-role="freq-slider"]');
  freqSlider.addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const hz = Math.pow(2, Math.log2(FREQ_MIN) + t * (Math.log2(FREQ_MAX) - Math.log2(FREQ_MIN)));
    dispatch.setFrequency(index, hz);
  });
  root.querySelector('[data-role="pan"]').addEventListener("input", (e) => {
    dispatch.setPan(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="level"]').addEventListener("input", (e) => {
    dispatch.setAmplitude(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="solo"]').addEventListener("click", () => dispatch.toggleSolo(index));
  root.querySelector('[data-role="mute"]').addEventListener("click", () => dispatch.toggleMute(index));
  root.querySelector('[data-role="randomize"]').addEventListener("click", () => dispatch.randomizeOscillator(index));
  root.querySelector('[data-role="voice-drift"]').addEventListener("click", (e) => openVoiceDriftMenu(e, index));
  root.querySelector('[data-role="voice-preset"]').addEventListener("click", (e) => openVoicePresetMenu(e, index));

  // Editable freq display — commit on Enter / blur; revert on Escape.
  const freqInput = root.querySelector('[data-role="freq-input"]');
  freqInput.addEventListener("focus", () => freqInput.select());
  freqInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); freqInput.blur(); }
    else if (e.key === "Escape") { e.preventDefault(); freqInput.value = ""; freqInput.blur(); }
  });
  freqInput.addEventListener("blur", () => {
    const v = parseFloat(freqInput.value);
    if (!isNaN(v) && isFinite(v) && v >= FREQ_MIN && v <= FREQ_MAX) {
      dispatch.setFrequency(index, v);
    } else {
      // Invalid / empty — re-render to restore the canonical display.
      syncStrip(index, root);
    }
  });
  root.querySelectorAll('[data-waveform]').forEach((btn) => {
    btn.addEventListener("click", () => dispatch.setWaveform(index, btn.dataset.waveform));
  });
  root.querySelectorAll('.lfo-control').forEach((section) => {
    const lfoIdx = parseInt(section.dataset.lfo, 10);
    section.querySelector('[data-role="lfo-rate"]').addEventListener("input", (e) => {
      const t = parseFloat(e.target.value);
      const hz = Math.pow(2, Math.log2(LFO_RATE_MIN) + t * (Math.log2(LFO_RATE_MAX) - Math.log2(LFO_RATE_MIN)));
      dispatch.setLfoRate(index, lfoIdx, hz);
    });
    section.querySelector('[data-role="lfo-depth"]').addEventListener("input", (e) => {
      dispatch.setLfoDepth(index, lfoIdx, parseFloat(e.target.value));
    });
    section.querySelectorAll('[data-shape]').forEach((b) =>
      b.addEventListener("click", () => dispatch.setLfoShape(index, lfoIdx, b.dataset.shape))
    );
    section.querySelectorAll('[data-target]').forEach((b) =>
      b.addEventListener("click", () => dispatch.setLfoTarget(index, lfoIdx, b.dataset.target))
    );
  });

  // Sample row wiring
  const sampleInput = root.querySelector('[data-role="sample-input"]');
  root.querySelector('[data-role="sample-load"]').addEventListener("click", () => sampleInput.click());
  sampleInput.addEventListener("change", (e) => {
    const file = e.target.files && e.target.files[0];
    if (file) dispatch.loadSampleFile(index, file);
    sampleInput.value = "";  // allow re-selecting the same file later
  });
  root.querySelector('[data-role="sample-clear"]').addEventListener("click", () => dispatch.clearSample(index));

  root.querySelectorAll('[data-filter-type]').forEach((btn) => {
    btn.addEventListener("click", () => dispatch.setFilterType(index, btn.dataset.filterType));
  });
  root.querySelector('[data-role="filter-cutoff"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const hz = Math.pow(2, Math.log2(FILT_MIN) + t * (Math.log2(FILT_MAX) - Math.log2(FILT_MIN)));
    dispatch.setFilterCutoff(index, hz);
  });
  root.querySelector('[data-role="filter-q"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const q = Math.pow(2, Math.log2(Q_MIN) + t * (Math.log2(Q_MAX) - Math.log2(Q_MIN)));
    dispatch.setFilterQ(index, q);
  });

  // Reverb + delay sliders
  root.querySelector('[data-role="rev-decay"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const sec = Math.pow(2, Math.log2(REV_MIN) + t * (Math.log2(REV_MAX) - Math.log2(REV_MIN)));
    dispatch.setReverbDecay(index, sec);
  });
  root.querySelector('[data-role="rev-mix"]').addEventListener("input", (e) => {
    dispatch.setReverbMix(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="dly-time"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const sec = Math.pow(2, Math.log2(DLY_MIN) + t * (Math.log2(DLY_MAX) - Math.log2(DLY_MIN)));
    dispatch.setDelayTime(index, sec);
  });
  root.querySelector('[data-role="dly-fb"]').addEventListener("input", (e) => {
    dispatch.setDelayFeedback(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="dly-mix"]').addEventListener("input", (e) => {
    dispatch.setDelayMix(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="dly-mode"]').addEventListener("change", (e) => {
    dispatch.setDelayMode(index, e.target.value);
  });
  root.querySelector('[data-role="dly-timing"]').addEventListener("change", (e) => {
    dispatch.setDelayTiming(index, e.target.value);
  });

  return root;
}

function syncStrip(index, root) {
  const osc = getState().oscillators[index];
  const anySoloed = getState().oscillators.some((o) => o.isSoloed);
  const silenced = (anySoloed && !osc.isSoloed) || osc.isMuted;
  root.classList.toggle("silenced", silenced);
  root.style.borderColor = `hsla(${Math.round(frequencyHue(osc.frequencyHz) * 360)}, 40%, 65%, 0.35)`;

  const freqInput = root.querySelector('[data-role="freq-input"]');
  if (document.activeElement !== freqInput) {
    freqInput.value = osc.frequencyHz.toFixed(2);
  }

  const freqSlider = root.querySelector('[data-role="freq-slider"]');
  const t = (Math.log2(osc.frequencyHz) - Math.log2(FREQ_MIN)) / (Math.log2(FREQ_MAX) - Math.log2(FREQ_MIN));
  if (document.activeElement !== freqSlider) {
    freqSlider.value = t.toFixed(4);
  }
  freqSlider.style.setProperty("--fill", `${Math.round(t * 100)}%`);
  freqSlider.style.accentColor = `hsl(${Math.round(frequencyHue(osc.frequencyHz) * 360)}, 65%, 60%)`;

  const panSlider = root.querySelector('[data-role="pan"]');
  if (document.activeElement !== panSlider) {
    panSlider.value = osc.pan.toFixed(3);
  }
  panSlider.style.setProperty("--fill", `${Math.round(((osc.pan + 1) / 2) * 100)}%`);

  const levelSlider = root.querySelector('[data-role="level"]');
  if (document.activeElement !== levelSlider) {
    levelSlider.value = osc.amplitude.toFixed(3);
  }
  levelSlider.style.setProperty("--fill", `${Math.round(osc.amplitude * 100)}%`);

  const panLabel = Math.abs(osc.pan) < 0.02
    ? "C"
    : (osc.pan < 0 ? "L" : "R") + Math.round(Math.abs(osc.pan) * 100);
  root.querySelector('[data-role="pan-label"]').textContent = "PAN " + panLabel;

  const soloBtn = root.querySelector('[data-role="solo"]');
  soloBtn.classList.toggle("solo-on", osc.isSoloed);
  const muteBtn = root.querySelector('[data-role="mute"]');
  muteBtn.classList.toggle("mute-on", osc.isMuted);
  // Voice-drift button glows when this voice has any non-static drift.
  const driftBtn = root.querySelector('[data-role="voice-drift"]');
  const d = osc.drift || {};
  const driftActive = (d.pitchMode && d.pitchMode !== "static") || (d.panMode && d.panMode !== "static");
  driftBtn.classList.toggle("drift-on", !!driftActive);

  root.querySelectorAll('[data-waveform]').forEach((btn) => {
    btn.classList.toggle("selected", btn.dataset.waveform === osc.waveform);
  });

  // Sample row visible only when "Sample" is the selected waveform.
  const sampleRow = root.querySelector('[data-role="sample-row"]');
  const sampleVisible = osc.waveform === "sample";
  sampleRow.hidden = !sampleVisible;
  if (sampleVisible) {
    const name = osc.sampleName || "no file loaded";
    const nameEl = root.querySelector('[data-role="sample-name"]');
    nameEl.textContent = name;
    nameEl.title = name;
    root.querySelector('[data-role="sample-clear"]').hidden = !osc.sampleName;
    root.querySelector('[data-role="sample-load"]').textContent =
      osc.sampleName ? "Replace…" : "Load file…";
  }

  // Filter row
  const f = osc.filter;
  root.querySelectorAll('[data-filter-type]').forEach((b) => {
    b.classList.toggle("selected", b.dataset.filterType === f.type);
  });
  const filtLo = Math.log2(FILT_MIN), filtHi = Math.log2(FILT_MAX);
  const filtT = (Math.log2(Math.max(FILT_MIN, f.cutoffHz)) - filtLo) / (filtHi - filtLo);
  const cutoffSlider = root.querySelector('[data-role="filter-cutoff"]');
  if (document.activeElement !== cutoffSlider) cutoffSlider.value = filtT.toFixed(4);
  cutoffSlider.style.setProperty("--fill", `${Math.round(filtT * 100)}%`);
  root.querySelector('[data-role="filter-cutoff-label"]').textContent =
    f.cutoffHz < 1000
      ? `CUTOFF ${Math.round(f.cutoffHz)}Hz`
      : `CUTOFF ${(f.cutoffHz / 1000).toFixed(2)}k`;

  const qLo = Math.log2(Q_MIN), qHi = Math.log2(Q_MAX);
  const qT = (Math.log2(Math.max(Q_MIN, f.q)) - qLo) / (qHi - qLo);
  const qSlider = root.querySelector('[data-role="filter-q"]');
  if (document.activeElement !== qSlider) qSlider.value = qT.toFixed(4);
  qSlider.style.setProperty("--fill", `${Math.round(qT * 100)}%`);
  root.querySelector('[data-role="filter-q-label"]').textContent = `Q ${f.q.toFixed(2)}`;

  // Reverb / Delay rows
  const rv = osc.reverb;
  const dl = osc.delay;
  const revActive = rv.mix > 0.001;
  const dlyActive = dl.mix > 0.001;
  root.querySelector('[data-role="rev-row"]').classList.toggle("active", revActive);
  root.querySelector('[data-role="dly-row"]').classList.toggle("active", dlyActive);

  const revT = (Math.log2(Math.max(REV_MIN, rv.decaySec)) - Math.log2(REV_MIN)) / (Math.log2(REV_MAX) - Math.log2(REV_MIN));
  const revDecaySlider = root.querySelector('[data-role="rev-decay"]');
  const revMixSlider = root.querySelector('[data-role="rev-mix"]');
  if (document.activeElement !== revDecaySlider) revDecaySlider.value = revT.toFixed(4);
  if (document.activeElement !== revMixSlider) revMixSlider.value = rv.mix.toFixed(3);
  revDecaySlider.style.setProperty("--fill", `${Math.round(revT * 100)}%`);
  revMixSlider.style.setProperty("--fill", `${Math.round(rv.mix * 100)}%`);
  root.querySelector('[data-role="rev-decay-label"]').textContent =
    rv.decaySec < 1 ? `DECAY ${rv.decaySec.toFixed(2)}s` : `DECAY ${rv.decaySec.toFixed(1)}s`;
  root.querySelector('[data-role="rev-mix-label"]').textContent = `MIX ${Math.round(rv.mix * 100)}`;

  const dlyT = (Math.log2(Math.max(DLY_MIN, dl.timeSec)) - Math.log2(DLY_MIN)) / (Math.log2(DLY_MAX) - Math.log2(DLY_MIN));
  const dlyTimeSlider = root.querySelector('[data-role="dly-time"]');
  const dlyFbSlider = root.querySelector('[data-role="dly-fb"]');
  const dlyMixSlider = root.querySelector('[data-role="dly-mix"]');
  if (document.activeElement !== dlyTimeSlider) dlyTimeSlider.value = dlyT.toFixed(4);
  if (document.activeElement !== dlyFbSlider) dlyFbSlider.value = dl.feedback.toFixed(3);
  if (document.activeElement !== dlyMixSlider) dlyMixSlider.value = dl.mix.toFixed(3);
  dlyTimeSlider.style.setProperty("--fill", `${Math.round(dlyT * 100)}%`);
  dlyFbSlider.style.setProperty("--fill", `${Math.round((dl.feedback / 0.95) * 100)}%`);
  dlyMixSlider.style.setProperty("--fill", `${Math.round(dl.mix * 100)}%`);
  root.querySelector('[data-role="dly-time-label"]').textContent =
    dl.timeSec < 1 ? `TIME ${Math.round(dl.timeSec * 1000)}ms` : `TIME ${dl.timeSec.toFixed(2)}s`;
  root.querySelector('[data-role="dly-fb-label"]').textContent = `FB ${Math.round(dl.feedback * 100)}`;
  root.querySelector('[data-role="dly-mix-label"]').textContent = `MIX ${Math.round(dl.mix * 100)}`;
  const dlyModeSel = root.querySelector('[data-role="dly-mode"]');
  const dlyTimingSel = root.querySelector('[data-role="dly-timing"]');
  if (document.activeElement !== dlyModeSel) dlyModeSel.value = dl.mode || "mono";
  if (document.activeElement !== dlyTimingSel) dlyTimingSel.value = dl.timing || "free";
  // Lock the time slider when the user has chosen a musical division.
  dlyTimeSlider.disabled = (dl.timing && dl.timing !== "free");

  // LFO sliders (3 LFOs)
  root.querySelectorAll('.lfo-control').forEach((section) => {
    const lfoIdx = parseInt(section.dataset.lfo, 10);
    const lfo = osc.lfos[lfoIdx];
    const lo = Math.log2(LFO_RATE_MIN), hi = Math.log2(LFO_RATE_MAX);
    const t = (Math.log2(Math.max(LFO_RATE_MIN, lfo.rateHz)) - lo) / (hi - lo);
    const rateSlider = section.querySelector('[data-role="lfo-rate"]');
    const depthSlider = section.querySelector('[data-role="lfo-depth"]');
    if (document.activeElement !== rateSlider) rateSlider.value = t.toFixed(4);
    if (document.activeElement !== depthSlider) depthSlider.value = lfo.depth.toFixed(3);
    rateSlider.style.setProperty("--fill", `${Math.round(t * 100)}%`);
    depthSlider.style.setProperty("--fill", `${Math.round(lfo.depth * 100)}%`);
    section.querySelector('[data-role="lfo-rate-label"]').textContent =
      `RATE ${lfo.rateHz < 1 ? lfo.rateHz.toFixed(2) : lfo.rateHz.toFixed(1)}Hz`;
    section.querySelector('[data-role="lfo-depth-label"]').textContent =
      `DEPTH ${Math.round(lfo.depth * 100)}`;
    section.classList.toggle("active", lfo.depth > 0.001);

    section.querySelectorAll('[data-shape]').forEach((b) =>
      b.classList.toggle("selected", b.dataset.shape === lfo.shape));
    section.querySelectorAll('[data-target]').forEach((b) =>
      b.classList.toggle("selected", b.dataset.target === lfo.target));
  });
}

// ───────── modal sheets ─────────

function openSheet(id) {
  document.getElementById(id).hidden = false;
}
function closeSheet(id) {
  document.getElementById(id).hidden = true;
  // Stopping mic when the listen sheet closes is critical — leaving the
  // audio stream open would keep the browser's mic indicator on.
  if (id === "listen-sheet") stopListeningCleanup();
}

// ───────── tune to room (mic pitch detection) ─────────

let lastDetectedPitch = null;  // last stable Hz, or null if quiet/aperiodic
// Smooth the displayed pitch a touch — autocorrelation jitters frame-to-frame.
let displayHz = 0;

async function openListenSheet() {
  openSheet("listen-sheet");
  const status = document.getElementById("listen-status");
  const applyBtn = document.getElementById("listen-apply");
  applyBtn.disabled = true;
  status.textContent = "Requesting microphone…";
  resetReadout();
  document.getElementById("listen-pill").classList.add("listening");
  try {
    await startListening(onPitchTick);
    status.textContent = "Listening — hold a steady tone";
    await populateInputDevices();
  } catch (err) {
    const msg = err && err.message ? err.message : "permission denied";
    status.textContent = "Microphone unavailable — " + msg;
    document.getElementById("listen-pill").classList.remove("listening");
    console.warn("[listen] getUserMedia failed:", err);
  }
}

// Populate the audio-input dropdown. Only show it when more than one
// device is available so it doesn't take screen real estate for single-
// mic users. Switching restarts the stream with the chosen deviceId.
async function populateInputDevices() {
  const row = document.getElementById("listen-source-row");
  const select = document.getElementById("listen-source");
  const devices = await listInputDevices();
  if (devices.length < 2) { row.hidden = true; return; }
  select.innerHTML = "";
  for (const d of devices) {
    const opt = document.createElement("option");
    opt.value = d.deviceId;
    opt.textContent = d.label;
    select.appendChild(opt);
  }
  row.hidden = false;
  select.onchange = async () => {
    const status = document.getElementById("listen-status");
    status.textContent = "Switching microphone…";
    resetReadout();
    try {
      await switchInputDevice(select.value, onPitchTick);
      status.textContent = "Listening — hold a steady tone";
    } catch (err) {
      status.textContent = "Couldn't switch — " + (err.message || "device unavailable");
    }
  };
}

function onPitchTick({ hz, level }) {
  // Drive the live level meter (logarithmic so quiet sounds register).
  const meter = document.getElementById("listen-meter-fill");
  if (meter) {
    // Map ~−60 dB → 0%, 0 dB → 100%. Floor at -60 dB.
    const dB = level > 0 ? 20 * Math.log10(level) : -100;
    const pct = Math.max(0, Math.min(100, ((dB + 60) / 60) * 100));
    meter.style.width = pct + "%";
  }

  if (!hz) {
    // Decay displayed value toward 0 so the note doesn't freeze on the
    // last captured pitch when the room goes quiet.
    displayHz *= 0.85;
    if (displayHz < 5) {
      lastDetectedPitch = null;
      resetReadout();
      document.getElementById("listen-apply").disabled = true;
    }
    return;
  }
  // Light smoothing on a stable pitch.
  displayHz = displayHz > 0 ? displayHz * 0.6 + hz * 0.4 : hz;
  lastDetectedPitch = displayHz;
  const note = freqToNote(displayHz);
  document.getElementById("listen-note").textContent = `${note.name}${note.octave}`;
  document.getElementById("listen-hz").textContent = `${displayHz.toFixed(2)} Hz`;
  document.getElementById("listen-cents").textContent =
    `${note.cents >= 0 ? "+" : ""}${note.cents.toFixed(0)} cents`;
  document.getElementById("listen-apply").disabled = false;
}

function applyDetectedRoot() {
  if (!lastDetectedPitch) return;
  const note = freqToNote(lastDetectedPitch);
  // Map detected MIDI note → key (0..11) + octave that the chord generator expects.
  dispatch.setKey(note.pitchClassId);
  dispatch.setOctave(Math.max(1, Math.min(6, note.octave)));
  closeSheet("listen-sheet");
}

function resetReadout() {
  document.getElementById("listen-note").textContent = "—";
  document.getElementById("listen-hz").textContent = "— Hz";
  document.getElementById("listen-cents").textContent = "— cents";
  const meter = document.getElementById("listen-meter-fill");
  if (meter) meter.style.width = "0%";
}

function stopListeningCleanup() {
  try { stopListening(); } catch {}
  lastDetectedPitch = null;
  displayHz = 0;
  document.getElementById("listen-pill").classList.remove("listening");
}

// ───────── Performance view (cymatics-only fullscreen) ─────────

function enterPerformance() {
  document.body.classList.add("performance");
  // Make sure the main controls panel is hidden too so it doesn't pop back
  // on the next tap once Performance is exited.
  dispatch.setShowControls(false);
}
function exitPerformance() {
  document.body.classList.remove("performance");
  // Bring the main controls back into view on exit so the user lands
  // somewhere usable instead of a blank Chladni.
  dispatch.setShowControls(true);
}

// ───────── meditation journeys ─────────

function openJourneySheet() {
  buildJourneyList();
  openSheet("journey-sheet");
}

function buildJourneyList() {
  const root = document.getElementById("journey-list");
  const activeId = getState().activeJourneyId;
  root.innerHTML = "";
  for (const j of JOURNEYS) {
    const total = journeyTotalSeconds(j);
    const totalMin = Math.round(total / 60);
    const isActive = j.id === activeId;
    const card = document.createElement("div");
    card.className = "preset-item" + (isActive ? " preset-active" : "");
    card.style.cssText = "display:flex;flex-direction:column;gap:8px;padding:12px;cursor:pointer;border-radius:10px;background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);margin-bottom:8px";
    const stages = j.stages.map((s) =>
      `<div style="font-size:11px;color:rgba(255,255,255,0.65);margin-left:8px;line-height:1.5">
        · ${Math.round(s.durationSec/60)} min — ${s.hint}
      </div>`
    ).join("");
    card.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:center;gap:8px">
        <div>
          <div style="font-size:14px;font-weight:600;color:#fff">${j.name}</div>
          <div style="font-size:11px;color:rgba(255,255,255,0.55);margin-top:2px">${totalMin} min · ${j.stages.length} stages</div>
        </div>
        <button type="button" data-journey="${j.id}" class="${isActive ? "journey-stop-btn" : "journey-start-btn"}"
          style="padding:6px 14px;border-radius:999px;border:0;font-size:12px;font-weight:600;cursor:pointer;
                 background:${isActive ? "rgba(220,80,80,0.85)" : "var(--accent,#6aa9ff)"};color:#fff">
          ${isActive ? "Stop" : "Start"}
        </button>
      </div>
      <div style="font-size:12px;color:rgba(255,255,255,0.75);line-height:1.4">${j.description}</div>
      <div>${stages}</div>
    `;
    card.querySelector("button").addEventListener("click", (e) => {
      e.stopPropagation();
      if (isActive) {
        dispatch.stopJourney();
      } else {
        dispatch.startJourney(j.id);
        closeSheet("journey-sheet");
      }
    });
    root.appendChild(card);
  }
}

// ───────── Web MIDI (controllers → chord root) ─────────

function initMIDIOnce() {
  initMIDI({
    onNoteFn: (note) => {
      // Set the chord generator's root to the played note. Octave is
      // clamped to the chord-gen's supported 1..6 range.
      const { pitchClassId, octave } = midiToKeyOctave(note.midi);
      dispatch.setKey(pitchClassId);
      dispatch.setOctave(Math.max(1, Math.min(6, octave)));
    },
    onStatusFn: (status) => {
      console.log("[MIDI]", status.available ? `connected — ${status.devices.length} input(s)` : status.lastError || "unavailable", status);
    }
  }).catch((err) => console.warn("[MIDI] init failed:", err));
}

function syncJourneyPill() {
  const s = getState();
  const pill = document.getElementById("journey-pill");
  const value = document.getElementById("journey-pill-value");
  if (!s.activeJourneyId) {
    value.textContent = "Off";
    pill.classList.remove("active");
  } else {
    const j = JOURNEYS.find((x) => x.id === s.activeJourneyId);
    if (j) {
      const stage = j.stages[s.journeyStageIndex];
      const stageNum = Math.min(s.journeyStageIndex + 1, j.stages.length);
      value.textContent = `${j.name} · ${stageNum}/${j.stages.length}`;
      pill.classList.add("active");
      pill.title = stage ? `${j.name}\nStage ${stageNum}/${j.stages.length}: ${stage.hint}` : j.name;
    } else {
      value.textContent = "Off";
      pill.classList.remove("active");
    }
  }
  // If the journey sheet is currently open, rebuild its card list so the
  // Start/Stop button labels reflect current state instead of stale closures.
  const sheet = document.getElementById("journey-sheet");
  if (sheet && !sheet.hidden) buildJourneyList();
}

function buildKeyGrid() {
  const grid = document.getElementById("key-grid");
  grid.innerHTML = PITCH_CLASSES.map((pc) => `<button type="button" data-key="${pc.id}">${pc.name}</button>`).join("");
  grid.querySelectorAll("button").forEach((b) => {
    b.addEventListener("click", () => dispatch.setKey(parseInt(b.dataset.key, 10)));
  });
}
function syncKeyGrid() {
  const id = getState().keyId;
  document.querySelectorAll("#key-grid button").forEach((b) => {
    b.classList.toggle("selected", parseInt(b.dataset.key, 10) === id);
  });
}

function buildTuningGrid() {
  const grid = document.getElementById("tuning-grid");
  grid.innerHTML = TUNING_SYSTEMS.map((t) => `<button type="button" data-tuning="${t.id}">${t.name}</button>`).join("");
  grid.querySelectorAll("button").forEach((b) => {
    b.addEventListener("click", () => dispatch.setTuning(b.dataset.tuning));
  });
}
function syncTuningGrid() {
  const id = getState().tuningId;
  document.querySelectorAll("#tuning-grid button").forEach((b) => {
    b.classList.toggle("selected", b.dataset.tuning === id);
  });
}

function buildChordList() {
  const list = document.getElementById("chord-list");
  list.innerHTML = CHORD_CATEGORIES.map((cat) => `
    <div class="chord-category" data-cat="${cat}">
      <h4>${cat}</h4>
      <div class="grid">
        ${CHORDS.filter((c) => c.category === cat).map((c) =>
          `<button type="button" data-chord="${c.id}">${c.name}</button>`
        ).join("")}
      </div>
    </div>
  `).join("");
  list.querySelectorAll("button[data-chord]").forEach((b) => {
    b.addEventListener("click", () => dispatch.setChord(b.dataset.chord));
  });
}
function syncChordList() {
  const id = getState().chordId;
  document.querySelectorAll("#chord-list button[data-chord]").forEach((b) => {
    b.classList.toggle("selected", b.dataset.chord === id);
  });
}

function buildPresetList() {
  const list = document.getElementById("preset-list");
  list.innerHTML = PRESET_CATEGORIES.map((cat) => `
    <div class="preset-category">
      <h4>${cat}</h4>
      <div>
        ${PRESETS.filter((p) => p.category === cat).map((p) => `
          <button class="preset-item" type="button" data-preset="${p.id}">
            <span class="name">${p.name}</span>
            ${p.sub ? `<span class="sub">${p.sub}</span>` : ""}
          </button>
        `).join("")}
      </div>
    </div>
  `).join("");
  list.querySelectorAll("button[data-preset]").forEach((b) => {
    b.addEventListener("click", () => {
      dispatch.applyPreset(b.dataset.preset);
      closeSheet("preset-sheet");
    });
  });
}
function syncPresetList() {
  const name = getState().activePresetName;
  document.querySelectorAll("#preset-list .preset-item").forEach((b) => {
    const id = b.dataset.preset;
    const preset = PRESETS.find((p) => p.id === id);
    b.classList.toggle("selected", preset && preset.name === name);
  });
}

function syncUserPresetList() {
  const list = document.getElementById("user-preset-list");
  const userPresets = getState().userPresets || [];
  const activeName = getState().activePresetName;
  if (!userPresets.length) {
    list.innerHTML = "";
    return;
  }
  list.innerHTML = `
    <div class="preset-category" data-cat="Your Presets">
      <h4>Your Presets</h4>
      <div>
        ${userPresets.map((p) => `
          <div class="user-preset-row${p.name === activeName ? ' selected' : ''}">
            <button class="preset-item" type="button" data-user-preset="${p.id}">
              <span class="name">${escapeHtml(p.name)}</span>
              <span class="sub">${new Date(p.createdAt).toLocaleString()}</span>
            </button>
            <button class="user-preset-delete" type="button" data-delete-preset="${p.id}" title="Delete preset">✕</button>
          </div>
        `).join("")}
      </div>
    </div>
  `;
  list.querySelectorAll("[data-user-preset]").forEach((b) => {
    b.addEventListener("click", () => {
      dispatch.loadUserPreset(b.dataset.userPreset);
      document.getElementById("preset-sheet").hidden = true;
    });
  });
  list.querySelectorAll("[data-delete-preset]").forEach((b) => {
    b.addEventListener("click", (e) => {
      e.stopPropagation();
      if (window.confirm("Delete this preset?")) {
        dispatch.deleteUserPreset(b.dataset.deletePreset);
      }
    });
  });
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

// ───────── transport ─────────

function syncTransport() {
  const s = getState();
  const playIcon = document.getElementById("play-icon");
  const pauseIcon = document.getElementById("pause-icon");
  const playing = s.transportState === "playing";
  playIcon.style.display = playing ? "none" : "";
  pauseIcon.style.display = playing ? "" : "none";

  const stopBtn = document.getElementById("stop");
  stopBtn.disabled = s.transportState === "stopped";

  const recordBtn = document.getElementById("record");
  // Recording is only available once audio context has been started by play.
  recordBtn.disabled = s.transportState === "stopped";
  recordBtn.classList.toggle("recording", !!s.isRecording);
  recordBtn.setAttribute(
    "aria-label",
    s.isRecording ? "Stop recording (will download the file)" : "Record session to file"
  );

  const fmt = (sec) => {
    const total = Math.round(sec);
    const m = Math.floor(total / 60).toString().padStart(2, "0");
    const ss = (total % 60).toString().padStart(2, "0");
    return `${m}:${ss}`;
  };
  const elapsed = fmt(s.elapsed);
  const total = s.sessionDuration > 0 ? fmt(s.sessionDuration) : null;
  document.getElementById("time-readout").textContent = total ? `${elapsed} / ${total}` : elapsed;
  document.getElementById("duration-label").textContent =
    s.sessionDuration > 0 ? `${Math.round(s.sessionDuration / 60)} min` : "Open";
}

// Per-voice drift dropdown — opens beside the strip's drift button. Lets
// the user override that single voice's pitch and pan motion without
// affecting the other three. Active button glow + bulk DRIFT pill
// switching to "Custom" both happen automatically when state changes.
const VOICE_PITCH_DRIFT_MODES = [
  { id: "static",  label: "Static" },
  { id: "up",      label: "Up 1 oct" },
  { id: "down",    label: "Down 1 oct" },
  { id: "upDown",  label: "Up / Down (^)" },
  { id: "downUp",  label: "Down / Up (V)" },
  { id: "wave",    label: "Wave (sine)" },
  { id: "glacial", label: "Glacial wander" }
];
const VOICE_PAN_DRIFT_MODES = [
  { id: "static",       label: "Static" },
  { id: "sweepLR",      label: "Sweep L → R" },
  { id: "sweepRL",      label: "Sweep R → L" },
  { id: "pendulum",     label: "Pendulum" },
  { id: "antiPendulum", label: "Anti-pendulum" },
  { id: "glacial",      label: "Glacial wander" }
];

function openVoiceDriftMenu(e, voiceIndex) {
  let menu = document.getElementById("voice-drift-menu");
  if (menu) { menu.remove(); return; }

  menu = document.createElement("div");
  menu.id = "voice-drift-menu";
  menu.style.cssText = `
    position: fixed; z-index: 30;
    background: #111; border: 1px solid rgba(255,255,255,0.10);
    border-radius: 10px; padding: 6px; min-width: 220px;
    display: flex; flex-direction: column; gap: 2px;
    box-shadow: 0 12px 28px rgba(0,0,0,0.5);
  `;
  const drift = getState().oscillators[voiceIndex]?.drift || { pitchMode: "static", panMode: "static" };

  const addSection = (title) => {
    const h = document.createElement("div");
    h.style.cssText = `
      padding: 8px 12px 4px 12px;
      font-size: 10px; font-weight: 700; letter-spacing: 0.08em;
      color: rgba(255,255,255,0.50); text-transform: uppercase;
    `;
    h.textContent = title;
    menu.appendChild(h);
  };
  const addOption = (mode, currentValue, onClick) => {
    const b = document.createElement("button");
    b.type = "button";
    const isCurrent = mode.id === currentValue;
    b.style.cssText = `
      text-align: left; padding: 6px 12px; font-size: 12px;
      color: #fff; background: ${isCurrent ? "rgba(140,195,255,0.18)" : "transparent"};
      border-radius: 6px;
    `;
    b.textContent = mode.label;
    b.addEventListener("click", () => {
      onClick(mode.id);
      menu.remove();
    });
    menu.appendChild(b);
  };

  addSection(`OSC ${voiceIndex + 1} · Pitch`);
  for (const m of VOICE_PITCH_DRIFT_MODES) {
    addOption(m, drift.pitchMode, (id) => dispatch.setVoicePitchDrift(voiceIndex, id));
  }
  addSection(`OSC ${voiceIndex + 1} · Pan`);
  for (const m of VOICE_PAN_DRIFT_MODES) {
    addOption(m, drift.panMode, (id) => dispatch.setVoicePanDrift(voiceIndex, id));
  }

  const rect = e.currentTarget.getBoundingClientRect();
  menu.style.top = `${rect.bottom + 6}px`;
  menu.style.left = `${Math.min(rect.left, window.innerWidth - 240)}px`;
  document.body.appendChild(menu);

  setTimeout(() => {
    const closer = (ev) => {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener("click", closer);
      }
    };
    document.addEventListener("click", closer);
  }, 0);
}

// Voice-preset dropdown — opens beside the strip's ★ button. Lets the
// user save the current voice as a named preset and load any previously
// saved voice into this slot. Presets are stored per-device in
// localStorage and can be loaded into ANY oscillator slot, enabling
// real mix-and-match across the four voices.
function openVoicePresetMenu(e, voiceIndex) {
  let menu = document.getElementById("voice-preset-menu");
  if (menu) { menu.remove(); return; }

  menu = document.createElement("div");
  menu.id = "voice-preset-menu";
  menu.style.cssText = `
    position: fixed; z-index: 30;
    background: #111; border: 1px solid rgba(255,255,255,0.10);
    border-radius: 10px; padding: 6px; min-width: 260px; max-height: 70vh; overflow-y: auto;
    display: flex; flex-direction: column; gap: 2px;
    box-shadow: 0 12px 28px rgba(0,0,0,0.5);
  `;

  // Top: save-current button.
  const saveBtn = document.createElement("button");
  saveBtn.type = "button";
  saveBtn.style.cssText = `
    text-align: left; padding: 8px 12px; font-size: 12px; font-weight: 600;
    color: #fff; background: rgba(140,195,255,0.18); border-radius: 6px;
  `;
  saveBtn.innerHTML = `💾 &nbsp; Save OSC ${voiceIndex + 1} as preset…`;
  saveBtn.addEventListener("click", () => {
    const o = getState().oscillators[voiceIndex];
    const defaultName = `${o.waveform === "sample" ? "Sample" : (o.waveform.charAt(0).toUpperCase()+o.waveform.slice(1))} ${o.frequencyHz.toFixed(1)} Hz`;
    const name = window.prompt("Name this voice preset:", defaultName);
    if (name === null) return;
    dispatch.saveCurrentVoiceAsPreset(voiceIndex, name);
    menu.remove();
  });
  menu.appendChild(saveBtn);

  // List of saved voice presets.
  const presets = getState().voicePresets || [];
  if (presets.length === 0) {
    const empty = document.createElement("div");
    empty.style.cssText = "padding:12px;font-size:11px;color:rgba(255,255,255,0.45);text-align:center";
    empty.textContent = "No saved voice presets yet.";
    menu.appendChild(empty);
  } else {
    const header = document.createElement("div");
    header.style.cssText = `
      margin: 6px 0 2px 0; padding: 6px 12px 2px 12px;
      font-size: 10px; font-weight: 700; letter-spacing: 0.08em;
      color: rgba(255,255,255,0.40); text-transform: uppercase;
      border-top: 1px solid rgba(255,255,255,0.10);
    `;
    header.textContent = "Load into this voice";
    menu.appendChild(header);

    for (const p of presets) {
      const row = document.createElement("div");
      row.style.cssText = "display:flex;align-items:center;gap:4px";
      const loadBtn = document.createElement("button");
      loadBtn.type = "button";
      loadBtn.style.cssText = `
        flex: 1; text-align: left; padding: 6px 12px; font-size: 12px;
        color: #fff; background: transparent; border-radius: 6px;
      `;
      const date = new Date(p.createdAt || 0);
      const stamp = date.getFullYear()
        ? `${date.getMonth()+1}/${date.getDate()}`
        : "";
      loadBtn.innerHTML = `<div style="font-weight:500">${escapeHtml(p.name)}</div>` +
                         `<div style="font-size:10px;color:rgba(255,255,255,0.45);margin-top:1px">${stamp} · ${p.voice?.frequencyHz?.toFixed(1) ?? "?"} Hz</div>`;
      loadBtn.addEventListener("mouseenter", () => loadBtn.style.background = "rgba(255,255,255,0.06)");
      loadBtn.addEventListener("mouseleave", () => loadBtn.style.background = "transparent");
      loadBtn.addEventListener("click", () => {
        dispatch.loadVoicePreset(voiceIndex, p.id);
        menu.remove();
      });
      row.appendChild(loadBtn);

      const delBtn = document.createElement("button");
      delBtn.type = "button";
      delBtn.title = "Delete preset";
      delBtn.style.cssText = `
        padding: 4px 8px; font-size: 14px; color: rgba(255,255,255,0.40);
        background: transparent; border-radius: 6px; cursor: pointer;
      `;
      delBtn.textContent = "✕";
      delBtn.addEventListener("mouseenter", () => { delBtn.style.color = "#e0524a"; delBtn.style.background = "rgba(224,82,74,0.10)"; });
      delBtn.addEventListener("mouseleave", () => { delBtn.style.color = "rgba(255,255,255,0.40)"; delBtn.style.background = "transparent"; });
      delBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        if (confirm(`Delete "${p.name}"?`)) {
          dispatch.deleteVoicePreset(p.id);
          openVoicePresetMenu({ currentTarget: e.currentTarget }, voiceIndex);  // re-render menu
        }
      });
      row.appendChild(delBtn);
      menu.appendChild(row);
    }
  }

  const rect = e.currentTarget.getBoundingClientRect();
  menu.style.top = `${rect.bottom + 6}px`;
  menu.style.left = `${Math.min(rect.left, window.innerWidth - 280)}px`;
  document.body.appendChild(menu);

  setTimeout(() => {
    const closer = (ev) => {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener("click", closer);
      }
    };
    document.addEventListener("click", closer);
  }, 0);
}

// Drift scene dropdown. Scenes come from main.js (DRIFT_SCENES). The first
// 6 are the "singles" (off + glacial + 4 simple journeys); the rest are
// coordinated multi-voice scenes. A divider separates the two sections.
const SCENE_SECTION_BREAK_AFTER = "upDown";  // last single-mode scene

function openDriftMenu(e) {
  let menu = document.getElementById("drift-menu");
  if (menu) { menu.remove(); return; }

  const scenes = (window.__drone?.DRIFT_SCENES) || [];

  menu = document.createElement("div");
  menu.id = "drift-menu";
  menu.style.cssText = `
    position: fixed; z-index: 30;
    background: #111; border: 1px solid rgba(255,255,255,0.10);
    border-radius: 10px; padding: 6px; min-width: 260px; max-height: 70vh; overflow-y: auto;
    display: flex; flex-direction: column; gap: 2px;
    box-shadow: 0 12px 28px rgba(0,0,0,0.5);
  `;

  const current = getState().driftSceneId;
  for (const scene of scenes) {
    const b = document.createElement("button");
    b.type = "button";
    const isCurrent = scene.id === current;
    b.style.cssText = `
      text-align: left; padding: 8px 12px; font-size: 13px;
      color: #fff; background: ${isCurrent ? "rgba(140,195,255,0.18)" : "transparent"};
      border-radius: 6px;
    `;
    b.innerHTML = `<div style="font-weight:600">${scene.name}</div>` +
                  `<div style="font-size:11px;color:rgba(255,255,255,0.55);margin-top:2px">${scene.hint || ""}</div>`;
    b.addEventListener("mouseenter", () => {
      if (scene.id !== getState().driftSceneId) b.style.background = "rgba(255,255,255,0.06)";
    });
    b.addEventListener("mouseleave", () => {
      b.style.background = scene.id === getState().driftSceneId ? "rgba(140,195,255,0.18)" : "transparent";
    });
    b.addEventListener("click", () => {
      dispatch.setDriftScene(scene.id);
      menu.remove();
    });
    menu.appendChild(b);

    // Divider between "singles" and coordinated scenes.
    if (scene.id === SCENE_SECTION_BREAK_AFTER) {
      const sep = document.createElement("div");
      sep.style.cssText = `
        margin: 6px 0; padding: 6px 12px 2px 12px;
        font-size: 10px; font-weight: 700; letter-spacing: 0.08em;
        color: rgba(255,255,255,0.40); text-transform: uppercase;
        border-top: 1px solid rgba(255,255,255,0.10);
      `;
      sep.textContent = "Coordinated scenes";
      menu.appendChild(sep);
    }
  }

  const rect = e.currentTarget.getBoundingClientRect();
  menu.style.top = `${rect.bottom + 6}px`;
  menu.style.left = `${rect.left}px`;
  document.body.appendChild(menu);

  setTimeout(() => {
    const closer = (ev) => {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener("click", closer);
      }
    };
    document.addEventListener("click", closer);
  }, 0);
}

// Lightweight inline duration picker — opens a small floating menu.
function openDurationMenu(e) {
  const options = [5, 10, 15, 20, 30, 45, 60, 0];
  let menu = document.getElementById("duration-menu");
  if (menu) { menu.remove(); return; }

  menu = document.createElement("div");
  menu.id = "duration-menu";
  menu.style.cssText = `
    position: fixed; z-index: 30;
    background: #111; border: 1px solid rgba(255,255,255,0.10);
    border-radius: 10px; padding: 6px; min-width: 140px;
    display: flex; flex-direction: column; gap: 2px;
    box-shadow: 0 12px 28px rgba(0,0,0,0.5);
  `;
  for (const m of options) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = m === 0 ? "Open (no auto-stop)" : `${m} min`;
    b.style.cssText = `
      text-align: left; padding: 8px 12px; font-size: 13px;
      color: #fff; background: transparent; border-radius: 6px;
    `;
    b.addEventListener("mouseenter", () => b.style.background = "rgba(255,255,255,0.08)");
    b.addEventListener("mouseleave", () => b.style.background = "transparent");
    b.addEventListener("click", () => {
      dispatch.setDuration(m * 60);
      menu.remove();
    });
    menu.appendChild(b);
  }

  const rect = e.currentTarget.getBoundingClientRect();
  menu.style.bottom = `${window.innerHeight - rect.top + 6}px`;
  menu.style.right = `${window.innerWidth - rect.right}px`;
  document.body.appendChild(menu);

  // Close on outside click
  setTimeout(() => {
    const closer = (ev) => {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener("click", closer);
      }
    };
    document.addEventListener("click", closer);
  }, 0);
}
