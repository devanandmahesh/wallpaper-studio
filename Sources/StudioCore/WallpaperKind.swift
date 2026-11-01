/// What a wallpaper file contains, decided from its extension.
public enum WallpaperKind: String, Sendable, CaseIterable {
    case video, image, animatedImage, scene, package

    private static let table: [String: WallpaperKind] = {
        var t: [String: WallpaperKind] = [:]
        for e in ["mp4", "mov", "m4v"] { t[e] = .video }
        for e in ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "webp"] { t[e] = .image }
        for e in ["gif", "apng"] { t[e] = .animatedImage }
        t[SceneCodec.fileExtension] = .scene
        t["wsp"] = .package
        return t
    }()

    public static func detect(pathExtension: String) -> WallpaperKind? { table[pathExtension.lowercased()] }

    public static var supportedExtensions: Set<String> { Set(table.keys) }
}

/// How content is fitted to the display.
public enum ScalingMode: String, Codable, Sendable, CaseIterable {
    case fill      // keep aspect ratio, crop the overflow
    case fit       // keep aspect ratio, letterbox
    case stretch   // ignore aspect ratio

    public var label: String {
        switch self { case .fill: "Fill (crop)"; case .fit: "Fit (letterbox)"; case .stretch: "Stretch" }
    }
}

/// User-adjustable look/feel values every renderer understands (each ignores what does not apply to it).
public struct RenderSettings: Equatable, Sendable {
    public var scaling: ScalingMode
    public var speed: Float
    public var volume: Float
    public var muted: Bool
    /// Frame-rate ceiling. GIFs are resampled; videos and scenes are drawn by the Metal renderer at this rate.
    public var maxFPS: Int?
    /// Visual effect laid over images and videos (drawn on the GPU).
    public var effect: EffectPreset
    /// Fraction of native resolution the GPU renderer draws at (0.25...1).
    public var resolutionScale: Float
    /// Ceiling imposed by the performance policy (battery, heat, load). Never makes a plain video take the costlier GPU path.
    public var performanceFPSCap: Int?

    public init(scaling: ScalingMode = .fill, speed: Float = 1, volume: Float = 0.5, muted: Bool = true, maxFPS: Int? = nil,
                effect: EffectPreset = .none, resolutionScale: Float = 1, performanceFPSCap: Int? = nil) {
        self.scaling = scaling; self.speed = speed; self.volume = volume; self.muted = muted; self.maxFPS = maxFPS
        self.effect = effect; self.resolutionScale = resolutionScale; self.performanceFPSCap = performanceFPSCap
    }
}
