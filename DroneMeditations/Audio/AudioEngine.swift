import Foundation
import AVFoundation

/// Owns AVAudioEngine and four `Voice` oscillators. UI code updates voice targets;
/// the engine's source node renders sample-accurate sine/triangle/saw/square audio
/// with smoothed parameter ramps.
final class AudioEngine {
    /// The underlying AVAudioEngine. `var` (not `let`) so we can fully
    /// recreate the instance after mic permission is granted for the
    /// first time — once an AVAudioEngine has been started without
    /// mic permission, its inputNode is permanently captured in a
    /// "no input route" state for the lifetime of that instance.
    /// Recreating is the only way to get a fresh inputNode.
    var engine = AVAudioEngine()
    let voices: [Voice]
    let sampleRate: Double

    /// Master output level (0..1). Setting cancels any in-progress fade and
    /// snaps to the new value; also remembers it as the target for the next
    /// fade-in (so play after volume change resumes to the right level).
    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set {
            let clamped = max(0, min(1, newValue))
            masterTarget = clamped
            cancelFade()
            engine.mainMixerNode.outputVolume = clamped
        }
    }
    private var masterTarget: Float = 0.30
    private var fadeTimer: Timer?
    /// Bumped on every new rampMaster call so any in-flight async ramp
    /// loop bails out on its next tick rather than fighting the newer
    /// one. Plays the same role for async-loop fades that
    /// fadeTimer.invalidate() played for Timer-based ones.
    private var rampGeneration: Int = 0
    /// Same idea for the reverb-bloom loop.
    private var bloomGeneration: Int = 0

    /// Transport elapsed seconds, pushed in by DroneController on every
    /// transport tick. The audio render thread reads it once per render
    /// block and fans it out to each voice so per-voice timing envelopes
    /// (startDelaySec + playDurationSec) can shape volume. NaN = stopped.
    var transportElapsed: Double = .nan

    private var sourceNode: AVAudioSourceNode!
    private var isSessionConfigured = false

    init() {
        // CRITICAL: configure the audio session as .playAndRecord BEFORE
        // touching ANY AVAudioEngine node (mainMixerNode, inputNode,
        // sourceNode). AVAudioEngine implicitly initializes its full
        // graph — including inputNode — based on the session category
        // that's active when the first node is touched. If we touch
        // mainMixerNode under .soloAmbient or .playback, the inputNode
        // is permanently captured in a "no input route" state and
        // reports sr=0 forever. Any later attempt to use the mic
        // (Listen / Tune to Room) crashes with Core Audio -10875.
        //
        // We swallow errors silently here — if session config fails,
        // the rest of init proceeds and the engine still works for
        // playback. Listen will likely fail but the user can still play.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            // NOTE: previously called setPreferredIOBufferDuration(0.020)
            // to try to fix the post-Listen pause "dragging." That didn't
            // actually fix the pause issue AND it forced the render
            // callback to fire 50×/s instead of iOS's default ~10×/s —
            // which caused audible crackling on parameter changes
            // (frequency / filter / LFO sweeps) because the render
            // thread couldn't keep up with the tight buffer under
            // simultaneous SwiftUI update load. Reverted — let iOS
            // pick the buffer size based on power/perf tradeoffs.
            try session.setActive(true, options: [])
            isSessionConfigured = true
        } catch {
            #if DEBUG
            print("AudioEngine.init session config failed: \(error)")
            #endif
        }

        // NOW use the session's preferred sample rate; the source node
        // format must match (under .playAndRecord this is typically 48k).
        let sr = session.sampleRate > 0 ? session.sampleRate : 48000.0
        self.sampleRate = sr
        self.voices = (0..<4).map { Voice(id: $0, sampleRate: sr) }
        attachSourceNode()
        // DELIBERATELY don't pre-touch engine.inputNode here. Accessing
        // inputNode under .playAndRecord triggers iOS's mic permission
        // prompt AT LAUNCH — a terrible first-launch experience. iOS
        // also takes 3-5s to fully wire the mic HW after the user
        // accepts, during which the transport buttons are unresponsive.
        //
        // Instead: the session is already .playAndRecord (set above),
        // so when MicPitchDetector lazily accesses inputNode on first
        // Listen tap, it will still be created under the correct
        // session — no inputNode "stuck in .playback state" bug. The
        // permission prompt also happens at the moment the user
        // explicitly asks for Tune to Room, which is the expected UX.
        // Default 0.30 — with 4 voices + reverb/delay wet sends, anything higher
        // can hit the soft-limiter and audibly compress. Remember as the fade
        // target; actual outputVolume starts at 0 and is ramped by play().
        masterTarget = 0.30
        engine.mainMixerNode.outputVolume = 0
    }

    private func attachSourceNode() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            fatalError("Could not create stereo audio format at \(sampleRate) Hz")
        }
        // Capture the voices array directly so the render closure never touches self.
        let voices = self.voices
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            // Expect 2 non-interleaved float channels.
            guard ablPtr.count >= 2,
                  let leftRaw = ablPtr[0].mData,
                  let rightRaw = ablPtr[1].mData else {
                return noErr
            }
            let n = Int(frameCount)
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)

            // Zero the output before voices sum in.
            for i in 0..<n { left[i] = 0; right[i] = 0 }

            // Resolve solo logic for this buffer.
            var anySoloed = false
            for v in voices where v.isSoloed {
                anySoloed = true
                break
            }
            // For each voice, wire its FM input pointer to the source voice's
            // PREVIOUS render's raw buffer (1-buffer latency — fine for FM at
            // typical iOS buffer sizes ~5-10 ms). Voices read from `src.lastRawBuffer`
            // which holds whatever was written last call; the new call updates
            // each voice's own lastRawBuffer in place.
            // Snapshot transport elapsed once for this render block so all
            // four voices see the same time for their envelope evaluation.
            let elapsed = self.transportElapsed
            for v in voices {
                v.effectiveEnabled = anySoloed ? v.isSoloed : true
                v.transportElapsed = elapsed
                let srcIdx = v.fmSourceIndex
                if srcIdx >= 0 && srcIdx < voices.count && srcIdx != v.id {
                    let src = voices[srcIdx]
                    src.lastRawBuffer.withUnsafeBufferPointer { srcPtr in
                        v.fmInputBuffer = srcPtr.baseAddress
                        v.fmInputCount = src.lastRawCount
                        v.render(frameCount: n, left: left, right: right)
                    }
                    v.fmInputBuffer = nil
                    v.fmInputCount = 0
                } else {
                    v.fmInputBuffer = nil
                    v.fmInputCount = 0
                    v.render(frameCount: n, left: left, right: right)
                }
            }
            // Soft-limit summed output at -0.1 dB ceiling (≈ 0.989) via tanh saturation.
            // Keeps peaks bounded without the brutality of hard clipping.
            let ceiling: Float = 0.989
            for i in 0..<n {
                left[i] = tanhf(left[i]) * ceiling
                right[i] = tanhf(right[i]) * ceiling
            }
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Engine recreation (post-mic-permission)

    /// Recreate the underlying AVAudioEngine instance. Used by
    /// MicPitchDetector after the user grants mic permission for the
    /// first time — the existing engine instance has its inputNode
    /// permanently captured in a "no input" state (because it was
    /// started under .playAndRecord but without permission), and
    /// stop/start does not refresh it. Building a fresh engine
    /// instance is the only reliable way to get a working inputNode.
    ///
    /// Preserves: voices array (parameter state lives on Voice
    /// objects, not the engine), session state (still .playAndRecord),
    /// master volume target.
    /// Loses: any in-flight async fades or blooms (caller should
    /// re-establish state if needed).
    func recreateEngineForFreshInput() {
        let savedVolume = engine.mainMixerNode.outputVolume
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }
        // AGGRESSIVE TEARDOWN. iOS's audio thread holds strong refs to
        // attached nodes via its render graph. If we just reassign
        // `engine = AVAudioEngine()`, the OLD engine + its sourceNode
        // + its output buffer can stay alive for SECONDS, with iOS
        // continuing to drain the OLD engine's buffered audio through
        // the speaker. Symptom: pause on the NEW engine sets its
        // outputVolume = 0, but the OLD engine keeps playing for ~3 s
        // until its buffer + retain cycle releases.
        //
        // Explicitly disconnect + detach so iOS releases the old graph
        // synchronously before we replace the engine reference.
        engine.mainMixerNode.outputVolume = 0   // silence old graph first
        if let oldSource = sourceNode {
            engine.disconnectNodeOutput(oldSource)
            engine.detach(oldSource)
        }
        sourceNode = nil
        engine.reset()
        engine = AVAudioEngine()
        // Re-touch inputNode under the new instance with mic permission
        // now granted, so it initializes with a real hardware format.
        _ = engine.inputNode
        // Re-build source node + connect to new mainMixer.
        attachSourceNode()
        engine.mainMixerNode.outputVolume = savedVolume
        if wasRunning {
            do {
                try engine.start()
            } catch {
                #if DEBUG
                print("recreateEngineForFreshInput: engine.start failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Session lifecycle

    func configureSessionIfNeeded() throws {
        guard !isSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        // Use .playAndRecord (not .playback) from the very first
        // session configuration. Reason: AVAudioEngine implicitly
        // initializes its full audio graph — INCLUDING inputNode —
        // the first time you touch mainMixerNode (which happens in
        // our init() at line 54). If that initialization happens
        // under a .playback session, the inputNode is permanently
        // captured in a "no input route" state. Subsequent attempts
        // to swap session to .playAndRecord and use the mic fail
        // with input AU reporting sr=0, ch=2 (the "no format"
        // placeholder), and any connect() to it crashes with
        // Core Audio -10875.
        //
        // .playAndRecord with .defaultToSpeaker + .mixWithOthers
        // behaves identically to .playback for output purposes
        // (sound comes out the speakers normally, mixes with other
        // apps' audio). The only user-visible difference: iOS may
        // show a one-time mic-permission prompt at first launch if
        // permission was never granted before — but it's OK to
        // accept-and-never-use, no orange dot until we actually
        // installTap.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: [])
        isSessionConfigured = true
    }

    func start() throws {
        try configureSessionIfNeeded()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Softer alternative to stop() — suspends the engine without
    /// tearing down the I/O AU. Resuming via start() is essentially
    /// instantaneous (no HW re-init) and there's no audible click on
    /// the suspend itself, because the audio output device isn't
    /// disconnected. Use this for transient pauses where the user is
    /// likely to resume soon; reserve stop() for terminal shutdown
    /// (app teardown, etc.). On iOS Core Audio, the difference shows
    /// up as: stop() can produce a small click on real hardware as
    /// the AU rebinds; pause() doesn't.
    func pause() {
        if engine.isRunning {
            engine.pause()
        }
    }

    /// Disconnect + reconnect the source node → mainMixer connection so it
    /// renegotiates its format with whatever sample rate / channel layout
    /// the session is now offering. Called by `MicPitchDetector` after a
    /// session category swap, where AVAudioEngine has been observed to
    /// leave the source-node connection in a stale state — `isRunning`
    /// reports true but the render block is never called, so audio
    /// silently goes to zero. This forces a fresh negotiation that
    /// rewires the render path. Safe to call when the engine is stopped
    /// (intended call site), since `connect()` while stopped is the
    /// documented happy path for AVAudioEngine graph mutations.
    func refreshOutputGraph() {
        guard let src = sourceNode else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.disconnectNodeOutput(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Recording

    /// Output URL of the currently active recording, if any.
    private(set) var recordingURL: URL?
    private var recordingFile: AVAudioFile?

    /// Install a tap on the main mixer and write each render block to a CAF
    /// file in the Documents/Recordings subdirectory. Returns the URL of the
    /// file being captured, or nil if recording couldn't start. The post-
    /// recording mastering pass (AudioMastering) writes the final M4A to
    /// the same directory, so both intermediate + final live in Recordings.
    @discardableResult
    func startRecording() -> URL? {
        guard recordingFile == nil else { return recordingURL }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // Put recordings in a dedicated Recordings/ subfolder so the
        // top-level Drone Meditations folder in the Files app doesn't
        // get cluttered with .caf intermediates + .m4a finals mixed
        // in with Samples and presets. Create the dir if it doesn't
        // exist yet (first ever recording on this device).
        let recordingsDir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: recordingsDir,
            withIntermediateDirectories: true
        )
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = recordingsDir.appendingPathComponent("drone-meditations-\(df.string(from: Date())).caf")

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            recordingFile = file
            recordingURL = url
        } catch {
            return nil
        }

        // mainMixerNode bus 0 is shared with SpectrumTap. installTap throws
        // an NSException (uncatchable from Swift) if a tap is already
        // present, so pre-emptively remove any existing one. SpectrumTap
        // will need to be restarted by the user after recording stops.
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let file = self?.recordingFile else { return }
            do { try file.write(from: buffer) } catch { /* drop on error */ }
        }
        return url
    }

    /// Remove the tap and close the file. Returns the URL of the captured
    /// recording (caller can hand it to a share sheet).
    @discardableResult
    func stopRecording() -> URL? {
        guard recordingFile != nil else { return nil }
        engine.mainMixerNode.removeTap(onBus: 0)
        recordingFile = nil  // closes the file via AVAudioFile deinit
        let url = recordingURL
        recordingURL = nil
        return url
    }

    var isRecording: Bool { recordingFile != nil }

    /// Gently ramp master output up to `masterTarget` over `seconds`. Used by
    /// DroneController on play to avoid a hard cut-in.
    func fadeInMaster(seconds: Double = 3.0) {
        // Fire-and-forget — fade-in doesn't need to be awaited by the
        // caller (play() returns immediately after kicking it off).
        Task { @MainActor in
            await rampMaster(to: masterTarget, over: seconds, curve: .equalPower)
        }
    }

    /// Ramp master output to silence over `seconds` with the chosen
    /// curve. Long fades (e.g. stop) should use `.smoothstep` for an
    /// even, gradual feel. Short fades (e.g. pause) can use
    /// `.exponential` for a snappier response. Awaits completion + a
    /// substantial post-silence buffer so a follow-up `engine.stop()`
    /// can't introduce a DC click.
    func fadeOutMaster(seconds: Double = 5.0, curve: FadeCurve = .smoothstep) async {
        // rampMaster is now async + self-pumped; awaiting it returns
        // when the curve has finished ticking. No separate sleep
        // needed for the fade itself.
        await rampMaster(to: 0, over: seconds, curve: curve)
        // Snap to exact zero — floating-point dust at very low volumes
        // can still click on engine.stop().
        engine.mainMixerNode.outputVolume = 0
        // 200 ms of explicit silence at zero before any stop() runs.
        // Lets the hardware's downstream output buffer fully drain to
        // silence, so engine.stop() never interrupts non-zero samples.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Cancel any in-progress fade (without snapping volume).
    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    // MARK: - Stop with reverb bloom
    //
    // "Atmospheric stop" — instead of a pure amplitude fade-out, ramp
    // each voice's reverb mix + decay UP over the first few seconds of
    // the stop while the master volume simultaneously fades down. The
    // dry signal disappears, the wet signal extends and dissolves into
    // space. Sounds far more "musical" than a pure volume drop and
    // hides the perceptual unevenness inherent in any amplitude fade
    // (the human ear has trouble parsing fast dB descents as smooth).

    private var stopBloomTimer: Timer?
    /// Snapshot of per-voice (mix, decaySec) captured when the bloom
    /// starts. Restored on cancelStopBloom() so a Play during the
    /// fade — or a clean teardown after the fade — returns each voice
    /// to the user's actual reverb settings.
    private var preBloomReverb: [(mix: Float, decay: Double)] = []

    /// Triangular reverb bloom over `totalDuration` seconds: ramp each
    /// voice's reverb mix + decay UP from current to (peakMix, peakDecay)
    /// over the first `peakAt`-fraction of the duration, then ramp BACK
    /// DOWN to the pre-bloom values over the remainder.
    ///
    /// Why triangular: the voice render mixes wet additively
    /// (`output = dry + revMix * wet`), so a constant bloom would
    /// compensate for the master fade and the user would hear "still
    /// loud" until the bloom collapses — which is exactly the
    /// "100 % → silence" symptom users reported. A triangular bloom
    /// means the wet signal also fades after its peak, so the perceived
    /// total loudness actually drops throughout the fade.
    ///
    /// Idempotent: cancels any prior bloom first.
    func startStopBloom(
        totalDuration: Double = 8.0,
        peakAt: Double = 0.30,
        peakMix: Float = 0.50,
        peakDecay: Double = 6.0,
        plateauWidth: Double = 0.0
    ) async {
        cancelStopBloom()
        preBloomReverb = voices.map { (mix: $0.reverbMix, decay: $0.reverbDecaySec) }
        let startMix = voices.map { $0.reverbMix }
        // startDecay no longer used: we don't ramp reverbDecaySec
        // anymore (mid-fade decay changes click — see startStopBloom
        // loop comment). Kept the comment as a marker for future
        // re-introduction if the comb-filter state can be smoothed.
        let startDate = Date()
        let voicesRef = voices
        let clampedPeakAt = max(0.05, min(0.95, peakAt))
        // Plateau spans [peakAt, peakAt + plateauWidth], clipped to 1.0.
        // Ramp-down then runs from plateauEnd to 1.0. plateauWidth=0
        // collapses back to the original triangular envelope.
        let clampedPlateauWidth = max(0, min(1 - clampedPeakAt, plateauWidth))
        let plateauEnd = clampedPeakAt + clampedPlateauWidth
        let tickNanos: UInt64 = 16_000_000   // ~60 fps

        bloomGeneration &+= 1
        let myGen = bloomGeneration

        while myGen == bloomGeneration {
            let elapsed = Date().timeIntervalSince(startDate)
            let tLin = min(1.0, elapsed / totalDuration)

            // Trapezoidal envelope:
            //   [0, peakAt]            ramp UP   (smoothstep)
            //   [peakAt, plateauEnd]   hold at 1 (plateau — wet wash)
            //   [plateauEnd, 1]        ramp DOWN (smoothstep)
            // With plateauWidth=0, plateauEnd == peakAt → collapses to
            // the original triangular shape (no behaviour change for
            // pauseWithReverbBloom which doesn't pass plateauWidth).
            let raw: Double
            if tLin <= clampedPeakAt {
                let phase = tLin / clampedPeakAt   // 0 → 1
                raw = phase * phase * (3 - 2 * phase)
            } else if tLin <= plateauEnd {
                raw = 1.0
            } else {
                let phase = (1 - tLin) / max(0.0001, 1 - plateauEnd)   // 1 → 0
                raw = phase * phase * (3 - 2 * phase)
            }
            let t = Float(raw)
            let tD = raw

            for i in 0..<voicesRef.count {
                let sm = startMix[i]
                // ONLY ramp reverbMix. Do NOT ramp reverbDecaySec
                // during a bloom, even though the original design did.
                // Voice.swift line ~349 recomputes the comb filter
                // feedback coefficients PER BUFFER from reverbDecaySec.
                // A mid-fade decay change causes the comb feedbacks to
                // jump discontinuously between buffers — audible as a
                // click during pause and stop. Mix is safe to ramp
                // (it's a multiply applied per-sample after the wet
                // signal is generated, no internal filter state).
                voicesRef[i].reverbMix = sm + (peakMix - sm) * t
            }
            _ = tD  // was used for decay ramp
            if tLin >= 1.0 {
                // Snap mix back to the snapshot.
                for i in 0..<voicesRef.count {
                    voicesRef[i].reverbMix = startMix[i]
                }
                break
            }
            try? await Task.sleep(nanoseconds: tickNanos)
        }
    }

    /// Stop any in-flight bloom ramp AND restore each voice's reverb
    /// settings to the values they had before the bloom started.
    /// Called both at the end of a clean stop sequence (after the
    /// master fade completes) and when Play interrupts a stop fade
    /// mid-flight.
    func cancelStopBloom() {
        // Bump the generation so the async bloom loop bails on its
        // next tick. (Legacy Timer field also cleared, for any future
        // re-introduction of a timer-based fallback.)
        bloomGeneration &+= 1
        stopBloomTimer?.invalidate()
        stopBloomTimer = nil
        // SNAPSHOT-THEN-CLEAR pattern. pauseWithReverbBloom/stopWithReverbBloom
        // calls this twice per cycle (once at the start of startStopBloom, once
        // at the end after the master fade + bloom complete). If those two
        // calls land on different concurrent dispatch queues — which they
        // can since AudioEngine isn't actor-isolated and the async let
        // bloomTask runs on the cooperative pool — both could try to
        // release the same preBloomReverb buffer at once: double-free
        // → EXC_BAD_ACCESS in objc_class::realizeIfNeeded during ARC.
        //
        // Capture the local snapshot AND clear the property in one
        // synchronous burst, then iterate the local. Two concurrent
        // callers race on the swap, but only one wins the non-empty
        // snapshot; the other gets [] and does nothing.
        let snapshot = preBloomReverb
        preBloomReverb = []
        if !snapshot.isEmpty {
            for (i, snap) in snapshot.enumerated() where i < voices.count {
                voices[i].reverbMix = snap.mix
                voices[i].reverbDecaySec = snap.decay
            }
        }
    }

    /// Combined "atmospheric stop": triangular reverb bloom (up, then
    /// back down) running ALONGSIDE a logarithmic master fade-out over
    /// the same duration. Because the bloom envelope returns to the
    /// pre-bloom values by the end, the wet signal also fades — so the
    /// user perceives total loudness actually dropping throughout
    /// (rather than a constant bloom masking the master fade until
    /// both collapse at the end). Caller is responsible for
    /// engine.stop() after this returns.
    func stopWithReverbBloom(
        fadeDuration: Double = 8.0,
        peakAt: Double = 0.30,
        peakMix: Float = 0.50,
        peakDecay: Double = 6.0,
        plateauWidth: Double = 0.0,
        fadeCurve: FadeCurve = .logarithmic
    ) async {
        // Run bloom + master fade concurrently. async let starts the
        // bloom loop in the background; await rampMaster ticks the
        // master fade on the current actor. When both finish, await
        // the bloom future to make sure its restore code has run.
        async let bloomTask: () = startStopBloom(
            totalDuration: fadeDuration,
            peakAt: peakAt,
            peakMix: peakMix,
            peakDecay: peakDecay,
            plateauWidth: plateauWidth
        )
        await rampMaster(to: 0, over: fadeDuration, curve: fadeCurve)
        await bloomTask
        engine.mainMixerNode.outputVolume = 0
        // 500 ms (was 200 ms) of explicit silence at zero before any
        // engine.stop()/pause() can run. Gives iOS Core Audio enough
        // time to flush the output buffer cleanly so the AU rebind /
        // suspend doesn't produce an audible click on real hardware.
        try? await Task.sleep(nanoseconds: 500_000_000)
        cancelStopBloom()
    }

    /// Smaller, faster bloom for pause — a gentle "lift then settle"
    /// while the master fade-out runs. Same triangular envelope shape
    /// as stopWithReverbBloom, just tuned for a short pause gesture
    /// (smaller peak mix, shorter decay target).
    func pauseWithReverbBloom(
        fadeDuration: Double = 1.4,
        peakAt: Double = 0.25,
        peakMix: Float = 0.25,
        peakDecay: Double = 3.5,
        fadeCurve: FadeCurve = .exponential
    ) async {
        // Run bloom + master fade concurrently. async let starts the
        // bloom loop in the background; await rampMaster ticks the
        // master fade on the current actor. When both finish, await
        // the bloom future to make sure its restore code has run.
        async let bloomTask: () = startStopBloom(
            totalDuration: fadeDuration,
            peakAt: peakAt,
            peakMix: peakMix,
            peakDecay: peakDecay
        )
        await rampMaster(to: 0, over: fadeDuration, curve: fadeCurve)
        await bloomTask
        engine.mainMixerNode.outputVolume = 0
        // 500 ms (was 200 ms) of explicit silence at zero before any
        // engine.stop()/pause() can run. Gives iOS Core Audio enough
        // time to flush the output buffer cleanly so the AU rebind /
        // suspend doesn't produce an audible click on real hardware.
        try? await Task.sleep(nanoseconds: 500_000_000)
        cancelStopBloom()
    }

    /// Curve shape for `rampMaster`.
    ///  - equalPower: sin-shaped, gentle onset — used for fade-ins.
    ///  - exponential: sharp early drop, gradual tail — "snappy" stop.
    ///  - smoothstep: slow start, faster middle, slow end (Hermite cubic).
    ///  - logarithmic: amplitude decays exponentially so the PERCEIVED
    ///    loudness (which is logarithmic in amplitude — every -6 dB
    ///    halves the perceived volume) drops at a steady rate. Sounds
    ///    "uniformly gradual" to the ear in a way smoothstep doesn't:
    ///    smoothstep is gradual in amplitude (linear-space) but the
    ///    last 20 % feels rushed because dropping from -10 dB to -∞
    ///    happens fast in amplitude terms. Logarithmic spreads the dB
    ///    drop evenly. The best curve for a "winding down" meditation
    ///    stop fade.
    enum FadeCurve { case linear, equalPower, exponential, smoothstep, logarithmic }

    /// Asynchronous master-volume ramp. The previous implementation used
    /// `Timer.scheduledTimer` to tick the fade, but the timer turned
    /// out to be unreliable when scheduled from inside the @MainActor
    /// `Task` that wraps fadeOutMaster — depending on runloop mode it
    /// would simply never fire on real iPhone hardware. Symptom: volume
    /// stays at startVolume for the entire fade duration, then snaps to
    /// target at the very end when fadeOutMaster's explicit
    /// `outputVolume = 0` runs after the sleep. Switched to a pure
    /// async loop pumped by `Task.sleep` — the same 60-fps tick rate,
    /// runs on whatever actor called us (typically @MainActor), no
    /// dependence on the runloop firing the timer at the right time.
    private func rampMaster(to target: Float, over duration: Double, curve: FadeCurve = .linear) async {
        cancelFade()   // legacy no-op; still safe in case any legacy callers exist
        guard duration > 0 else {
            engine.mainMixerNode.outputVolume = target
            return
        }
        let startVolume = engine.mainMixerNode.outputVolume
        let startDate = Date()
        let mixer = engine.mainMixerNode
        let tickNanos: UInt64 = 16_000_000  // ~60 fps

        // Bump the ramp generation so any older in-flight rampMaster
        // loop bails out on its next tick (modeled after cancelFade()).
        rampGeneration &+= 1
        let myGen = rampGeneration

        while myGen == rampGeneration {
            let elapsed = Date().timeIntervalSince(startDate)
            let tLin = min(1.0, elapsed / duration)
            let t: Double
            switch curve {
            case .linear:
                t = tLin
            case .equalPower:
                // sin curve — gentle onset, used for fade-in.
                t = sin(tLin * .pi / 2)
            case .exponential:
                // 1 - (1-t)^3 — sharp early drop, gradual tail. Feels
                // "snappy" for short fades, "abrupt at the start" for
                // long fades.
                t = 1 - pow(1 - tLin, 3)
            case .smoothstep:
                // Hermite cubic 3t² - 2t³ — slow at both endpoints,
                // faster in the middle. Feels uniformly gradual in
                // AMPLITUDE space but the last 20 % rushes in
                // perceived loudness terms (going from -10 dB to -∞
                // happens fast in amplitude).
                t = tLin * tLin * (3 - 2 * tLin)
            case .logarithmic:
                // Two-segment curve for an actually-smooth perceived
                // fade-out:
                //
                //   1. BULK (first 90 % of duration): amplitude follows
                //      10^(-2 * tLin / 0.9), giving a TRUE linear dB
                //      descent of -40 dB over the bulk window. Every
                //      second of the bulk drops the same number of dB,
                //      so the ear perceives a uniform wind-down. For a
                //      6-second fade that's about -7.4 dB per second —
                //      below the "steppy" threshold (psychoacoustic JND
                //      around 3 dB, anything below ~7 dB/sec reads as
                //      continuous).
                //
                //   2. TAIL (last 10 % of duration): linear taper from
                //      the bulk-end amplitude (0.01 = -40 dB, already
                //      essentially inaudible) down to exactly 0. The
                //      taper is too small to be perceived but
                //      eliminates the snap-click that would otherwise
                //      happen if the curve ended at the bulk's -40 dB
                //      floor and then jumped to 0.
                //
                // Previous attempts at this curve failed for two
                // reasons: the unnormalized form (1 - 10^(-2*tLin))
                // asymptoted at -40 dB and clicked on the final snap;
                // the /0.99 normalized form fixed the click but
                // squeezed the actual dB descent into the first 95 %
                // of duration so the per-second drop was ~12 dB/sec —
                // above the perceptual smoothness threshold. The
                // explicit bulk+tail split handles both: smooth in
                // the audible range, clean at the inaudible tail.
                let bulkEnd = 0.9
                let floorRatio = pow(10.0, -2.0)   // 0.01 = -40 dB
                if tLin < bulkEnd {
                    let logRatio = pow(10.0, -2.0 * tLin / bulkEnd)
                    t = 1.0 - logRatio
                } else {
                    let tailProgress = (tLin - bulkEnd) / (1.0 - bulkEnd)
                    t = 1.0 - floorRatio * (1.0 - tailProgress)
                }
            }
            mixer.outputVolume = startVolume + (target - startVolume) * Float(t)
            if tLin >= 1.0 {
                mixer.outputVolume = target
                break
            }
            try? await Task.sleep(nanoseconds: tickNanos)
        }
    }

    // MARK: - Convenience parameter setters (UI-thread safe)

    func setFrequency(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].targetFrequencyHz = max(1.0, hz)
    }

    func setAmplitude(_ amp: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].targetAmplitude = Float(max(0, min(1, amp)))
    }

    func setPan(_ pan: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].targetPan = Float(max(-1, min(1, pan)))
    }

    func setWaveform(_ wave: Waveform, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].waveform = wave
    }

    func setMute(_ muted: Bool, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].isMuted = muted
    }

    func setSolo(_ soloed: Bool, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].isSoloed = soloed
    }

    func setLfoRate(_ hz: Double, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        let clamped = max(LfoState.rateMin, min(LfoState.rateMax, hz))
        voices[voiceIndex].lfoRatesHz[lfoIndex] = clamped
    }

    func setLfoDepth(_ depth: Double, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoDepths[lfoIndex] = max(0, min(1, depth))
    }

    func setLfoShape(_ shape: LfoState.Shape, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoShapes[lfoIndex] = shape
    }

    /// v1.1: replace the LFO's full target set in one call. Old name
    /// kept for the few internal call sites that still pass a single
    /// target — wrapped into a one-element set for backward compat.
    func setLfoTarget(_ target: LfoState.Target, for voiceIndex: Int, lfoIndex: Int) {
        setLfoTargets([target], for: voiceIndex, lfoIndex: lfoIndex)
    }

    func setLfoTargets(_ targets: Set<LfoState.Target>, for voiceIndex: Int, lfoIndex: Int) {
        guard voices.indices.contains(voiceIndex),
              (0..<4).contains(lfoIndex) else { return }
        voices[voiceIndex].lfoTargets[lfoIndex] = targets
    }

    func setFilterType(_ type: FilterState.FilterType, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].filterType = type
    }

    func setFilterCutoff(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].filterCutoffHz = max(FilterState.cutoffMin, min(FilterState.cutoffMax, hz))
    }

    func setFilterQ(_ q: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].filterQ = max(FilterState.qMin, min(FilterState.qMax, q))
    }

    /// Voice timing envelope. 0 (default) for both means play immediately
    /// and play forever. Clamped to 0..3600 each (a one-hour cap).
    func setStartDelay(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].startDelaySec = max(0, min(3600, sec))
    }
    func setPlayDuration(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].playDurationSec = max(0, min(3600, sec))
    }
    /// Replay cycles for the timing envelope. 1 (default) = play once,
    /// 2/3/5 = repeat N times, 0 = ∞. Clamped to [0, 99] — anything beyond
    /// a few dozen would never finish in a normal session anyway.
    func setReplayCount(_ count: Int, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].replayCount = max(0, min(99, count))
    }

    /// 1.0 = no drive; up to ~12 for heavy saturation. Lower-only clamp so
    /// negative values can't invert the waveshaper.
    func setDrive(_ d: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].drive = max(1.0, min(12.0, d))
    }

    // MARK: - Granular (only active when waveform == .granular)
    func setGrainSize(_ ms: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainSizeMs = max(GrainState.sizeMinMs, min(GrainState.sizeMaxMs, ms))
    }
    func setGrainDensity(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainDensityHz = max(GrainState.densityMin, min(GrainState.densityMax, hz))
    }
    func setGrainJitter(_ j: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainJitter = max(0, min(1, j))
    }
    func setGrainPanSpread(_ s: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainPanSpread = max(0, min(1, s))
    }

    // MARK: - Sample play-window (only audible when waveform == .sample)
    func setSampleStart(_ frac: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleStartFrac = max(0, min(0.999, frac))
    }
    func setSampleEnd(_ frac: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleEndFrac = max(0.001, min(1, frac))
    }
    func setSampleFadeIn(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleFadeInSec = max(0, min(10, sec))
    }
    func setSampleFadeOut(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleFadeOutSec = max(0, min(10, sec))
    }
    // ── Granular sampling (v1.1) — only audible when waveform == .sample. ──
    /// Toggle granular-sampling mode for a voice. When on, the loaded
    /// sample is sliced into Hann-windowed grains driven by the same
    /// GRAIN row (size/density/jitter/spread) as pink-noise granular,
    /// plus the position controls below.
    func setSampleGranular(_ on: Bool, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleGranular = on
    }
    func setGrainSamplePos(_ frac: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainSamplePosFrac = max(0, min(1, frac))
    }
    func setGrainSamplePosJitter(_ frac: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].grainSamplePosJitter = max(0, min(1, frac))
    }

    func setReverbDecay(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].reverbDecaySec = max(ReverbState.decayMin, min(ReverbState.decayMax, sec))
    }
    func setReverbMix(_ mix: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].reverbMix = Float(max(0, min(1, mix)))
    }
    func setDelayTime(_ sec: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].delayTimeSec = max(DelayState.timeMin, min(DelayState.timeMax, sec))
    }
    func setDelayFeedback(_ fb: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].delayFeedback = Float(max(0, min(DelayState.feedbackMax, fb)))
    }
    func setDelayMix(_ mix: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].delayMix = Float(max(0, min(1, mix)))
    }
    func setDelayMode(_ mode: DelayState.Mode, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        let voiceMode: Voice.DelayMode
        switch mode {
        case .mono:     voiceMode = .mono
        case .stereo:   voiceMode = .stereo
        case .pingPong: voiceMode = .pingPong
        }
        voices[voiceIndex].delayMode = voiceMode
    }

    // ── Chorus ───────────────────────────────────────────
    func setChorusRate(_ hz: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusRateHz = max(ChorusState.rateMin, min(ChorusState.rateMax, hz))
    }
    func setChorusDepth(_ depth: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusDepth = max(0, min(1, depth))
    }
    func setChorusWidth(_ width: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusWidth = max(0, min(1, width))
    }
    func setChorusMix(_ mix: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].chorusMix = Float(max(0, min(1, mix)))
    }

    // ── FM (cross-osc) ───────────────────────────────────
    /// Pass -1 to disable. Self-modulation is silently disabled.
    func setFMSource(_ sourceIndex: Int, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        var src = sourceIndex
        if src == voiceIndex { src = -1 }
        voices[voiceIndex].fmSourceIndex = src
    }
    func setFMIndex(_ index: Double, for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].fmIndex = max(0, min(FMState.indexMax, index))
    }

    /// Load an audio file into a voice's sample slot. The file is decoded with
    /// AVAudioFile, downmixed to mono, and stored as a Float buffer that the
    /// render loop reads with linear interpolation. Throws on decode failure.
    func loadSample(from url: URL, for voiceIndex: Int) throws {
        guard voices.indices.contains(voiceIndex) else { return }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "DroneMeditations.loadSample", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate buffer"])
        }
        try file.read(into: buffer)

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let chData = buffer.floatChannelData else {
            throw NSError(domain: "DroneMeditations.loadSample", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Empty audio buffer"])
        }
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float]()
        mono.reserveCapacity(frameCount)
        if channelCount == 1 {
            for i in 0..<frameCount { mono.append(chData[0][i]) }
        } else {
            // Downmix by simple average.
            let inv = Float(1.0) / Float(channelCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<channelCount { sum += chData[c][i] }
                mono.append(sum * inv)
            }
        }
        voices[voiceIndex].sampleData = mono
        voices[voiceIndex].sampleNativeRate = format.sampleRate
    }

    func clearSample(for voiceIndex: Int) {
        guard voices.indices.contains(voiceIndex) else { return }
        voices[voiceIndex].sampleData = nil
    }
}
