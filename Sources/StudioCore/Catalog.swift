import Foundation

/// Curated free clips from Mixkit (https://mixkit.co/license/#videoFree).
/// Each file URL was checked to exist; `quality` is the highest size Mixkit serves for that clip.
public struct CatalogItem: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let category: String
    public let quality: Int   // 1080 or 720
    public let sizeMB: Int

    public init(id: Int, title: String, category: String, quality: Int, sizeMB: Int) {
        self.id = id; self.title = title; self.category = category; self.quality = quality; self.sizeMB = sizeMB
    }

    public var videoURL: URL { Self.url("https://assets.mixkit.co/videos/\(id)/\(id)-\(quality).mp4") }
    public var thumbURL: URL { Self.url("https://assets.mixkit.co/videos/\(id)/\(id)-thumb-720-0.jpg") }
    public var fileName: String { "mixkit-\(id).mp4" }

    // The strings are built from integers only, so they are always valid URLs.
    private static func url(_ string: String) -> URL { URL(string: string) ?? URL(fileURLWithPath: "/") }
}

public enum Catalog {
    public static let categories = ["All", "Generated", "Nature", "Space", "Sky", "City", "Abstract"]

    public static let items: [CatalogItem] = [
        // Nature
        .init(id: 2213, title: "Forest Waterfall", category: "Nature", quality: 1080, sizeMB: 44),
        .init(id: 4075, title: "Countryside Meadow", category: "Nature", quality: 1080, sizeMB: 75),
        .init(id: 51502, title: "Rocky Coast & Crashing Waves", category: "Nature", quality: 1080, sizeMB: 62),
        .init(id: 51445, title: "Beach Sunset", category: "Nature", quality: 1080, sizeMB: 73),
        .init(id: 4881, title: "Field of Sunflowers", category: "Nature", quality: 1080, sizeMB: 69),
        .init(id: 50847, title: "Tranquil Forest", category: "Nature", quality: 1080, sizeMB: 73),
        .init(id: 1564, title: "White Sand Beach", category: "Nature", quality: 1080, sizeMB: 68),
        // Space
        .init(id: 1610, title: "Stars in Space", category: "Space", quality: 1080, sizeMB: 86),
        .init(id: 10418, title: "Supernova", category: "Space", quality: 1080, sizeMB: 33),
        .init(id: 18791, title: "Wormhole", category: "Space", quality: 720, sizeMB: 5),
        .init(id: 45020, title: "Rotating Black Hole", category: "Space", quality: 720, sizeMB: 2),
        .init(id: 29351, title: "Earth Slowly Spinning", category: "Space", quality: 720, sizeMB: 6),
        .init(id: 14185, title: "Space Nebula", category: "Space", quality: 720, sizeMB: 4),
        .init(id: 45033, title: "Earth from Orbit", category: "Space", quality: 720, sizeMB: 10),
        .init(id: 14540, title: "Rocky Planet Flyover", category: "Space", quality: 720, sizeMB: 5),
        .init(id: 14151, title: "Through the Nebulae", category: "Space", quality: 720, sizeMB: 5),
        // Sky
        .init(id: 4040, title: "Aurora at Dawn", category: "Sky", quality: 1080, sizeMB: 36),
        .init(id: 4034, title: "Pink & Yellow Northern Lights", category: "Sky", quality: 1080, sizeMB: 27),
        .init(id: 39770, title: "Night Sky Full of Stars", category: "Sky", quality: 1080, sizeMB: 45),
        .init(id: 26108, title: "Drifting Clouds", category: "Sky", quality: 1080, sizeMB: 28),
        .init(id: 46119, title: "Starry Desert Night", category: "Sky", quality: 720, sizeMB: 4),
        .init(id: 14468, title: "Star Shower Time-lapse", category: "Sky", quality: 720, sizeMB: 7),
        .init(id: 19636, title: "Milky Way", category: "Sky", quality: 720, sizeMB: 4),
        // City
        .init(id: 49845, title: "Glass Towers at Night", category: "City", quality: 1080, sizeMB: 73),
        .init(id: 49878, title: "Big City at Night", category: "City", quality: 1080, sizeMB: 49),
        .init(id: 4308, title: "City Lights from Above", category: "City", quality: 1080, sizeMB: 42),
        .init(id: 41375, title: "City at Dusk", category: "City", quality: 1080, sizeMB: 50),
        .init(id: 42343, title: "Aerial Night Movement", category: "City", quality: 1080, sizeMB: 93),
        .init(id: 4332, title: "Times Square Rainy Night", category: "City", quality: 1080, sizeMB: 66),
        // Abstract
        .init(id: 44818, title: "Flowing Dark Ink", category: "Abstract", quality: 1080, sizeMB: 69),
        .init(id: 30, title: "Car Light Bokeh", category: "Abstract", quality: 1080, sizeMB: 57),
        .init(id: 31562, title: "Fractal Space Tunnel", category: "Abstract", quality: 720, sizeMB: 5),
        .init(id: 14165, title: "Dream World Clouds", category: "Abstract", quality: 720, sizeMB: 4),
    ]
}
