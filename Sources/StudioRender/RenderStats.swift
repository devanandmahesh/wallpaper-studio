import Foundation

/// Measured render cost. Updated from GPU completion handlers, read from anywhere.
public final class RenderStats {
    public struct Snapshot: Equatable {
        public var frames = 0
        public var averageGPUMilliseconds = 0.0
        public var averageEncodeMilliseconds = 0.0
        public var maxGPUMilliseconds = 0.0
        public init() {}
        public init(frames: Int, averageGPUMilliseconds: Double, averageEncodeMilliseconds: Double, maxGPUMilliseconds: Double) {
            self.frames = frames; self.averageGPUMilliseconds = averageGPUMilliseconds
            self.averageEncodeMilliseconds = averageEncodeMilliseconds; self.maxGPUMilliseconds = maxGPUMilliseconds
        }
    }

    private let lock = NSLock()
    private var frames = 0
    private var gpuTotal = 0.0, encodeTotal = 0.0, gpuMax = 0.0

    public init() {}

    func record(encodeSeconds: Double, gpuSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        encodeTotal += encodeSeconds * 1000
        gpuTotal += gpuSeconds * 1000
        gpuMax = max(gpuMax, gpuSeconds * 1000)
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard frames > 0 else { return Snapshot() }
        return Snapshot(frames: frames, averageGPUMilliseconds: gpuTotal / Double(frames),
                        averageEncodeMilliseconds: encodeTotal / Double(frames), maxGPUMilliseconds: gpuMax)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        frames = 0; gpuTotal = 0; encodeTotal = 0; gpuMax = 0
    }
}
