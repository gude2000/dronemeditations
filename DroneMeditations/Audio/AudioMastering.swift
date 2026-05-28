import Foundation
import AVFoundation

/// Post-recording mastering pipeline. Takes the raw CAF capture and
/// produces TWO files in the Recordings/ folder:
///
///   • `<name>.wav` — uncompressed 24-bit PCM, professional quality,
///     for DAW editing / archival / remastering. Big (~17 MB/min
///     stereo @48k) but bit-perfect.
///   • `<name>.m4a` — AAC sidecar, ~10× smaller, ideal for sharing /
///     AirDrop / email / Music app. Same loudness + fades baked in;
///     just compressed for portability.
///
/// Pipeline:
///   1. **Loudness normalization** — scans the recording, computes its
///      RMS, applies a single gain so the result lands around
///      -16 dBFS RMS (a reasonable proxy for -14 LUFS on stationary
///      ambient/drone content; not true ITU-R BS.1770, but predictable).
///   2. **Fade-in / fade-out** — 2 s in, 4 s out. Softens session edges
///      so the file doesn't start or end with an abrupt click.
///   3. **WAV write** — chunked AVAudioFile read of the CAF, per-frame
///      gain * fade envelope, written to 24-bit PCM WAV.
///   4. **M4A sidecar** — AVAssetExportSession over the mastered WAV
///      with AppleM4A preset. Embeds title/artist/comment metadata.
///      Best-effort: WAV success is required; M4A failure is silent.
enum AudioMastering {

    /// Run the full master on `inputCAFURL` and return the URL of the
    /// finished .wav. The input CAF is deleted on success. A compressed
    /// .m4a sidecar is also written alongside the WAV using the same
    /// gain + fades; `presetName` is embedded as metadata in that M4A.
    /// Throws if the WAV pipeline fails; M4A sidecar failures are
    /// silently swallowed (WAV is the primary deliverable).
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

        // ── 6. Also export an AAC M4A from the finished WAV ───────
        // User wants both: WAV for editing/archival, M4A for easy
        // sharing (~10× smaller, universally playable). The M4A is
        // written alongside the WAV in the Recordings/ folder. If
        // export fails we silently skip — the WAV is the primary
        // output and shouldn't be blocked by a secondary format.
        await exportM4ASidecar(from: outURL, presetName: presetName)

        // ── 7. Clean up the source CAF ────────────────────────────
        try? FileManager.default.removeItem(at: inputCAFURL)
        return outURL
    }

    /// Write a compressed AAC .m4a copy alongside the mastered WAV.
    /// Reads the already-mastered WAV (gain + fades baked in) and runs
    /// it through AVAssetExportSession with the AppleM4A preset.
    /// Best-effort: any failure is logged but not thrown — the WAV is
    /// the primary deliverable and the M4A is a convenience sidecar.
    private static func exportM4ASidecar(from wavURL: URL, presetName: String?) async {
        let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: m4aURL)

        let asset = AVURLAsset(url: wavURL)
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            #if DEBUG
            print("AudioMastering: M4A sidecar — couldn't create export session")
            #endif
            return
        }
        export.outputURL = m4aURL
        export.outputFileType = .m4a
        // Embed friendly metadata so the M4A shows up nicely in
        // Music / Files / share sheets (title, artist, etc).
        let durationSec: Double = {
            if let f = try? AVAudioFile(forReading: wavURL) {
                return Double(f.length) / f.processingFormat.sampleRate
            }
            return 0
        }()
        export.metadata = buildMetadata(presetName: presetName,
                                        durationSec: durationSec)

        do {
            if #available(iOS 18.0, *) {
                try await export.export(to: m4aURL, as: .m4a)
            } else {
                await export.export()
                if let err = export.error {
                    #if DEBUG
                    print("AudioMastering: M4A sidecar export failed: \(err)")
                    #endif
                    return
                }
            }
        } catch {
            #if DEBUG
            print("AudioMastering: M4A sidecar export threw: \(error)")
            #endif
        }
    }

    // MARK: - Metadata (M4A sidecar only)

    /// Build a metadata block embedded into the .m4a so the file's
    /// title/artist/comment fields display nicely in Music, Files, etc.
    /// Not used for WAV — AVAudioFile doesn't support WAV LIST/INFO
    /// metadata writing.
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
