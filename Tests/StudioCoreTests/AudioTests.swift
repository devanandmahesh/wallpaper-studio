import Testing
import Foundation
@testable import StudioCore

private func sine(_ hz: Double, amplitude: Float = 0.5, seconds: Double, sampleRate: Double = 48_000) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
}

/// Runs a signal through an analyzer in small chunks (like an audio callback) and returns the last frame.
@discardableResult
private func analyse(_ samples: [Float], with a: AudioAnalyzer, chunk: Int = 512) -> AudioFrame {
    var frame = AudioFrame.silent
    var i = 0
    while i < samples.count {
        if let f = a.process(Array(samples[i..<min(i + chunk, samples.count)])) { frame = f }
        i += chunk
    }
    return frame
}

private func peakBand(_ f: AudioFrame) -> Int { f.bands.enumerated().max { $0.element < $1.element }!.offset }

@Suite struct AudioFrameTests {
    @Test func packedLayoutMatchesWhatTheShaderExpects() {
        let f = AudioFrame(bands: (0..<32).map(Float.init), waveform: (0..<64).map { Float($0) / 100 }, bass: 0.1, mid: 0.2, treble: 0.3, level: 0.4, beat: 0.5, beatSerial: 3)
        #expect(f.packed.count == AudioFrame.packedCount && AudioFrame.packedCount == 104)
        #expect(f.packed[0] == 0 && f.packed[31] == 31 && f.packed[32] == 0 && abs(f.packed[95] - 0.63) < 1e-6)
        #expect(Array(f.packed[96...100]) == [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    @Test func shortAndLongArraysArePaddedOrClipped() {
        #expect(AudioFrame(bands: [1, 2]).bands.count == 32 && AudioFrame(bands: [1, 2]).bands[2] == 0)
        #expect(AudioFrame(bands: Array(repeating: 1, count: 99)).bands.count == 32)
        #expect(AudioFrame.silent.packed.allSatisfy { $0 == 0 })
    }

    @Test func smootherAttacksFastAndReleasesSlowly() {
        var s = AudioSmoother(count: 1)
        let up = s.update([1], dt: 0.021, smoothing: 0.5)[0]
        #expect(up > 0.7)                                          // jumps up almost immediately
        let down = s.update([0], dt: 0.021, smoothing: 0.5)[0]
        #expect(down > 0.8 * up)                                   // but falls slowly
        var snappy = AudioSmoother(count: 1), slow = AudioSmoother(count: 1)
        _ = snappy.update([1], dt: 0.1, smoothing: 0); _ = slow.update([1], dt: 0.1, smoothing: 1)
        #expect(snappy.update([0], dt: 0.1, smoothing: 0)[0] < slow.update([0], dt: 0.1, smoothing: 1)[0])
    }

    @Test func beatDetectorFindsKicksButIgnoresSteadyLevelsAndRespectsTheGap() {
        var d = BeatDetector()
        var pulse: Float = 0
        for _ in 0..<200 { pulse = d.update(bass: 0.5, dt: 0.02) }          // steady loud bass
        #expect(d.serial <= 1)
        var kicks = BeatDetector()
        for step in 0..<400 { _ = kicks.update(bass: step % 25 == 0 ? 0.9 : 0.1, dt: 0.02) }     // a kick every 0.5 s for 8 s
        #expect((14...17).contains(kicks.serial), "beats \(kicks.serial)")
        var rapid = BeatDetector()
        for step in 0..<100 { _ = rapid.update(bass: step % 2 == 0 ? 0.9 : 0.05, dt: 0.02) }       // 25 Hz flutter
        #expect(rapid.serial <= 12, "minimum gap should limit beats, got \(rapid.serial)")
        _ = pulse
    }
}

@Suite struct AudioAnalyzerTests {
    @Test func producesAFrameEveryHopAndNoneBefore() {
        let a = AudioAnalyzer()
        #expect(a.process(Array(repeating: 0, count: 1000)) == nil)
        #expect(a.process(Array(repeating: 0, count: 100)) != nil)
        var frames = 0
        let b = AudioAnalyzer()
        for _ in 0..<94 { if b.process(Array(repeating: 0.1, count: 512)) != nil { frames += 1 } }     // ~1 s of audio
        #expect((45...47).contains(frames))
    }

    @Test func silenceGivesAnEmptyFrame() {
        let f = analyse(Array(repeating: 0, count: 48_000), with: AudioAnalyzer())
        #expect(f.level == 0 && f.bass == 0 && f.mid == 0 && f.treble == 0 && f.bands.allSatisfy { $0 == 0 } && f.beatSerial == 0)
    }

    @Test func aToneLightsTheBandAtItsFrequency() {
        let a = AudioAnalyzer()
        for hz in [100.0, 440, 1000, 4000, 10_000] {
            a.reset()
            let f = analyse(sine(hz, seconds: 0.6), with: a)
            let band = peakBand(f)
            let centre = a.centerFrequency(ofBand: band)
            #expect(abs(log2(centre / hz)) < 0.4, "\(hz) Hz → band centred at \(centre) Hz")
            #expect(f.bands[band] > 0.3, "\(hz) Hz weak: \(f.bands[band])")
        }
    }

    @Test func bassMidAndTrebleSeparateTheSpectrum() {
        let a = AudioAnalyzer()
        let low = analyse(sine(90, seconds: 0.6), with: a); a.reset()
        let middle = analyse(sine(1000, seconds: 0.6), with: a); a.reset()
        let high = analyse(sine(9000, seconds: 0.6), with: a)
        #expect(low.bass > low.mid && low.bass > low.treble)
        #expect(middle.mid > middle.bass && middle.mid > middle.treble)
        #expect(high.treble > high.bass && high.treble > high.mid)
    }

    @Test func levelsTrackLoudnessAboutSixDecibelsPerDoubling() {
        let a = AudioAnalyzer(); a.tuning = AudioTuning(sensitivity: 1, smoothing: 0)
        func band(_ amp: Float) -> Float { a.reset(); let f = analyse(sine(1000, amplitude: amp, seconds: 0.6), with: a); return f.bands[peakBand(f)] }
        let quiet = band(0.05), mid = band(0.1), loud = band(0.2)
        #expect(quiet < mid && mid < loud)
        let step = 6.0 / 62.0                                     // 6 dB on a 62 dB scale
        #expect(abs(Double(loud - mid) - step) < 0.04 && abs(Double(mid - quiet) - step) < 0.04, "\(quiet) \(mid) \(loud)")
    }

    @Test func sensitivityIsAGainStage() {
        func peak(sens: Float, amp: Float) -> Float {
            let a = AudioAnalyzer(); a.tuning = AudioTuning(sensitivity: sens, smoothing: 0)
            let f = analyse(sine(1000, amplitude: amp, seconds: 0.6), with: a)
            return f.bands[peakBand(f)]
        }
        #expect(abs(peak(sens: 2, amp: 0.1) - peak(sens: 1, amp: 0.2)) < 0.02)        // ×2 = +6 dB
        #expect(peak(sens: 4, amp: 0.1) > peak(sens: 1, amp: 0.1))
        #expect(peak(sens: 0.25, amp: 0.1) < peak(sens: 1, amp: 0.1))
    }

    @Test func levelsFallAfterTheSoundStopsFasterWithLessSmoothing() {
        func tail(smoothing: Float) -> (Float, Float) {
            let a = AudioAnalyzer(); a.tuning = AudioTuning(sensitivity: 1, smoothing: smoothing)
            let f = analyse(sine(1000, seconds: 0.5), with: a)
            let peak = f.bands[peakBand(f)]
            let after = analyse(Array(repeating: 0, count: 4800), with: a)         // 0.1 s of silence
            return (peak, after.bands[peakBand(f)])
        }
        let fast = tail(smoothing: 0), slow = tail(smoothing: 1)
        #expect(fast.1 < slow.1 && slow.1 > 0.3 * slow.0, "fast \(fast), slow \(slow)")
        let a = AudioAnalyzer()
        analyse(sine(1000, seconds: 0.5), with: a)
        let later = analyse(Array(repeating: 0, count: 96_000), with: a)             // 2 s of silence
        #expect(later.level < 0.01 && later.bands.allSatisfy { $0 < 0.01 })
    }

    @Test func kickDrumsProduceBeatsAndATonedoesNot() {
        // 60 Hz thumps, 90 ms long, twice a second, for 5 s.
        var kick = [Float](repeating: 0, count: 5 * 48_000)
        for beat in 0..<10 {
            let start = beat * 24_000
            for i in 0..<4320 { kick[start + i] = 0.8 * Float(sin(2 * .pi * 60 * Double(i) / 48_000)) * exp(-Float(i) / 1500) }
        }
        let f = analyse(kick, with: AudioAnalyzer())
        #expect((8...12).contains(f.beatSerial), "beats \(f.beatSerial)")
        let steady = analyse(sine(60, amplitude: 0.5, seconds: 5), with: AudioAnalyzer())
        #expect(steady.beatSerial <= 1)
    }

    @Test func waveformFollowsTheSignalShape() {
        let f = analyse(sine(500, amplitude: 0.5, seconds: 0.3), with: AudioAnalyzer())
        #expect(f.waveform.contains { $0 > 0.5 } && f.waveform.contains { $0 < -0.5 })
        #expect(f.waveform.allSatisfy { abs($0) <= 1 })
        let flat = analyse(Array(repeating: 0, count: 8000), with: AudioAnalyzer())
        #expect(flat.waveform.allSatisfy { $0 == 0 })
    }

    @Test func otherSampleRatesPlaceTonesCorrectly() {
        for rate in [44_100.0, 96_000.0] {
            let a = AudioAnalyzer(sampleRate: rate)
            let f = analyse(sine(1000, seconds: 0.6, sampleRate: rate), with: a)
            #expect(abs(log2(a.centerFrequency(ofBand: peakBand(f)) / 1000)) < 0.4, "rate \(rate)")
        }
    }

    @Test func clippedAndLoudInputStaysInRange() {
        let f = analyse(sine(200, amplitude: 4, seconds: 0.5), with: AudioAnalyzer())
        #expect(f.bands.allSatisfy { $0 >= 0 && $0 <= 1 } && f.level <= 1 && f.waveform.allSatisfy { abs($0) <= 1 })
    }
}

@Suite struct AudioSceneTests {
    @Test func bindingsReadTheAudioFrame() {
        let layer = SceneLayer(id: "l", content: .solid(.white), bindings: [
            InputBinding(source: .audioBass, target: .scale, gain: 0.5),
            InputBinding(source: .audioLevel, target: .brightness, gain: 1),
            InputBinding(source: .audioBeat, target: .lightIntensity, gain: 2),
        ])
        let frame = AudioFrame(bass: 0.8, level: 0.5, beat: 1)
        let r = SceneEvaluator.resolve(layer, time: 0, input: SceneInput(audio: frame))
        #expect(abs(r.scale - 1.4) < 1e-6 && abs(r.effects.brightness - 0.5) < 1e-6 && abs(r.effects.lightIntensity - 2) < 1e-6)
        #expect(SceneEvaluator.resolve(layer, time: 0).scale == 1)             // silence = no change
    }

    @Test func sceneFlagsFindAudioUse() {
        func scene(_ l: SceneLayer) -> Scene { Scene(name: "s", layers: [l]) }
        #expect(!scene(SceneLayer(id: "a", content: .solid(.white))).reactsToAudio)
        #expect(scene(SceneLayer(id: "a", content: .visualizer(VisualizerSpec()))).reactsToAudio)
        #expect(scene(SceneLayer(id: "a", content: .solid(.white), bindings: [InputBinding(source: .audioTreble, target: .hueShift, gain: 90)])).reactsToAudio)
        var p = ParticleSpec(); p.audioSizeGain = 1
        #expect(scene(SceneLayer(id: "a", content: .particles(p))).reactsToAudio)
        p = ParticleSpec(); p.beatBurstCount = 10
        #expect(scene(SceneLayer(id: "a", content: .particles(p))).reactsToAudio)
        #expect(scene(SceneLayer(id: "a", content: .visualizer(VisualizerSpec()))).isAnimated)
        #expect(!scene(SceneLayer(id: "a", content: .visualizer(VisualizerSpec()))).reactsToPointer)
    }

    @Test func visualizerSpecsValidateAndRoundTrip() throws {
        var v = VisualizerSpec(); v.style = .circular; v.bandCount = 16; v.hueReactivity = 0.5
        let scene = Scene(name: "v", layers: [SceneLayer(id: "v", content: .visualizer(v))])
        #expect(try SceneCodec.decode(try SceneCodec.encode(scene)) == scene)
        for edit in [{ (s: inout VisualizerSpec) in s.bandCount = 2 }, { $0.bandCount = 33 }, { $0.amplitude = 0 }, { $0.thickness = 1 },
                     { $0.gap = 1 }, { $0.hueReactivity = .nan }, { $0.color = RGBA(2, 0, 0) }] {
            var bad = VisualizerSpec(); edit(&bad)
            #expect(throws: SceneError.self) { try SceneCodec.validate(Scene(name: "b", layers: [SceneLayer(id: "b", content: .visualizer(bad))])) }
        }
        let missing = LayerContent(kind: .visualizer)
        #expect(throws: SceneError.self) { try SceneCodec.validate(Scene(name: "m", layers: [SceneLayer(id: "m", content: missing)])) }
        let partial = try JSONDecoder().decode(VisualizerSpec.self, from: Data(#"{"style":"wave"}"#.utf8))
        #expect(partial.style == .wave && partial.bandCount == 32)
    }

    @Test func particleAudioFieldsRoundTripAndOldFilesStillLoad() throws {
        var p = ParticleSpec(); p.audioSizeGain = 2; p.beatBurstCount = 25
        #expect(try JSONDecoder().decode(ParticleSpec.self, from: JSONEncoder().encode(p)) == p)
        let old = try JSONDecoder().decode(ParticleSpec.self, from: Data(#"{"count":5}"#.utf8))
        #expect(old.audioSizeGain == 0 && old.beatBurstCount == 0)
    }
}
