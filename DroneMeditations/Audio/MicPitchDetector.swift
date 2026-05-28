import Foundation
import AVFoundation
import Combine

/// Microphone pitch detection — "tune to room/voice" for the iOS app.
///
/// Lazily reconfigures the AVAudioSession to .playAndRecord when listening
/// starts (and back to .playback when it stops), so the app doesn't ask for
/// mic permission until the user actually requests it. Installs a tap on
/// the engine's inputNode and runs autocorrelation on each buffer — same
/// algorithm as the web pitch-detect.js so the two platforms agree.
@MainActor
final class MicPitchDetector: ObservableObject {
    /// Currently detected pitch in Hz. KEPT after the mic goes quiet so the
    /// user has time to tap "Set as Root" — previously this decayed to nil
    /// in ~0.5s and the readout disappeared mid-tap. Cleared explicitly via
    /// `clearHeldPitch()` (Reset button) or replaced by a new stable pitch.
    @Published private(set) var detectedHz: Double?
    /// True when `detectedHz` is being kept on screen even though the mic
    /// has gone quiet. Used by the UI to dim the readout + show a "held" badge.
    @Published private(set) var isHolding: Bool = false
    /// Live input RMS [0..1] so the UI can show a level meter and the user
    /// can confirm the mic is actually being heard even before a pitch lands.
    @Published private(set) var inputLevel: Float = 0
    /// True while the mic tap is active.
    @Published private(set) var isListening: Bool = false
    /// Last error message from session/tap setup, surfaced in the UI.
    @Published var lastError: String?

    private let engine: AudioEngine
    private var smoothHz: Double = 0

    // Silent sink that the inputNode is connected to. Without this
    // connection, AVAudioEngine never delivers buffers to a tap on
    // inputNode — the input node has to be part of the active graph
    // (connected to something downstream that the engine is rendering).
    // The mixer has no output connection so its samples go nowhere —
    // it just exists to put inputNode into the active graph.
    private var silentInputSink: AVAudioMixerNode?

    // Listen-mode state we need to restore on stop():
    //  - Whether the engine was already running when Listen started. If
    //    it wasn't, we'll stop it again on Listen close (otherwise the
    //    user gets unexpected post-Listen playback).
    //  - The master output volume at Listen-start time. If the user
    //    wasn't playing, we silence the master so they don't hear the
    //    preset audio just because Tune to Room had to start the engine.
    //    Restored to its original value when Listen closes.
    private var engineWasRunningBeforeListen: Bool = false
    private var masterVolumeBeforeListen: Float = 1.0
    private var didOverrideMasterVolume: Bool = false

    init(engine: AudioEngine) {
        self.engine = engine
    }

    func start() async {
        guard !isListening else { return }
        lastError = nil

        // Diagnostic prints with timestamps so we can pinpoint exactly
        // where the function hangs when reported by users. Remove (or
        // wrap in #if DEBUG) before App Store submission.
        func log(_ msg: String) {
            let t = String(format: "%.3f", Date().timeIntervalSince1970)
                .suffix(7)
            print("🎤 [\(t)] MicPitchDetector.start: \(msg)")
        }
        log("entered")

        // 1. Check + request mic permission. iOS 17+ API. We must NOT
        //    blindly `await` requestRecordPermission() — it has a known
        //    hang on some devices when permission was already granted in
        //    a previous launch (the async variant never completes). Check
        //    the sync state first and only request if undetermined.
        let current = AVAudioApplication.shared.recordPermission
        log("permission state = \(current.rawValue) (0=undet, 1=denied, 2=granted)")
        let granted: Bool
        switch current {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            log("calling async requestRecordPermission…")
            granted = await AVAudioApplication.requestRecordPermission()
            log("async permission returned: \(granted)")
        @unknown default:
            granted = false
        }
        guard granted else {
            lastError = "Microphone permission denied. Enable it in Settings → Drone Meditations → Microphone."
            log("BAIL: permission not granted")
            return
        }
        log("permission OK")

        // 2. Session swap to .playAndRecord — only if not already there.
        //    Once we've done one Listen this app session, the category
        //    is already correct and there's nothing to do. The previous
        //    flow ALWAYS stopped + restarted the engine, which on real
        //    iPhone hardware left the source-node → main-mixer connection
        //    in a stale format. `engine.isRunning` stayed `true` but the
        //    render block was no longer called — so audio silently went
        //    to zero. The transport buttons "worked" (calling pause/stop
        //    on already-silent audio is a no-op the user can't hear).
        //
        //    The new flow: only stop+restart the engine on the FIRST
        //    Listen of the app session, when we genuinely need to add
        //    the input AU to the graph and swap the session category.
        //    Subsequent Listens (and every Listen invoked while audio is
        //    playing once the input AU is already wired up) skip the
        //    restart entirely and just install the tap on a live engine.
        let wasRunning = engine.engine.isRunning
        engineWasRunningBeforeListen = wasRunning
        let session = AVAudioSession.sharedInstance()
        let needsSessionSwap = (session.category != .playAndRecord)
        let needsInputWireUp = (silentInputSink == nil)
        log("engine.isRunning=\(wasRunning) needsSessionSwap=\(needsSessionSwap) needsInputWireUp=\(needsInputWireUp)")

        // 2a. Master-volume hygiene. If the user wasn't playing, silence
        //     the master so the preset audio doesn't suddenly come on
        //     just because we may have started the engine for the mic.
        //     If they ARE playing, leave volume alone — they expect to
        //     keep hearing the synth while they tune.
        masterVolumeBeforeListen = engine.engine.mainMixerNode.outputVolume
        if !wasRunning {
            engine.engine.mainMixerNode.outputVolume = 0
            didOverrideMasterVolume = true
            log("muted master (was \(masterVolumeBeforeListen)) for tune-only mode")
        } else {
            didOverrideMasterVolume = false
        }

        // 2b. Session category swap (only if not already .playAndRecord).
        if needsSessionSwap {
            do {
                log("setCategory playAndRecord…")
                // Use .default mode (not .measurement). .measurement disables
                // AGC + echo cancellation which sounds great in theory but
                // leaves the input route in an inconsistent format state on
                // many devices.
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
                )
                log("setActive true…")
                try session.setActive(true, options: [])
            } catch {
                lastError = "Couldn't switch audio session: \(error.localizedDescription)"
                log("BAIL: session error \(error.localizedDescription)")
                return
            }
            // Give iOS time to wire up the new input route.
            try? await Task.sleep(nanoseconds: 300_000_000)
            log("session configured + settled")
        }

        // 2c. Lazily wire up input → silentInputSink → mainMixer. This
        //     requires the engine to be stopped briefly so the connection
        //     takes effect deterministically. Only happens the very first
        //     time Listen runs in this app session. Subsequent invocations
        //     skip this entirely and the engine stays running through
        //     Listen.
        //
        //     CRITICAL: silentInputSink MUST be connected downstream to
        //     mainMixerNode, not left as a dangling endpoint. AVAudioEngine
        //     only pulls samples from input when there's an actual sink
        //     chain that reaches the engine's output. A mixer with no
        //     output connection is treated as "no consumer" and the input
        //     AU goes silent — the tap fires with empty buffers and pitch
        //     detection returns -1 forever, leaving the UI stuck at
        //     "Listening — hold a steady tone".
        //
        //     silentInputSink.outputVolume = 0 silences ONLY the mic in
        //     the final output mix, so the user's preset audio still
        //     plays at full volume but they don't get a feedback howl
        //     from mic-into-speakers.
        let bus = 0
        let input = engine.engine.inputNode
        if needsInputWireUp {
            log("input AU needs to be wired into the graph — stopping engine briefly…")
            if wasRunning { engine.engine.stop() }
            let sink = AVAudioMixerNode()
            sink.outputVolume = 0
            engine.engine.attach(sink)
            engine.engine.connect(input, to: sink, format: nil)
            // Connect the sink to mainMixer so the engine actually
            // pulls samples from input. Format nil = let the engine
            // negotiate (typically the mixer's stereo format).
            engine.engine.connect(sink, to: engine.engine.mainMixerNode, format: nil)
            silentInputSink = sink
            log("connected inputNode → silent sink → mainMixer")
            // NOTE: removed an earlier refreshOutputGraph() call that
            // disconnected + reconnected the source node here. That was
            // added in 1.0(3) to fix a "post-Listen transport feels frozen"
            // bug — but the actual cause of that bug turned out to be the
            // stale fade-out Task in DroneController (fixed in 1.0(4)).
            // The extra graph mutation between stop and start was
            // confusing the input AU initialization and leaving its
            // outputFormat stuck at sr=0 — i.e. the "Microphone format
            // unavailable" error path. Leaving the output graph alone
            // gives the input AU the room it needs to settle.
            if wasRunning {
                do {
                    try engine.engine.start()
                    log("engine restarted after input wire-up; isRunning=\(engine.engine.isRunning)")
                } catch {
                    lastError = "Couldn't restart engine after input wire-up: \(error.localizedDescription)"
                    log("BAIL: engine start error \(error.localizedDescription)")
                    return
                }
            }
        } else if !wasRunning {
            // Cold start path — input already wired, engine just needs
            // to start (e.g. user opened Listen without ever pressing play).
            do {
                try engine.engine.start()
                log("engine cold-started; isRunning=\(engine.engine.isRunning)")
            } catch {
                lastError = "Couldn't start engine for input: \(error.localizedDescription)"
                log("BAIL: engine start error \(error.localizedDescription)")
                return
            }
        } else {
            log("engine already running with input wired — no restart needed (the new fast path)")
        }
        // Poll the input bus until it reports a valid (non-zero) sample
        // rate. The input AU takes time to fully initialize after a
        // session swap + engine restart — on real iPhone hardware this
        // can range from ~150 ms (best case) to ~2 s (Bluetooth route,
        // post-phone-call, low-power mode). Up to 3 s of polling with
        // 100 ms intervals.
        //
        // CRITICAL: installTap with a 0-Hz format throws an
        // uncatchable NSException ("Failed to initialize active nodes
        // in input chain, err = -10868") that crashes the whole app.
        // We must verify the format is valid BEFORE calling installTap
        // — there is no way to recover from that exception once
        // thrown, since Swift can't catch Obj-C NSExceptions raised
        // from the audio thread.
        var settledFormat: AVAudioFormat = input.outputFormat(forBus: bus)
        var pollAttempts = 0
        let maxPollAttempts = 50   // 50 × 100 ms = 5 s budget
        while settledFormat.sampleRate <= 0 && pollAttempts < maxPollAttempts {
            try? await Task.sleep(nanoseconds: 100_000_000)
            settledFormat = input.outputFormat(forBus: bus)
            pollAttempts += 1
            // Only log every 5 attempts to avoid log spam in the
            // common case where the format settles in 1-3 polls.
            if pollAttempts % 5 == 0 || settledFormat.sampleRate > 0 {
                log("poll #\(pollAttempts) (\(pollAttempts * 100) ms): sr=\(settledFormat.sampleRate) ch=\(settledFormat.channelCount)")
            }
        }

        if settledFormat.sampleRate <= 0 {
            lastError = "Microphone format unavailable — try again in a moment, or check Settings → Drone Meditations → Microphone."
            log("BAIL: input format never settled after \(pollAttempts * 100) ms (sr still 0). Not installing tap to avoid the AVAudioEngine NSException crash.")
            return
        }
        log("input format settled after \(pollAttempts * 100) ms: sr=\(settledFormat.sampleRate) ch=\(settledFormat.channelCount)")

        // Pre-emptively remove any stale tap from a previous Listen session
        // that didn't clean up cleanly. installTap throws an uncatchable
        // NSException if a tap is already installed on this bus.
        input.removeTap(onBus: bus)
        log("installing tap with settled format (sr=\(settledFormat.sampleRate))…")
        // Pass the settled format explicitly (rather than nil) so installTap
        // uses exactly what the bus reports. The two should be identical
        // since installTap's nil path also queries outputFormat(forBus:)
        // — but being explicit eliminates any ambiguity if the format
        // shifts between this check and the installTap call.
        // Capture sample rate locally so the closure (which runs on the
        // audio thread) doesn't have to touch `self` or anything else
        // that might have race issues.
        let sampleRateForPitch = settledFormat.sampleRate
        // Throttle diagnostic logging to one print per ~50 buffers
        // (~half a second at 48kHz/4096-frame buffers) — otherwise the
        // log spams the console at every buffer callback.
        nonisolated(unsafe) var tapCallbackCount = 0
        input.installTap(onBus: bus, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            tapCallbackCount += 1
            let shouldLog = (tapCallbackCount % 50 == 1)

            // Diagnostics: what's the buffer format? Is floatChannelData nil?
            // What's the peak amplitude? This tells us whether audio is
            // actually flowing or the input is silent / wrong format.
            if shouldLog {
                let fmt = buffer.format
                print("🎤 tap#\(tapCallbackCount): frames=\(buffer.frameLength) sr=\(fmt.sampleRate) ch=\(fmt.channelCount) common=\(fmt.commonFormat.rawValue) floatCh=\(buffer.floatChannelData != nil) int16Ch=\(buffer.int16ChannelData != nil) int32Ch=\(buffer.int32ChannelData != nil)")
            }

            // Try floatChannelData first (most common: Float32 PCM)…
            var monoSamples: [Float]? = nil
            if let ch = buffer.floatChannelData?[0] {
                monoSamples = Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
            } else if let ch16 = buffer.int16ChannelData?[0] {
                // Fallback: Int16 → Float32 conversion. Some iOS routes
                // deliver Int16 even though we expect Float32.
                let count = Int(buffer.frameLength)
                var floats = [Float](repeating: 0, count: count)
                for i in 0..<count { floats[i] = Float(ch16[i]) / 32768.0 }
                monoSamples = floats
            } else if let ch32 = buffer.int32ChannelData?[0] {
                // Fallback: Int32 → Float32.
                let count = Int(buffer.frameLength)
                var floats = [Float](repeating: 0, count: count)
                let scale: Float = 1.0 / Float(Int32.max)
                for i in 0..<count { floats[i] = Float(ch32[i]) * scale }
                monoSamples = floats
            }
            guard let samples = monoSamples else {
                if shouldLog { print("🎤 tap#\(tapCallbackCount): NO channel data — bailing") }
                return
            }
            let frameCount = samples.count

            // RMS for the level meter.
            var sumSq: Double = 0
            for v in samples { sumSq += Double(v) * Double(v) }
            let rms = Float((sumSq / Double(max(1, frameCount))).squareRoot())
            if shouldLog { print("🎤 tap#\(tapCallbackCount): rms=\(rms)") }

            // If buffer.format reports a valid sample rate, prefer that;
            // otherwise use what we computed before installTap.
            let sr = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : sampleRateForPitch
            let hz = samples.withUnsafeBufferPointer { ptr in
                autocorrelate(samples: ptr.baseAddress!, count: frameCount, sampleRate: sr)
            }
            if shouldLog { print("🎤 tap#\(tapCallbackCount): detected hz=\(hz)") }
            Task { @MainActor in
                self.inputLevel = rms
                self.consumePitch(hz)
            }
        }
        log("tap installed, isListening=true")
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        // removeTap on the inputNode can block the calling thread for
        // several seconds on real iPhone hardware while iOS unwires the
        // mic AU — same family of issue as engine.stop() blocking when
        // input is wired. Since this runs on @MainActor (from the
        // Listen sheet's .onDismiss callback), it would freeze UI taps
        // (Play, Pause, sliders) for that whole window. Detach the
        // teardown so the @MainActor returns immediately.
        let inputNodeRef = engine.engine.inputNode
        Task.detached {
            inputNodeRef.removeTap(onBus: 0)
        }
        isListening = false
        detectedHz = nil
        smoothHz = 0
        inputLevel = 0

        // Keep the engine RUNNING after Listen closes — even if it
        // wasn't running before Listen opened. The previous behavior
        // (stop the engine if it wasn't running pre-Listen) made the
        // user's next Play tap multi-second-laggy: AVAudioEngine.start()
        // had to re-initialize the audio hardware (the session swap +
        // I/O AU rebind is expensive after a fresh stop).
        //
        // By leaving the engine running silently (master volume restored
        // to whatever it was — typically 0 for an idle engine), the
        // next Play is just a fade-in, no engine.start() cost.
        // CPU impact is negligible — 4 source nodes producing silence
        // into a 0-volume mixer is sub-1 % on modern iPhones.
        //
        // We also DON'T disconnect/detach the silent sink (the input AU
        // needs a downstream consumer to stay valid) and DON'T swap the
        // session category back to .playback (.playback has no input
        // device so the input AU can't init and engine.start() would
        // fail forever).
        //
        // Note: we still need to leave the engine running. We deliberately
        // DON'T call engine.stop() here, even though the previous code did.

        // Restore master volume if we muted it for tune-only mode. If
        // the user wasn't playing pre-Listen, this restores to whatever
        // it was (typically 0 if the engine had never produced audio;
        // or the user's configured value if they'd been playing earlier).
        if didOverrideMasterVolume {
            engine.engine.mainMixerNode.outputVolume = masterVolumeBeforeListen
            didOverrideMasterVolume = false
        }
    }

    private func consumePitch(_ hz: Double) {
        // Display-layer clamp — defense in depth against the detector ever
        // returning a value outside the human-voice / drone range. The
        // autocorrelate() function already clamps to [MIN_FREQ, MAX_FREQ];
        // this is a second line of defense for any regression that could
        // possibly let a small-lag "ghost" pitch through.
        let displayMin: Double = 60
        let displayMax: Double = 1700
        let valid = hz > 0 && hz >= displayMin && hz <= displayMax

        if !valid {
            // Mic went quiet (or returned garbage) — KEEP the last detected
            // pitch on screen so the user has time to tap "Set as Root".
            // Previously this faded to nil in ~0.5s, which made it nearly
            // impossible to act on a brief stable note.
            if detectedHz != nil { isHolding = true }
            return
        }
        // Light smoothing on a fresh stable pitch.
        smoothHz = smoothHz > 0 ? smoothHz * 0.6 + hz * 0.4 : hz
        detectedHz = smoothHz
        isHolding = false
    }

    /// Clear the held pitch — wired to the Reset button so the user can
    /// start over without restarting the whole sheet.
    func clearHeldPitch() {
        detectedHz = nil
        smoothHz = 0
        isHolding = false
    }
}

// MARK: - YIN pitch detection
//
// Replaces the original autocorrelation, which could lock onto the early
// descent from lag=0 and then let parabolic interpolation push the refined
// lag below the search range — turning a hummed D#4 into a reported D#10.
//
// Same algorithm as web/js/pitch-detect.js so the platforms agree.
//   1. Difference function  d[lag] = Σ (x[i] - x[i+lag])²
//   2. CMNDF: d'[lag] = d[lag] · lag / Σ(d[1..lag])
//   3. First lag past minLag below threshold, walk to local min
//   4. Parabolic refinement (±1-sample shift cap)
//   5. Hard clamp to [MIN_FREQ, MAX_FREQ] — defense in depth.

private let MIN_FREQ: Double = 70
// 1500 Hz covers human voice + most pitched-instrument fundamentals.
// Narrowing from 2000 reduces false-positive matches at very small lags.
// Defense in depth alongside the hard clamp at the end of autocorrelate().
private let MAX_FREQ: Double = 1500
private let RMS_FLOOR: Double = 0.005
private let YIN_THRESHOLD: Double = 0.10   // tightened from 0.15
private let YIN_ABSMAX: Double = 0.4       // tightened from 0.5

private func autocorrelate(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Double {
    if count < 64 { return -1 }
    var rmsSum: Double = 0
    for i in 0..<count {
        let v = Double(samples[i])
        rmsSum += v * v
    }
    let rms = (rmsSum / Double(count)).squareRoot()
    if rms < RMS_FLOOR { return -1 }

    let minLag = max(2, Int(sampleRate / MAX_FREQ))
    let maxLag = min(count / 2, Int(sampleRate / MIN_FREQ))
    if minLag >= maxLag { return -1 }

    // 1. Difference function over a fixed (count - maxLag) analysis window so
    //    d[lag] values stay comparable.
    let W = count - maxLag
    if W <= 0 { return -1 }
    var d = [Double](repeating: 0, count: maxLag + 1)
    for lag in 1...maxLag {
        var sum: Double = 0
        for i in 0..<W {
            let diff = Double(samples[i]) - Double(samples[i + lag])
            sum += diff * diff
        }
        d[lag] = sum
    }

    // 2. CMNDF.
    var cmndf = [Double](repeating: 0, count: maxLag + 1)
    cmndf[0] = 1
    var runningSum: Double = 0
    for lag in 1...maxLag {
        runningSum += d[lag]
        cmndf[lag] = runningSum > 0 ? d[lag] * Double(lag) / runningSum : 1
    }

    // 3. First lag in [minLag, maxLag) below threshold, walk to local min.
    var bestLag = -1
    var lag = minLag
    while lag < maxLag {
        if cmndf[lag] < YIN_THRESHOLD {
            while lag + 1 < maxLag && cmndf[lag + 1] < cmndf[lag] { lag += 1 }
            bestLag = lag
            break
        }
        lag += 1
    }
    if bestLag < 0 {
        // Fallback: absolute minimum of CMNDF, only if periodicity isn't weak.
        var minVal = Double.infinity
        for l in minLag..<maxLag {
            if cmndf[l] < minVal { minVal = cmndf[l]; bestLag = l }
        }
        if bestLag < 0 || minVal > YIN_ABSMAX { return -1 }
    }

    // 4. Parabolic refinement around the CMNDF minimum.
    var refined: Double = Double(bestLag)
    if bestLag > minLag && bestLag < maxLag - 1 {
        let y0 = cmndf[bestLag - 1]
        let y1 = cmndf[bestLag]
        let y2 = cmndf[bestLag + 1]
        let denom = (y0 - 2 * y1 + y2)
        if abs(denom) > 1e-9 {
            let shift = 0.5 * (y0 - y2) / denom
            refined = Double(bestLag) + max(-1, min(1, shift))  // cap shift
        }
    }

    // 5. Defense in depth: never report a frequency outside the search range.
    let hz = sampleRate / refined
    if hz < MIN_FREQ || hz > MAX_FREQ { return -1 }
    return hz
}

// MARK: - Hz → 12-TET note helper

struct DetectedNote {
    let name: String
    let octave: Int
    let cents: Double
    /// 0=C, 1=C♯, ..., 9=A, 10=A♯, 11=B — matches PitchClass.allCases.
    let pitchClassId: Int
}

func freqToNote(_ hz: Double, refA4: Double = 440) -> DetectedNote? {
    guard hz > 0 else { return nil }
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    let midi = 69.0 + 12.0 * log2(hz / refA4)
    let midiRound = Int(midi.rounded())
    let cents = (midi - Double(midiRound)) * 100.0
    let idx = ((midiRound % 12) + 12) % 12
    let octave = midiRound / 12 - 1
    return DetectedNote(name: names[idx], octave: octave, cents: cents, pitchClassId: idx)
}
