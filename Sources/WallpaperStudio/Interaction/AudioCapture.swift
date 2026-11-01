import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import StudioCore

enum AudioPermissionState: Equatable { case granted, notDetermined, denied }

enum AudioCaptureError: LocalizedError {
    case permissionDenied(String)
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let m): m
        case .noDisplay: "No display is available to attach the audio stream to."
        case .failed(let m): m
        }
    }
}

/// A source of raw audio. Capturing only ever begins from `start()`, which the engine calls only when the user has
/// chosen this source *and* the system permission is already granted. `requestPermission` is the single place a system
/// prompt can appear, and it is only called from the user's explicit choice in Settings.
protocol AudioCaptureSource: AnyObject {
    /// Mono samples and their sample rate. Called on an audio queue.
    var onSamples: (([Float], Double) -> Void)? { get set }
    /// Called if the stream dies on its own (device removed, permission revoked).
    var onFailure: ((String) -> Void)? { get set }
    var permission: AudioPermissionState { get }
    func requestPermission(_ done: @escaping (Bool) -> Void)
    func start() async throws
    func stop() async
}

/// Conversion helpers (pure, so they can be tested without hardware).
enum AudioSampleConverter {
    /// Averages the channels of planar (`channels[c][i]`) float audio into one mono array.
    static func mono(planar channels: [UnsafePointer<Float>], frames: Int) -> [Float] {
        guard let first = channels.first, frames > 0 else { return [] }
        if channels.count == 1 { return Array(UnsafeBufferPointer(start: first, count: frames)) }
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels.count)
        for ch in channels { for i in 0..<frames { out[i] += ch[i] * scale } }
        return out
    }

    /// Averages interleaved float audio (`l r l r …`) into mono.
    static func mono(interleaved data: UnsafePointer<Float>, channels: Int, frames: Int) -> [Float] {
        guard channels > 0, frames > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data, count: frames)) }
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += data[i * channels + c] }
            out[i] = sum * scale
        }
        return out
    }

    /// Mono samples from a Core Media audio buffer (32-bit float, planar or interleaved), plus its sample rate.
    static func mono(from sampleBuffer: CMSampleBuffer) -> ([Float], Double)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        let result: [Float]? = try? sampleBuffer.withAudioBufferList { list, _ in
            let buffers = Array(list)
            if buffers.count > 1 || asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                let pointers = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }.map { UnsafePointer($0) }
                return mono(planar: pointers, frames: frames)
            }
            guard let b = buffers.first, let data = b.mData?.assumingMemoryBound(to: Float.self) else { return [] }
            return mono(interleaved: data, channels: max(Int(b.mNumberChannels), 1), frames: frames)
        }
        guard let result, !result.isEmpty else { return nil }
        return (result, asbd.mSampleRate)
    }
}

/// System audio (everything the Mac is playing) through ScreenCaptureKit.
///
/// macOS requires the **Screen & System Audio Recording** permission for this, shows a purple recording indicator while
/// it runs, and ties the audio stream to a display; we ask for a 2×2 pixel, 1 fps video stream and discard it, and
/// exclude our own app's sound. Nothing starts until `start()`; the permission prompt appears only via `requestPermission`.
final class SystemAudioCapture: NSObject, AudioCaptureSource, SCStreamOutput, SCStreamDelegate {
    var onSamples: (([Float], Double) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "studio.audio.system", qos: .userInitiated)
    private static let askedKey = "askedScreenCapturePermission"

    var permission: AudioPermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: Self.askedKey) ? .denied : .notDetermined
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        done(CGRequestScreenCaptureAccess())
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw AudioCaptureError.permissionDenied("Allow Wallpaper Studio under System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app.")
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw AudioCaptureError.permissionDenied("macOS did not allow system audio capture: \(error.localizedDescription)") }
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)       // swallow the (tiny) video frames
        try await stream.startCapture()
        self.stream = stream
        Log.engine.info("System audio capture started")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        Log.engine.info("System audio capture stopped")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let (samples, rate) = AudioSampleConverter.mono(from: sampleBuffer) else { return }
        onSamples?(samples, rate)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onFailure?(error.localizedDescription)
    }
}

/// The microphone through `AVAudioEngine`. Needs the Microphone permission (and `NSMicrophoneUsageDescription`).
final class MicrophoneCapture: AudioCaptureSource {
    var onSamples: (([Float], Double) -> Void)?
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?

    var permission: AudioPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.permissionDenied("Allow Wallpaper Studio under System Settings → Privacy & Security → Microphone.")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.failed("No microphone input is available.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) }
            let samples = AudioSampleConverter.mono(planar: channels, frames: Int(buffer.frameLength))
            self?.onSamples?(samples, buffer.format.sampleRate)
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw AudioCaptureError.failed(error.localizedDescription) }
        self.engine = engine
        Log.engine.info("Microphone capture started")
    }

    func stop() async {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        Log.engine.info("Microphone capture stopped")
    }
}
