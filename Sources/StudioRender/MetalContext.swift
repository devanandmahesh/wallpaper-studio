import Metal
import StudioCore

public enum RenderError: Error, LocalizedError {
    case noDevice
    case shaderCompile(String)
    case pipeline(String)
    case texture(String)

    public var errorDescription: String? {
        switch self {
        case .noDevice: "No Metal-capable GPU was found."
        case .shaderCompile(let m): "Shader compilation failed: \(m)"
        case .pipeline(let m): "Could not create a render pipeline: \(m)"
        case .texture(let m): "Could not create a texture: \(m)"
        }
    }
}

/// Long-lived Metal objects shared by every renderer: device, queue, compiled shaders, pipeline states.
/// Created once; nothing here is allocated per frame.
public final class MetalContext {
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let library: MTLLibrary
    private var pipelines: [BlendMode: MTLRenderPipelineState] = [:]
    private var particlePipelines: [BlendMode: MTLRenderPipelineState] = [:]
    let particleUpdate: MTLComputePipelineState
    let whiteTexture: MTLTexture

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        self.queue = queue
        do { library = try device.makeLibrary(source: Shaders.source, options: nil) }
        catch { throw RenderError.shaderCompile(error.localizedDescription) }

        for blend in BlendMode.allCases {
            pipelines[blend] = try Self.makePipeline(device: device, library: library, blend: blend, vertex: "layerVertex", fragment: "layerFragment")
            particlePipelines[blend] = try Self.makePipeline(device: device, library: library, blend: blend, vertex: "particleVertex", fragment: "particleFragment")
        }
        guard let update = library.makeFunction(name: "particleUpdate") else { throw RenderError.pipeline("particleUpdate missing") }
        do { particleUpdate = try device.makeComputePipelineState(function: update) }
        catch { throw RenderError.pipeline(error.localizedDescription) }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: desc) else { throw RenderError.texture("1x1 placeholder") }
        var px: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        whiteTexture = white
    }

    /// One shared context per process (nil if the machine has no usable GPU).
    public static let shared: MetalContext? = try? MetalContext()

    func pipeline(for blend: BlendMode) -> MTLRenderPipelineState? { pipelines[blend] }
    func particlePipeline(for blend: BlendMode) -> MTLRenderPipelineState? { particlePipelines[blend] }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary, blend: BlendMode, vertex: String, fragment: String) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.label = "\(vertex)-\(blend.rawValue)"
        d.vertexFunction = library.makeFunction(name: vertex)
        d.fragmentFunction = library.makeFunction(name: fragment)
        let c = d.colorAttachments[0]!
        c.pixelFormat = pixelFormat
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
        // The shader outputs premultiplied colour.
        switch blend {
        case .normal: c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        case .add: c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
        case .screen: c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceColor
        case .multiply: c.sourceRGBBlendFactor = .destinationColor; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        }
        do { return try device.makeRenderPipelineState(descriptor: d) }
        catch { throw RenderError.pipeline(error.localizedDescription) }
    }
}
