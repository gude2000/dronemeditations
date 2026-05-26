import Foundation
import AVFoundation

/// Post-recording mastering pipeline. Takes the raw CAF capture from the
/// engine's recording tap and produces a release-ready M4A:
///
///   1. **Loudness normalization** — scans the recording, computes its
///      RMS, and applies a single gain so the result lands around
///      -16 dBFS RMS (a reasonable proxy for -14 LUFS on stationary
///      ambient/drone content; not true ITU-R BS.1770, but predictable).
///   2. **Fade-in / fade-out** — 2 s in, 4 s out. Softens session edges
///      so the file doesn't start or end with an abrupt click.
///   3. **AAC encoding** — packaged into an .m4a container at high
///      quality. ~10× smaller than the lossless CAF; universally
///      playable in Music, Files, share sheets, AirDrop, etc.
///   4. **Metadata** — title, artist, comments, made-with tag.
///
/// Implemented via AVAssetExportSession + AVAudioMix so the heavy
/// lifting (encoding + gain ramps) happens in optimized system code
/// rather than per-sample Swift loops.
enum AudioMastering {

    /// Run the full master on `inputCAFURL` and return the URL of the
    /// finished .m4a. The input CAF is deleted on success.
    /// Throws if any stage of the pipeline fails.
    static func master(
        inputCAFURL: URL,
        presetName: String?,
        targetRMSdBFS: Double = -16.0,
        fadeInSec: Double = 2.0,
        fadeOutSec: Double = 4.0
    ) async throws -> URL {
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

        // ── 2. Prepare output URL ─────────────────────────────────
        let outURL = inputCAFURL.deletingPathExtension().appendingPathExtension("m4a")
        // Clean any stale file at the target path so the exporter can write.
        try? FileManager.default.removeItem(at: outURL)

        // ── 3. Build the asset + audio mix (gain + fades) ─────────
        let asset = AVURLAsset(url: inputCAFURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MasteringError.noAudioTrack
        }
        let totalDuration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(totalDuration)

        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: audioTrack)
        // Apply the normalization gain as the base volume across the whole file.
        params.setVolume(safeGainLinear, at: .zero)

        // Fade-in: 0 → safeGainLinear over the first `fadeInSec`.
        if fadeInSec > 0.01 && fadeInSec < totalSeconds {
            let inRange = CMTimeRange(start: .zero,
                                      duration: CMTime(seconds: fadeInSec, preferredTimescale: 44100))
            params.setVolumeRamp(fromStartVolume: 0,
                                 toEndVolume: safeGainLinear,
                                 timeRange: inRange)
        }
        // Fade-out: safeGainLinear → 0 over the last `fadeOutSec`.
        if fadeOutSec > 0.01 && fadeOutSec < totalSeconds {
            let outStart = CMTime(seconds: max(0, totalSeconds - fadeOutSec),
                                  preferredTimescale: 44100)
            let outRange = CMTimeRange(start: outStart,
                                       duration: CMTime(seconds: fadeOutSec, preferredTimescale: 44100))
            params.setVolumeRamp(fromStartVolume: safeGainLinear,
                                 toEndVolume: 0,
                                 timeRange: outRange)
        }
        mix.inputParameters = [params]

        // ── 4. Export to AAC/M4A ──────────────────────────────────
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MasteringError.exportSessionInit
        }
        export.outputURL = outURL
        export.outputFileType = .m4a
        export.audioMix = mix
        export.metadata = buildMetadata(presetName: presetName,
                                        durationSec: totalSeconds)

        // iOS 17+ async export. We deliberately don't poll progress
        // here — typical drone sessions are 5-20 min and the export
        // is faster than realtime; UI can show a spinner during the
        // call site's `await`.
        if #available(iOS 18.0, *) {
            try await export.export(to: outURL, as: .m4a)
        } else {
            await export.export()
            if let err = export.error {
                throw MasteringError.exportFailed(err)
            }
            if export.status != .completed {
                throw MasteringError.exportNotCompleted(export.status)
            }
        }

        // ── 5. Clean up the source CAF ────────────────────────────
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

    // MARK: - Metadata

    /// Build a metadata block embedded into the .m4a so the file's
    /// title/artist/comment fields display nicely in Music, Files, etc.
    private static func buildMetadata(presetName: String?, durationSec: Double) -> [AVMetadataItem] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())

        let mins = Int(durationSec / 60)
        let secs = Int(durationSec.truncatingRemainder(dividingBy: 60))
        let durStr = String(format: "%d:%02d", mins, secs)

        let title = presetName.map { "Drone Meditation — \($0)" }
            ?? "Drone Meditation — \(dateStr)"
        let comment = "Recorded with Drone Meditations · \(dateStr) · \(durStr)"

        func meta(_ key: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = key
            m.value = value as NSString
            m.extendedLanguageTag = "en"
            return m.copy() as! AVMetadataItem
        }

        return [
            meta(.commonIdentifierTitle, title),
            meta(.commonIdentifierArtist, "Drone Meditations"),
            meta(.commonIdentifierCreator, "Drone Meditations"),
            meta(.commonIdentifierDescription, comment),
            meta(.commonIdentifierSoftware, "Drone Meditations iOS")
        ]
    }

    // MARK: - Errors

    enum MasteringError: LocalizedError {
        case recordingTooShort
        case noAudioTrack
        case exportSessionInit
        case exportFailed(Error)
        case exportNotCompleted(AVAssetExportSession.Status)

        var errorDescription: String? {
            switch self {
            case .recordingTooShort:
                return "Recording was too short to master (need at least 0.5 s)."
            case .noAudioTrack:
                return "Couldn't find audio data in the recording."
            case .exportSessionInit:
                return "Couldn't create AAC export session."
            case .exportFailed(let e):
                return "Export failed: \(e.localizedDescription)"
            case .exportNotCompleted(let status):
                return "Export ended with unexpected status: \(status.rawValue)"
            }
        }
    }
}
