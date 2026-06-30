import Foundation
import Combine

/// Polls `engine.transportElapsed` at ~30 Hz and fires automation events
/// when their `timeSec` passes. Pure scheduler — the actual action work
/// (chord changes, fade ramps, etc.) is delegated to a handler closure
/// supplied by the owner (typically DroneViewModel.dispatchAutomation).
///
/// Lifecycle is driven from DroneController:
///   - `play()`  → `start(events:)` with the current sorted timeline
///   - `pause()` → `pause()` — freezes time, doesn't reset index
///   - `stop()`  → `reset()` — index back to 0, ready for next Play
///
/// All work runs on the main actor (the dispatcher reads `transportElapsed`
/// via a Timer scheduled on the main run loop, and calls the action
/// handler synchronously on the main thread). The timer interval is short
/// (33 ms) but the per-tick workload is trivial: a single time comparison
/// plus an index advance.
@MainActor
final class AutomationDispatcher {
    // MARK: - Inputs
    private weak var engine: AudioEngine?
    /// Called once per fired event. Handler runs on the main actor.
    private let onFire: (AutomationEvent) -> Void

    // MARK: - State
    private var events: [AutomationEvent] = []      // sorted by timeSec at start
    private var nextEventIndex: Int = 0
    private var timer: Timer?
    private var isPaused: Bool = false
    /// Generation counter — invalidated by reset()/pause()/start() so
    /// stale Timer fires (or in-flight closures) bail before doing work.
    private var generation: Int = 0
    /// Loop config snapshot taken at start(); changes mid-play don't apply
    /// until the next start().
    private var totalDurationSec: Double = 0
    private var loop: Bool = false
    /// Cumulative time offset for loop wraps. We don't touch
    /// engine.transportElapsed (which would be invasive); instead the
    /// dispatcher tracks how many full loops have elapsed and subtracts
    /// to get the "phase within current loop." Updated when a loop wrap
    /// is detected, NOT every tick.
    private var loopOffsetSec: Double = 0

    init(engine: AudioEngine, onFire: @escaping (AutomationEvent) -> Void) {
        self.engine = engine
        self.onFire = onFire
    }

    // MARK: - Public

    /// Begin scheduling. Resets index, starts the polling Timer.
    /// Call at the moment transport.play() resets engine.transportElapsed.
    func start(events: [AutomationEvent], totalDurationSec: Double, loop: Bool) {
        cancelTimer()
        generation &+= 1
        // Snapshot a sorted, deduplicated copy so UI edits during play
        // don't shift our cursor.
        self.events = events.sorted { $0.timeSec < $1.timeSec }
        self.nextEventIndex = 0
        self.totalDurationSec = totalDurationSec
        self.loop = loop
        self.loopOffsetSec = 0
        self.isPaused = false
        guard !self.events.isEmpty else { return }
        scheduleTimer()
    }

    /// Freeze: no more events fire and the index stays put. transportElapsed
    /// is already frozen by the engine on pause, so resuming is effectively
    /// a no-op except for re-enabling the Timer.
    func pause() {
        isPaused = true
        cancelTimer()
    }

    /// Resume polling after a pause(). If never started, this is a no-op.
    func resume() {
        guard !events.isEmpty else { return }
        isPaused = false
        scheduleTimer()
    }

    /// Full reset: clear schedule + index. Call on transport.stop().
    func reset() {
        cancelTimer()
        events.removeAll(keepingCapacity: true)
        nextEventIndex = 0
        loopOffsetSec = 0
        isPaused = false
        generation &+= 1
    }

    // MARK: - Private

    private func scheduleTimer() {
        // 33 ms ≈ 30 Hz. Plenty granular for "fire on second-level
        // markers"; cheaper than CADisplayLink and doesn't tie us to
        // the screen refresh rate when the device is locked.
        let myGen = generation
        let t = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == myGen else { return }
                self.tick()
            }
        }
        // Common run-loop mode so the timer keeps firing during scroll /
        // sheet presentation (default mode pauses during gestures).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !isPaused, let engine = engine else { return }
        // engine.transportElapsed is Double seconds since last Play, or
        // .nan when stopped. NaN comparisons always return false, so
        // this naturally pauses when stopped.
        let rawElapsed = engine.transportElapsed
        guard rawElapsed.isFinite else { return }

        // Loop wrap. We don't reset engine.transportElapsed (which
        // would be invasive); the dispatcher tracks how much of the
        // raw elapsed has been "consumed" by prior loops via
        // loopOffsetSec and works in phase-within-current-loop.
        if loop && totalDurationSec > 0 {
            while rawElapsed - loopOffsetSec >= totalDurationSec {
                loopOffsetSec += totalDurationSec
                nextEventIndex = 0
            }
        }
        let elapsed = rawElapsed - loopOffsetSec

        // Fire any events whose time has passed since the last tick.
        // Loop instead of single-fire so a chunk of fast events at the
        // same timeSec all fire on the same tick.
        while nextEventIndex < events.count
            && events[nextEventIndex].timeSec <= elapsed
        {
            let event = events[nextEventIndex]
            nextEventIndex += 1
            onFire(event)
        }
        if nextEventIndex >= events.count && !loop {
            cancelTimer()
        }
    }
}
