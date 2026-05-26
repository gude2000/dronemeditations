import Foundation
import AVFoundation
import Accelerate
import Combine

/// Live FFT-based spectrum source. Installs a tap on the engine's main
/// mixer, runs a Hann-windowed FFT per buffer on the audio thread, and
/// publishes log-magnitude bins for SwiftUI to read. Off by default;
/// `start()` and `stop()` are idempotent.
final class SpectrumTap: ObservableObject {
    /// Magnitudes in 0…1, length = `binCount`. Updated on main thread.
    @Published private(set) var bins: [Float] = []
    @Published private(set) var isActive: Bool = false

    private let engine: AudioEngine
    private let log2N: vDSP_Length
    private let n: Int
    private let binCount: Int

    // Audio-thread state. Not actor-isolated; the tap callback is the only
    // place that touches them, and the tap fires sequentially per voice.
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var hann: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var magBuf: [Float]
    // Locally-computed bins; copied to @Published `bins` on main.
    private var localBins: [Float]

    init(engine: AudioEngine, fftSize: Int = 2048) {
        self.engine = engine
        self.n = fftSize
        self.log2N = vDSP_Length(log2(Double(fftSize)))
        self.binCount = fftSize / 2
        var h = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&h, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.hann = h
        self.realBuf = [Float](repeating: 0, count: fftSize / 2)
        self.imagBuf = [Float](repeating: 0, count: fftSize / 2)
        self.magBuf  = [Float](repeating: 0, count: fftSize / 2)
        self.localBins = [Float](repeating: 0, count: fftSize / 2)
        self.fftSetup = vDSP.FFT(log2n: log2N, radix: .radix2, ofType: DSPSplitComplex.self)
        self.bins = [Float](repeating: 0, count: binCount)
    }

    func start() {
        guard !isActive else { return }
        // Tap the main mixer node. We previously tapped outputNode, but
        // iOS sometimes throws an NSException on outputNode taps when
        // the device session isn't in a fully-tappable state (e.g. right
        // after a session reconfiguration from Listen / mic detector).
        // The NSException is uncatchable from Swift and crashes the app.
        //
        // mainMixerNode is reliably tappable. It conflicts with the
        // recording tap if active, so we noop in that case — the user
        // can re-enable the analyzer after they stop recording. Also
        // wrap the install in a defensive try/catch via an NSException
        // helper would be ideal but Swift can't catch ObjC exceptions;
        // instead we validate format aggressively before the call.
        if engine.isRecording {
            // Recording tap occupies the same node-bus. Don't crash; leave
            // isActive=false so the UI toggle reflects reality and the user
            // can try again after stopping recording.
            DispatchQueue.main.async { self.isActive = false }
            return
        }
        // Ensure the engine is running before we tap — the output format
        // is invalid (0/0) until the engine has been started and connected.
        if !engine.engine.isRunning {
            try? engine.engine.start()
        }
        let mixer = engine.engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            // Format not ready yet — bail without crashing. The UI button
            // toggles back off naturally because we never flip isActive.
            return
        }
        // installTap will throw an ObjC exception if a tap is already
        // installed. removeTap is a safe no-op if there isn't one, so we
        // call it pre-emptively to clear any stale tap from a previous
        // session config change.
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(n), format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
        DispatchQueue.main.async { self.isActive = true }
    }

    func stop() {
        guard isActive else { return }
        engine.engine.mainMixerNode.removeTap(onBus: 0)
        DispatchQueue.main.async {
            self.isActive = false
            self.bins = [Float](repeating: 0, count: self.binCount)
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        if frameCount < n { return }   // tap should fire with ≥ n; if not, drop

        // Window the latest n samples.
        var windowed = [Float](repeating: 0, count: n)
        for i in 0..<n {
            windowed[i] = ch[i] * hann[i]
        }

        realBuf.withUnsafeMutableBufferPointer { rPtr in
            imagBuf.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fftSetup?.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &magBuf, 1, vDSP_Length(n / 2))
            }
        }

        // sqrt compression so the display feels responsive to quiet content.
        let scale: Float = 1.0 / Float(n)
        for i in 0..<binCount {
            localBins[i] = min(1, sqrt(magBuf[i] * scale * 8))
        }
        let snapshot = localBins
        DispatchQueue.main.async {
            self.bins = snapshot
        }
    }
}
