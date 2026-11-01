// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WallpaperStudio",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: models, catalog, logging. Strict Swift 6 concurrency.
        .target(name: "StudioCore"),
        // Metal engine: shaders, scene renderer, textures. No UI; also usable headless (thumbnails, tests).
        .target(name: "StudioRender", dependencies: ["StudioCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // AppKit/SwiftUI app. Stays in Swift 5 mode until the legacy engine is rewritten (Phases 2-3).
        .executableTarget(
            name: "WallpaperStudio",
            dependencies: ["StudioCore", "StudioRender"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]),
        .testTarget(name: "StudioRenderTests", dependencies: ["StudioRender", "StudioCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "WallpaperStudioTests", dependencies: ["WallpaperStudio", "StudioCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
