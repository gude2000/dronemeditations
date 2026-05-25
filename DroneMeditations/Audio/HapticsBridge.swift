import Foundation
import CoreHaptics
import UIKit

/// Optional subtle haptic feedback synced to the slowest active LFO across
/// all voices. When enabled, fires a transient tap on each LFO cycle with
/// intensity proportional to the LFO's depth. Off by default — the user
/// toggles it from the controls overlay.
@MainActor
final class HapticsBridge: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled { startEngineAndTimer() } else { stop() }
        }
    }

    private var engine: CHHapticEngine?
    private var timer: Timer?
    private weak var vm: DroneViewModel?

    init(vm: DroneViewModel) {
        self.vm = vm
    }

    private func startEngineAndTimer() {
        // CoreHaptics requires the device to support haptic feedback —
        // every iPhone since 7 does, but iPad doesn't.
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            isEnabled = false
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
                isEnabled = false
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
    /// a gentle 2-second pulse when no LFO is active.
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
        guard let engine = engine else { return }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
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
