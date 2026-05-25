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
    /// Currently detected pitch in Hz, or nil when quiet/aperiodic.
    @Published private(set) var detectedHz: Double?
    /// True while the mic tap is active.
    @Published private(set) var isListening: Bool = false
    /// Last error message from session/tap setup, surfaced in the UI.
    @Published var lastError: String?

    private let engine: AudioEngine
    /// Light exponential smoothing on the detected pitch so the displayed
    /// note doesn't jitter from autocorrelation frame-to-frame noise.
    private var smoothHz: Double = 0

    init(engine: AudioEngine) {
        self.engine = engine
    }

    func start() async {
        guard !isListening else { return }
        lastError = nil

        do {
            // Reconfigure session for input + playback. Keep .mixWithOthers
            // so we don't interrupt the user's other audio.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [])
            // Make sure engine is running so the input node delivers frames.
            try engine.start()
        } catch {
            lastError = error.localizedDescription
            return
        }

        let bus = 0
        let input = engine.engine.inputNode
        let format = input.outputFormat(forBus: bus)
        // Reject zero-channel format (happens momentarily during session
        // transitions on some devices).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "Microphone format unavailable — try again in a moment."
            return
        }

        input.installTap(onBus: bus, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let ch = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            let hz = autocorrelate(samples: ch, count: frameCount, sampleRate: format.sampleRate)
            Task { @MainActor in self.consumePitch(hz) }
        }
        isListening = true
    }

    func stop() {
        guard isListening else { return }
        engine.engine.inputNode.removeTap(onBus: 0)
        isListening = false
        detectedHz = nil
        smoothHz = 0

        // Restore the playback-only session so we don't keep the mic
        // indicator hot when the user moves on.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Non-fatal: the next play() call will retry session setup.
            lastError = error.localizedDescription
        }
    }

    private func consumePitch(_ hz: Double) {
        if hz <= 0 {
            // Decay smoothed value so the readout doesn't freeze on silence.
            smoothHz *= 0.85
            if smoothHz < 5 {
                detectedHz = nil
                smoothHz = 0
            }
            return
        }
        smoothHz = smoothHz > 0 ? smoothHz * 0.6 + hz * 0.4 : hz
        detectedHz = smoothHz
    }
}

// MARK: - Autocorrelation (parabolic-refined)

private let MIN_FREQ: Double = 70
private let MAX_FREQ: Double = 2000
private let RMS_FLOOR: Double = 0.005
private let PEAK_THRESH: Double = 0.85

private func autocorrelate(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Double {
    if count < 64 { return -1 }
    var rms: Double = 0
    for i in 0..<count {
        let v = Double(samples[i])
        rms += v * v
    }
    rms = (rms / Double(count)).squareRoot()
    if rms < RMS_FLOOR { return -1 }

    let minLag = max(1, Int(sampleRate / MAX_FREQ))
    let maxLag = min(count - 1, Int(sampleRate / MIN_FREQ))
    if minLag >= maxLag { return -1 }

    var bestLag = -1
    var bestCorr: Double = 0
    var foundPositive = false
    for lag in minLag...maxLag {
        var corr: Double = 0
        for i in 0..<(count - lag) {
            corr += Double(samples[i]) * Double(samples[i + lag])
        }
        corr /= Double(count - lag)
        if corr > 0 { foundPositive = true }
        if corr > bestCorr {
            bestCorr = corr
            bestLag = lag
        } else if foundPositive && corr < bestCorr * PEAK_THRESH && bestLag > 0 {
            break
        }
    }
    if bestLag < 0 || bestCorr < 0.01 { return -1 }

    // Parabolic interpolation for sub-sample lag accuracy.
    var refined: Double = Double(bestLag)
    if bestLag > 0 && bestLag < count - 1 {
        var y0: Double = 0, y1: Double = 0, y2: Double = 0
        let n = count - bestLag - 1
        if n > 0 {
            for i in 0..<n {
                y0 += Double(samples[i]) * Double(samples[i + bestLag - 1])
                y1 += Double(samples[i]) * Double(samples[i + bestLag])
                y2 += Double(samples[i]) * Double(samples[i + bestLag + 1])
            }
            let denom = (y0 - 2 * y1 + y2)
            if abs(denom) > 1e-9 {
                refined = Double(bestLag) + 0.5 * (y0 - y2) / denom
            }
        }
    }
    return sampleRate / refined
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
