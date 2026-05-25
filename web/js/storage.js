// User-preset persistence.
//
// Preset metadata (per-osc settings) lives in localStorage as JSON — small,
// synchronous, fine for a few hundred presets.
// Sample audio blobs live in IndexedDB (`dronemeditations` DB, `samples`
// store) keyed by a generated id. The preset JSON references samples by
// id so multiple presets can share the same underlying file without dup.

const DB_NAME = "dronemeditations";
const DB_VERSION = 1;
const SAMPLE_STORE = "samples";
const PRESETS_KEY = "dronemeditations:user-presets";

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(SAMPLE_STORE)) {
        db.createObjectStore(SAMPLE_STORE, { keyPath: "id" });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx(mode, fn) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const t = db.transaction(SAMPLE_STORE, mode);
    const store = t.objectStore(SAMPLE_STORE);
    const result = fn(store);
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
  });
}

export async function putSample(id, blob, name, type) {
  return tx("readwrite", (s) => s.put({ id, blob, name, type }));
}

export async function getSample(id) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const t = db.transaction(SAMPLE_STORE, "readonly");
    const req = t.objectStore(SAMPLE_STORE).get(id);
    req.onsuccess = () => resolve(req.result || null);
    req.onerror = () => reject(req.error);
  });
}

export async function deleteSample(id) {
  return tx("readwrite", (s) => s.delete(id));
}

// ─── preset list (localStorage) ──────────────────────────────

export function loadUserPresets() {
  try {
    const raw = localStorage.getItem(PRESETS_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export function saveUserPresets(list) {
  localStorage.setItem(PRESETS_KEY, JSON.stringify(list));
}

export function newPresetId() {
  return `preset-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function newSampleId() {
  return `sample-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

// ─── per-voice presets (localStorage) ────────────────────────

const VOICE_PRESETS_KEY = "dronemeditations:voice-presets";

export function loadVoicePresets() {
  try {
    const raw = localStorage.getItem(VOICE_PRESETS_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch { return []; }
}

export function saveVoicePresets(list) {
  localStorage.setItem(VOICE_PRESETS_KEY, JSON.stringify(list));
}

export function newVoicePresetId() {
  return `voice-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}
