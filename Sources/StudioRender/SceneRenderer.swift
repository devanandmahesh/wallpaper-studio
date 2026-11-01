import Metal
import QuartzCore
import AVFoundation
import StudioCore

/// Draws a `Scene` with Metal. Scene data (what to draw) is plain `StudioCore` values; this class only turns a
/// resolved scene into GPU commands. It owns the per-scene GPU resources (textures, video sources) and nothing
/// is allocated while a frame is encoded apart from the small resolved-layer array.
public final class SceneRenderer {
    public let context: MetalContext
    public private(set) var scene: Scene
    public let stats = RenderStats()
    /// Assets the scene mentioned that could not be loaded (layers using them are skipped).
    public private(set) var missingAssets: [String] = []
    /// Overrides how image/video layers fit the canvas (used when a plain media file is wrapped in a scene).
    public var mediaScaling: ScalingMode?
    /// Fired when a non-looping video reaches its end.
    public var onVideoEnded: (() -> Void)? { didSet { videoSources.values.forEach { $0.onEnded = onVideoEnded } } }

    private var sources: [String: LayerTexture] = [:]       // layer id → colour source
    public var videoSources: [String: VideoTexture] { sources.compactMapValues { $0 as? VideoTexture } }
    private var depthMaps: [String: MTLTexture] = [:]       // layer id → depth map
    private var particleSystems: [String: ParticleSystem] = [:]
    private var lastSimTime: Double?
    private var lastClickSerial: Int?
    private var lastBeatSerial: Int?

    private let assetBase: URL?
    private let loops: Bool
    private let maxTexture: Int
    private var loadedAssets: [String: String] = [:]          // layer id → "kind:asset:depth" it was loaded from

    /// - Parameters:
    ///   - assetBase: folder that the scene's asset names are resolved against.
    ///   - maxTexture: largest texture dimension to upload (images are decoded at most this large).
    public init(context: MetalContext, scene: Scene, assetBase: URL?, loops: Bool = true, maxTexture: Int = 8192) {
        self.context = context
        self.scene = scene
        self.assetBase = assetBase
        self.loops = loops
        self.maxTexture = maxTexture
        rebuildResources(keepingExisting: false)
    }

    /// Swaps in an edited scene (the editor does this on every change). Textures, video decoders and particle systems of
    /// layers whose content did not change are kept, so editing opacity or position never reloads a movie.
    public func update(_ newScene: Scene) {
        scene = newScene
        rebuildResources(keepingExisting: true)
    }

    private func signature(_ layer: SceneLayer) -> String {
        "\(layer.content.kind.rawValue):\(layer.content.asset ?? ""):\(layer.depthAsset ?? "")"
    }

    private func rebuildResources(keepingExisting keep: Bool) {
        missingAssets = []
        let ids = Set(scene.layers.map(\.id))
        for id in Array(sources.keys) where !ids.contains(id) { sources[id]?.teardown(); sources[id] = nil; depthMaps[id] = nil; loadedAssets[id] = nil }
        for id in Array(particleSystems.keys) where !ids.contains(id) { particleSystems[id] = nil }

        for layer in scene.layers {
            if layer.content.kind == .particles, let spec = layer.content.particles {
                if particleSystems[layer.id]?.spec != spec { particleSystems[layer.id] = ParticleSystem(spec: spec, device: context.device); particleCreations += 1 }
            } else {
                particleSystems[layer.id] = nil
            }

            guard layer.content.isMedia, let name = layer.content.asset else {
                if sources[layer.id] != nil { sources[layer.id]?.teardown(); sources[layer.id] = nil; depthMaps[layer.id] = nil; loadedAssets[layer.id] = nil }
                continue
            }
            if keep, loadedAssets[layer.id] == signature(layer), sources[layer.id] != nil { continue }
            sources[layer.id]?.teardown(); sources[layer.id] = nil; depthMaps[layer.id] = nil
            guard let base = assetBase else { missingAssets.append(name); continue }
            let url = base.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { missingAssets.append(name); continue }
            do {
                switch layer.content.kind {
                case .image: sources[layer.id] = try ImageTexture(url: url, device: context.device, maxDimension: maxTexture); mediaLoads += 1
                case .video:
                    mediaLoads += 1
                    let v = try VideoTexture(url: url, device: context.device, loops: loops)
                    v.onEnded = onVideoEnded
                    sources[layer.id] = v
                default: break
                }
                loadedAssets[layer.id] = signature(layer)
            } catch {
                missingAssets.append(name)
            }
            if let depthName = layer.depthAsset {
                let depthURL = base.appendingPathComponent(depthName)
                if let depth = try? ImageTexture(url: depthURL, device: context.device, maxDimension: maxTexture) {
                    depthMaps[layer.id] = depth.texture(at: 0)
                } else {
                    missingAssets.append(depthName)
                }
            }
        }
    }

    /// How many media sources / particle systems have been created so far (tests use these to prove resources survive edits).
    private(set) var mediaLoads = 0
    private(set) var particleCreations = 0
    func hasSource(layer id: String) -> Bool { sources[id] != nil }
    func hasParticles(layer id: String) -> Bool { particleSystems[id] != nil }

    /// Animated scenes need a frame every tick; static ones only when something changes.
    public var needsContinuousRendering: Bool { scene.isAnimated }
    public var reactsToPointer: Bool { scene.reactsToPointer }

    public func play() { sources.values.forEach { $0.play() } }
    public func pause() { sources.values.forEach { $0.pause() } }
    public func teardown() { sources.values.forEach { $0.teardown() }; sources.removeAll(); depthMaps.removeAll(); particleSystems.removeAll() }

    /// Particle state of one layer (reads GPU memory; call after the GPU finished). For tests and diagnostics.
    func particleStates(layer id: String) -> [ParticleState]? { particleSystems[id]?.states() }

    /// Video sources, for owners that want to control sound.
    public var videoPlayers: [AVQueuePlayerBox] { sources.values.compactMap { ($0 as? VideoTexture).map { AVQueuePlayerBox(player: $0.player) } } }

    /// Steps every particle system up to `time` (one compute pass). Call once per frame, however many targets are drawn.
    /// Mouse clicks that happened since the last call launch bursts; the first call initialises the particles.
    public func advance(commandBuffer: MTLCommandBuffer, time: Double, input: SceneInput) {
        guard !particleSystems.isEmpty else { return }
        let first = lastSimTime == nil
        let dt = Float(min(max(time - (lastSimTime ?? time), 0), 0.05))
        let clicked = lastClickSerial.map { input.clickSerial != $0 } ?? false
        lastClickSerial = input.clickSerial
        let beat = lastBeatSerial.map { input.audio.beatSerial != $0 } ?? false
        lastBeatSerial = input.audio.beatSerial
        guard first || dt > 0 || clicked || beat else { return }
        lastSimTime = time
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "particles"
        for layer in scene.layers {
            guard let system = particleSystems[layer.id] else { continue }
            // A click wins over a beat if both land in the same frame.
            var burstAt: SIMD2<Float>?
            var burstCount: Int?
            if clicked && system.spec.burstCount > 0 {
                burstAt = SIMD2(Float(input.clickX), Float(input.clickY))
            } else if beat && system.spec.beatBurstCount > 0 {
                let s = system.spec
                burstAt = s.shape == .pointer && input.pointerActive ? SIMD2(Float(input.pointerX), Float(input.pointerY)) : SIMD2(Float(s.emitterX), Float(s.emitterY))
                burstCount = s.beatBurstCount
            }
            system.encodeUpdate(encoder, pipeline: context.particleUpdate, dt: dt, time: Float(time),
                                pointer: SIMD2(Float(input.pointerX), Float(input.pointerY)), pointerActive: input.pointerActive,
                                burstAt: burstAt, burstCount: burstCount)
        }
        encoder.endEncoding()
    }

    /// Encodes the whole scene into `target`; committing `commandBuffer` is the caller's job.
    /// `advance` steps the particle simulation first; pass false when the caller already called `advance` this frame.
    public func encode(into target: MTLTexture, commandBuffer: MTLCommandBuffer, time: Double, input: SceneInput = SceneInput(),
                       hostTime: CFTimeInterval = CACurrentMediaTime(), advance doAdvance: Bool = true) {
        if doAdvance { advance(commandBuffer: commandBuffer, time: time, input: input) }
        let start = CACurrentMediaTime()
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.storeAction = .store
        let bg = scene.background
        attachment.clearColor = MTLClearColor(red: Double(bg.r), green: Double(bg.g), blue: Double(bg.b), alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "scene"

        let canvas = SIMD2<Float>(Float(target.width), Float(target.height))
        for var resolved in SceneEvaluator.resolve(scene, time: time, input: input) where resolved.opacity > 0 {
            if let scaling = mediaScaling, resolved.content.isMedia { resolved.scaling = scaling }
            if resolved.content.kind == .particles {
                guard let system = particleSystems[resolved.id], let pipeline = context.particlePipeline(for: resolved.blend) else { continue }
                var params = system.paramsForDrawing(canvas: canvas, opacity: Float(resolved.opacity),
                                                     keyBoost: Float(input.keyPulse * (resolved.content.particles?.keyGain ?? 0)) + input.audio.bass * Float(resolved.content.particles?.audioSizeGain ?? 0))
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(system.buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&params, length: MemoryLayout<ParticleParams>.stride, index: 1)
                encoder.setFragmentBytes(&params, length: MemoryLayout<ParticleParams>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: system.spec.count)
                continue
            }
            var texture: MTLTexture = context.whiteTexture
            var aspect: Double?
            if resolved.content.isMedia {
                guard let source = sources[resolved.id], let t = source.texture(at: hostTime) else { continue }   // not ready yet: skip layer
                texture = t
                aspect = source.aspect
            }
            guard let pipeline = context.pipeline(for: resolved.blend) else { continue }
            let depth = depthMaps[resolved.id]
            var uniforms = LayerUniforms(layer: resolved, contentAspect: aspect, canvasSize: canvas, time: time, hasDepth: depth != nil, audioLevel: input.audio.level)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            input.audio.packed.withUnsafeBytes { if let base = $0.baseAddress { encoder.setFragmentBytes(base, length: $0.count, index: 1) } }
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(depth ?? context.whiteTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        let encodeSeconds = CACurrentMediaTime() - start
        let stats = self.stats
        commandBuffer.addCompletedHandler { buffer in
            stats.record(encodeSeconds: encodeSeconds, gpuSeconds: max(buffer.gpuEndTime - buffer.gpuStartTime, 0))
        }
    }
}

/// Small wrapper so callers outside this module can reach a video's player without importing internals.
public struct AVQueuePlayerBox {
    public let player: AVQueuePlayer
}
