// Canvas backdrops — blob field + Chladni nodal pattern.
// Both read from the shared app state at render time.

import { frequencyHue } from "./music.js";

let bgCanvas, chladniCanvas, bgCtx, chladniCtx;
let getState;
let isShowingChladni = true;
let lastSize = { w: 0, h: 0, dpr: 1 };

// Sampled grid resolution. Higher = finer detail but more work per frame.
// At 128 on a typical desktop the patterns show classic Chladni geometry
// (crosses, grids, multi-pointed stars) instead of coarse blocks.
const CHLADNI_GRID = 128;

export function initVisualizations(state) {
  getState = state;
  bgCanvas = document.getElementById("bg-canvas");
  chladniCanvas = document.getElementById("chladni-canvas");
  bgCtx = bgCanvas.getContext("2d");
  chladniCtx = chladniCanvas.getContext("2d");
  resize();
  window.addEventListener("resize", resize);
  requestAnimationFrame(loop);
}

export function setChladniVisible(visible) {
  isShowingChladni = visible;
  chladniCanvas.style.display = visible ? "" : "none";
}

function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const w = window.innerWidth;
  const h = window.innerHeight;
  for (const c of [bgCanvas, chladniCanvas]) {
    c.width = Math.round(w * dpr);
    c.height = Math.round(h * dpr);
    c.style.width = w + "px";
    c.style.height = h + "px";
  }
  lastSize = { w, h, dpr };
}

function loop(t) {
  drawBlobs(t / 1000);
  if (isShowingChladni) drawChladni(t / 1000);
  requestAnimationFrame(loop);
}

// ────────────────────────────────────────────────────────────
// Blob background — 4 colored radial gradients drifting around.
// ────────────────────────────────────────────────────────────
function drawBlobs(t) {
  const { w, h, dpr } = lastSize;
  const ctx = bgCtx;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  // Base background — vertical gentle gradient.
  const grd = ctx.createLinearGradient(0, 0, 0, h);
  grd.addColorStop(0, "#040405");
  grd.addColorStop(1, "#0c0c10");
  ctx.fillStyle = grd;
  ctx.fillRect(0, 0, w, h);

  const oscs = getState().oscillators;
  ctx.globalCompositeOperation = "screen";

  for (let i = 0; i < oscs.length; i++) {
    const osc = oscs[i];
    const isAudible = !isVoiceSilenced(i, oscs);
    const logF = Math.log2(Math.max(osc.frequencyHz, 20));
    const speedScale = 1.0 + (logF - Math.log2(20)) / 12;
    const phaseA = i * Math.PI * 0.5;
    const phaseB = i * Math.PI * 0.31;
    const omegaX = 0.045 * speedScale;
    const omegaY = 0.052 * speedScale;
    const nx = (Math.sin(omegaX * t + phaseA) + 0.6 * Math.sin(0.13 * t + phaseB)) / 1.6;
    const ny = (Math.cos(omegaY * t + phaseB) + 0.6 * Math.cos(0.17 * t + phaseA)) / 1.6;

    const cx = (nx * 0.5 + 0.5) * w;
    const cy = (ny * 0.5 + 0.5) * h;
    const maxDim = Math.max(w, h);
    const radius = maxDim * (0.30 + 0.06 * (i % 3));
    const hue = frequencyHue(osc.frequencyHz);
    const alpha = isAudible ? 0.32 : 0.10;
    const color = `hsla(${Math.round(hue * 360)}, 55%, 60%, ${alpha})`;
    const colorFade = `hsla(${Math.round(hue * 360)}, 55%, 60%, 0)`;

    const radial = ctx.createRadialGradient(cx, cy, 1, cx, cy, radius);
    radial.addColorStop(0, color);
    radial.addColorStop(1, colorFade);
    ctx.fillStyle = radial;
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalCompositeOperation = "source-over";
}

// ────────────────────────────────────────────────────────────
// Chladni — sum-of-modes nodal field rendered as small cells.
// ────────────────────────────────────────────────────────────
function drawChladni(t) {
  const { w, h, dpr } = lastSize;
  const ctx = chladniCtx;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  const oscs = getState().oscillators;
  const audible = oscs.filter((_, i) => !isVoiceSilenced(i, oscs));
  if (audible.length === 0) return;

  // Map each audible voice to a (m, n) mode pair.
  // Bumped to 2–10 so even low-frequency drones produce rich nodal patterns.
  // A wider per-voice spread (i+1) gives each voice a distinct geometry that
  // interferes interestingly with the others.
  const modes = audible.map((osc, i) => {
    const logF = Math.log2(Math.max(osc.frequencyHz, 20));
    const lo = Math.log2(20), hi = Math.log2(2000);
    const tt = (logF - lo) / (hi - lo);
    const m = Math.max(2, Math.round(2 + tt * 8));
    const n = Math.max(2, m + ((i + 1) % 4) - 2);
    return { m, n, weight: osc.amplitude, hue: frequencyHue(osc.frequencyHz) };
  });

  const cellW = w / CHLADNI_GRID;
  const cellH = h / CHLADNI_GRID;

  for (let j = 0; j < CHLADNI_GRID; j++) {
    for (let i = 0; i < CHLADNI_GRID; i++) {
      const x = (i + 0.5) / CHLADNI_GRID;
      const y = (j + 0.5) / CHLADNI_GRID;

      let field = 0, hueA = 0, wA = 0;
      for (const v of modes) {
        const mPi = v.m * Math.PI;
        const nPi = v.n * Math.PI;
        const term = Math.cos(mPi * x) * Math.cos(nPi * y) -
                     Math.cos(nPi * x) * Math.cos(mPi * y);
        field += term * v.weight;
        hueA += v.hue * v.weight;
        wA += v.weight;
      }
      const mag = Math.abs(field);
      // Tighter threshold = thinner, sharper nodal lines.
      const node = Math.max(0, 1 - mag * 6.0);
      if (node <= 0.04) continue;

      const hue = wA > 0 ? hueA / wA : 0.5;
      ctx.fillStyle = `hsla(${Math.round(hue * 360)}, 25%, 95%, ${node * 0.85})`;
      ctx.fillRect(i * cellW, j * cellH, cellW + 0.5, cellH + 0.5);
    }
  }
}

function isVoiceSilenced(i, oscs) {
  const anySoloed = oscs.some((o) => o.isSoloed);
  return (anySoloed && !oscs[i].isSoloed) || oscs[i].isMuted;
}
