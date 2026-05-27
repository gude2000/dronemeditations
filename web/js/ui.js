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
import {
  loadSnapshotMeta, saveSnapshotMeta, getSnapshotBlob, deleteSnapshotBlob
} from "./storage.js";

const WAVEFORM_SVG = {
  sine:     '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 12c3-7 7-7 10 0s7 7 10 0"/></svg>',
  triangle: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><path d="M2 20l5-16 5 16 5-16 5 16"/></svg>',
  sawtooth: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><path d="M2 20l5-16v16l5-16v16l5-16v16"/></svg>',
  square:   '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M2 18V8h6v10h6V8h6v10"/></svg>',
  // White noise — dense random verticals (visually noise).
  whiteNoise: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M2 17l1-7 1 5 1-9 1 8 1-4 1 6 1-7 1 9 1-5 1 7 1-8 1 4 1-6 1 8 1-9 1 5 1-7 1 6 1-4 1 7"/></svg>',
  // Pink noise — softer, lower-frequency hill silhouette.
  pinkNoise:  '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M2 16q3-4 5-1t3 3 3-6 4 4 5-2"/></svg>',
  // Granular — discrete grains (six raindrop/teardrop shapes across the baseline).
  granular: '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor" stroke="none"><circle cx="3" cy="12" r="1.4"/><circle cx="7" cy="12" r="1.4"/><circle cx="11" cy="12" r="1.4"/><circle cx="15" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/><circle cx="23" cy="12" r="1.4"/></svg>',
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

  // v1.1 OSC nav pills — wire each pill to scroll its corresponding
  // strip into view. Uses event delegation so we don't have to
  // re-attach if the strip column re-renders (it doesn't, but cheap
  // either way).
  document.querySelectorAll('[data-osc-nav]').forEach((btn) => {
    btn.addEventListener("click", () => {
      const idx = parseInt(btn.dataset.oscNav, 10);
      const strip = stripContainer.children[idx];
      if (strip && typeof strip.scrollIntoView === "function") {
        strip.scrollIntoView({ behavior: "smooth", block: "start" });
      }
    });
  });

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
  document.getElementById("gallery-pill").addEventListener("click", openGallerySheet);
  document.getElementById("morph-pill").addEventListener("click", openMorphSheet);

  // Cross-window: the pop-out Chladni broadcasts "gallery-changed" after each
  // snapshot save so we can refresh the counter pill + sheet contents live.
  if (typeof BroadcastChannel !== "undefined") {
    try {
      const galleryWatcher = new BroadcastChannel("drone-meditations-chladni");
      galleryWatcher.addEventListener("message", (e) => {
        if (e?.data?.type === "gallery-changed") {
          syncGalleryPill();
          const sheet = document.getElementById("gallery-sheet");
          if (sheet && !sheet.hidden) rebuildGalleryGrid();
        }
      });
    } catch {}
  }

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
  const listenReset = document.getElementById("listen-reset");
  if (listenReset) listenReset.addEventListener("click", clearHeldPitch);

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
  syncGalleryPill();
  syncMorphPill();

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

// ───────── Bundled samples ─────────
//
// Browsers can't enumerate a static folder, so the app fetches a manifest
// (web/samples/index.json) once and uses that to populate the picker. The
// manifest is shipped alongside the audio files in the GitHub Pages deploy.

let _bundledSamplesCache = null;
let _bundledSamplesPromise = null;

async function loadBundledSampleManifest() {
  if (_bundledSamplesCache) return _bundledSamplesCache;
  if (_bundledSamplesPromise) return _bundledSamplesPromise;
  _bundledSamplesPromise = (async () => {
    try {
      const resp = await fetch("./samples/index.json", { cache: "no-cache" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      _bundledSamplesCache = Array.isArray(data.samples) ? data.samples : [];
    } catch (err) {
      console.warn("[samples] couldn't load index.json:", err);
      _bundledSamplesCache = [];
    }
    return _bundledSamplesCache;
  })();
  return _bundledSamplesPromise;
}

/// Render a small popup menu of bundled samples anchored beneath the
/// Bundled button on the given oscillator's sample row. Tapping an
/// entry loads it via dispatch.loadBundledSample. The popup auto-closes
/// on selection or on outside click.
async function openBundledSamplePicker(anchor, oscIndex) {
  // Tear down any existing popup first.
  document.querySelectorAll(".bundled-sample-popup").forEach((p) => p.remove());

  const samples = await loadBundledSampleManifest();
  const rect = anchor.getBoundingClientRect();
  const popup = document.createElement("div");
  popup.className = "bundled-sample-popup";
  popup.style.cssText = `
    position: fixed;
    top: ${Math.round(rect.bottom + 4)}px;
    left: ${Math.round(rect.left)}px;
    max-height: 60vh;
    overflow-y: auto;
    min-width: 240px;
    z-index: 9999;
    background: #14141a;
    border: 1px solid rgba(255,255,255,0.18);
    border-radius: 10px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.5);
    padding: 6px;
  `;

  // Pull the user's browser-library samples first so they appear at the
  // top of the picker — these are files the user explicitly chose to save
  // and are more likely the ones they want again.
  const librarySamples = dispatch.getLibrarySamples();

  if (samples.length === 0 && librarySamples.length === 0) {
    const empty = document.createElement("div");
    empty.style.cssText = "padding:12px 14px;font-size:12px;color:rgba(255,255,255,0.65);max-width:280px;line-height:1.45";
    empty.innerHTML = `No bundled samples yet. Add audio files to
      <code style="font-family:ui-monospace,monospace;background:rgba(255,255,255,0.10);padding:1px 4px;border-radius:4px">web/samples/</code>
      and list them in <code style="font-family:ui-monospace,monospace;background:rgba(255,255,255,0.10);padding:1px 4px;border-radius:4px">samples/index.json</code>,
      or load a file with <strong>Load file…</strong> and click 🔖 to save
      it to your browser library.`;
    popup.appendChild(empty);
  } else {
    // ── My Library section (renders only if there are saved entries) ──
    if (librarySamples.length > 0) {
      const hdr = document.createElement("div");
      hdr.style.cssText = "font-size:9px;letter-spacing:0.10em;text-transform:uppercase;color:#ffcf80;padding:8px 10px 4px";
      hdr.textContent = "My Library";
      popup.appendChild(hdr);
      for (const entry of librarySamples) {
        // Each row is a load-button + a small × delete button.
        const row = document.createElement("div");
        row.style.cssText = "display:flex;align-items:center;gap:4px;border-radius:6px";
        row.addEventListener("mouseenter", () => { row.style.background = "rgba(255,255,255,0.08)"; });
        row.addEventListener("mouseleave", () => { row.style.background = "transparent"; });

        const loadBtn = document.createElement("button");
        loadBtn.type = "button";
        loadBtn.style.cssText = "flex:1;text-align:left;padding:8px 10px;background:transparent;border:0;color:#fff;font-size:13px;cursor:pointer";
        loadBtn.textContent = entry.name || "(unnamed)";
        loadBtn.addEventListener("click", () => {
          popup.remove();
          dispatch.loadLibrarySample(oscIndex, entry);
        });

        const delBtn = document.createElement("button");
        delBtn.type = "button";
        delBtn.title = "Remove from library";
        delBtn.style.cssText = "padding:4px 8px;background:transparent;border:0;color:rgba(255,255,255,0.45);font-size:14px;cursor:pointer;border-radius:4px";
        delBtn.textContent = "×";
        delBtn.addEventListener("mouseenter", () => { delBtn.style.color = "#ff7a7a"; });
        delBtn.addEventListener("mouseleave", () => { delBtn.style.color = "rgba(255,255,255,0.45)"; });
        delBtn.addEventListener("click", (e) => {
          e.stopPropagation();
          if (confirm(`Remove "${entry.name}" from your browser library?`)) {
            dispatch.removeFromLibrary(entry.id);
            // Re-open the picker so the list refreshes.
            popup.remove();
            openBundledSamplePicker(anchor, oscIndex);
          }
        });

        row.appendChild(loadBtn);
        row.appendChild(delBtn);
        popup.appendChild(row);
      }
    }

    // ── Shipped bundled samples, grouped by optional category ──
    const groups = {};
    for (const s of samples) {
      const k = s.category || "Samples";
      (groups[k] = groups[k] || []).push(s);
    }
    for (const [cat, list] of Object.entries(groups)) {
      const hdr = document.createElement("div");
      hdr.style.cssText = "font-size:9px;letter-spacing:0.10em;text-transform:uppercase;color:rgba(255,255,255,0.45);padding:8px 10px 4px";
      hdr.textContent = cat;
      popup.appendChild(hdr);
      for (const entry of list) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.style.cssText = "display:block;width:100%;text-align:left;padding:8px 10px;background:transparent;border:0;color:#fff;font-size:13px;cursor:pointer;border-radius:6px";
        btn.textContent = entry.name || entry.file;
        btn.addEventListener("mouseenter", () => { btn.style.background = "rgba(255,255,255,0.08)"; });
        btn.addEventListener("mouseleave", () => { btn.style.background = "transparent"; });
        btn.addEventListener("click", () => {
          popup.remove();
          dispatch.loadBundledSample(oscIndex, entry);
        });
        popup.appendChild(btn);
      }
    }
  }

  document.body.appendChild(popup);

  // Dismiss on outside click. Use a one-shot capture-phase handler so it
  // doesn't fight the open button's click that was already in flight.
  setTimeout(() => {
    const dismiss = (e) => {
      if (!popup.contains(e.target)) {
        popup.remove();
        document.removeEventListener("click", dismiss, true);
      }
    };
    document.addEventListener("click", dismiss, true);
  }, 0);
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
// Granular slider ranges (mirror GrainState on iOS).
const GRAIN_SIZE_MIN = 5;     // ms
const GRAIN_SIZE_MAX = 500;
const GRAIN_DENS_MIN = 0.5;   // grains/sec
const GRAIN_DENS_MAX = 50;
const Q_MIN = 0.3;
const Q_MAX = 20;

const LFO_ICON_SVG = {
  sine:     '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M1 6c2-5 4-5 6 0s4 5 6 0 4-5 6 0 4 5 4 0"/></svg>',
  triangle: '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 10l5-8 6 8 6-8 6 8"/></svg>',
  square:   '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 10h5V2h6v8h6V2h5"/></svg>',
  sh:       '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 9h4V3h5v6h4V5h4v4h4"/></svg>',
  // Rising sawtooth: linear ramp up, vertical drop back. Drawn as
  // two periods so the shape reads at a glance in the picker.
  sawtooth: '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 10l5-8v8l5-8v8l5-8v8l5-8"/></svg>',
  // Falling ramp: vertical jump up, linear ramp down. Mirror of saw.
  ramp:     '<svg viewBox="0 0 24 12" width="20" height="10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"><path d="M1 2v8l5-8v8l5-8v8l5-8v8l5-8"/></svg>'
};
const LFO_SHAPES  = [
  {id: "sine",     label: "sine"},
  {id: "triangle", label: "triangle"},
  {id: "square",   label: "square"},
  {id: "sh",       label: "S&H"},
  {id: "sawtooth", label: "saw ↗"},
  {id: "ramp",     label: "ramp ↘"}
];
const LFO_TARGETS = [
  {id: "pan",    label: "pan"},
  {id: "amp",    label: "amp"},
  {id: "cutoff", label: "cut"},
  {id: "pitch",  label: "pitch"},
  {id: "q",      label: "Q"},
  {id: "fm",     label: "FM"}
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
        <button class="sm-button" data-role="voice-timing" type="button" title="Timing envelope — silence this voice for N seconds after play, then fade in; optionally fade out after N minutes" aria-label="Timing envelope">⏱</button>
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
      <button type="button" class="sample-button" data-role="sample-bundled" title="Pick from samples shipped with the app + your browser library">Bundled ▾</button>
      <button type="button" class="sample-button" data-role="sample-load" title="Browser picks the folder — use Bundled ▾ for shipped + saved samples">Load file…</button>
      <span class="sample-name" data-role="sample-name" title="">—</span>
      <button type="button" class="sample-bookmark" data-role="sample-save-library" title="Save to my browser library — appears in Bundled ▾ on next visit" hidden>🔖</button>
      <button type="button" class="sample-clear" data-role="sample-clear" hidden>Clear</button>
    </div>
    <!-- Sample window row: shown when waveform === "sample" AND a sample is
         loaded. Four sliders trim the playback window inside the loaded
         file (start/end fractions) and apply per-loop fade-in / fade-out so
         the looped slice doesn't tick at the seam. -->
    <div class="filter-row sample-window-row" data-role="sample-window-row" hidden>
      <span class="strip-label">WINDOW</span>
      <div class="mini-control">
        <span class="mini-label" data-role="sample-start-label">START</span>
        <input type="range" min="0" max="1" step="0.001" data-role="sample-start" title="Where in the sample looping begins (0 = file start)" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="sample-end-label">END</span>
        <input type="range" min="0" max="1" step="0.001" data-role="sample-end" title="Where in the sample looping wraps back (1 = file end)" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="sample-fadein-label">FADE IN</span>
        <input type="range" min="0" max="1" step="0.001" data-role="sample-fadein" title="Per-loop fade-in length, 0–10 sec" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="sample-fadeout-label">FADE OUT</span>
        <input type="range" min="0" max="1" step="0.001" data-role="sample-fadeout" title="Per-loop fade-out length, 0–10 sec" />
      </div>
    </div>
    <!-- Granular row: shown only when waveform === "granular". Four sliders
         shape the grain texture (size + density log-scaled; jitter + spread
         linear 0-1). -->
    <div class="filter-row grain-row" data-role="grain-row" hidden>
      <span class="strip-label">GRAIN</span>
      <div class="mini-control">
        <span class="mini-label" data-role="grain-size-label">SIZE</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="grain-size" title="Grain length, 5–500 ms (log)" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="grain-density-label">DENSITY</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="grain-density" title="Grains per second, 0.5–50 (log)" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="grain-jitter-label">JITTER</span>
        <input type="range" min="0" max="1" step="0.001" data-role="grain-jitter" title="Random inter-grain timing (0 = clockwork, 1 = Poisson)" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="grain-spread-label">SPREAD</span>
        <input type="range" min="0" max="1" step="0.001" data-role="grain-spread" title="Random per-grain stereo placement" />
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
      <div class="mini-control">
        <span class="mini-label" data-role="drive-label">DRIVE clean</span>
        <input type="range" min="1" max="12" step="0.01" data-role="drive" title="Per-voice tanh saturation (1.0 = clean)" />
      </div>
    </div>
    <!-- FX rows in user-requested vertical order: FM → Chorus → Delay → Reverb -->
    <div class="fx-row" data-role="fm-row">
      <span class="strip-label">FM</span>
      <select class="fx-select" data-role="fm-source" title="FM modulator — pick which other oscillator drives this voice's pitch">
        <option value="-1">Off</option>
        ${[0, 1, 2, 3].filter((j) => j !== index).map((j) => `<option value="${j}">Osc ${j + 1}</option>`).join("")}
      </select>
      <div class="mini-control">
        <span class="mini-label" data-role="fm-index-label">INDEX</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="fm-index" title="Modulation index (0-800 Hz, log)" />
      </div>
    </div>
    <div class="fx-row" data-role="ch-row">
      <span class="strip-label">CHO</span>
      <div class="mini-control">
        <span class="mini-label" data-role="ch-rate-label">RATE</span>
        <input type="range" min="0" max="1" step="0.0001" data-role="ch-rate" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="ch-depth-label">DEPTH</span>
        <input type="range" min="0" max="1" step="0.001" data-role="ch-depth" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="ch-width-label">WIDTH</span>
        <input type="range" min="0" max="1" step="0.001" data-role="ch-width" />
      </div>
      <div class="mini-control">
        <span class="mini-label" data-role="ch-mix-label">MIX</span>
        <input type="range" min="0" max="1" step="0.001" data-role="ch-mix" />
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
  root.querySelector('[data-role="voice-timing"]').addEventListener("click", (e) => openTimingMenu(e, index));

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
    // v1.1 multi-target: target buttons toggle membership instead
    // of single-select. Selected state is rendered from lfo.targets
    // in syncStrip — see the data-target highlight below.
    section.querySelectorAll('[data-target]').forEach((b) =>
      b.addEventListener("click", () => dispatch.toggleLfoTarget(index, lfoIdx, b.dataset.target))
    );
  });

  // Sample row wiring
  const sampleInput = root.querySelector('[data-role="sample-input"]');
  root.querySelector('[data-role="sample-load"]').addEventListener("click", () => sampleInput.click());
  root.querySelector('[data-role="sample-bundled"]').addEventListener("click", (e) => {
    openBundledSamplePicker(e.currentTarget, index);
  });
  sampleInput.addEventListener("change", (e) => {
    const file = e.target.files && e.target.files[0];
    if (file) dispatch.loadSampleFile(index, file);
    sampleInput.value = "";  // allow re-selecting the same file later
  });
  root.querySelector('[data-role="sample-clear"]').addEventListener("click", () => dispatch.clearSample(index));
  root.querySelector('[data-role="sample-save-library"]').addEventListener("click", () => dispatch.saveSampleToLibrary(index));

  // Sample window sliders. Start/end are 0..1 fractions; fade-in/out are
  // 0..1 slider positions mapped to 0–10 seconds (linear).
  root.querySelector('[data-role="sample-start"]').addEventListener("input", (e) => {
    dispatch.setSampleStart(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="sample-end"]').addEventListener("input", (e) => {
    dispatch.setSampleEnd(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="sample-fadein"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    dispatch.setSampleFadeIn(index, t * 10);
  });
  root.querySelector('[data-role="sample-fadeout"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    dispatch.setSampleFadeOut(index, t * 10);
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

  root.querySelector('[data-role="drive"]').addEventListener("input", (e) => {
    dispatch.setDrive(index, parseFloat(e.target.value));
  });

  // Granular sliders. Size + density are log-scaled in [GRAIN_*_MIN, MAX];
  // jitter + spread are linear 0..1.
  root.querySelector('[data-role="grain-size"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const ms = GRAIN_SIZE_MIN * Math.pow(GRAIN_SIZE_MAX / GRAIN_SIZE_MIN, t);
    dispatch.setGrainSize(index, ms);
  });
  root.querySelector('[data-role="grain-density"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    const hz = GRAIN_DENS_MIN * Math.pow(GRAIN_DENS_MAX / GRAIN_DENS_MIN, t);
    dispatch.setGrainDensity(index, hz);
  });
  root.querySelector('[data-role="grain-jitter"]').addEventListener("input", (e) => {
    dispatch.setGrainJitter(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="grain-spread"]').addEventListener("input", (e) => {
    dispatch.setGrainPanSpread(index, parseFloat(e.target.value));
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

  // ── FM ──
  root.querySelector('[data-role="fm-source"]').addEventListener("change", (e) => {
    dispatch.setFMSource(index, parseInt(e.target.value, 10));
  });
  root.querySelector('[data-role="fm-index"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    // Log scale, 0 → exactly 0 (off), otherwise 1 → 800 Hz.
    const idx = t <= 0 ? 0 : Math.pow(10, Math.log10(1) + t * Math.log10(800));
    dispatch.setFMIndex(index, idx);
  });

  // ── Chorus ──
  root.querySelector('[data-role="ch-rate"]').addEventListener("input", (e) => {
    const t = parseFloat(e.target.value);
    // 0.05 – 6 Hz log
    const hz = Math.pow(10, Math.log10(0.05) + t * (Math.log10(6.0) - Math.log10(0.05)));
    dispatch.setChorusRate(index, hz);
  });
  root.querySelector('[data-role="ch-depth"]').addEventListener("input", (e) => {
    dispatch.setChorusDepth(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="ch-width"]').addEventListener("input", (e) => {
    dispatch.setChorusWidth(index, parseFloat(e.target.value));
  });
  root.querySelector('[data-role="ch-mix"]').addEventListener("input", (e) => {
    dispatch.setChorusMix(index, parseFloat(e.target.value));
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
    // 🔖 button visible only when the loaded sample is a fresh upload
    // (i.e. not yet persisted). Bundled + library-sourced samples are
    // already in IndexedDB / shipped, so saving them again is redundant.
    const source = dispatch.getSampleSource(index);
    root.querySelector('[data-role="sample-save-library"]').hidden =
      !osc.sampleName || source !== "upload";
  }

  // Sample window row visible only when sample mode AND a sample is loaded.
  const sampleWindowRow = root.querySelector('[data-role="sample-window-row"]');
  const sampleWindowVisible = osc.waveform === "sample" && !!osc.sampleName;
  sampleWindowRow.hidden = !sampleWindowVisible;
  if (sampleWindowVisible) {
    const startFrac = osc.sampleStartFrac ?? 0;
    const endFrac = osc.sampleEndFrac ?? 1;
    const fadeInSec = osc.sampleFadeInSec ?? 0;
    const fadeOutSec = osc.sampleFadeOutSec ?? 0;

    const startSlider = root.querySelector('[data-role="sample-start"]');
    if (document.activeElement !== startSlider) startSlider.value = startFrac.toFixed(3);
    startSlider.style.setProperty("--fill", `${Math.round(startFrac * 100)}%`);
    root.querySelector('[data-role="sample-start-label"]').textContent =
      `START ${Math.round(startFrac * 100)}%`;

    const endSlider = root.querySelector('[data-role="sample-end"]');
    if (document.activeElement !== endSlider) endSlider.value = endFrac.toFixed(3);
    endSlider.style.setProperty("--fill", `${Math.round(endFrac * 100)}%`);
    root.querySelector('[data-role="sample-end-label"]').textContent =
      `END ${Math.round(endFrac * 100)}%`;

    const fadeInSlider = root.querySelector('[data-role="sample-fadein"]');
    const fadeInT = Math.min(1, fadeInSec / 10);
    if (document.activeElement !== fadeInSlider) fadeInSlider.value = fadeInT.toFixed(3);
    fadeInSlider.style.setProperty("--fill", `${Math.round(fadeInT * 100)}%`);
    root.querySelector('[data-role="sample-fadein-label"]').textContent =
      fadeInSec < 0.05 ? "FADE IN off" : `FADE IN ${fadeInSec.toFixed(1)}s`;

    const fadeOutSlider = root.querySelector('[data-role="sample-fadeout"]');
    const fadeOutT = Math.min(1, fadeOutSec / 10);
    if (document.activeElement !== fadeOutSlider) fadeOutSlider.value = fadeOutT.toFixed(3);
    fadeOutSlider.style.setProperty("--fill", `${Math.round(fadeOutT * 100)}%`);
    root.querySelector('[data-role="sample-fadeout-label"]').textContent =
      fadeOutSec < 0.05 ? "FADE OUT off" : `FADE OUT ${fadeOutSec.toFixed(1)}s`;
  }

  // Granular row visible only when waveform === "granular".
  const grainRow = root.querySelector('[data-role="grain-row"]');
  const grainVisible = osc.waveform === "granular";
  grainRow.hidden = !grainVisible;
  if (grainVisible) {
    const g = osc.grain || { sizeMs: 80, densityHz: 8, jitter: 0.6, panSpread: 0.5 };
    // Size (log)
    const sizeT = Math.log(Math.max(GRAIN_SIZE_MIN, g.sizeMs) / GRAIN_SIZE_MIN) /
                  Math.log(GRAIN_SIZE_MAX / GRAIN_SIZE_MIN);
    const sizeSlider = root.querySelector('[data-role="grain-size"]');
    if (document.activeElement !== sizeSlider) sizeSlider.value = sizeT.toFixed(4);
    sizeSlider.style.setProperty("--fill", `${Math.round(sizeT * 100)}%`);
    root.querySelector('[data-role="grain-size-label"]').textContent =
      `SIZE ${Math.round(g.sizeMs)}ms`;
    // Density (log) — show as /s for ≥1, /min otherwise (sparse geiger feel)
    const densT = Math.log(Math.max(GRAIN_DENS_MIN, g.densityHz) / GRAIN_DENS_MIN) /
                  Math.log(GRAIN_DENS_MAX / GRAIN_DENS_MIN);
    const densSlider = root.querySelector('[data-role="grain-density"]');
    if (document.activeElement !== densSlider) densSlider.value = densT.toFixed(4);
    densSlider.style.setProperty("--fill", `${Math.round(densT * 100)}%`);
    root.querySelector('[data-role="grain-density-label"]').textContent =
      g.densityHz >= 1
        ? `DENSITY ${Math.round(g.densityHz)}/s`
        : `DENSITY ${Math.round(g.densityHz * 60)}/min`;
    // Jitter (linear)
    const jitSlider = root.querySelector('[data-role="grain-jitter"]');
    if (document.activeElement !== jitSlider) jitSlider.value = g.jitter.toFixed(3);
    jitSlider.style.setProperty("--fill", `${Math.round(g.jitter * 100)}%`);
    root.querySelector('[data-role="grain-jitter-label"]').textContent =
      `JITTER ${Math.round(g.jitter * 100)}`;
    // Spread (linear)
    const sprSlider = root.querySelector('[data-role="grain-spread"]');
    if (document.activeElement !== sprSlider) sprSlider.value = g.panSpread.toFixed(3);
    sprSlider.style.setProperty("--fill", `${Math.round(g.panSpread * 100)}%`);
    root.querySelector('[data-role="grain-spread-label"]').textContent =
      `SPREAD ${Math.round(g.panSpread * 100)}`;
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

  // Drive slider — sits in the filter row. Label flips to "clean" at 1.0.
  const driveSlider = root.querySelector('[data-role="drive"]');
  const driveVal = osc.drive || 1.0;
  if (document.activeElement !== driveSlider) driveSlider.value = driveVal.toFixed(2);
  // Map drive [1, 12] → fill 0–100%.
  const driveFill = ((driveVal - 1) / 11) * 100;
  driveSlider.style.setProperty("--fill", `${Math.round(driveFill)}%`);
  root.querySelector('[data-role="drive-label"]').textContent =
    driveVal <= 1.01 ? "DRIVE clean" : `DRIVE ${driveVal.toFixed(1)}×`;

  // FM row
  const fm = osc.fm || { sourceIndex: -1, index: 0 };
  const fmActive = fm.sourceIndex >= 0 && fm.index > 0.5;
  root.querySelector('[data-role="fm-row"]').classList.toggle("active", fmActive);
  const fmSrcSel = root.querySelector('[data-role="fm-source"]');
  if (document.activeElement !== fmSrcSel) fmSrcSel.value = String(fm.sourceIndex);
  // Log map for FM index slider: 0 → 0, then 1..800 Hz log
  const fmIdxSlider = root.querySelector('[data-role="fm-index"]');
  const fmIdxT = fm.index <= 0 ? 0 :
    (Math.log10(Math.max(1, fm.index)) - Math.log10(1)) / (Math.log10(800) - Math.log10(1));
  if (document.activeElement !== fmIdxSlider) fmIdxSlider.value = fmIdxT.toFixed(4);
  fmIdxSlider.style.setProperty("--fill", `${Math.round(fmIdxT * 100)}%`);
  // Label tells the user to pick a source when one isn't chosen yet,
  // since the index has nothing to apply to until they do. Slider is
  // always active so the user can pre-dial a value before flipping
  // source on — previously it was disabled and felt broken.
  if (fm.sourceIndex < 0) {
    root.querySelector('[data-role="fm-index-label"]').textContent = "INDEX (pick source)";
  } else {
    root.querySelector('[data-role="fm-index-label"]').textContent =
      fm.index < 10 ? `INDEX ${fm.index.toFixed(1)}` : `INDEX ${Math.round(fm.index)}`;
  }

  // Chorus row
  const ch = osc.chorus || { rateHz: 0.5, depth: 0, width: 0, mix: 0 };
  const chActive = ch.mix > 0.001;
  root.querySelector('[data-role="ch-row"]').classList.toggle("active", chActive);
  const chRateLo = Math.log10(0.05), chRateHi = Math.log10(6.0);
  const chRateT = (Math.log10(Math.max(0.05, ch.rateHz)) - chRateLo) / (chRateHi - chRateLo);
  const chRateSlider = root.querySelector('[data-role="ch-rate"]');
  const chDepthSlider = root.querySelector('[data-role="ch-depth"]');
  const chWidthSlider = root.querySelector('[data-role="ch-width"]');
  const chMixSlider = root.querySelector('[data-role="ch-mix"]');
  if (document.activeElement !== chRateSlider) chRateSlider.value = chRateT.toFixed(4);
  if (document.activeElement !== chDepthSlider) chDepthSlider.value = ch.depth.toFixed(3);
  if (document.activeElement !== chWidthSlider) chWidthSlider.value = ch.width.toFixed(3);
  if (document.activeElement !== chMixSlider) chMixSlider.value = ch.mix.toFixed(3);
  chRateSlider.style.setProperty("--fill", `${Math.round(chRateT * 100)}%`);
  chDepthSlider.style.setProperty("--fill", `${Math.round(ch.depth * 100)}%`);
  chWidthSlider.style.setProperty("--fill", `${Math.round(ch.width * 100)}%`);
  chMixSlider.style.setProperty("--fill", `${Math.round(ch.mix * 100)}%`);
  root.querySelector('[data-role="ch-rate-label"]').textContent =
    `RATE ${ch.rateHz < 1 ? ch.rateHz.toFixed(2) : ch.rateHz.toFixed(1)}Hz`;
  root.querySelector('[data-role="ch-depth-label"]').textContent = `DEPTH ${Math.round(ch.depth * 100)}`;
  root.querySelector('[data-role="ch-width-label"]').textContent = `WIDTH ${Math.round(ch.width * 100)}`;
  root.querySelector('[data-role="ch-mix-label"]').textContent = `MIX ${Math.round(ch.mix * 100)}`;

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
    // v1.1 multi-target: highlight every button whose target is in
    // the LFO's targets array (legacy single-string `target` also
    // honored via currentTargets() in main.js's helpers; here we
    // just read the resolved list off the lfo).
    const activeTargets = Array.isArray(lfo.targets)
      ? lfo.targets
      : (lfo.target ? [lfo.target] : []);
    section.querySelectorAll('[data-target]').forEach((b) =>
      b.classList.toggle("selected", activeTargets.includes(b.dataset.target)));
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

// Display-layer clamp — defense in depth against a runtime regression in the
// pitch detector ever returning a frequency outside the human-voice / drone
// range. Anything outside is ignored at display time too.
const DISPLAY_MIN_HZ = 60;
const DISPLAY_MAX_HZ = 1700;

function onPitchTick({ hz, level }) {
  // Drive the live level meter (logarithmic so quiet sounds register).
  const meter = document.getElementById("listen-meter-fill");
  if (meter) {
    // Map ~−60 dB → 0%, 0 dB → 100%. Floor at -60 dB.
    const dB = level > 0 ? 20 * Math.log10(level) : -100;
    const pct = Math.max(0, Math.min(100, ((dB + 60) / 60) * 100));
    meter.style.width = pct + "%";
  }

  // Display-layer clamp — drop anything that somehow escaped the detector's
  // own [MIN_FREQ, MAX_FREQ] clamp.
  if (hz != null && (hz < DISPLAY_MIN_HZ || hz > DISPLAY_MAX_HZ)) {
    hz = null;
  }

  if (!hz) {
    // KEEP the last detected pitch on screen until either a new pitch comes
    // in or the user explicitly clears it. Previously this decayed to zero
    // in about half a second — too fast to tap "Set as Root" before the note
    // disappeared. The audio-level meter still shows the mic is alive; a
    // small "(held)" badge below the note tells the user the value is
    // sticky. They can press "Reset" to clear or just sing a new pitch.
    if (lastDetectedPitch != null) {
      // Mark as held — UI shows a subtle indicator.
      document.getElementById("listen-note").dataset.held = "true";
    }
    return;
  }
  // Light smoothing on a stable pitch.
  displayHz = displayHz > 0 ? displayHz * 0.6 + hz * 0.4 : hz;
  lastDetectedPitch = displayHz;
  const note = freqToNote(displayHz);
  const noteEl = document.getElementById("listen-note");
  noteEl.textContent = `${note.name}${note.octave}`;
  delete noteEl.dataset.held;
  document.getElementById("listen-hz").textContent = `${displayHz.toFixed(2)} Hz`;
  document.getElementById("listen-cents").textContent =
    `${note.cents >= 0 ? "+" : ""}${note.cents.toFixed(0)} cents`;
  document.getElementById("listen-apply").disabled = false;
}

/// Clear the held pitch — wired to the Reset button in the Listen sheet so
/// the user can start over without restarting the whole sheet.
function clearHeldPitch() {
  lastDetectedPitch = null;
  displayHz = 0;
  resetReadout();
  document.getElementById("listen-apply").disabled = true;
  const noteEl = document.getElementById("listen-note");
  if (noteEl) delete noteEl.dataset.held;
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
  const userJourneys = getState().userJourneys || [];
  root.innerHTML = "";

  // Composer launcher — sits at the top so it's always discoverable.
  const composerBtn = document.createElement("button");
  composerBtn.type = "button";
  composerBtn.textContent = "＋  Create your own journey";
  composerBtn.style.cssText = "display:block;width:100%;padding:11px 14px;margin-bottom:12px;border-radius:10px;border:1px dashed rgba(255,255,255,0.30);background:rgba(255,255,255,0.04);color:#fff;font-size:13px;font-weight:600;cursor:pointer;letter-spacing:0.02em";
  composerBtn.addEventListener("click", () => openJourneyComposer(null));
  root.appendChild(composerBtn);

  if (userJourneys.length > 0) {
    const header = document.createElement("div");
    header.style.cssText = "font-size:10px;letter-spacing:0.12em;text-transform:uppercase;color:rgba(255,255,255,0.50);margin:8px 0 6px;padding-left:2px";
    header.textContent = "Your journeys";
    root.appendChild(header);
    for (const j of userJourneys) {
      root.appendChild(renderJourneyCard(j, activeId, /*isUser=*/true));
    }
    const factoryHeader = document.createElement("div");
    factoryHeader.style.cssText = "font-size:10px;letter-spacing:0.12em;text-transform:uppercase;color:rgba(255,255,255,0.50);margin:16px 0 6px;padding-left:2px";
    factoryHeader.textContent = "Curated journeys";
    root.appendChild(factoryHeader);
  }

  for (const j of JOURNEYS) {
    root.appendChild(renderJourneyCard(j, activeId, /*isUser=*/false));
  }
}

function renderJourneyCard(j, activeId, isUser) {
  const total = journeyTotalSeconds(j);
  const totalMin = Math.round(total / 60);
  const isActive = j.id === activeId;
  const card = document.createElement("div");
  card.className = "preset-item" + (isActive ? " preset-active" : "");
  card.style.cssText = "display:flex;flex-direction:column;gap:8px;padding:12px;cursor:pointer;border-radius:10px;background:rgba(255,255,255,0.04);border:1px solid " +
    (isUser ? "rgba(143,185,217,0.35)" : "rgba(255,255,255,0.08)") + ";margin-bottom:8px";
  const stages = j.stages.map((s) =>
    `<div style="font-size:11px;color:rgba(255,255,255,0.65);margin-left:8px;line-height:1.5">
      · ${Math.round(s.durationSec/60)} min — ${escapeHtml(s.hint || '')}
    </div>`
  ).join("");
  card.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:center;gap:8px">
      <div>
        <div style="font-size:14px;font-weight:600;color:#fff">${escapeHtml(j.name)}</div>
        <div style="font-size:11px;color:rgba(255,255,255,0.55);margin-top:2px">${totalMin} min · ${j.stages.length} stage${j.stages.length === 1 ? '' : 's'}</div>
      </div>
      <div style="display:flex;gap:6px;align-items:center">
        ${isUser ? `<button type="button" data-edit="${j.id}" title="Edit"
            style="width:26px;height:26px;border:0;border-radius:50%;background:rgba(255,255,255,0.08);color:#fff;cursor:pointer;font-size:12px">✎</button>
          <button type="button" data-delete="${j.id}" title="Delete"
            style="width:26px;height:26px;border:0;border-radius:50%;background:rgba(255,255,255,0.08);color:#fff;cursor:pointer;font-size:12px">×</button>` : ''}
        <button type="button" data-journey="${j.id}" class="${isActive ? "journey-stop-btn" : "journey-start-btn"}"
          style="padding:6px 14px;border-radius:999px;border:0;font-size:12px;font-weight:600;cursor:pointer;
                 background:${isActive ? "rgba(220,80,80,0.85)" : "var(--accent,#6aa9ff)"};color:#fff">
          ${isActive ? "Stop" : "Start"}
        </button>
      </div>
    </div>
    <div style="font-size:12px;color:rgba(255,255,255,0.75);line-height:1.4">${escapeHtml(j.description || '')}</div>
    <div>${stages}</div>
  `;
  card.querySelector('[data-journey]').addEventListener("click", (e) => {
    e.stopPropagation();
    if (isActive) {
      dispatch.stopJourney();
    } else {
      dispatch.startJourney(j.id);
      closeSheet("journey-sheet");
    }
  });
  const editBtn = card.querySelector('[data-edit]');
  if (editBtn) {
    editBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      openJourneyComposer(j);
    });
  }
  const delBtn = card.querySelector('[data-delete]');
  if (delBtn) {
    delBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      if (window.confirm(`Delete journey "${j.name}"?`)) {
        dispatch.deleteUserJourney(j.id);
      }
    });
  }
  return card;
}

// ───────── Journey composer ─────────
//
// Inline composer rendered into the same journey sheet. Lets the user
// name a journey, pick any number of stages (preset + drift scene + minutes),
// and save. Editing an existing journey pre-populates the form.
function openJourneyComposer(existing) {
  // Render INTO the journey-list container (not the parent sheet-scroll)
  // so the "Back" button can simply call buildJourneyList() to restore the
  // listing — the journey-list element stays in the DOM the whole time.
  const root = document.getElementById("journey-list");
  // Build a draft model. Each stage gets a stable nonce so we can re-render
  // without losing focus on inputs.
  const draft = {
    name: existing?.name || "",
    description: existing?.description || "",
    stages: (existing?.stages || [{ durationSec: 300, presetId: PRESETS[0]?.id, driftSceneId: "off" }])
      .map((s, i) => ({
        nonce: i,
        durationMin: Math.max(0.5, Math.round((s.durationSec / 60) * 10) / 10),
        presetId: s.presetId,
        driftSceneId: s.driftSceneId || "off"
      }))
  };
  let nextNonce = draft.stages.length;

  const driftScenes = (window.__drone?.DRIFT_SCENES || []);
  const renderComposer = () => {
    root.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:14px">
        <button type="button" id="composer-back" style="background:transparent;border:0;color:var(--accent);cursor:pointer;font-size:13px">‹ Back</button>
        <div style="color:rgba(255,255,255,0.7);font-size:12px;font-weight:600">${existing ? 'Edit journey' : 'New journey'}</div>
        <div style="width:46px"></div>
      </div>
      <label style="display:block;font-size:11px;color:rgba(255,255,255,0.55);letter-spacing:0.05em;text-transform:uppercase;margin-bottom:4px">Name</label>
      <input id="composer-name" type="text" maxlength="60" value="${escapeHtml(draft.name)}"
        placeholder="My evening journey…"
        style="width:100%;padding:8px 10px;border-radius:8px;background:rgba(255,255,255,0.06);border:1px solid rgba(255,255,255,0.12);color:#fff;font-size:13px;margin-bottom:12px" />
      <label style="display:block;font-size:11px;color:rgba(255,255,255,0.55);letter-spacing:0.05em;text-transform:uppercase;margin-bottom:4px">Description (optional)</label>
      <input id="composer-desc" type="text" maxlength="200" value="${escapeHtml(draft.description)}"
        placeholder="What it's for…"
        style="width:100%;padding:8px 10px;border-radius:8px;background:rgba(255,255,255,0.06);border:1px solid rgba(255,255,255,0.12);color:#fff;font-size:13px;margin-bottom:18px" />

      <div style="font-size:11px;color:rgba(255,255,255,0.55);letter-spacing:0.05em;text-transform:uppercase;margin-bottom:6px">Stages</div>
      <div id="composer-stages"></div>
      <button type="button" id="composer-add" style="display:block;width:100%;padding:8px;border-radius:8px;border:1px dashed rgba(255,255,255,0.25);background:rgba(255,255,255,0.03);color:rgba(255,255,255,0.8);font-size:12px;cursor:pointer;margin:8px 0 16px">＋ Add stage</button>

      <div style="display:flex;gap:8px;justify-content:flex-end">
        <button type="button" id="composer-cancel" style="padding:8px 16px;border-radius:999px;background:rgba(255,255,255,0.08);color:#fff;border:0;font-size:13px;cursor:pointer">Cancel</button>
        <button type="button" id="composer-save" style="padding:8px 18px;border-radius:999px;background:var(--accent,#6aa9ff);color:#fff;border:0;font-size:13px;font-weight:600;cursor:pointer">${existing ? 'Save changes' : 'Save journey'}</button>
      </div>
      <div id="composer-error" style="color:rgba(255,170,170,0.95);font-size:12px;margin-top:10px;display:none"></div>
    `;
    const stagesRoot = root.querySelector("#composer-stages");
    stagesRoot.innerHTML = "";
    const totalSec = draft.stages.reduce((acc, s) => acc + s.durationMin * 60, 0);
    for (const stage of draft.stages) {
      const row = document.createElement("div");
      row.style.cssText = "display:grid;grid-template-columns:1fr 1fr 70px 28px;gap:6px;align-items:center;margin-bottom:6px;padding:8px;background:rgba(255,255,255,0.03);border-radius:8px;border:1px solid rgba(255,255,255,0.08)";
      row.innerHTML = `
        <select data-role="preset" style="padding:5px;background:rgba(0,0,0,0.4);color:#fff;border:1px solid rgba(255,255,255,0.15);border-radius:6px;font-size:11px">
          ${PRESETS.map((p) => `<option value="${p.id}" ${p.id === stage.presetId ? 'selected' : ''}>${escapeHtml(p.name)}</option>`).join("")}
        </select>
        <select data-role="drift" style="padding:5px;background:rgba(0,0,0,0.4);color:#fff;border:1px solid rgba(255,255,255,0.15);border-radius:6px;font-size:11px">
          <option value="off" ${stage.driftSceneId === "off" ? "selected" : ""}>Drift off</option>
          ${driftScenes.filter((d) => d.id !== "off").map((d) => `<option value="${d.id}" ${d.id === stage.driftSceneId ? "selected" : ""}>${escapeHtml(d.name)}</option>`).join("")}
        </select>
        <input data-role="dur" type="number" min="0.5" max="90" step="0.5" value="${stage.durationMin}"
          style="padding:5px;background:rgba(0,0,0,0.4);color:#fff;border:1px solid rgba(255,255,255,0.15);border-radius:6px;font-size:11px;text-align:right" title="Minutes" />
        <button type="button" data-role="remove" title="Remove stage" style="width:24px;height:24px;border-radius:50%;border:0;background:rgba(255,255,255,0.08);color:#fff;cursor:pointer;font-size:12px">×</button>
      `;
      row.querySelector('[data-role="preset"]').addEventListener("change", (e) => { stage.presetId = e.target.value; });
      row.querySelector('[data-role="drift"]').addEventListener("change", (e) => { stage.driftSceneId = e.target.value; });
      row.querySelector('[data-role="dur"]').addEventListener("input", (e) => {
        const v = parseFloat(e.target.value);
        stage.durationMin = isFinite(v) && v >= 0.5 ? Math.min(90, v) : stage.durationMin;
        updateTotal();
      });
      row.querySelector('[data-role="remove"]').addEventListener("click", () => {
        if (draft.stages.length <= 1) return;  // never remove the last stage
        draft.stages = draft.stages.filter((s) => s.nonce !== stage.nonce);
        renderComposer();
      });
      stagesRoot.appendChild(row);
    }
    const totalDiv = document.createElement("div");
    totalDiv.id = "composer-total";
    totalDiv.style.cssText = "font-size:11px;color:rgba(255,255,255,0.55);text-align:right;margin-top:4px";
    totalDiv.textContent = `Total: ${formatTotal(totalSec)}`;
    stagesRoot.appendChild(totalDiv);

    function updateTotal() {
      const total = draft.stages.reduce((a, s) => a + s.durationMin * 60, 0);
      const el = root.querySelector("#composer-total");
      if (el) el.textContent = `Total: ${formatTotal(total)}`;
    }

    root.querySelector("#composer-add").addEventListener("click", () => {
      draft.stages.push({ nonce: nextNonce++, durationMin: 5, presetId: PRESETS[0].id, driftSceneId: "off" });
      renderComposer();
    });
    root.querySelector("#composer-back").addEventListener("click", () => {
      buildJourneyList();
    });
    root.querySelector("#composer-cancel").addEventListener("click", () => {
      buildJourneyList();
    });
    root.querySelector("#composer-save").addEventListener("click", () => {
      const nameEl = root.querySelector("#composer-name");
      const descEl = root.querySelector("#composer-desc");
      const errEl  = root.querySelector("#composer-error");
      errEl.style.display = "none";
      const spec = {
        name: nameEl.value,
        description: descEl.value,
        stages: draft.stages.map((s) => ({
          durationSec: Math.round(s.durationMin * 60),
          presetId: s.presetId,
          driftSceneId: s.driftSceneId,
          hint: (PRESETS.find((p) => p.id === s.presetId)?.name || "Stage")
                + (s.driftSceneId && s.driftSceneId !== "off" ? ` · ${s.driftSceneId}` : "")
        }))
      };
      // If we're editing, delete the old entry first so the saved one
      // replaces it (the save action prepends a new entry with a fresh id).
      if (existing) dispatch.deleteUserJourney(existing.id);
      const ok = dispatch.saveUserJourney(spec);
      if (!ok) {
        errEl.textContent = "Couldn't save — give the journey a name and at least one valid stage.";
        errEl.style.display = "block";
        return;
      }
      buildJourneyList();
    });
  };

  function formatTotal(sec) {
    if (sec < 60) return `${Math.round(sec)} s`;
    const m = Math.round(sec / 60 * 10) / 10;
    return m >= 60 ? `${Math.floor(m / 60)} h ${Math.round(m % 60)} min` : `${m} min`;
  }

  renderComposer();
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

// ───────── cymatics snapshot gallery ─────────

function openGallerySheet() {
  rebuildGalleryGrid();
  openSheet("gallery-sheet");
}

function rebuildGalleryGrid() {
  const grid = document.getElementById("gallery-grid");
  const empty = document.getElementById("gallery-empty");
  const meta = loadSnapshotMeta();
  if (!meta.length) {
    grid.innerHTML = "";
    empty.style.display = "block";
    return;
  }
  empty.style.display = "none";
  grid.innerHTML = meta.map((m) => {
    const freqs = (m.oscillators || []).map((o) => `${o.frequencyHz.toFixed(0)} Hz`).join(" · ");
    const when = new Date(m.createdAt);
    const whenStr = when.toLocaleString(undefined, {
      year: "numeric", month: "short", day: "numeric",
      hour: "2-digit", minute: "2-digit"
    });
    return `
      <figure class="gallery-card" data-id="${m.id}">
        <button class="gallery-delete" data-id="${m.id}" type="button" aria-label="Delete snapshot">×</button>
        <button class="gallery-thumb-btn" data-id="${m.id}" type="button" title="Click to re-download PNG">
          <img class="gallery-thumb" src="${m.thumbnail || ""}" alt="Cymatic pattern" loading="lazy" />
        </button>
        <figcaption class="gallery-caption">
          <div class="gallery-when">${whenStr}</div>
          <div class="gallery-freqs">${freqs || "—"}</div>
        </figcaption>
      </figure>
    `;
  }).join("");

  grid.querySelectorAll(".gallery-thumb-btn").forEach((btn) => {
    btn.addEventListener("click", () => redownloadSnapshot(btn.dataset.id));
  });
  grid.querySelectorAll(".gallery-delete").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      removeSnapshot(btn.dataset.id);
    });
  });
}

async function redownloadSnapshot(id) {
  try {
    const blob = await getSnapshotBlob(id);
    if (!blob) return;
    const meta = loadSnapshotMeta().find((m) => m.id === id);
    const stamp = meta?.stamp || id;
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `chladni-${stamp}.png`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 500);
  } catch (err) {
    console.warn("Re-download failed:", err);
  }
}

async function removeSnapshot(id) {
  try {
    await deleteSnapshotBlob(id);
    const meta = loadSnapshotMeta().filter((m) => m.id !== id);
    saveSnapshotMeta(meta);
    rebuildGalleryGrid();
    syncGalleryPill();
  } catch (err) {
    console.warn("Snapshot delete failed:", err);
  }
}

// ───────── Morph sheet ─────────

function openMorphSheet() {
  buildMorphSheet();
  openSheet("morph-sheet");
}

function buildMorphSheet() {
  const fromSel = document.getElementById("morph-from");
  const toSel   = document.getElementById("morph-to");
  const slider  = document.getElementById("morph-slider");
  const readout = document.getElementById("morph-readout");
  const fromLbl = document.getElementById("morph-from-label");
  const toLbl   = document.getElementById("morph-to-label");

  // Populate both dropdowns with grouped <optgroup>s. User-saved presets
  // come first under "My Presets" so they're easy to find; built-in
  // presets follow grouped by category. The morph applier resolves IDs
  // back to voices via morphSourceFor() in main.js (handles both shapes).
  const groups = {};
  for (const p of PRESETS) {
    (groups[p.category] = groups[p.category] || []).push(p);
  }
  const s0 = getState();
  const userOpts = (s0.userPresets || []).length
    ? `<optgroup label="My Presets">${
        s0.userPresets.map((p) =>
          `<option value="${escapeHtml(p.id)}">${escapeHtml(p.name)}</option>`).join("")
      }</optgroup>`
    : "";
  const factoryOpts = PRESET_CATEGORIES
    .filter((c) => groups[c]?.length)
    .map((c) => `<optgroup label="${escapeHtml(c)}">${
      groups[c].map((p) => `<option value="${p.id}">${escapeHtml(p.name)}</option>`).join("")
    }</optgroup>`).join("");
  const allOpts = `<option value="">— pick —</option>` + userOpts + factoryOpts;
  fromSel.innerHTML = allOpts;
  toSel.innerHTML   = allOpts;

  const s = getState();
  fromSel.value = s.morphFromId || "";
  toSel.value   = s.morphToId   || "";
  slider.value  = String(s.morphAmount || 0);
  updateMorphLabels();
  updateMorphReadout();

  fromSel.onchange = () => {
    dispatch.setMorphFrom(fromSel.value || null);
    updateMorphLabels();
  };
  toSel.onchange = () => {
    dispatch.setMorphTo(toSel.value || null);
    updateMorphLabels();
  };
  slider.oninput = (e) => {
    // Manual drag pauses the auto-morph so the user can scrub freely.
    if (s.morphIsRunning) dispatch.pauseMorph();
    dispatch.setMorphAmount(parseFloat(e.target.value));
    updateMorphReadout();
  };
  document.getElementById("morph-reset").onclick = () => {
    dispatch.clearMorph();
    fromSel.value = "";
    toSel.value = "";
    slider.value = "0";
    updateMorphLabels();
    updateMorphReadout();
    updateAutoControls();
  };

  // ── Auto-morph controls ──
  const chipBox = document.getElementById("morph-duration-chips");
  chipBox.querySelectorAll("button").forEach((b) => {
    b.onclick = () => {
      dispatch.setMorphDuration(parseFloat(b.dataset.sec));
      updateAutoControls();
    };
  });

  const playBtn = document.getElementById("morph-play");
  playBtn.onclick = () => {
    const st = getState();
    if (st.morphIsRunning) {
      dispatch.pauseMorph();
    } else {
      dispatch.startMorph();
    }
    updateAutoControls();
  };

  document.getElementById("morph-reset-pos").onclick = () => {
    dispatch.resetMorphPosition();
    slider.value = "0";
    updateMorphReadout();
    updateAutoControls();
  };

  const pingPong = document.getElementById("morph-pingpong");
  pingPong.onchange = () => {
    dispatch.setMorphPingPong(pingPong.checked);
  };

  updateAutoControls();

  function updateMorphLabels() {
    // Look in built-in first, then user presets — matches morphSourceFor.
    const findName = (id) => {
      if (!id) return "—";
      const built = PRESETS.find((p) => p.id === id);
      if (built) return built.name;
      const st = getState();
      const user = (st.userPresets || []).find((p) => p.id === id);
      return user ? user.name : id;
    };
    fromLbl.textContent = findName(fromSel.value);
    toLbl.textContent   = findName(toSel.value);
  }
  function updateMorphReadout() {
    const t = parseFloat(slider.value);
    const st = getState();
    const dirGlyph = st.morphIsRunning
      ? (st.morphIsPingPong
          ? (st.morphAmount < 1.0 ? "▶ " : "◀ ")
          : "▶ ")
      : "";
    readout.textContent = `${dirGlyph}${Math.round(t * 100)}%  ${fromSel.value && toSel.value ? "" : "(pick From + To)"}`;
  }
  function updateAutoControls() {
    const st = getState();
    // Duration chips
    chipBox.querySelectorAll("button").forEach((b) => {
      const sec = parseFloat(b.dataset.sec);
      b.classList.toggle("active", Math.abs(sec - st.morphDurationSec) < 0.5);
    });
    document.getElementById("morph-duration-readout").textContent =
      `Duration: ${formatMorphDuration(st.morphDurationSec)}`;
    // Play/pause label
    playBtn.textContent = st.morphIsRunning ? "⏸ Pause" : "▶ Play";
    playBtn.classList.toggle("running", st.morphIsRunning);
    const hasBoth = !!st.morphFromId && !!st.morphToId;
    playBtn.disabled = !hasBoth;
    pingPong.checked = st.morphIsPingPong;
    // Live slider tracking while running (don't fight an active drag).
    if (st.morphIsRunning && document.activeElement !== slider) {
      slider.value = String(st.morphAmount || 0);
      updateMorphReadout();
    }
  }
}

function formatMorphDuration(sec) {
  const s = Math.round(sec);
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return rem === 0 ? `${m} min` : `${m} min ${rem} s`;
}

function syncMorphPill() {
  const s = getState();
  const pill = document.getElementById("morph-pill");
  const value = document.getElementById("morph-pill-value");
  if (!pill || !value) return;
  if (!s.morphFromId || !s.morphToId) {
    value.textContent = "Off";
    pill.classList.remove("active");
  } else {
    const pct = Math.round((s.morphAmount || 0) * 100);
    value.textContent = s.morphIsRunning ? `▶ ${pct}%` : `${pct}%`;
    pill.classList.add("active");
  }
  // If the morph sheet is open, keep its slider/labels/transport live too.
  const sheet = document.getElementById("morph-sheet");
  if (sheet && !sheet.hidden) {
    const slider = document.getElementById("morph-slider");
    if (slider && document.activeElement !== slider) {
      slider.value = String(s.morphAmount || 0);
    }
    const readout = document.getElementById("morph-readout");
    if (readout) {
      const dirGlyph = s.morphIsRunning
        ? (s.morphIsPingPong
            ? (s.morphAmount < 1.0 ? "▶ " : "◀ ")
            : "▶ ")
        : "";
      readout.textContent = `${dirGlyph}${Math.round((s.morphAmount || 0) * 100)}%`;
    }
    const playBtn = document.getElementById("morph-play");
    if (playBtn) {
      playBtn.textContent = s.morphIsRunning ? "⏸ Pause" : "▶ Play";
      playBtn.classList.toggle("running", s.morphIsRunning);
    }
  }
}

function syncGalleryPill() {
  const meta = loadSnapshotMeta();
  const value = document.getElementById("gallery-pill-value");
  const pill = document.getElementById("gallery-pill");
  if (!value || !pill) return;
  value.textContent = String(meta.length);
  pill.classList.toggle("active", meta.length > 0);
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
  { id: "ocean",   label: "Ocean (±¼ semi · 90 s)" },
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

  // v1.1 quantize-to-scale toggle — at the top so it reads as a
  // top-level voice option, not a drift mode itself.
  addOption(
    { id: "_quant_on", label: drift.quantizeToScale ? "✓ Quantize to scale" : "Quantize to scale" },
    "",
    () => dispatch.setVoiceQuantizeToScale(voiceIndex, !drift.quantizeToScale)
  );

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
/// Timing-envelope popup — quick-pick presets for "voice silent for N
/// seconds after play" + "voice fades out after N minutes". Used in
/// dynamic presets and for the user to stagger voice introductions
/// during long meditations. Default = play immediately + forever.
function openTimingMenu(e, voiceIndex) {
  // Toggle: tapping the icon while the menu is open closes it.
  let menu = document.getElementById("voice-timing-menu");
  if (menu) { menu.remove(); return; }

  const o = getState().oscillators[voiceIndex];
  const curStart = o.startDelaySec || 0;
  const curPlay  = o.playDurationSec || 0;

  const rect = e.currentTarget.getBoundingClientRect();
  menu = document.createElement("div");
  menu.id = "voice-timing-menu";
  menu.style.cssText = `
    position: fixed;
    top: ${Math.round(rect.bottom + 4)}px;
    left: ${Math.round(rect.right - 260)}px;
    min-width: 260px;
    z-index: 9999;
    background: #14141a;
    border: 1px solid rgba(255,255,255,0.18);
    border-radius: 10px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.5);
    padding: 10px 12px;
    color: #fff;
    font-size: 12px;
  `;

  const startPresets = [
    { label: "Now",  sec: 0 },
    { label: "15 s", sec: 15 },
    { label: "30 s", sec: 30 },
    { label: "1 min", sec: 60 },
    { label: "2 min", sec: 120 },
    { label: "5 min", sec: 300 },
    { label: "10 min", sec: 600 }
  ];
  const playPresets = [
    { label: "Forever", sec: 0 },
    { label: "1 min",  sec: 60 },
    { label: "3 min",  sec: 180 },
    { label: "5 min",  sec: 300 },
    { label: "10 min", sec: 600 },
    { label: "15 min", sec: 900 },
    { label: "20 min", sec: 1200 }
  ];

  const fmtStart = (s) => s === 0 ? "Now" : (s < 60 ? `${s}s` : `${Math.round(s/60)}m`);
  const fmtPlay  = (s) => s === 0 ? "Forever" : `${Math.round(s/60)}m`;

  const renderChips = (group, selected, fmt, onPick) =>
    group.map((p) => {
      const sel = p.sec === selected;
      return `<button type="button" data-sec="${p.sec}"
        style="padding:5px 10px;border-radius:999px;border:0;cursor:pointer;font-size:11px;font-weight:600;
               background:${sel ? "var(--accent,#6aa9ff)" : "rgba(255,255,255,0.08)"};
               color:${sel ? "#fff" : "rgba(255,255,255,0.85)"}">${p.label}</button>`;
    }).join(" ");

  menu.innerHTML = `
    <div style="font-size:10px;letter-spacing:0.10em;text-transform:uppercase;color:rgba(255,255,255,0.55);margin-bottom:6px">Start after</div>
    <div id="timing-start-chips" style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px">${
      renderChips(startPresets, curStart, fmtStart)
    }</div>

    <div style="font-size:10px;letter-spacing:0.10em;text-transform:uppercase;color:rgba(255,255,255,0.55);margin-bottom:6px">Play duration</div>
    <div id="timing-play-chips" style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px">${
      renderChips(playPresets, curPlay, fmtPlay)
    }</div>

    <div style="display:flex;gap:8px;align-items:center;font-size:11px;color:rgba(255,255,255,0.65);margin-top:4px">
      <span style="flex:0 0 60px">Custom →</span>
      <input id="timing-start-custom" type="number" min="0" max="3600" step="1" placeholder="Start sec" value="${curStart}"
        style="flex:1;padding:4px 6px;background:rgba(0,0,0,0.4);color:#fff;border:1px solid rgba(255,255,255,0.15);border-radius:6px;font-size:11px" />
      <input id="timing-play-custom" type="number" min="0" max="60" step="0.5" placeholder="Play min" value="${(curPlay/60).toFixed(1)}"
        style="flex:1;padding:4px 6px;background:rgba(0,0,0,0.4);color:#fff;border:1px solid rgba(255,255,255,0.15);border-radius:6px;font-size:11px" />
    </div>

    <div style="display:flex;justify-content:space-between;margin-top:10px;align-items:center">
      <span id="timing-summary" style="font-size:10px;color:rgba(255,255,255,0.50)"></span>
      <button type="button" id="timing-close" style="background:rgba(255,255,255,0.10);border:0;border-radius:6px;color:#fff;padding:4px 10px;font-size:11px;cursor:pointer">Done</button>
    </div>
  `;
  document.body.appendChild(menu);

  const updateSummary = () => {
    const o2 = getState().oscillators[voiceIndex];
    const s = o2.startDelaySec || 0;
    const p = o2.playDurationSec || 0;
    const part1 = s > 0 ? `starts at ${fmtStart(s)}` : "starts immediately";
    const part2 = p > 0 ? `fades out after ${fmtPlay(p)}` : "plays forever";
    menu.querySelector("#timing-summary").textContent = `Voice ${voiceIndex + 1} ${part1}, ${part2}`;
  };
  updateSummary();

  menu.querySelectorAll('#timing-start-chips [data-sec]').forEach((btn) => {
    btn.addEventListener("click", () => {
      dispatch.setStartDelay(voiceIndex, parseFloat(btn.dataset.sec));
      menu.remove();
      openTimingMenu(e, voiceIndex);  // re-render with new selection
    });
  });
  menu.querySelectorAll('#timing-play-chips [data-sec]').forEach((btn) => {
    btn.addEventListener("click", () => {
      dispatch.setPlayDuration(voiceIndex, parseFloat(btn.dataset.sec));
      menu.remove();
      openTimingMenu(e, voiceIndex);
    });
  });
  menu.querySelector("#timing-start-custom").addEventListener("change", (ev) => {
    const v = parseFloat(ev.target.value);
    if (Number.isFinite(v) && v >= 0) {
      dispatch.setStartDelay(voiceIndex, v);
      updateSummary();
    }
  });
  menu.querySelector("#timing-play-custom").addEventListener("change", (ev) => {
    const minutes = parseFloat(ev.target.value);
    if (Number.isFinite(minutes) && minutes >= 0) {
      dispatch.setPlayDuration(voiceIndex, minutes * 60);
      updateSummary();
    }
  });
  menu.querySelector("#timing-close").addEventListener("click", () => menu.remove());

  // Dismiss on outside click (capture-phase one-shot).
  setTimeout(() => {
    const dismiss = (ev) => {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener("click", dismiss, true);
      }
    };
    document.addEventListener("click", dismiss, true);
  }, 0);
}

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
