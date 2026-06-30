import Foundation

// MARK: - VoiceFilter

/// Which voice(s) an automation event targets.
/// `.all` applies the action to the whole patch; `.oscillator(n)` targets
/// one voice index (0…3). Per the v1.1 spec, `.all` events affect every
/// voice regardless of whether the voice has been faded-in or muted by an
/// earlier event — predictable rule, queues the action even for voices
/// that don't "exist" yet at event time.
enum VoiceFilter: Hashable, Codable {
    case all
    case oscillator(Int)

    var displayName: String {
        switch self {
        case .all: return "All voices"
        case .oscillator(let i): return "OSC \(i + 1)"
        }
    }
}

// MARK: - Action

/// What an automation event does when it fires. Phase A ships the two
/// most useful types (chord change + fade in/out). Phase B adds
/// `waveformSet` / `levelSet` / `muteToggle`. Waveform morphing,
/// curve types, BPM-change, and drift-mode events are intentionally
/// out of scope for v1.1.
enum AutomationAction: Hashable, Codable {
    case chordChange(keyRaw: Int, chordId: String)
    case fadeIn(durationSec: Double)
    case fadeOut(durationSec: Double)
}

extension AutomationAction {
    /// One-line label for list rows.
    func summary() -> String {
        switch self {
        case .chordChange(let keyRaw, let chordId):
            let keyName = PitchClass(rawValue: keyRaw)?.displayName ?? "?"
            return "Chord: \(keyName) \(chordId)"
        case .fadeIn(let sec):
            return "Fade in (\(formatSec(sec)))"
        case .fadeOut(let sec):
            return "Fade out (\(formatSec(sec)))"
        }
    }

    private func formatSec(_ s: Double) -> String {
        if s == floor(s) { return "\(Int(s))s" }
        return String(format: "%.1fs", s)
    }
}

// MARK: - AutomationEvent

/// One scheduled action at a single point in time.
struct AutomationEvent: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var timeSec: Double
    var voice: VoiceFilter
    var action: AutomationAction

    init(id: UUID = UUID(), timeSec: Double, voice: VoiceFilter, action: AutomationAction) {
        self.id = id
        self.timeSec = max(0, timeSec)
        self.voice = voice
        self.action = action
    }
}

// MARK: - AutomationTimeline

/// All scheduled events for a single patch, plus duration / loop config.
/// `totalDurationSec = 0` (the v1.1 default per the locked design) means
/// "until manual stop" — events fire once and the timeline holds. Setting
/// a positive duration with `loop = true` wraps back to 0 at the end.
struct AutomationTimeline: Codable, Equatable {
    /// Schema version embedded in `.dronepreset` files for forward-compat.
    /// Bump only when the on-disk shape changes incompatibly.
    var schemaVersion: Int = 1
    var totalDurationSec: Double = 0
    var loop: Bool = false
    /// Stored unsorted (UI may insert at any time). Dispatcher sorts by
    /// timeSec at Play.
    var events: [AutomationEvent] = []

    var isEmpty: Bool { events.isEmpty }

    /// Soft cap warning threshold (per the ROADMAP risk note).
    static let softCapEvents = 50
    /// Hard cap — UI should refuse to insert beyond this.
    static let hardCapEvents = 200

    /// Events sorted ascending by time, ready for the dispatcher.
    var sortedEvents: [AutomationEvent] {
        events.sorted { $0.timeSec < $1.timeSec }
    }
}

// MARK: - Codable shape note
//
// `AutomationAction` uses Swift's synthesized enum-with-associated-values
// Codable, which writes a discriminated key per case. Sample shape:
//
//   {"chordChange": {"keyRaw": 9, "chordId": "Minor 7"}}
//   {"fadeIn":      {"durationSec": 3.0}}
//
// `VoiceFilter` similarly:
//
//   "all"
//   {"oscillator": {"_0": 1}}
//
// The web `.dronepreset` writer will need to match this exact shape on its
// end so cross-platform round-trip stays clean — that's part of Phase C.
