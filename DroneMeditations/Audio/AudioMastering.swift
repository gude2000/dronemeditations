import Foundation
import AVFoundation

/// Post-recording mastering pipeline. Takes the raw CAF capture from the
/// engine's recording tap and produces a release-ready 24-bit PCM WAV:
///
///   1. **Loudness normalization** — scans the recording, computes its
///      RMS, and applies a single gain so the result lands around
///      -16 dBFS RMS (a reasonable proxy for -14 LUFS on stationary
///      ambient/drone content; not true ITU-R BS.1770, but predictable).
///   2. **Fade-in / fade-out** — 2 s in, 4 s out. Softens session edges
///      so the file doesn't start or end with an abrupt click.
///   3. **24-bit PCM WAV** — uncompressed, lossless, professional
///      quality. Universally accepted by DAWs, samplers, mastering
///      software, and AirDrop / share workflows. File size is larger
///      than AAC (~17 MB/min for stereo 48k) but quality is bit-perfect
///      for downstream editing or remastering.
///
/// Switched from M4A (AVAssetExportSession + AAC) to WAV per user
/// request. WAV can't go through ExportSession (the preset list is
/// AAC-only for audio), so we read the CAF chunk-by-chunk via
/// AVAudioFile, apply gain + fades in Swift, and write to a WAV file
/// in 24-bit PCM. Per-sample fade math (vs. AVAudioMix's volume ramps)
/// is fine here — drone sessions are short enough that the loop runs
/// faster than realtime even on older iPhones.
enum AudioMastering {

    /// Run the full master on `inputCAFURL` and return the URL of the
    /// finished .wav. The input CAF is deleted on success.
    /// Throws if any stage of the pipeline fails.
    /// `presetName` is currently unused (WAV via AVAudioFile doesn't
    /// support embedded metadata) but kept in the signature so call
    /// sites don't need to change.
    static func master(
        inputCAFURL: URL,
        presetName: String?,
        targetRMSdBFS: Double = -16.0,
        fadeInSec: Double = 2.0,
        fadeOutSec: Double = 4.0
    ) async throws -> URL {
        _ = presetName  // unused; see note above
        // ── 1. Measure loudness ───────────────────────────────────
        let (rmsDBFS, peakDBFS, durationSec) = try measureLoudness(url: inputCAFURL)
        guard durationSec > 0.5 else {
            throw MasteringError.recordingTooShort
        }
        // Gain such that final RMS hits the target. Cap the boost so
        // peaks can't exceed -0.3 dBFS — important for stationary drone
        // content where the crest factor is low and over-eager
        // normalization would clip.
        let neededGainDB = targetRMSdBFS - rmsDBFS
        let peakHeadroomDB = -0.3 - peakDBFS
        let safeGainDB = min(neededGainDB, peakHeadroomDB)
        let safeGainLinear = Float(pow(10.0, safeGainDB / 20.0))

        // ── 2. Prepare output WAV path ────────────────────────────
        let outURL = inputCAFURL.deletingPathExtension().appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: outURL)

        // ── 3. Open the CAF reader ────────────────────────────────
        let inFile = try AVAudioFile(forReading: inputCAFURL)
        let inFormat = inFile.processingFormat   // Float32, interleaved or non
        let sampleRate = inFormat.sampleRate
        let channelCount = Int(inFormat.channelCount)
        let totalFrames = inFile.length

        // ── 4. Open the WAV writer: 24-bit interleaved PCM ────────
        // 24-bit is the professional standard for mastering output —
        // bit-perfect within audible dynamic range, ~50% smaller than
        // 32-bit float without quality loss for human-audible content.
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: wavSettings)

        // ── 5. Stream-process: apply gain + linear fade ramps ─────
        // Linear fades are simpler than smoothstep/exponential and
        // indistinguishable to the ear for the 2 s / 4 s ramps used
        // here — fades are slow enough that the curve shape doesn't
        // matter audibly.
        let fadeInFrames  = AVAudioFramePosition(fadeInSec  * sampleRate)
        let fadeOutFrames = AVAudioFramePosition(fadeOutSec * sampleRate)
        let fadeOutStartFrame = max(0, totalFrames - fadeOutFrames)

        let chunkSize: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                            frameCapacity: chunkSize) else {
            throw MasteringError.bufferAlloc
        }

        inFile.framePosition = 0
        while inFile.framePosition < totalFrames {
            buffer.frameLength = 0
            try inFile.read(into: buffer, frameCount: chunkSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chans = buffer.floatChannelData else { break }

            // Frame index within the FILE of the first sample in this chunk.
            // file.framePosition has already advanced past the chunk by this
            // point, so the starting frame is (now − n).
            let chunkStart = inFile.framePosition - AVAudioFramePosition(n)

            for f in 0..<n {
                let frame = chunkStart + AVAudioFramePosition(f)
                var envelope = safeGainLinear

                // Fade-in: linear 0 → 1 over [0, fadeInFrames)
                if fadeInFrames > 0 && frame < fadeInFrames {
                    envelope *= Float(frame) / Float(fadeInFrames)
                }
                // Fade-out: linear 1 → 0 over [fadeOutStartFrame, totalFrames)
                if fadeOutFrames > 0 && frame >= fadeOutStartFrame {
                    let into = frame - fadeOutStartFrame
                    let t = 1.0 - Float(into) / Float(fadeOutFrames)
                    envelope *= max(0, t)
                }

                for c in 0..<channelCount {
                    chans[c][f] *= envelope
                }
            }

            // AVAudioFile.write handles the Float32 → 24-bit PCM
            // conversion internally based on the file's settings.
            try outFile.write(from: buffer)
        }

        // ── 6. Clean up the source CAF ────────────────────────────
        try? FileManager.default.removeItem(at: inputCAFURL)
        return outURL
    }

    // MARK: - Loudness measurement

    /// First pass — read the whole file in chunks, compute RMS and peak.
    /// Returns (rmsDBFS, peakDBFS, durationSec). Operates on mono-mixed
    /// samples so multi-channel recordings get a single number.
    private static func measureLoudness(url: URL) throws -> (Double, Double, Double) {
        let file = try AVAudioFile(forReading: url)
        let processingFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return (-100, -100, 0) }

        let chunkSize: AVAudioFrameCount = 16384
        var sumSq: Double = 0
        var peak: Float = 0
        var counted: Double = 0

        let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                      frameCapacity: chunkSize)!
        let channelCount = Int(processingFormat.channelCount)

        while file.framePosition < AVAudioFramePosition(totalFrames) {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunkSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chans = buffer.floatChannelData else { break }
            for f in 0..<n {
                // Average across channels into a single mono sample.
                var s: Float = 0
                for c in 0..<channelCount { s += chans[c][f] }
                let mono = s / Float(channelCount)
                let absV = abs(mono)
                if absV > peak { peak = absV }
                sumSq += Double(mono) * Double(mono)
                counted += 1
            }
        }
        let rms = (counted > 0) ? sqrt(sumSq / counted) : 0
        let rmsDB = (rms > 1e-10) ? 20.0 * log10(rms) : -100.0
        let peakDB = (peak > 1e-10) ? 20.0 * log10(Double(peak)) : -100.0
        let durSec = Double(totalFrames) / processingFormat.sampleRate
        return (rmsDB, peakDB, durSec)
    }

    // MARK: - Errors

    enum MasteringError: LocalizedError {
        case recordingTooShort
        case bufferAlloc

        var errorDescription: String? {
            switch self {
            case .recordingTooShort:
                return "Recording was too short to master (need at least 0.5 s)."
            case .bufferAlloc:
                return "Couldn't allocate audio buffer for mastering pass."
            }
        }
    }
}
