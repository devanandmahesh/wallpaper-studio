import Foundation

/// Where the audio that drives wallpapers comes from. Nothing is captured unless the user picks a source.
public enum AudioMode: String, Codable, Sendable, CaseIterable {
    case off, system, microphone

    public var label: String {
        switch self { case .off: "Off"; case .system: "System audio"; case .microphone: "Microphone" }
    }
}

/// One analysed slice of sound, everything 0...1 unless noted. Immutable; `packed` is the flat array the GPU reads.
public struct AudioFrame: Equatable, Sendable {
    public static let bandCount = 32
    public static let waveformCount = 64
    /// Layout of `packed`: bands (32), waveform (64, -1...1), then bass, mid, treble, level, beat, 3 spare.
    public static let packedCount = bandCount + waveformCount + 8

    public let bands: [Float]
    public let waveform: [Float]
    public let bass: Float
    public let mid: Float
    public let treble: Float
    public let level: Float
    /// 1 at a detected beat, fading to 0.
    public let beat: Float
    /// Increases by one at every beat (lets consumers react exactly once per beat).
    public let beatSerial: Int
    public let packed: [Float]

    public static let silent = AudioFrame()

    public init(bands: [Float] = [], waveform: [Float] = [], bass: Float = 0, mid: Float = 0, treble: Float = 0,
                level: Float = 0, beat: Float = 0, beatSerial: Int = 0) {
        let b = Self.fit(bands, to: Self.bandCount), w = Self.fit(waveform, to: Self.waveformCount)
        self.bands = b; self.waveform = w
        self.bass = bass; self.mid = mid; self.treble = treble; self.level = level; self.beat = beat; self.beatSerial = beatSerial
        packed = b + w + [bass, mid, treble, level, beat, 0, 0, 0]
    }

    private static func fit(_ a: [Float], to n: Int) -> [Float] {
        a.count == n ? a : Array(a.prefix(n)) + Array(repeating: 0, count: max(0, n - a.count))
    }
}

/// User-adjustable audio behaviour.
public struct AudioTuning: Equatable, Sendable {
    /// Gain applied before the level mapping: 1 = neutral, 2 = twice as sensitive (+6 dB).
    public var sensitivity: Float = 1
    /// 0 = snappy, 1 = slow and fluid.
    public var smoothing: Float = 0.5
    public init(sensitivity: Float = 1, smoothing: Float = 0.5) { self.sensitivity = sensitivity; self.smoothing = smoothing }
}

/// Exponential smoothing with a fast attack and a slower release, so bars jump up with the music and fall gracefully.
public struct AudioSmoother: Sendable {
    public var attackSeconds: Float = 0.015
    private var values: [Float]

    public init(count: Int) { values = Array(repeating: 0, count: count) }

    public mutating func update(_ targets: [Float], dt: Float, smoothing: Float) -> [Float] {
        let release = 0.05 + 0.5 * min(max(smoothing, 0), 1)
        for i in 0..<min(values.count, targets.count) {
            let tau = targets[i] > values[i] ? attackSeconds : release
            values[i] += (targets[i] - values[i]) * (1 - exp(-dt / tau))
        }
        return values
    }

    public mutating func reset() { values = Array(repeating: 0, count: values.count) }
}

/// Detects beats as sudden rises of bass energy over its recent average.
public struct BeatDetector: Sendable {
    public var minimumGapSeconds: Float = 0.18
    public var threshold: Float = 1.35
    /// A beat is a *sudden* rise: at least this much higher than the previous analysis frame.
    public var minimumRise: Float = 0.04
    public private(set) var serial = 0
    private var average: Float = 0
    private var previous: Float = 0
    private var sinceBeat: Float = 10
    private var pulse: Float = 0

    public init() {}

    /// - Returns: the beat pulse (1 at a beat, decaying).
    public mutating func update(bass: Float, dt: Float) -> Float {
        sinceBeat += dt
        pulse *= exp(-dt / 0.25)
        let rising = bass - previous >= minimumRise
        if bass > average * threshold + 0.06 && rising && sinceBeat >= minimumGapSeconds {
            serial += 1
            sinceBeat = 0
            pulse = 1
        }
        average += (bass - average) * (1 - exp(-dt / 1.0))
        previous = bass
        return pulse
    }
}
