import Testing
import AppKit
import AVFoundation
import CoreMedia
import StudioCore
@testable import WallpaperStudio

final class FakeCapture: AudioCaptureSource {
    var onSamples: (([Float], Double) -> Void)?
    var onFailure: ((String) -> Void)?
    var permission: AudioPermissionState
    var grantOnRequest = true
    var startError: Error?
    private(set) var starts = 0, stops = 0, requests = 0

    init(permission: AudioPermissionState = .granted) { self.permission = permission }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        requests += 1
        if grantOnRequest { permission = .granted }
        done(grantOnRequest)
    }
    func start() async throws { starts += 1; if let startError { throw startError } }
    func stop() async { stops += 1 }

    /// Feeds a tone through the same path real audio takes.
    func emit(hz: Double, seconds: Double = 0.4, amplitude: Float = 0.5, rate: Double = 48_000) {
        let samples = (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
        var i = 0
        while i < samples.count {
            onSamples?(Array(samples[i..<min(i + 480, samples.count)]), rate)
            i += 480
        }
    }
}

final class FakeFeed: AudioFeed {
    var onNeedsReconcile: (() -> Void)?
    private(set) var isRunning = false
    private(set) var starts = 0, stops = 0
    var frame = AudioFrame.silent
    func start() { if !isRunning { isRunning = true; starts += 1 } }
    func stop() { if isRunning { isRunning = false; stops += 1 } }
    func latest(now: Double) -> AudioFrame { frame }
}

@MainActor
@Suite struct AudioEngineTests {
    func make(mode: AudioMode = .system, capture: FakeCapture, clock: @escaping () -> Double = { 100 }) -> AudioReactiveEngine {
        AudioReactiveEngine(mode: mode, clock: clock, makeCapture: { _ in capture })
    }

    /// Waits (up to 4 s) for asynchronous engine work; other suites may be holding the main thread for a while.
    func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(4)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    func settle() async { try? await Task.sleep(nanoseconds: 60_000_000) }

    @Test func nothingIsCreatedOrStartedWhileAudioIsOff() async {
        var created = 0
        let engine = AudioReactiveEngine(mode: .off, makeCapture: { _ in created += 1; return FakeCapture() })
        engine.start()
        await settle()
        #expect(created == 0 && !engine.isRunning && engine.status == .off)
        #expect(engine.latest(now: 0) == .silent)
    }

    @Test func startingNeverShowsAPermissionPromptAndReportsWhatIsMissing() async {
        let capture = FakeCapture(permission: .notDetermined)
        let engine = make(capture: capture)
        engine.start()
        await settle()
        #expect(capture.requests == 0 && capture.starts == 0)
        if case .needsPermission(let text) = engine.status { #expect(text.contains("Screen")) } else { Issue.record("status \(engine.status)") }
        #expect(!engine.isRunning && engine.latest(now: 100) == .silent)
    }

    @Test func aDeniedPermissionStopsEverythingGracefully() async {
        let capture = FakeCapture(permission: .denied)
        let engine = make(mode: .microphone, capture: capture)
        engine.start()
        await settle()
        #expect(capture.starts == 0)
        if case .needsPermission(let text) = engine.status { #expect(text.contains("Microphone")) } else { Issue.record("status \(engine.status)") }
    }

    @Test func choosingASourceIsTheOnlyThingThatAsksForPermission() async {
        let capture = FakeCapture(permission: .notDetermined)
        let engine = AudioReactiveEngine(mode: .off, makeCapture: { _ in capture })
        var reconciles = 0
        engine.onNeedsReconcile = { reconciles += 1 }
        engine.chooseMode(.system)
        #expect(capture.requests == 1 && engine.mode == .system && reconciles == 1)
        engine.chooseMode(.system)                                    // same choice again: nothing happens
        #expect(capture.requests == 1)
        engine.chooseMode(.off)
        #expect(engine.mode == .off && engine.status == .off)
    }

    @Test func refusingThePromptLeavesAHelpfulMessage() async {
        let capture = FakeCapture(permission: .notDetermined)
        capture.grantOnRequest = false
        let engine = AudioReactiveEngine(mode: .off, makeCapture: { _ in capture })
        engine.chooseMode(.microphone)
        if case .needsPermission = engine.status {} else { Issue.record("status \(engine.status)") }
        engine.start()
        await settle()
        #expect(capture.starts == 0)
    }

    @Test func grantedPermissionStartsCaptureAndTonesBecomeFrames() async {
        let capture = FakeCapture()
        var now = 100.0
        let engine = make(capture: capture, clock: { now })
        engine.start()
        await until { engine.status != .starting }
        #expect(capture.starts == 1 && engine.status == .running && engine.isRunning)
        capture.emit(hz: 80)
        let bass = engine.latest(now: now)
        #expect(bass.bass > 0.3 && bass.bass > bass.treble, "bass \(bass.bass) treble \(bass.treble)")
        capture.emit(hz: 9000)
        let treble = engine.latest(now: now)
        #expect(treble.treble > 0.15 && treble.treble > treble.bass)
        now += 1                                                       // the source went quiet
        #expect(engine.latest(now: now) == .silent)
    }

    @Test func stoppingReleasesTheCaptureAndIgnoresLateSamples() async {
        let capture = FakeCapture()
        let engine = make(capture: capture)
        engine.start(); await until { engine.status != .starting }
        capture.emit(hz: 440, seconds: 0.2)
        let late = capture.onSamples                                    // a callback that was already in flight
        engine.stop(); await until { capture.stops >= 1 }
        #expect(capture.stops == 1 && !engine.isRunning && engine.latest(now: 100) == .silent)
        late?(Array(repeating: 0.5, count: 4800), 48_000)               // must not resurrect old state
        #expect(engine.latest(now: 100) == .silent)
        #expect(engine.status == .idle)
    }

    @Test func aFailingCaptureReportsAndCanBeRetried() async {
        let capture = FakeCapture()
        capture.startError = AudioCaptureError.failed("device went away")
        let engine = make(capture: capture)
        engine.start(); await until { engine.status != .starting }
        if case .failed(let m) = engine.status { #expect(m.contains("device")) } else { Issue.record("status \(engine.status)") }
        #expect(!engine.isRunning)
        capture.startError = nil
        engine.start(); await until { engine.status != .starting }
        #expect(capture.starts == 2 && engine.status == .running)
    }

    @Test func aStreamThatDiesByItselfIsReported() async {
        let capture = FakeCapture()
        let engine = make(capture: capture)
        engine.start(); await until { engine.status != .starting }
        capture.onFailure?("display disconnected")
        await until { engine.status != .running }
        #expect(engine.status == .failed("display disconnected") && !engine.isRunning)
    }

    @Test func theAnalyzerFollowsTheSourceSampleRateAndTheTuning() async {
        let capture = FakeCapture()
        let engine = make(capture: capture)
        engine.start(); await until { engine.status != .starting }
        capture.emit(hz: 1000, rate: 44_100)
        capture.emit(hz: 1000, rate: 96_000)
        #expect(engine.latest(now: 100).mid > 0.2)
        engine.tuning = AudioTuning(sensitivity: 1, smoothing: 0)
        capture.emit(hz: 1000, amplitude: 0.02, rate: 96_000)
        let normal = engine.latest(now: 100).mid
        engine.tuning = AudioTuning(sensitivity: 0.25, smoothing: 0)           // takes effect on the running analyzer
        capture.emit(hz: 1000, amplitude: 0.02, rate: 96_000)
        #expect(engine.latest(now: 100).mid < normal - 0.03, "normal \(normal) → \(engine.latest(now: 100).mid)")
    }
}

@MainActor
@Suite struct AudioHubTests {
    @Test func theFeedRunsOnlyWhileAClientNeedsItAndTheUserChoseASource() {
        let feed = FakeFeed()
        let hub = InteractionHub(pointer: ManualPointerSource(), keys: ManualKeySource(), audio: feed)
        let token = hub.acquire(pointer: false, keys: false, audio: true)
        #expect(!feed.isRunning)                                        // no source chosen yet
        hub.audioEnabled = true
        #expect(feed.isRunning)
        hub.audioEnabled = false
        #expect(!feed.isRunning)
        hub.audioEnabled = true
        hub.release(token)
        #expect(!feed.isRunning && feed.starts == 2 && feed.stops == 2)
    }

    @Test func snapshotsCarryAudioOnlyWhileItIsAllowed() {
        let feed = FakeFeed()
        feed.frame = AudioFrame(bass: 0.9)
        let hub = InteractionHub(pointer: ManualPointerSource(), keys: ManualKeySource(), audio: feed)
        let token = hub.acquire(pointer: false, keys: false, audio: true)
        #expect(hub.snapshot().audio == .silent)
        hub.audioEnabled = true
        #expect(hub.snapshot().audio.bass == 0.9)
        hub.release(token)
        #expect(hub.snapshot().audio == .silent)
    }

    @Test func aGrantedPermissionRestartsAWaitingFeed() {
        let feed = FakeFeed()
        let hub = InteractionHub(pointer: ManualPointerSource(), keys: ManualKeySource(), audio: feed)
        hub.audioEnabled = true
        let token = hub.acquire(pointer: false, keys: false, audio: true)
        feed.stop()
        feed.onNeedsReconcile?()                                        // what the engine does after the user allows access
        #expect(feed.isRunning)
        hub.release(token)
    }
}

@MainActor
@Suite struct AudioRendererIntegrationTests {
    init() { MetalSceneRenderer.pacingMode = .timer }

    func spin(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func layer(_ r: MetalSceneRenderer) -> StudioMetalLayer {
        let l = r.makeLayer() as! StudioMetalLayer
        l.contentsScale = 2
        l.screenFrame = CGRect(x: 0, y: 0, width: 400, height: 200)
        l.bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        return l
    }

    @Test func anAudioSceneAsksForAudioAndReceivesTheFrames() async throws {
        guard NSScreen.main != nil else { return }
        let feed = FakeFeed()
        feed.frame = AudioFrame(bands: Array(repeating: 0.5, count: 32), bass: 0.7, mid: 0.4, treble: 0.2, level: 0.5)
        let hub = InteractionHub(pointer: ManualPointerSource(), keys: ManualKeySource(), audio: feed)
        hub.audioEnabled = true
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.spectrum, assetBase: nil, kind: .scene, wrapsMedia: false,
                                                settings: RenderSettings(maxFPS: 30), loops: true, interaction: hub))
        let l = layer(r)
        #expect(!feed.isRunning)
        r.play(); await spin(0.3)
        #expect(feed.isRunning)
        #expect(r.lastSimInput.audio.bass == 0.7)
        r.pause()
        #expect(!feed.isRunning)                                        // capture stops when the wallpaper stops
        r.teardown()
        withExtendedLifetime(l) {}
    }

    @Test func scenesWithoutAudioNeverTouchTheFeed() async throws {
        guard NSScreen.main != nil else { return }
        let feed = FakeFeed()
        let hub = InteractionHub(pointer: ManualPointerSource(), keys: ManualKeySource(), audio: feed)
        hub.audioEnabled = true
        let r = try #require(MetalSceneRenderer(scene: BuiltInScenes.plasma, assetBase: nil, kind: .scene, wrapsMedia: false,
                                                settings: RenderSettings(maxFPS: 30), loops: true, interaction: hub))
        let l = layer(r)
        r.play(); await spin(0.3)
        #expect(!feed.isRunning && feed.starts == 0)
        r.teardown()
        withExtendedLifetime(l) {}
    }

    @Test func everyBuiltInSceneDeclaresWhatItNeeds() {
        let audio = BuiltInScenes.all.filter(\.reactsToAudio).map(\.name)
        #expect(Set(audio) == ["Spectrum", "Pulse Ring", "Waveform Glow", "Bass Bloom"])
        #expect(BuiltInScenes.all.filter { $0.reactsToAudio }.allSatisfy { $0.isAnimated })
        for scene in BuiltInScenes.all { #expect(throws: Never.self, "\(scene.name)") { try SceneCodec.validate(scene) } }
    }
}

@Suite struct AudioSampleConverterTests {
    @Test func planarAndInterleavedStereoBecomeMono() {
        let left: [Float] = [1, 0, 0.5, -1], right: [Float] = [0, 1, 0.5, -1]
        let mono = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in
            AudioSampleConverter.mono(planar: [l.baseAddress!, r.baseAddress!], frames: 4)
        } }
        #expect(mono == [0.5, 0.5, 0.5, -1])
        let inter: [Float] = [1, 0, 0, 1, 0.5, 0.5, -1, -1]
        #expect(inter.withUnsafeBufferPointer { AudioSampleConverter.mono(interleaved: $0.baseAddress!, channels: 2, frames: 4) } == mono)
        #expect(left.withUnsafeBufferPointer { AudioSampleConverter.mono(planar: [$0.baseAddress!], frames: 4) } == left)
        #expect(AudioSampleConverter.mono(planar: [], frames: 4).isEmpty)
    }

    private func sampleBuffer(planar: Bool, left: [Float], right: [Float]) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1, mBytesPerFrame: planar ? 4 : 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var payload = planar ? left + right : zip(left, right).flatMap { [$0, $1] }
        let bytes = payload.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(with: &payload, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: left.count,
                                                             presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
        return try #require(sb)
    }

    @Test func coreMediaBuffersAreConvertedInBothLayouts() throws {
        let left: [Float] = [0.2, 0.4, 0.6, 0.8], right: [Float] = [0.0, 0.2, 0.4, 0.6]
        for planar in [false, true] {
            let (mono, rate) = try #require(AudioSampleConverter.mono(from: try sampleBuffer(planar: planar, left: left, right: right)), "planar \(planar)")
            #expect(rate == 48_000 && mono.count == 4)
            #expect(zip(mono, [0.1, 0.3, 0.5, 0.7]).allSatisfy { abs($0 - $1) < 1e-6 }, "planar \(planar): \(mono)")
        }
    }
}
