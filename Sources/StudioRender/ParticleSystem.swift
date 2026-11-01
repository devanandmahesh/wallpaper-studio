import Metal
import StudioCore

/// GPU state for one particle layer: a fixed buffer of particles (allocated once) plus the bookkeeping for bursts.
/// The simulation itself is the `particleUpdate` compute kernel; `ParticleReference` is its CPU twin.
final class ParticleSystem {
    let spec: ParticleSpec
    let buffer: MTLBuffer
    private var initialized = false
    private var burstCursor: UInt32 = 0
    private var base: ParticleParams

    init?(spec: ParticleSpec, device: MTLDevice) {
        guard let buffer = device.makeBuffer(length: MemoryLayout<ParticleState>.stride * spec.count, options: .storageModeShared) else { return nil }
        buffer.label = "particles"
        self.spec = spec
        self.buffer = buffer
        base = ParticleParams(spec: spec)
    }

    /// Particles currently in the buffer (reads GPU memory; only valid once the GPU has finished). For tests/diagnostics.
    func states() -> [ParticleState] {
        Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: ParticleState.self, capacity: spec.count), count: spec.count))
    }

    /// Records one simulation step. `burstAt` launches `burstCount` particles from that point.
    func encodeUpdate(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                      dt: Float, time: Float, pointer: SIMD2<Float>, pointerActive: Bool, burstAt: SIMD2<Float>?, burstCount: Int? = nil) {
        var p = base
        p.dt = dt
        p.time = time
        p.pointer = pointer
        p.pointerActive = pointerActive ? 1 : 0
        if !initialized {
            p.initialize = 1
            initialized = true
        } else if let burstAt {
            let n = min(burstCount ?? spec.burstCount, spec.count)
            if n > 0 {
                p.burstPosition = burstAt
                p.burstStart = burstCursor
                p.burstCount = UInt32(n)
                burstCursor = (burstCursor + UInt32(n)) % UInt32(spec.count)
            }
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<ParticleParams>.stride, index: 1)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: spec.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    func paramsForDrawing(canvas: SIMD2<Float>, opacity: Float, keyBoost: Float) -> ParticleParams {
        var p = base
        p.canvas = canvas
        p.opacity = opacity
        p.keyBoost = keyBoost
        return p
    }
}
