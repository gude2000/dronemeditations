import Foundation
import Combine

/// Transport + countdown timer for the meditation session.
/// Owns the audio engine lifecycle and publishes elapsed/remaining state.
@MainActor
final class DroneController: ObservableObject {
    enum State: Equatable {
        case stopped
        case playing
        case paused
    }

    @Published private(set) var state: State = .stopped
    /// Selected session length in seconds. 0 means "open / no auto-stop".
    @Published var sessionDuration: TimeInterval = 15 * 60
    @Published private(set) var elapsed: TimeInterval = 0

    var remaining: TimeInterval {
        guard sessionDuration > 0 else { return .infinity }
        return max(0, sessionDuration - elapsed)
    }

    private let engine: AudioEngine
    private var ticker: Timer?
    private var lastTickDate: Date?

    /// Reasonable preset choices for the duration picker.
    static let durationChoices: [TimeInterval] = [
        5 * 60, 10 * 60, 15 * 60, 20 * 60, 30 * 60, 45 * 60, 60 * 60, 0
    ]

    init(engine: AudioEngine) {
        self.engine = engine
    }

    func play() {
        let fromStopped = (state == .stopped)
        do {
            try engine.start()
        } catch {
            print("AudioEngine start failed: \(error)")
            return
        }
        if state != .playing {
            // Fresh start gets a 3s meditation-fade; resume from pause is 1s.
            engine.fadeInMaster(seconds: fromStopped ? 3.0 : 1.0)
            lastTickDate = Date()
            startTicker()
            state = .playing
        }
    }

    func pause() {
        guard state == .playing else { return }
        stopTicker()
        state = .paused
        // Short fade down before suspending so we don't click.
        Task { @MainActor in
            await engine.fadeOutMaster(seconds: 0.4)
            engine.stop()
        }
    }

    func stop() {
        stopTicker()
        elapsed = 0
        lastTickDate = nil
        state = .stopped
        // If recording is active, finalize the file first so the captured
        // fade-out is part of the export. The completed URL is held in
        // `lastRecordingURL` for the UI to surface via the share sheet.
        if engine.isRecording {
            lastRecordingURL = engine.stopRecording()
            isRecording = false
        }
        // UI updates immediately; audio fades over 8 seconds, then engine tears down.
        Task { @MainActor in
            await engine.fadeOutMaster(seconds: 8.0)
            engine.stop()
        }
    }

    // MARK: - Recording

    /// Whether a session recording is currently being captured to disk.
    @Published private(set) var isRecording: Bool = false
    /// URL of the most recently finished recording. The UI clears it once
    /// it has been presented (e.g. via a share sheet).
    @Published var lastRecordingURL: URL?

    /// Toggle recording on/off. Recording only works while the engine is
    /// running, so a recording started while playing will capture from now
    /// until either toggleRecord() is called again or the user hits Stop
    /// (which finalizes automatically).
    func toggleRecord() {
        if engine.isRecording {
            lastRecordingURL = engine.stopRecording()
            isRecording = false
        } else {
            // Make sure the engine is actually running before tapping it.
            if state != .playing {
                play()
            }
            _ = engine.startRecording()
            isRecording = true
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard state == .playing else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTickDate ?? now)
        lastTickDate = now
        elapsed += dt
        if sessionDuration > 0 && elapsed >= sessionDuration {
            stop()
        }
    }
}
