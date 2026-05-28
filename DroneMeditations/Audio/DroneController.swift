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

    /// The async Task spawned by the most recent pause()/stop() to run
    /// the fade-out and then call engine.stop(). Held onto so that a
    /// subsequent play() can cancel it BEFORE its sleep wakes up — without
    /// this, the Task fires engine.stop() on whatever audio the user has
    /// since resumed. Symptom: tap Stop, tap Play within 5 s, audio
    /// resumes, then ~5 s after the original Stop the audio cuts off
    /// silently as the stale Task wakes up and slams volume to 0.
    private var pendingFadeOutTask: Task<Void, Never>?

    /// Reasonable preset choices for the duration picker.
    static let durationChoices: [TimeInterval] = [
        5 * 60, 10 * 60, 15 * 60, 20 * 60, 30 * 60, 45 * 60, 60 * 60, 0
    ]

    init(engine: AudioEngine) {
        self.engine = engine
    }

    func play() {
        // Cancel any in-flight fade-out from a recent pause/stop so it
        // can't wake up post-sleep and slam audio to 0 / stop the engine
        // out from under the just-resumed playback. See the
        // pendingFadeOutTask comment.
        pendingFadeOutTask?.cancel()
        pendingFadeOutTask = nil
        // ALSO restore reverb settings if a stop-bloom was in flight —
        // otherwise the next play would inherit the bloomed values
        // (mix=0.85, decay=8s) instead of the user's preset settings.
        engine.cancelStopBloom()

        let fromStopped = (state == .stopped)
        // If the engine is already running (typically because Listen left
        // it running silently to avoid hardware re-init lag), treat this
        // as a quick resume even when our transport state says .stopped.
        // Otherwise the 3 s "fresh start" fade-in feels like Play is
        // laggy — the user expects instant onset since the engine was
        // already ticking under the hood.
        let engineAlreadyRunning = engine.engine.isRunning
        do {
            try engine.start()
        } catch {
            print("AudioEngine start failed: \(error)")
            return
        }
        if state != .playing {
            // Choose fade-in duration:
            //  - 3 s if this is a true cold start (engine wasn't running)
            //    — preserves the "meditative onset" for the very first
            //    play of the session.
            //  - 1 s if engine was already running (resume from pause OR
            //    play-after-Listen-close) — feels responsive.
            let fadeDuration: Double = (fromStopped && !engineAlreadyRunning) ? 3.0 : 1.0
            engine.fadeInMaster(seconds: fadeDuration)
            engine.transportElapsed = elapsed
            lastTickDate = Date()
            startTicker()
            state = .playing
        }
    }

    /// Called by ListenSheetView.onAppear BEFORE MicPitchDetector.start().
    /// Cancels any in-flight pause/stop fade Task so its scheduled
    /// engine.pause()/engine.stop() can't fire while a mic tap is
    /// installed — that race used to cause occasional NSException
    /// crashes (audio thread modifying graph while tap is active) and
    /// the "Listen picks up nothing" failure mode (engine.pause() fires
    /// during Listen, suspending the I/O render loop and starving the
    /// tap of audio buffers). Also restores reverb settings if a
    /// stop-bloom was mid-flight so Listen doesn't inherit the bloomed
    /// state. Safe to call multiple times.
    func prepareForListen() {
        pendingFadeOutTask?.cancel()
        pendingFadeOutTask = nil
        engine.cancelStopBloom()
    }

    func pause() {
        guard state == .playing else { return }
        stopTicker()
        state = .paused
        // 1.4 s exponential master fade + small triangular reverb
        // bloom (peak mix 0.25 at t=0.35 s, peak decay 3 s). Per user
        // feedback: pause is the right gesture for a "quick wind
        // down", but a touch of bloom adds atmosphere without making
        // it feel like a stop. Held onto so play() can cancel it
        // before it fires engine.stop() against resumed playback.
        pendingFadeOutTask?.cancel()
        let engineRef = engine
        pendingFadeOutTask = Task { @MainActor in
            await engineRef.pauseWithReverbBloom()
            // If the user re-pressed Play during the fade, state is no
            // longer .paused — skip the engine suspend so the now-
            // playing engine isn't interrupted.
            guard self.state == .paused else { return }
            // Use engine.pause() — NOT engine.stop() — on the pause
            // path. pause() suspends the I/O AU without tearing it
            // down, eliminating the occasional click that stop()
            // produces on real iPhone hardware (the AU rebind can
            // pop the output device). Resume on the next Play is
            // also faster since there's no HW re-init.
            //
            // Still on a detached task so the @MainActor stays
            // unblocked and UI taps stay responsive — pause() is
            // fast but the Listen mic AU teardown isn't, and we
            // want this code to be safe whether or not the mic is
            // wired in.
            Task.detached { [engineRef] in
                engineRef.pause()
            }
        }
    }

    func stop() {
        stopTicker()
        elapsed = 0
        lastTickDate = nil
        state = .stopped
        // Mark transport stopped so the per-voice timing envelopes don't
        // keep advancing while the master fade-out plays.
        engine.transportElapsed = .nan
        // If recording is active, finalize the file first so the captured
        // fade-out is part of the export. finalizeRecording() runs the
        // mastering pipeline async; the finished .m4a URL appears in
        // `lastRecordingURL` for the UI to surface via the share sheet.
        if engine.isRecording {
            finalizeRecording()
        }
        // 8 s "atmospheric stop" — per-voice reverb mix + decay ramp UP
        // over the first 3 s of the fade (bloom into space) while the
        // master volume simultaneously fades down on the logarithmic
        // curve over the full 8 s. The dry signal disappears, the wet
        // signal extends and dissolves into the room. Hides the
        // perceptual unevenness of pure amplitude fades and feels much
        // more "musical" than a flat volume drop.
        //
        // After the master hits 0, voice reverb settings are restored
        // automatically (by stopWithReverbBloom → cancelStopBloom) so
        // the next Play resumes with the user's preset reverb intact.
        //
        // Pause stays at the snappier 1.2 s exponential — it's a
        // "quick wind down" gesture rather than a "settle into space"
        // one.
        pendingFadeOutTask?.cancel()
        let engineRef = engine
        pendingFadeOutTask = Task { @MainActor in
            // 8 s fade, bloom peaking 30 % in (at t≈2.4 s) with mix=0.7
            // and decay=7 s — then the bloom ramps BACK down over the
            // remaining 5.6 s so the wet signal joins the master fade
            // instead of holding loud and then collapsing at the end.
            // User confirmed the bloom feels good; bumped peakMix
            // 0.50→0.70 (more wash) and peakDecay 6→7 s (a touch
            // longer hall) per user request.
            await engineRef.stopWithReverbBloom(
                fadeDuration: 8.0,
                peakAt: 0.30,
                peakMix: 0.70,
                peakDecay: 7.0
            )
            // If the user re-pressed Play during the fade, state is no
            // longer .stopped — skip the engine stop. (Play also calls
            // engine.cancelStopBloom() so reverb is restored even if
            // the fade Task was cancelled mid-bloom.)
            guard self.state == .stopped else { return }
            // engine.stop() can block on real hardware when the mic
            // input AU is wired into the graph (post-Listen). Detach
            // so UI stays responsive — see pause() for details.
            Task.detached { [engineRef] in
                engineRef.stop()
            }
        }
    }

    // MARK: - Recording

    /// Whether a session recording is currently being captured to disk.
    @Published private(set) var isRecording: Bool = false
    /// True while the mastering pipeline runs after recording stops.
    /// UI surfaces this as a brief "Mastering…" spinner so the user knows
    /// the share button is coming.
    @Published private(set) var isMastering: Bool = false
    /// URL of the most recently finished + mastered recording (M4A). The
    /// UI clears it once it has been presented (e.g. via a share sheet).
    @Published var lastRecordingURL: URL?
    /// Last mastering error, surfaced in the UI as a toast. nil = no error.
    @Published var lastMasteringError: String?
    /// Name of the active preset when recording started, used in the
    /// exported file's title metadata.
    private var recordingPresetName: String?

    /// Toggle recording on/off. Recording only works while the engine is
    /// running, so a recording started while playing will capture from now
    /// until either toggleRecord() is called again or the user hits Stop
    /// (which finalizes automatically). When stopping, the raw CAF capture
    /// is async-mastered into a release-ready .m4a (AAC + LUFS-style
    /// normalization + 2s/4s fades + metadata) before being handed back
    /// to the UI in `lastRecordingURL`.
    func toggleRecord(presetName: String? = nil) {
        if engine.isRecording {
            finalizeRecording()
        } else {
            // Make sure the engine is actually running before tapping it.
            if state != .playing {
                play()
            }
            recordingPresetName = presetName
            _ = engine.startRecording()
            isRecording = true
        }
    }

    /// Stop the capture, run the mastering pipeline, and publish the
    /// finished .m4a URL. Safe to call when recording is already finalized
    /// (becomes a no-op).
    func finalizeRecording() {
        guard let rawURL = engine.stopRecording() else {
            isRecording = false
            return
        }
        isRecording = false
        isMastering = true
        let presetName = recordingPresetName
        Task { @MainActor in
            do {
                let masteredURL = try await AudioMastering.master(
                    inputCAFURL: rawURL,
                    presetName: presetName
                )
                self.lastRecordingURL = masteredURL
            } catch {
                // Fall back to the raw CAF so the user at least gets
                // something to share, and surface a toast.
                self.lastRecordingURL = rawURL
                self.lastMasteringError = error.localizedDescription
            }
            self.isMastering = false
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
        // Push to the engine so per-voice timing envelopes
        // (startDelaySec + playDurationSec) can shape volume.
        engine.transportElapsed = elapsed
        if sessionDuration > 0 && elapsed >= sessionDuration {
            stop()
        }
    }
}
