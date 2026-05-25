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

    init(engine: AudioEngine) {
        self.engine = engine
    }

    func start() async {
        guard !isListening else { return }
        lastError = nil

        // 1. Explicitly request mic permission. iOS won't prompt just from
        //    changing AVAudioSession category — without this, the session
        //    quietly fails to record and we get silent buffers.
        let granted: Bool = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        guard granted else {
            lastError = "Microphone permission denied. Enable it in Settings → Drone Meditations."
            return
        }

        // 2. Stop the engine before reconfiguring the session — switching
        //    category live can leave the inputNode in a stale state where
        //    its format reports channelCount = 0 and the tap silently drops.
        let wasRunning = engine.engine.isRunning
        if wasRunning { engine.engine.stop() }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,        // disables AGC/echo cancellation
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [])
        } catch {
            lastError = "Couldn't switch audio session: \(error.localizedDescription)"
            if wasRunning { try? engine.engine.start() }
            return
        }

        // 3. Restart engine so the inputNode picks up the new session config.
        do { try engine.engine.start() } catch {
            lastError = "Couldn't start engine for input: \(error.localizedDescription)"
            return
        }

        let bus = 0
        let input = engine.engine.inputNode
        // outputFormat after a session switch needs a brief moment on some
        // devices; if channelCount is 0 we wait one runloop and try again.
        var format = input.outputFormat(forBus: bus)
        if format.channelCount == 0 || format.sampleRate <= 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            format = input.outputFormat(forBus: bus)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "Microphone format unavailable — try again in a moment."
            return
        }

        input.installTap(onBus: bus, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let ch = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)

            // RMS for the level meter.
            var sumSq: Double = 0
            for i in 0..<frameCount {
                let v = Double(ch[i])
                sumSq += v * v
            }
            let rms = Float((sumSq / Double(max(1, frameCount))).squareRoot())

            let hz = autocorrelate(samples: ch, count: frameCount, sampleRate: format.sampleRate)
            Task { @MainActor in
                self.inputLevel = rms
                self.consumePitch(hz)
            }
        }
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        engine.engine.inputNode.removeTap(onBus: 0)
        isListening = false
        detectedHz = nil
        smoothHz = 0
        inputLevel = 0

        // Restore the playback-only session so the mic indicator goes away.
        // Stop/restart engine across the switch for the same reason we
        // do on the way in.
        let wasRunning = engine.engine.isRunning
        if wasRunning { engine.engine.stop() }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            lastError = error.localizedDescription
        }
        if wasRunning { try? engine.engine.start() }
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
