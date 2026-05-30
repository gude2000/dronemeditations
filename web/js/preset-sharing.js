// v1.1 cross-device user-preset sharing for the web app.
//
// Mirrors the iOS .dronepreset file format so a preset saved in the
// iPhone app loads in the browser app and vice versa. The envelope is
// the same JSON shape on both platforms:
//
//   {
//     "version": 1,
//     "preset":  { …UserPreset… },
//     "samples": [ { "filename": "…", "data": "<base64>", "name": "…",
//                    "mime": "audio/wav" }, … ]
//   }
//
// On iOS the sample is identified by `sampleStoredFilename` (the file
// inside Documents/DroneSamples/). On web the sample is identified by
// `sampleRef.id` (the IndexedDB key in the `samples` store). For
// cross-platform compat the envelope uses a single string per sample
// — interpreted as a filename on iOS, as an IndexedDB id on web.

import {
  loadUserPresets, saveUserPresets, newPresetId, newSampleId,
  putSample, getSample
} from "./storage.js";

const CURRENT_VERSION = 1;
const FILE_EXTENSION = "dronepreset";

// MARK: - Export
//
// Pack a saved preset + every IndexedDB sample blob it references into
// a single .dronepreset JSON file and trigger a browser download.
// Returns true on success, false if the preset id wasn't found.
export async function exportUserPresetDownload(presetId) {
  const presets = loadUserPresets();
  const p = presets.find((x) => x.id === presetId);
  if (!p) return false;

  // Collect referenced samples once each (multiple voices may share
  // the same sample id; we embed it once and let both voices point at
  // the same filename on the receiving side).
  const samples = [];
  const seen = new Set();
  for (const v of p.oscillators || []) {
    const ref = v.sampleRef;
    if (!ref || !ref.id || seen.has(ref.id)) continue;
    seen.add(ref.id);
    try {
      const rec = await getSample(ref.id);
      if (rec && rec.blob) {
        const data = await blobToBase64(rec.blob);
        samples.push({
          filename: ref.id,                          // doubles as IndexedDB id on re-import
          name: ref.name || rec.name || "sample",
          mime: rec.type || rec.blob.type || "audio/wav",
          data
        });
      }
    } catch { /* sample missing — skip */ }
  }

  const envelope = { version: CURRENT_VERSION, preset: p, samples };
  const json = JSON.stringify(envelope, null, 2);
  const blob = new Blob([json], { type: "application/x-dronepreset" });
  const url = URL.createObjectURL(blob);

  // Trigger a download via an off-screen anchor — works in every
  // mainstream browser without permission prompts. The browser cleans
  // up the object URL after a microtask; revoke explicitly so memory
  // doesn't leak if the user spams Share.
  const a = document.createElement("a");
  a.href = url;
  a.download = `${sanitizeFilename(p.name)}.${FILE_EXTENSION}`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return true;
}

// MARK: - Import
//
// Decode a .dronepreset (or compatible JSON) File the user picked,
// materialize any embedded samples into IndexedDB, and append the
// preset to userPresets with a freshly-issued id so importing twice
// produces two distinct entries. Returns the preset's display name on
// success, throws an Error on a malformed file.
export async function importUserPresetFromFile(file) {
  if (!file) throw new Error("No file picked.");
  const text = await file.text();
  let env;
  try { env = JSON.parse(text); }
  catch { throw new Error("This file isn't a Drone Meditations preset."); }

  if (typeof env !== "object" || env === null || !env.preset) {
    throw new Error("Preset file is missing the preset payload.");
  }
  if (typeof env.version === "number" && env.version > CURRENT_VERSION) {
    throw new Error(
      `This preset uses a newer format (v${env.version}) than this version of Drone Meditations understands. Please refresh.`
    );
  }

  // Materialize each embedded sample. Use the envelope's filename as
  // the IndexedDB id so the preset's sampleRef.id (which equals the
  // filename) still resolves on this device. If the same id already
  // exists locally, leave it — could be a previous import or another
  // preset on this device.
  for (const s of env.samples || []) {
    if (!s || !s.filename || !s.data) continue;
    const existing = await getSample(s.filename).catch(() => null);
    if (existing) continue;
    const bytes = base64ToBytes(s.data);
    const blob = new Blob([bytes], { type: s.mime || "audio/wav" });
    await putSample(s.filename, blob, s.name || "sample", s.mime || "audio/wav");
  }

  // Re-id the preset so duplicates never overwrite. Preserve
  // createdAt so the receiver sees the author's save time.
  const orig = env.preset;
  const p = {
    id: newPresetId(),
    name: orig.name || "Imported Preset",
    createdAt: orig.createdAt || new Date().toISOString(),
    keyId: orig.keyId,
    octave: orig.octave,
    chordId: orig.chordId,
    tuningId: orig.tuningId,
    masterVolume: orig.masterVolume,
    oscillators: orig.oscillators || []
  };

  const list = loadUserPresets();
  saveUserPresets([p, ...list]);
  return p.name;
}

// MARK: - Helpers

function sanitizeFilename(name) {
  let s = (name || "").trim();
  if (!s) s = "Drone Preset";
  s = s.replace(/[/:\\?*"<>|]/g, "-");
  if (s.length > 80) s = s.slice(0, 80);
  return s;
}

/**
 * Read a Blob as base64 (without the data: URI prefix).
 * Uses FileReader so we don't pull the bytes into a giant intermediate
 * string in JS land — for a multi-MB sample this matters.
 */
function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result; // "data:<mime>;base64,<payload>"
      const idx = String(result).indexOf(",");
      resolve(idx >= 0 ? String(result).slice(idx + 1) : "");
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/** Decode base64 → Uint8Array. atob() works on every modern browser. */
function base64ToBytes(b64) {
  const binary = atob(String(b64));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}
