// Web MIDI input — listen for note-on events from a connected controller
// and (currently) set the chord generator's root key + octave to the
// played note. Hot-plug supported: connecting/disconnecting devices mid-
// session reattaches handlers automatically via onstatechange.

let access = null;
let isOnUserGesture = false;
let onNote = null;          // callback({ midi, velocity, source })
let onStatusChange = null;  // callback({ available, devices: [{name, manufacturer}], lastError })

/**
 * Initialize Web MIDI. Must be called from a user gesture (click) the
 * first time on iOS Safari and some Chrome configs; subsequent calls
 * reuse the cached access object.
 */
export async function initMIDI({ onNoteFn, onStatusFn } = {}) {
  if (onNoteFn) onNote = onNoteFn;
  if (onStatusFn) onStatusChange = onStatusFn;
  if (access) {
    publishStatus();
    return access;
  }
  if (!navigator.requestMIDIAccess) {
    publishStatus({ available: false, lastError: "Web MIDI not supported in this browser" });
    return null;
  }
  try {
    access = await navigator.requestMIDIAccess({ sysex: false });
    access.onstatechange = () => {
      attachInputHandlers();
      publishStatus();
    };
    attachInputHandlers();
    publishStatus();
    return access;
  } catch (err) {
    publishStatus({ available: false, lastError: err?.message || "MIDI access denied" });
    return null;
  }
}

function attachInputHandlers() {
  if (!access) return;
  for (const input of access.inputs.values()) {
    // Replace any prior handler so reconnects work cleanly.
    input.onmidimessage = handleMessage;
  }
}

function handleMessage(event) {
  const [status, data1, data2] = event.data;
  // Note-on with non-zero velocity. Some controllers send note-on
  // velocity-0 as note-off — treat those as off too.
  if ((status & 0xf0) === 0x90 && data2 > 0) {
    if (onNote) onNote({ midi: data1, velocity: data2, source: event.target?.name || "MIDI" });
  }
}

function publishStatus(override) {
  if (!onStatusChange) return;
  if (override) { onStatusChange(override); return; }
  if (!access) {
    onStatusChange({ available: false, devices: [], lastError: null });
    return;
  }
  const devices = Array.from(access.inputs.values()).map((d) => ({
    name: d.name || "Unnamed",
    manufacturer: d.manufacturer || ""
  }));
  onStatusChange({ available: true, devices, lastError: null });
}

/// MIDI note number (60 = C4) → { pitchClassId 0..11, octave } compatible
/// with the chord generator's key/octave fields.
export function midiToKeyOctave(midi) {
  const pitchClassId = ((midi % 12) + 12) % 12;
  const octave = Math.floor(midi / 12) - 1;
  return { pitchClassId, octave };
}
