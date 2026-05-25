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
    ]
}
