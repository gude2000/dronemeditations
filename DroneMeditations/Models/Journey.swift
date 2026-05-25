import Foundation

/// A scripted multi-stage meditation session. Each stage applies a Preset
/// and a drift scene for `durationSec`, then auto-advances. When the last
/// stage ends, the transport's session-auto-stop fade kicks in.
struct Journey: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let stages: [Stage]

    struct Stage: Hashable {
        let durationSec: TimeInterval
        let presetName: String       // matches Preset.name
        let driftSceneId: String     // matches a DroneViewModel.driftScenes id
        let hint: String
    }

    var totalSeconds: TimeInterval {
        stages.reduce(0) { $0 + $1.durationSec }
    }
}

extension Journey {
    /// Curated set of journeys. Preset names + drift scene ids must match
    /// what's defined in Preset.swift and DroneViewModel.driftScenes — if
    /// either is renamed, update here.
    static let all: [Journey] = [
        Journey(
            id: "sundown",
            name: "Sundown",
            description: "Bright clarity slowly descending into deep rest. Good for end of day.",
            stages: [
                Stage(durationSec:  5*60, presetName: "Solfeggio 528 Hz",        driftSceneId: "glacial",   hint: "Pure 528 Hz · gentle wander"),
                Stage(durationSec: 10*60, presetName: "Scriabin 2 — Mystic Upper", driftSceneId: "breathing", hint: "Mystic chord · breathing"),
                Stage(durationSec:  5*60, presetName: "Sable's Chord",           driftSceneId: "descend",   hint: "φ-tuned descent"),
            ]
        ),
        Journey(
            id: "awakening",
            name: "Awakening",
            description: "Deep root rising into bright resonance. Good for morning focus.",
            stages: [
                Stage(durationSec: 5*60, presetName: "OM 136.1 Hz",           driftSceneId: "off",     hint: "OM 136.1 Hz · still"),
                Stage(durationSec: 5*60, presetName: "Harmonic Series 1:2:3:4", driftSceneId: "ascend",  hint: "Harmonic series · ascending"),
                Stage(durationSec: 5*60, presetName: "Just Major Triad 4:5:6", driftSceneId: "aurora",  hint: "Just major triad · aurora"),
            ]
        ),
        Journey(
            id: "floating",
            name: "Floating",
            description: "Sustained ambient texture for long sessions or sleep onset.",
            stages: [
                Stage(durationSec: 10*60, presetName: "Phi-Tuned Field",            driftSceneId: "aurora",   hint: "Phi field · aurora"),
                Stage(durationSec: 10*60, presetName: "Complex Schumann",           driftSceneId: "tidal",    hint: "Schumann layers · tidal"),
                Stage(durationSec: 10*60, presetName: "Ligeti 2 — Whole-Tone Cluster", driftSceneId: "pendulum", hint: "Whole-tone cluster · pendulum"),
            ]
        ),
        Journey(
            id: "centering",
            name: "Centering",
            description: "Short focus session — 10 minutes total, ideal for a quick reset.",
            stages: [
                Stage(durationSec: 3*60, presetName: "Hypogeum 111 Hz",                 driftSceneId: "off",     hint: "Hypogeum 111 Hz · still"),
                Stage(durationSec: 4*60, presetName: "Jose & Alex Phi Augmented Chord", driftSceneId: "glacial", hint: "Phi-augmented · wander"),
                Stage(durationSec: 3*60, presetName: "Earth (Schumann fundamental)",    driftSceneId: "downUp",  hint: "Schumann fundamental · return"),
            ]
        ),
        Journey(
            id: "spiralDescent",
            name: "Spiral Descent",
            description: "Outer voices spiral around a central drone, slowly descending. 25 min.",
            stages: [
                Stage(durationSec:  5*60, presetName: "Perfect Fifths 2:3:9/2:27/4", driftSceneId: "spiral",      hint: "Perfect fifths · spiral"),
                Stage(durationSec: 10*60, presetName: "Fibonacci Quartet",           driftSceneId: "convergence", hint: "Fibonacci · converging"),
                Stage(durationSec: 10*60, presetName: "Octave Stack 1:2:4:8",        driftSceneId: "descend",     hint: "Octave stack · descending"),
            ]
        ),
        Journey(
            id: "bodyScan",
            name: "Body Scan",
            description: "Progressive solfeggio sweep — root chakra up through the crown. 20 min.",
            stages: [
                Stage(durationSec: 4*60, presetName: "Solfeggio 174 Hz", driftSceneId: "off",       hint: "174 Hz · feet, grounding"),
                Stage(durationSec: 4*60, presetName: "Solfeggio 396 Hz", driftSceneId: "glacial",   hint: "396 Hz · root"),
                Stage(durationSec: 4*60, presetName: "Solfeggio 528 Hz", driftSceneId: "breathing", hint: "528 Hz · heart"),
                Stage(durationSec: 4*60, presetName: "Solfeggio 741 Hz", driftSceneId: "aurora",    hint: "741 Hz · throat / intuition"),
                Stage(durationSec: 4*60, presetName: "Solfeggio 963 Hz", driftSceneId: "tidal",     hint: "963 Hz · crown"),
            ]
        ),
        Journey(
            id: "cathedral",
            name: "Cathedral",
            description: "Sacred geometry — phi, just intonation, hypogeum resonance. 20 min.",
            stages: [
                Stage(durationSec:  5*60, presetName: "Hypogeum 111 Hz",        driftSceneId: "aurora",   hint: "Hypogeum 111 Hz · aurora"),
                Stage(durationSec: 10*60, presetName: "Just Major Triad 4:5:6", driftSceneId: "pendulum", hint: "Just major triad · pendulum"),
                Stage(durationSec:  5*60, presetName: "Phi-Tuned Field",        driftSceneId: "glacial",  hint: "Phi field · settle"),
            ]
        ),
        Journey(
            id: "mountainClimb",
            name: "Mountain Climb",
            description: "Slowly ascending energy from deep root to crown. 30 min.",
            stages: [
                Stage(durationSec: 10*60, presetName: "OM 136.1 Hz",      driftSceneId: "off",     hint: "OM 136.1 Hz · steady"),
                Stage(durationSec: 10*60, presetName: "Solfeggio 528 Hz", driftSceneId: "ascend",  hint: "528 Hz · ascending"),
                Stage(durationSec: 10*60, presetName: "Solfeggio 963 Hz", driftSceneId: "spiral",  hint: "963 Hz · crown spiral"),
            ]
        ),
        Journey(
            id: "vespers",
            name: "Vespers",
            description: "Evening contemplation — mystic chords descending into rest. 20 min.",
            stages: [
                Stage(durationSec:  5*60, presetName: "Solfeggio 432 Hz (Verdi)", driftSceneId: "downUp",   hint: "Verdi 432 · breath"),
                Stage(durationSec: 10*60, presetName: "Scriabin 1 — Mystic Core", driftSceneId: "pendulum", hint: "Scriabin mystic · pendulum"),
                Stage(durationSec:  5*60, presetName: "Sable's Chord",            driftSceneId: "descend",  hint: "Sable's chord · settling"),
            ]
        ),
        Journey(
            id: "crystalCave",
            name: "Crystal Cave",
            description: "Bright high-frequency textures with stereo motion. 25 min.",
            stages: [
                Stage(durationSec: 10*60, presetName: "Just Major Triad 4:5:6",        driftSceneId: "aurora",   hint: "Just major · aurora"),
                Stage(durationSec: 10*60, presetName: "Fibonacci Quartet",             driftSceneId: "crossing", hint: "Fibonacci · crossing paths"),
                Stage(durationSec:  5*60, presetName: "Jose & Alex Phi Augmented Chord", driftSceneId: "glacial",  hint: "Phi-augmented · resolve"),
            ]
        ),
        Journey(
            id: "phiSpiral",
            name: "Phi Spiral",
            description: "Golden-ratio frequencies, slowly turning. 30 min.",
            stages: [
                Stage(durationSec: 10*60, presetName: "Phi-Tuned Field",                  driftSceneId: "spiral",    hint: "Phi field · spiral"),
                Stage(durationSec: 10*60, presetName: "Jose & Alex Phi Augmented Chord",  driftSceneId: "breathing", hint: "Phi-augmented · breathing"),
                Stage(durationSec: 10*60, presetName: "Sable's Chord",                    driftSceneId: "downUp",    hint: "Sable · breath"),
            ]
        ),
        Journey(
            id: "quartz",
            name: "Quartz",
            description: "Clean integer-ratio harmonics — the bones of pitched sound. 15 min.",
            stages: [
                Stage(durationSec: 5*60, presetName: "Harmonic Series 1:2:3:4", driftSceneId: "off",         hint: "1:2:3:4 · still"),
                Stage(durationSec: 5*60, presetName: "Octave Stack 1:2:4:8",    driftSceneId: "ascend",      hint: "Octave stack · ascending"),
                Stage(durationSec: 5*60, presetName: "Fibonacci Quartet",       driftSceneId: "convergence", hint: "Fibonacci · converging"),
            ]
        ),
        Journey(
            id: "lullaby",
            name: "Lullaby",
            description: "Short sleep-onset session — theta + delta carriers. 10 min.",
            stages: [
                Stage(durationSec: 5*60, presetName: "Theta Triad",            driftSceneId: "breathing", hint: "Theta triad · breathing"),
                Stage(durationSec: 5*60, presetName: "Delta 4 Hz (Deep Sleep)", driftSceneId: "downUp",    hint: "Delta 4 Hz · into sleep"),
            ]
        ),
        Journey(
            id: "tibetanBowl",
            name: "Tibetan Bowl",
            description: "Classic drone meditation — three deep tones, glacial throughout. 15 min.",
            stages: [
                Stage(durationSec: 5*60, presetName: "OM 136.1 Hz",               driftSceneId: "glacial", hint: "OM 136.1 Hz · settle"),
                Stage(durationSec: 5*60, presetName: "Hypogeum 111 Hz",           driftSceneId: "glacial", hint: "Hypogeum 111 Hz · deepen"),
                Stage(durationSec: 5*60, presetName: "Earth (Schumann fundamental)", driftSceneId: "glacial", hint: "Earth Schumann · resolve"),
            ]
        ),
        Journey(
            id: "stormFront",
            name: "Storm Front",
            description: "Tension building then resolving — Ligeti clusters into convergence. 12 min.",
            stages: [
                Stage(durationSec: 4*60, presetName: "Ligeti 1 — Chromatic Cluster", driftSceneId: "glacial",     hint: "Chromatic cluster · wander"),
                Stage(durationSec: 4*60, presetName: "Ligeti 3 — Microtone Cluster", driftSceneId: "crossing",    hint: "Quartertone cluster · crossing"),
                Stage(durationSec: 4*60, presetName: "OM 136.1 Hz",                  driftSceneId: "convergence", hint: "OM · convergence resolve"),
            ]
        ),
    ]
}
