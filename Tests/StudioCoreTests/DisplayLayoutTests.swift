import Testing
import Foundation
import CoreGraphics
@testable import StudioCore

@Suite struct DisplayLayoutTests {
    @Test func signatureIgnoresOrder() {
        #expect(DisplayLayoutState.signature(of: ["b", "a"]) == DisplayLayoutState.signature(of: ["a", "b"]))
        #expect(DisplayLayoutState.signature(of: ["a"]) != DisplayLayoutState.signature(of: ["a", "b"]))
    }

    @Test func modeDefaultsToMirrorAndIsRememberedPerDisplaySet() {
        var state = DisplayLayoutState()
        #expect(state.mode(for: ["laptop"]) == .mirror)
        state.setMode(.independent, for: ["laptop", "monitor"])
        state.setMode(.span, for: ["laptop"])
        #expect(state.mode(for: ["monitor", "laptop"]) == .independent)   // docked
        #expect(state.mode(for: ["laptop"]) == .span)                     // undocked
        #expect(state.mode(for: ["other"]) == .mirror)
    }

    @Test func reconnectedDisplayGetsItsConfigBack() {
        var state = DisplayLayoutState()
        state.configs["uuid-1"] = DisplayConfig(wallpaperPath: "/a.mp4", scaling: .fit, rotation: .r90, maxFPS: 15)
        state.remember(name: "LG", uuid: "uuid-1")
        // The display disappears and later returns under a different CGDirectDisplayID; the UUID is the identity.
        #expect(state.configs["uuid-1"]?.rotation == .r90)
        state.forget(uuid: "uuid-1")
        #expect(state.configs["uuid-1"] == nil && state.knownNames["uuid-1"] == nil)
    }

    @Test func configMapsToRenderSettings() {
        let c = DisplayConfig(scaling: .stretch, maxFPS: 24, speed: 2, volume: 0.25, muted: false)
        #expect(c.renderSettings == RenderSettings(scaling: .stretch, speed: 2, volume: 0.25, muted: false, maxFPS: 24))
    }

    @Test func storeRoundTripsAndTreatsMissingFileAsDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)/displays.json")
        let store = DisplayLayoutStore(url: url)
        #expect(store.load() == DisplayLayoutState())
        var state = DisplayLayoutState()
        state.configs["u"] = DisplayConfig(wallpaperPath: "/x.gif", rotation: .r270, paused: true)
        state.setMode(.independent, for: ["u"])
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test func damagedFileYieldsDefaultsAndIsKeptAsCorrupt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("displays.json")
        try Data("{ not json".utf8).write(to: url)
        #expect(DisplayLayoutStore(url: url).load() == DisplayLayoutState())
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func stateFromANewerVersionIsNotOverwrittenSilently() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("displays.json")
        try Data(#"{"version":9,"configs":{},"modes":{},"knownNames":{}}"#.utf8).write(to: url)
        #expect(DisplayLayoutStore(url: url).load() == DisplayLayoutState())
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }
}

@Suite struct LayoutGeometryTests {
    @Test func unionOfSideBySideDisplays() {
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let b = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        #expect(SpanLayout.union(of: [a, b]) == CGRect(x: 0, y: 0, width: 4480, height: 1440))
    }

    @Test func unionHandlesNegativeOriginsAndStackedDisplays() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        #expect(SpanLayout.union(of: [left, main, above]) == CGRect(x: -1920, y: 0, width: 3840, height: 2160))
        #expect(SpanLayout.union(of: []) == .zero)
    }

    @Test func eachDisplayShowsItsSliceOfTheSpanPicture() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let union = SpanLayout.union(of: [left, main])
        #expect(SpanLayout.contentFrame(union: union, screen: left) == CGRect(x: 0, y: 0, width: 3840, height: 1080))
        #expect(SpanLayout.contentFrame(union: union, screen: main) == CGRect(x: -1920, y: 0, width: 3840, height: 1080))
    }

    @Test func singleDisplaySpanEqualsFullScreen() {
        let f = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(SpanLayout.contentFrame(union: SpanLayout.union(of: [f]), screen: f) == CGRect(origin: .zero, size: f.size))
    }

    @Test func rotationSwapsSizeForQuarterTurns() {
        let screen = CGSize(width: 1920, height: 1080)
        #expect(RotationGeometry.layerGeometry(screen: screen, rotation: .r0).size == screen)
        #expect(RotationGeometry.layerGeometry(screen: screen, rotation: .r180).size == screen)
        let r90 = RotationGeometry.layerGeometry(screen: screen, rotation: .r90)
        #expect(r90.size == CGSize(width: 1080, height: 1920))
        #expect(abs(r90.angle + .pi / 2) < 1e-9)                                  // clockwise = negative z-rotation
        #expect(RotationGeometry.layerGeometry(screen: screen, rotation: .r270).size == CGSize(width: 1080, height: 1920))
        #expect(abs(RotationGeometry.layerGeometry(screen: screen, rotation: .r180).angle + .pi) < 1e-9)
    }

    @Test func frameLimiterLeavesSlowAnimationsAlone() {
        let delays = Array(repeating: 0.1, count: 5)
        let identity = FrameRateLimiter.reduce(delays: delays, maxFPS: nil)
        #expect(identity.map(\.source) == [0, 1, 2, 3, 4])
        #expect(FrameRateLimiter.reduce(delays: delays, maxFPS: 30).map(\.source) == [0, 1, 2, 3, 4])   // 10 fps already under 30
    }

    @Test func frameLimiterResamplesFastAnimationsAndKeepsTotalDuration() {
        let delays = Array(repeating: 0.04, count: 10)          // 25 fps, 0.4 s
        let out = FrameRateLimiter.reduce(delays: delays, maxFPS: 10)
        #expect(out.map(\.source) == [0, 2, 5, 7])
        #expect(abs(out.reduce(0) { $0 + $1.delay } - 0.4) < 1e-9)
        #expect(out.allSatisfy { $0.delay >= 0.1 - 1e-9 })
    }

    @Test func frameLimiterHandlesUnevenDelaysAndTinyInputs() {
        let out = FrameRateLimiter.reduce(delays: [0.02, 0.02, 0.5, 0.02], maxFPS: 15)
        #expect(abs(out.reduce(0) { $0 + $1.delay } - 0.56) < 1e-9)
        #expect(out.first?.source == 0)
        #expect(FrameRateLimiter.reduce(delays: [0.05], maxFPS: 5).map(\.source) == [0])
        #expect(FrameRateLimiter.reduce(delays: [], maxFPS: 5).isEmpty)
        #expect(FrameRateLimiter.reduce(delays: [0.01, 0.01], maxFPS: 0).count == 2)
    }
}
