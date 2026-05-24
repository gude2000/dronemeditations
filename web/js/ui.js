// UI render + event wiring.
// Reads from app state, writes through dispatcher callbacks supplied by main.js.

import {
  WAVEFORMS, PITCH_CLASSES, TUNING_SYSTEMS,
  CHORDS, CHORD_CATEGORIES, PRESETS, PRESET_CATEGORIES,
  FREQ_MIN, FREQ_MAX, frequencyHue
} from "./music.js";

const WAVEFORM_SVG = {
  sine:     '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 12c3-7 7-7 10 0s7 7 10 0"/></svg>',
  triangle: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><path d="M2 20l5-16 5 16 5-16 5 16"/></svg>',
  sawtooth: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><path d="M2 20l5-16v16l5-16v16l5-16v16"/></svg>',
  square:   '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M2 18V8h6v10h6V8h6v10"/></svg>'
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

  // Wire static event handlers.
  document.getElementById("chord-pill").addEventListener("click", () => openSheet("chord-sheet"));
  document.getElementById("preset-pill").addEventListener("click", () => openSheet("preset-sheet"));
  document.querySelectorAll(".sheet-done").forEach((b) =>
    b.addEventListener("click", () => closeSheet(b.dataset.close))
  );
  document.querySelectorAll(".sheet").forEach((s) =>
    s.addEventListener("click", (e) => { if (e.target === s) closeSheet(s.id); })
  );

  document.getElementById("octave-down").addEventListener("click", () => dispatch.setOctave(getState().octave - 1));
  document.getElementById("octave-up").addEventListener("click", () => dispatch.setOctave(getState().octave + 1));

  document.getElementById("master-volume").addEventListener("input", (e) => {
    dispatch.setMasterVolume(parseFloat(e.target.value));
  });

  document.getElementById("play-pause").addEventListener("click", () => dispatch.togglePlay());
  document.getElementById("stop").addEventListener("click", () => dispatch.stop());

  document.getElementById("chladni-toggle").addEventListener("click", () => {
    dispatch.toggleChladni();
  });

  document.getElementById("duration-button").addEventListener("click", openDurationMenu);

  document.getElementById("tap-layer").addEventListener("click", () => dispatch.toggleControls());
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

  document.getElementById("master-volume").value = s.masterVolume;
  document.getElementById("master-volume").style.setProperty("--fill", `${Math.round(s.masterVolume * 100)}%`);
  document.getElementById("master-volume-readout").textContent = Math.round(s.masterVolume * 100);

  // Sheets — sync selected state
  syncKeyGrid();
  syncTuningGrid();
  syncChordList();
  syncPresetList();
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
// Filter cutoff range, log-scaled.
const FILT_MIN = 20;
const FILT_MAX = 8000;
const Q_MIN = 0.3;
const Q_MAX = 20;

const LFO_ICON_SVG = {
  sine: '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M1 6c2-5 4-5 6 0s4 5 6 0 4-5 6 0 4 5 4 0"/></svg>',
  sh:   '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 9h4V3h5v6h4V5h4v4h4"/></svg>'
};
const LFO_SHAPES  = [{id: "sine", label: "sine"}, {id: "sh", label: "S&H"}];
const LFO_TARGETS = [{id: "pan", label: "pan"}, {id: "amp", label: "amp"}, {id: "cutoff", label: "cut"}];
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
    <div class="lfo-rows">
      ${[0, 1, 2].map((k) => `
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

  root.querySelectorAll('[data-waveform]').forEach((btn) => {
    btn.classList.toggle("selected", btn.dataset.waveform === osc.waveform);
  });

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
