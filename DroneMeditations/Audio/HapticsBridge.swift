import Foundation
import CoreHaptics
import UIKit

/// Optional subtle haptic feedback synced to the slowest active LFO across
/// all voices. Three-state intensity selector: Off / Light / Heavy. Light
/// halves the computed per-tap intensity for a barely-there pulse; Heavy
/// is the original (v1.0) behavior. The user cycles modes by tapping the
/// haptics icon in the master row. State persists in UserDefaults.
@MainActor
final class HapticsBridge: ObservableObject {

    /// Intensity tiers. `off` = no taps at all. `light` = 0.5× scale on
    /// the computed per-tap intensity. `heavy` = 1.0× scale (original
    /// v1.0 behavior).
    enum Mode: String, CaseIterable {
        case off, light, heavy

        /// Multiplier applied to the per-tap intensity computed from the
        /// slowest active LFO's depth.
        var intensityScale: Float {
            switch self {
            case .off:   return 0
            case .light: return 0.5
            case .heavy: return 1.0
            }
        }

        /// SF Symbol used by the toolbar button. Distinct glyphs make the
        /// current mode legible at a glance.
        var symbolName: String {
            switch self {
            case .off:   return "waveform.path"
            case .light: return "waveform.path.badge.minus"
            case .heavy: return "waveform.path.ecg"
            }
        }

        /// Cycle order shown in the toolbar: Off → Light → Heavy → Off.
        var next: Mode {
            switch self {
            case .off:   return .light
            case .light: return .heavy
            case .heavy: return .off
            }
        }
    }

    private static let defaultsKey = "DroneMeditations.HapticsMode"

    /// The currently active mode. Setting this restarts (or stops) the
    /// pulse timer and persists the choice to UserDefaults so it survives
    /// app relaunches.
    @Published var mode: Mode = {
        let raw = UserDefaults.standard.string(forKey: HapticsBridge.defaultsKey) ?? Mode.off.rawValue
        return Mode(rawValue: raw) ?? .off
    }() {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: HapticsBridge.defaultsKey)
            if mode == .off { stop() }
            else if oldValue == .off { startEngineAndTimer() }
            // light↔heavy with engine already running: scheduleNextTick()
            // will pick up the new scale on the next tap, no restart needed.
        }
    }

    /// Backwards-compat shim. Some legacy call sites still flip a Bool;
    /// keep the binding alive but map it through Mode. Setting `true`
    /// from the legacy path means "heavy" (the v1.0 default behavior).
    var isEnabled: Bool {
        get { mode != .off }
        set { mode = newValue ? .heavy : .off }
    }

    private var engine: CHHapticEngine?
    private var timer: Timer?
    private weak var vm: DroneViewModel?

    init(vm: DroneViewModel) {
        self.vm = vm
        // Restore engine if mode was persisted as light/heavy.
        if mode != .off { startEngineAndTimer() }
    }

    private func startEngineAndTimer() {
        // CoreHaptics requires the device to support haptic feedback —
        // every iPhone since 7 does, but iPad doesn't.
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            mode = .off
            return
        }
        if engine == nil {
            do {
                engine = try CHHapticEngine()
                try engine?.start()
                engine?.resetHandler = { [weak self] in
                    try? self?.engine?.start()
                }
                engine?.stoppedHandler = { _ in /* no-op */ }
            } catch {
                mode = .off
                return
            }
        }
        scheduleNextTick()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        engine?.stop()
        engine = nil
    }

    /// Compute the period between haptic pulses. Walks every voice's LFOs,
    /// finds the slowest non-silent one, and uses 1/rateHz. Falls back to
    /// a gentle 2-second pulse when no LFO is active. The intensity
    /// returned is the *unscaled* LFO depth; the per-tap call multiplies
    /// it by `mode.intensityScale` before firing.
    private func currentPulsePeriod() -> (period: TimeInterval, intensity: Float) {
        guard let vm = vm else { return (2.0, 0.4) }
        var slowestRate: Double = .infinity
        var bestDepth: Double = 0
        for osc in vm.oscillators {
            for lfo in osc.lfos where lfo.depth > 0.05 && lfo.rateHz > 0 {
                if lfo.rateHz < slowestRate {
                    slowestRate = lfo.rateHz
                    bestDepth = lfo.depth
                }
            }
        }
        let period = slowestRate.isFinite ? max(0.25, min(8.0, 1.0 / slowestRate)) : 2.0
        let intensity = Float(max(0.15, min(1.0, bestDepth)))
        return (period, intensity)
    }

    private func scheduleNextTick() {
        let (period, intensity) = currentPulsePeriod()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: period, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.tap(intensity: intensity)
                self?.scheduleNextTick()
            }
        }
    }

    private func tap(intensity: Float) {
        // Apply the mode's intensity scale BEFORE handing the value to
        // CoreHaptics. Light = 0.5× = a quiet brush; Heavy = 1.0× = the
        // original v1.0 pulse.
        let scaled = intensity * mode.intensityScale
        // Avoid firing barely-there events that the OS would clamp to 0
        // anyway — saves a CoreHaptics player allocation per tick.
        guard scaled > 0.02, let engine = engine else { return }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: scaled),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
            ],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // Non-fatal: drop a single tap silently.
        }
    }
}
