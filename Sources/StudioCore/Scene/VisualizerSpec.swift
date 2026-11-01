import Foundation

public enum VisualizerStyle: String, Codable, Sendable, CaseIterable {
    case bars, mirrorBars, circular, wave

    public var label: String {
        switch self { case .bars: "Spectrum bars"; case .mirrorBars: "Mirrored bars"; case .circular: "Circular"; case .wave: "Waveform" }
    }
}

/// A layer that draws the live audio spectrum or waveform on the GPU.
public struct VisualizerSpec: Codable, Equatable, Sendable {
    public var style = VisualizerStyle.bars
    public var bandCount = 32                 // bars shown, 4...32
    public var amplitude = 0.5                // tallest bar / ring growth / wave height, as a fraction of the canvas
    public var thickness = 0.01               // wave line / ring line width
    public var gap = 0.25                     // empty share of each bar's slot
    public var glow = 0.6
    public var size = 0.22                    // ring radius (circular)
    public var rotationSpeed = 0.0            // turns per second (circular)
    public var hueReactivity = 0.0            // hue turns added at full loudness: colours drift with the music
    public var color = RGBA(0.2, 0.8, 1)      // low frequencies
    public var color2 = RGBA(1, 0.3, 0.7)     // high frequencies

    public init() {}

    public var isValid: Bool {
        (4...32).contains(bandCount) && (0.01...2).contains(amplitude) && (0.0005...0.3).contains(thickness)
            && (0...0.9).contains(gap) && (0...5).contains(glow) && (0.01...0.6).contains(size)
            && rotationSpeed.isFinite && abs(rotationSpeed) <= 5 && hueReactivity.isFinite && abs(hueReactivity) <= 4
            && color.isValid && color2.isValid
    }

    enum CodingKeys: String, CodingKey {
        case style, bandCount, amplitude, thickness, gap, glow, size, rotationSpeed, hueReactivity, color, color2
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VisualizerSpec()
        style = try c.value(.style, d.style); bandCount = try c.value(.bandCount, d.bandCount); amplitude = try c.value(.amplitude, d.amplitude)
        thickness = try c.value(.thickness, d.thickness); gap = try c.value(.gap, d.gap); glow = try c.value(.glow, d.glow)
        size = try c.value(.size, d.size); rotationSpeed = try c.value(.rotationSpeed, d.rotationSpeed)
        hueReactivity = try c.value(.hueReactivity, d.hueReactivity); color = try c.value(.color, d.color); color2 = try c.value(.color2, d.color2)
    }
}
