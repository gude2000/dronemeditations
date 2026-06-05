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

    /// v1 metronome — separate state from engine.metronomeOn because
    /// the controller needs to know whether the user wants the click
    /// to keep ticking when transport is stopped (so we can override
    /// the mainMixer gate to make it audible pre-Play). engine flag is
    /// the live render-loop trigger; this is the user-intent flag.
    @Published private(set) var metronomeOn: Bool = false
    /// Master mainMixer volume saved when we bumped it for the metronome
    /// pre-Play override, so we can restore it on metronome off / Play.
    private var savedMainMixerVolumeBeforeMetronome: Float? = nil

    init(engine: AudioEngine) {
        self.engine = engine
    }

    /// Toggle the metronome. Works regardless of transport state — if
    /// stopped, we bring the engine up + bump mainMixer.outputVolume so
    /// the click is audible during the pre-Play tempo preview. Voices
    /// stay silent thanks to the isAudible-gated zero in the source
    /// node closure.
    func setMetronomeOn(_ on: Bool) {
        if on && !metronomeOn {
            // Make sure the engine is running so the source node
            // closure can render the click. Cheap no-op if already up.
            do { try engine.start() } catch {
                #if DEBUG
                print("setMetronomeOn: engine.start failed: \(error)")
                #endif
                return
            }
            // v1: cancel any in-flight stop/pause fade-out so it
            // can't keep writing to mainMixer.outputVolume after we
            // bump it for the metronome preview. Without this, the
            // ramp's continued execution races our 0.6 back down to
            // 0 and the click goes silent after the first beat.
            pendingFadeOutTask?.cancel()
            pendingFadeOutTask = nil
            // Restore reverb to user values if a stop-bloom was in
            // flight (otherwise the click rides over a still-bloomed
            // reverb tail — minor but worth fixing while we're here).
            engine.cancelStopBloom()
            // If the transport is stopped, mainMixer.outputVolume is
            // 0. Bump it to a fixed preview level (0.6) so the click
            // is audible. Save the prior value so we can restore on
            // metronome-off or Play. Set voicesMuted=true so voices
            // (which may have non-zero amps from a loaded preset) don't
            // bleed through the bumped 0.6 gain. voicesMuted is the new
            // narrow flag used specifically for this preview scenario;
            // the older `!isAudible` check also caught pause/stop fade-
            // out states and silenced voices BEFORE the fade ramp had a
            // chance to run.
            if !engine.isAudible {
                savedMainMixerVolumeBeforeMetronome = engine.engine.mainMixerNode.outputVolume
                engine.engine.mainMixerNode.outputVolume = 0.6
                engine.voicesMuted = true
            }
            engine.setMetronomeOn(true)
        } else if !on && metronomeOn {
            engine.setMetronomeOn(false)
            // Restore the master volume override if we bumped it.
            if let saved = savedMainMixerVolumeBeforeMetronome, !engine.isAudible {
                engine.engine.mainMixerNode.outputVolume = saved
                engine.voicesMuted = false
            }
            savedMainMixerVolumeBeforeMetronome = nil
        }
        metronomeOn = on
    }

    func play() {
        #if DEBUG
        let playStart = Date()
        let preVol = engine.engine.mainMixerNode.outputVolume
        let preRunning = engine.engine.isRunning
        print("▶️ [\(timestamp())] play() called — state=\(state), engine.isRunning=\(preRunning), outputVolume=\(preVol)")
        #endif
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
            #if DEBUG
            let startElapsed = Date().timeIntervalSince(playStart)
            print("▶️ [\(timestamp())] engine.start returned in \(String(format: "%.3f", startElapsed))s, isRunning=\(engine.engine.isRunning)")
            #endif
        } catch {
            #if DEBUG
            print("AudioEngine start failed: \(error)")
            #endif
            return
        }
        if state != .playing {
            #if DEBUG
            print("▶️ [\(timestamp())] firing fadeInMaster, fromStopped=\(fromStopped), engineAlreadyRunning=\(engineAlreadyRunning)")
            #endif
            // Choose fade-in duration:
            //  - 3 s if this is a true cold start (engine wasn't running)
            //    — preserves the "meditative onset" for the very first
            //    play of the session.
            //  - 0.4 s if engine was already running (resume from pause OR
            //    play-after-Listen-close). The previous 1 s value felt
            //    laggy because the equalPower (sin) curve has a gentle
            //    onset — the first 100-200 ms are barely audible. 0.4 s
            //    feels immediate without being a hard cut-in.
            let fadeDuration: Double = (fromStopped && !engineAlreadyRunning) ? 3.0 : 0.4
            // Flip audible-flag BEFORE fadeInMaster so any concurrent
            // setMasterVolume (e.g. user dragging the master slider
            // exactly as Play is tapped) goes through to live output
            // instead of being staged.
            engine.isAudible = true
            // Clear the metronome-preview voice-mute (if Play was hit
            // while the metronome was previewing pre-Play). Voices now
            // need to render.
            engine.voicesMuted = false
            // v1: clear the pre-Play metronome override now that
            // fadeInMaster is taking over the mainMixer volume.
            savedMainMixerVolumeBeforeMetronome = nil
            // v1: anchor metronome + grain phases to the Play moment
            // so beat 1 of the click and grain 1 of every quantized
            // voice land on the same audio sample. The user
            // perceives this as "the metronome and the granular
            // texture started together, locked, downbeat aligned."
            engine.resetMetronomePhase()
            engine.resetGrainPhases()
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
        // Flag transport as non-audible. setMasterVolume calls that
        // arrive while paused (preset load, slider drag) will now stage
        // the value into masterTarget instead of nudging the live output
        // out through the silenced engine. The fade-out below still
        // pushes the live output to 0 — flag flip just blocks further
        // nudges from bypassing it.
        engine.isAudible = false
        #if DEBUG
        let pauseStart = Date()
        let preVol = engine.engine.mainMixerNode.outputVolume
        print("⏸️ [\(timestamp())] pause() called — state=.paused, mainMixer.outputVolume=\(preVol)")
        #endif
        // PAUSE: 1.4s exponential master fade. NO reverb bloom.
        // (The audio-session preferredIOBufferDuration is forced to
        // 20 ms in AudioEngine.init so the buffer doesn't drain a
        // second of audio after we set outputVolume = 0 — that was
        // the post-Listen "dragging" the user heard.)
        //
        // CLICK-FREE engine strategy unchanged: don't call engine.pause()
        // or engine.stop(). Leave engine running silently at outputVolume=0.
        pendingFadeOutTask?.cancel()
        let engineRef = engine
        pendingFadeOutTask = Task { @MainActor in
            #if DEBUG
            print("⏸️ [\(self.timestamp())] pause Task starting fadeOutMaster(1.4s)")
            #endif
            await engineRef.fadeOutMaster(seconds: 1.4, curve: .exponential)
            #if DEBUG
            let elapsed = Date().timeIntervalSince(pauseStart)
            let postVol = engineRef.engine.mainMixerNode.outputVolume
            print("⏸️ [\(self.timestamp())] pause Task DONE — elapsed=\(String(format: "%.2f", elapsed))s, mainMixer.outputVolume=\(postVol)")
            #endif
            guard self.state == .paused else { return }
        }
    }

    #if DEBUG
    private func timestamp() -> String {
        let t = String(format: "%.3f", Date().timeIntervalSince1970)
        return String(t.suffix(7))
    }
    #endif

    func stop() {
        stopTicker()
        elapsed = 0
        lastTickDate = nil
        state = .stopped
        // Mark transport stopped so the per-voice timing envelopes don't
        // keep advancing while the master fade-out plays.
        engine.transportElapsed = .nan
        // Flag transport as non-audible. setMasterVolume calls arriving
        // during / after this point (preset load tap, slider drag) will
        // stage the value into masterTarget only, instead of nudging
        // live output back up through a "stopped" transport — which
        // used to make the Stop button look broken (Stop UI is
        // .disabled(state == .stopped); the audio bled out anyway and
        // user had to tap pause first to break the deadlock).
        engine.isAudible = false
        // v1: Stop also turns the metronome off (audibly + via the
        // @Published flag the UI mirrors). User feedback: clicks
        // continuing through the stop felt broken.
        if metronomeOn {
            engine.setMetronomeOn(false)
            metronomeOn = false
            savedMainMixerVolumeBeforeMetronome = nil
        }
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
            // 10 s atmospheric stop. Trapezoidal bloom envelope:
            //   ramp up → plateau at peak (sustained wash) → ramp down.
            // User feedback: previous triangular bloom "bailed too
            // soon" because the envelope started ramping down the
            // instant it hit peak — the plateau fixes that.
            //
            // peakMix lowered to 0.30 — user finally heard the bloom
            // clearly (an earlier buffer-size experiment was masking
            // it audibly by starving render cycles) and 0.65 felt
            // "huge / too much." 0.30 keeps the atmospheric expansion
            // present and noticeable without overwhelming the preset's
            // original character.
            // plateauWidth shortened 0.25 → 0.15 so the sustained peak
            // is briefer — wet wash still carries through the mid-fade
            // but doesn't dominate.
            await engineRef.stopWithReverbBloom(
                fadeDuration: 10.0,
                peakAt: 0.40,
                peakMix: 0.20,
                peakDecay: 7.0,
                plateauWidth: 0.05
            )
            // Softening pass per user request: peakMix 0.30 → 0.20 (less
            // wet wash at peak), peakAt 0.30 → 0.40 (slower, gentler
            // ramp-in into the wash), plateauWidth 0.15 → 0.05 (briefer
            // peak — drift in, hold a moment, drift out). Curve in
            // AudioEngine.startStopBloom upgraded to smootherstep, which
            // also softens the endpoint approach independently. Together,
            // the bloom now feels like a slow breath rather than a swell.
            // If the user re-pressed Play during the fade, state is no
            // longer .stopped — exit cleanly. (Play also calls
            // cancelStopBloom() so reverb is restored even if the fade
            // Task was cancelled mid-bloom.)
            guard self.state == .stopped else { return }
            // CLICK-FREE STRATEGY (same as pause): don't call
            // engine.stop(). Master is already at 0 from the fade;
            // the engine keeps running silently. Avoids the audible
            // click that the AU rebind produces on real iPhone
            // hardware. CPU cost is sub-1 % (4 silent oscillators
            // through a 0-volume mixer). Engine truly stops on app
            // deinit.
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
