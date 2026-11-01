import Foundation
import Accelerate

/// Turns a stream of mono PCM samples into `AudioFrame`s: Hann window → FFT (Accelerate) → 32 log-spaced bands →
/// dB mapping with sensitivity → smoothing, plus bass/mid/treble, overall level, a downsampled waveform and beat detection.
///
/// Not thread-safe: feed it from one thread (the audio callback) and hand the finished frames to others.
public final class AudioAnalyzer {
    public static let fftSize = 2048
    public static let hop = 1024                       // a new frame every 1024 samples (~21 ms at 48 kHz)
    public static let minimumFrequency = 40.0
    public static let maximumFrequency = 16_000.0
    static let floorDB: Float = -72
    static let ceilingDB: Float = -10

    public var tuning = AudioTuning()
    public let sampleRate: Double

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var ring = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var writeIndex = 0
    private var pending = 0
    private var windowed = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var real = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var imag = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var bandRanges: [ClosedRange<Int>] = []
    private var bandCenters: [Double] = []
    private var smoother = AudioSmoother(count: AudioFrame.bandCount + 1)     // bands + overall level
    private var beats = BeatDetector()
    public private(set) var lastFrame = AudioFrame.silent

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(Self.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = w
        computeBands()
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Frequency (Hz) at the centre of band `i`.
    public func centerFrequency(ofBand i: Int) -> Double { bandCenters[i] }

    private func computeBands() {
        let n = AudioFrame.bandCount
        let ratio = pow(Self.maximumFrequency / Self.minimumFrequency, 1.0 / Double(n))
        let binHz = sampleRate / Double(Self.fftSize)
        let lastBin = Self.fftSize / 2 - 1
        for i in 0..<n {
            let lo = Self.minimumFrequency * pow(ratio, Double(i)), hi = lo * ratio
            let a = min(max(Int((lo / binHz).rounded(.down)), 1), lastBin)
            let b = min(max(Int((hi / binHz).rounded(.up)) - 1, a), lastBin)
            bandRanges.append(a...b)
            bandCenters.append((lo * hi).squareRoot())
        }
    }

    /// Feeds samples; returns the newest frame if at least one hop of new audio has arrived since the last call.
    @discardableResult
    public func process(_ samples: [Float]) -> AudioFrame? {
        var produced: AudioFrame?
        for s in samples {
            ring[writeIndex] = s
            writeIndex = (writeIndex + 1) % Self.fftSize
            pending += 1
            if pending >= Self.hop {
                pending = 0
                produced = analyse()
            }
        }
        if let produced { lastFrame = produced }
        return produced
    }

    public func reset() {
        ring = [Float](repeating: 0, count: Self.fftSize)
        writeIndex = 0; pending = 0
        smoother.reset()
        beats = BeatDetector()
        lastFrame = .silent
    }

    private func analyse() -> AudioFrame {
        // Unroll the ring into time order.
        for i in 0..<Self.fftSize { windowed[i] = ring[(writeIndex + i) % Self.fftSize] }
        let waveform = downsampledWaveform()

        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(Self.fftSize))

        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
        windowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { complex in
                real.withUnsafeMutableBufferPointer { r in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
            }
        }

        let gainDB = 20 * log10(max(tuning.sensitivity, 0.01))
        var targets = [Float](repeating: 0, count: AudioFrame.bandCount + 1)
        for (i, range) in bandRanges.enumerated() {
            var peak: Float = 0
            for k in range { peak = max(peak, magnitudes[k]) }
            // vDSP's real FFT is scaled by 2 and a Hann window has a coherent gain of 0.5, so amplitude = 2·|Z| / N.
            let amplitude = 2 * peak.squareRoot() / Float(Self.fftSize)
            let tilt = Float(3 * log2(bandCenters[i] / 1000))                  // +3 dB/octave: music falls off towards the treble
            targets[i] = Self.mapToUnit(20 * log10(max(amplitude, 1e-7)) + tilt + gainDB)
        }
        targets[AudioFrame.bandCount] = Self.mapToUnit(20 * log10(max(rms, 1e-7)) + 6 + gainDB)

        let dt = Float(Self.hop) / Float(sampleRate)
        let smoothed = smoother.update(targets, dt: dt, smoothing: tuning.smoothing)
        let bands = Array(smoothed[0..<AudioFrame.bandCount])

        let bass = average(bands, where: { $0 < 250 })
        let mid = average(bands, where: { $0 >= 250 && $0 < 4000 })
        let treble = average(bands, where: { $0 >= 4000 })
        let rawBass = average(Array(targets[0..<AudioFrame.bandCount]), where: { $0 < 250 })
        let pulse = beats.update(bass: rawBass, dt: dt)

        return AudioFrame(bands: bands, waveform: waveform, bass: bass, mid: mid, treble: treble,
                          level: smoothed[AudioFrame.bandCount], beat: pulse, beatSerial: beats.serial)
    }

    /// Root-mean-square of the bands in a frequency range: more punch than a plain mean when only a few bands are active.
    private func average(_ bands: [Float], where inRange: (Double) -> Bool) -> Float {
        var sum: Float = 0, n = 0
        for (i, v) in bands.enumerated() where inRange(bandCenters[i]) { sum += v * v; n += 1 }
        return n == 0 ? 0 : (sum / Float(n)).squareRoot()
    }

    private func downsampledWaveform() -> [Float] {
        let group = Self.fftSize / AudioFrame.waveformCount
        let gain = max(tuning.sensitivity, 0.01)
        return (0..<AudioFrame.waveformCount).map { i in
            var mean: Float = 0
            vDSP_meanv(Array(windowed[(i * group)..<((i + 1) * group)]), 1, &mean, vDSP_Length(group))
            return min(max(mean * gain * 2, -1), 1)
        }
    }

    static func mapToUnit(_ db: Float) -> Float { min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1) }
}
