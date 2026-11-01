import Testing
@testable import StudioCore

@Suite struct WallpaperKindTests {
    @Test func detectsEachKind() {
        #expect(WallpaperKind.detect(pathExtension: "mp4") == .video)
        #expect(WallpaperKind.detect(pathExtension: "MOV") == .video)
        #expect(WallpaperKind.detect(pathExtension: "heic") == .image)
        #expect(WallpaperKind.detect(pathExtension: "JPG") == .image)
        #expect(WallpaperKind.detect(pathExtension: "gif") == .animatedImage)
    }

    @Test func rejectsUnsupportedFormats() {
        for ext in ["mkv", "webm", "txt", ""] { #expect(WallpaperKind.detect(pathExtension: ext) == nil, "\(ext)") }
    }

    @Test func defaultSettingsAreMutedFill() {
        let s = RenderSettings()
        #expect(s.scaling == .fill && s.muted && s.speed == 1 && s.maxFPS == nil)
    }
}
