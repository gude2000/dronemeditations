// Pop-out Chladni window.
//
// Runs the same WebGL fragment shader as the main app's visualizations.js,
// but renders fullscreen. State (oscillators array) arrives via a
// BroadcastChannel that the main app posts to on every change.

import { frequencyHue } from "./music.js";

const canvas = document.getElementById("chladni");
const disconnected = document.getElementById("disconnected");
let gl;
let glProgram, glAttribs = {}, glUniforms = {};

const VS = `
attribute vec2 a_position;
varying vec2 v_uv;
void main() {
  v_uv = a_position * 0.5 + 0.5;
  gl_Position = vec4(a_position, 0.0, 1.0);
}
`;

const FS = `
precision highp float;
varying vec2 v_uv;
uniform int  u_voiceCount;
uniform vec3 u_modes[4];
uniform vec3 u_colors[4];

void main() {
  float field = 0.0;
  vec3  colorAccum = vec3(0.0);
  float weightAccum = 0.0;
  for (int i = 0; i < 4; i++) {
    if (i >= u_voiceCount) break;
    float m = u_modes[i].x;
    float n = u_modes[i].y;
    float w = u_modes[i].z;
    float term = cos(m * 3.14159265 * v_uv.x) * cos(n * 3.14159265 * v_uv.y)
               - cos(n * 3.14159265 * v_uv.x) * cos(m * 3.14159265 * v_uv.y);
    field += term * w;
    colorAccum += u_colors[i] * w;
    weightAccum += w;
  }
  float mag = abs(field);
  float node = max(0.0, 1.0 - mag * 9.0);
  if (node <= 0.04) discard;
  vec3 baseColor = weightAccum > 0.0 ? colorAccum / weightAccum : vec3(0.85);
  vec3 finalColor = mix(vec3(0.95), baseColor, 0.30);
  gl_FragColor = vec4(finalColor, node * 0.85);
}
`;

// Same per-voice n table as the main app for visual continuity.
const VOICE_N = [8, 12, 16, 20];

// Latest snapshot of the main app's state. Updated by BroadcastChannel
// messages; rendered every animation frame.
let latestOscillators = null;
let lastMessageTime = 0;

function initWebGL() {
  gl = canvas.getContext("webgl", {
    premultipliedAlpha: false,
    antialias: true,
    alpha: false
  });
  if (!gl) {
    disconnected.textContent = "WebGL not available in this browser.";
    disconnected.classList.add("shown");
    return;
  }
  const vs = compileShader(gl.VERTEX_SHADER, VS);
  const fs = compileShader(gl.FRAGMENT_SHADER, FS);
  glProgram = gl.createProgram();
  gl.attachShader(glProgram, vs);
  gl.attachShader(glProgram, fs);
  gl.linkProgram(glProgram);
  if (!gl.getProgramParameter(glProgram, gl.LINK_STATUS)) {
    console.error(gl.getProgramInfoLog(glProgram));
    return;
  }
  glAttribs.position    = gl.getAttribLocation(glProgram, "a_position");
  glUniforms.voiceCount = gl.getUniformLocation(glProgram, "u_voiceCount");
  glUniforms.modes      = gl.getUniformLocation(glProgram, "u_modes");
  glUniforms.colors     = gl.getUniformLocation(glProgram, "u_colors");
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
}

function compileShader(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    throw new Error("Shader compile failed: " + gl.getShaderInfoLog(s));
  }
  return s;
}

function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.round(window.innerWidth * dpr);
  canvas.height = Math.round(window.innerHeight * dpr);
  canvas.style.width = window.innerWidth + "px";
  canvas.style.height = window.innerHeight + "px";
  if (gl) gl.viewport(0, 0, canvas.width, canvas.height);
}

function isVoiceSilenced(i, oscs) {
  const anySoloed = oscs.some((o) => o.isSoloed);
  return (anySoloed && !oscs[i].isSoloed) || oscs[i].isMuted;
}

function hslToRgb(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h * 6) % 2) - 1));
  const m = l - c / 2;
  let r, g, b;
  if (h < 1 / 6)      { r = c; g = x; b = 0; }
  else if (h < 2 / 6) { r = x; g = c; b = 0; }
  else if (h < 3 / 6) { r = 0; g = c; b = x; }
  else if (h < 4 / 6) { r = 0; g = x; b = c; }
  else if (h < 5 / 6) { r = x; g = 0; b = c; }
  else                { r = c; g = 0; b = x; }
  return [r + m, g + m, b + m];
}

function render() {
  requestAnimationFrame(render);
  if (!gl) return;
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  if (!latestOscillators || latestOscillators.length === 0) return;

  const audible = latestOscillators.filter((_, i) => !isVoiceSilenced(i, latestOscillators));
  if (audible.length === 0) return;

  const count = Math.min(4, audible.length);
  const modes = new Float32Array(12);
  const colors = new Float32Array(12);
  for (let i = 0; i < count; i++) {
    const osc = audible[i];
    const logF = Math.log2(Math.max(osc.frequencyHz, 20));
    const lo = Math.log2(20), hi = Math.log2(2000);
    const tt = (logF - lo) / (hi - lo);
    const m = Math.max(3, Math.round(6 + tt * 16));
    const n = VOICE_N[i % VOICE_N.length];
    modes[i * 3 + 0] = m;
    modes[i * 3 + 1] = n;
    modes[i * 3 + 2] = osc.amplitude;
    const [r, g, b] = hslToRgb(frequencyHue(osc.frequencyHz), 0.30, 0.85);
    colors[i * 3 + 0] = r;
    colors[i * 3 + 1] = g;
    colors[i * 3 + 2] = b;
  }

  gl.useProgram(glProgram);
  gl.uniform1i(glUniforms.voiceCount, count);
  gl.uniform3fv(glUniforms.modes, modes);
  gl.uniform3fv(glUniforms.colors, colors);
  gl.enableVertexAttribArray(glAttribs.position);
  gl.vertexAttribPointer(glAttribs.position, 2, gl.FLOAT, false, 0, 0);
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
}

// ──────────────────────────────────────────────────
// State sync via BroadcastChannel
// ──────────────────────────────────────────────────
const channel = new BroadcastChannel("drone-meditations-chladni");

channel.addEventListener("message", (e) => {
  const msg = e.data;
  if (!msg || msg.type !== "state") return;
  latestOscillators = msg.oscillators;
  lastMessageTime = Date.now();
  if (disconnected.classList.contains("shown")) {
    disconnected.classList.remove("shown");
  }
});

// Show "disconnected" hint if the main window has been quiet for ~3s
setInterval(() => {
  if (!latestOscillators) return;
  if (Date.now() - lastMessageTime > 3000) {
    disconnected.classList.add("shown");
  }
}, 1000);

// Initial poke — the main window may not have broadcasted recently because
// nothing's changing. Ask it to send the current state.
channel.postMessage({ type: "request-state" });

// ESC closes the window
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape") window.close();
});

initWebGL();
resize();
window.addEventListener("resize", resize);
render();
