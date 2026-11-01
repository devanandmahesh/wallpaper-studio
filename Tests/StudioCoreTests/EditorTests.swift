import Testing
import Foundation
@testable import StudioCore

@Suite struct EditorDocumentTests {
    func doc() -> EditorDocument { EditorDocument.blank() }

    @Test func aBlankDocumentIsAValidScene() throws {
        try doc().validate()
        #expect(doc().scene.layers.count == 1)
    }

    @Test func layersGetUniqueIDsAndKeepDrawingOrder() throws {
        var d = doc()
        let a = d.addLayer(.solid(.white)), b = d.addLayer(.solid(.black)), c = d.addLayer(.procedural(.plasma, .black, .white))
        #expect(Set([a, b, c]).count == 3 && d.scene.layers.map(\.id).suffix(3) == [a, b, c])
        d.removeLayer(a)
        let again = d.addLayer(.solid(.white))
        #expect(again == a)                                         // freed ids are reused
        #expect(d.addLayer(.particles(ParticleSpec()), at: 0) != again && d.scene.layers.first?.content.kind == .particles)
        try d.validate()
    }

    @Test func duplicatesAreIndependentAndNextToTheOriginal() throws {
        var d = doc()
        let a = d.addLayer(.solid(RGBA(1, 0, 0)), name: "Red")
        let copyOptional = d.duplicateLayer(a)
        let copy = try #require(copyOptional)
        #expect(copy != a && d.index(of: copy) == (d.index(of: a) ?? 0) + 1 && d.layer(copy)?.name == "Red copy")
        d.setBase(layer: copy, .opacity, 0.2)
        #expect(d.layer(a)?.opacity == 1)
        #expect(d.duplicateLayer("nope") == nil)
    }

    @Test func reorderingAndRemovingKeepsTheSceneValid() throws {
        var d = doc()
        let a = d.addLayer(.solid(.white)), b = d.addLayer(.solid(.black))
        d.moveLayer(b, to: 0)
        #expect(d.scene.layers.first?.id == b)
        d.moveLayer(a, to: 99)
        #expect(d.scene.layers.last?.id == a)
        let zoneOptional = d.addZone(layerID: a)
        let zone = try #require(zoneOptional)
        d.removeLayer(a)
        #expect(d.scene.zones.isEmpty && !d.scene.zones.contains { $0.id == zone })        // zones die with their layer
        try d.validate()
    }

    @Test func settingBaseValuesRoundTripsEveryAnimatableProperty() {
        var d = doc()
        let id = d.addLayer(.solid(.white))
        for (i, p) in AnimatableProperty.allCases.enumerated() {
            let v = 0.1 + Double(i) * 0.05
            d.setBase(layer: id, p, v)
            #expect(d.layer(id)?.baseValue(p) == v, "\(p)")
        }
        d.setBase(layer: id, .scale, -3)
        #expect((d.layer(id)?.scale ?? 0) > 0)                       // never invalid
    }

    @Test func keyframesAreAddedReplacedSortedMovedAndRemoved() throws {
        var d = doc()
        let id = d.addLayer(.solid(.white))
        d.setKeyframe(layer: id, property: .opacity, time: 4, value: 1)
        d.setKeyframe(layer: id, property: .opacity, time: 1, value: 0)
        d.setKeyframe(layer: id, property: .opacity, time: 1, value: 0.25)             // replaces the one at t = 1
        var track = try #require(d.layer(id)?.tracks.first)
        #expect(track.keyframes.map(\.time) == [1, 4] && track.keyframes[0].value == 0.25)
        #expect(abs((d.value(layer: id, property: .opacity, at: 2.5) ?? -1) - 0.625) < 1e-9)        // halfway between 0.25 and 1
        let movedOptional = d.moveKeyframe(layer: id, property: .opacity, index: 0, to: 6)
        let moved = try #require(movedOptional)
        track = try #require(d.layer(id)?.tracks.first)
        #expect(moved == 1 && track.keyframes.map(\.time) == [4, 6])
        d.setEasing(layer: id, property: .opacity, index: 0, easing: .easeIn)
        d.setKeyframeValue(layer: id, property: .opacity, index: 0, value: 0.5)
        d.setLoop(layer: id, property: .opacity, loop: .pingPong)
        track = try #require(d.layer(id)?.tracks.first)
        #expect(track.keyframes[0].easing == .easeIn && track.keyframes[0].value == 0.5 && track.loop == .pingPong)
        d.removeKeyframe(layer: id, property: .opacity, index: 0)
        d.removeKeyframe(layer: id, property: .opacity, index: 0)
        #expect(d.layer(id)?.tracks.isEmpty == true)                  // an empty track is dropped
        d.removeKeyframe(layer: id, property: .opacity, index: 5)     // out of range: ignored
        try d.validate()
    }

    @Test func keyframesStayInsideTheTimeline() throws {
        var d = doc()
        let id = d.addLayer(.solid(.white))
        d.setKeyframe(layer: id, property: .scale, time: 999, value: 2)
        d.setKeyframe(layer: id, property: .scale, time: -5, value: 1)
        #expect(d.layer(id)?.tracks.first?.keyframes.map(\.time) == [0, d.duration])
    }

    @Test func changingTheTimelineLengthRescalesCyclingTracks() {
        var d = doc()
        let id = d.addLayer(.solid(.white))
        d.setKeyframe(layer: id, property: .opacity, time: 0, value: 0)
        let before = d.layer(id)?.tracks.first?.duration
        #expect(before == 10)
        d.setDuration(30)
        #expect(d.duration == 30 && d.layer(id)?.tracks.first?.duration == 30)
        d.setDuration(0)
        #expect(d.duration == EditorDocument.minimumDuration)
    }

    @Test func bindingsAreLimitedAndRemovable() {
        var d = doc()
        let id = d.addLayer(.solid(.white))
        for _ in 0..<20 { d.addBinding(layer: id, InputBinding(source: .audioBass, target: .scale, gain: 0.1)) }
        #expect(d.layer(id)?.bindings.count == 16)
        d.removeBinding(layer: id, index: 0); d.removeBinding(layer: id, index: 99)
        #expect(d.layer(id)?.bindings.count == 15)
    }

    @Test func zonesStayOnTheCanvas() throws {
        var d = doc()
        let id = d.addLayer(.solid(.white))
        let zOptional = d.addZone(layerID: id)
        let z = try #require(zOptional)
        d.updateZone(z) { $0.x = 0.9; $0.width = 0.5 }
        let zone = try #require(d.scene.zones.first)
        #expect(zone.x + zone.width <= 1.0001 && zone.x >= 0)
        d.updateZone(z) { $0.width = -1; $0.height = 5 }
        #expect(d.scene.zones[0].width >= 0.01 && d.scene.zones[0].height <= 1)
        try d.validate()
        #expect(d.addZone(layerID: "ghost") == nil)
    }

    @Test func everyBuiltInSceneSurvivesEditingAndStaysValid() throws {
        for scene in BuiltInScenes.all {
            var d = EditorDocument(scene: scene)
            let first = try #require(d.scene.layers.first?.id)
            d.setBase(layer: first, .opacity, 0.5)
            d.setKeyframe(layer: first, property: .rotation, time: 0, value: 0)
            d.setKeyframe(layer: first, property: .rotation, time: 5, value: 10)
            _ = d.duplicateLayer(first)
            try d.validate()
        }
    }

    @Test func particlePresetsAreValidParticleLayers() throws {
        for preset in ParticlePreset.allCases {
            var d = doc()
            d.addLayer(.particles(preset.spec), name: preset.label)
            try d.validate()
        }
    }
}

@Suite struct EditorHistoryTests {
    @Test func undoAndRedoWalkThroughStates() {
        var h = EditorHistory<Int>()
        var state = 0
        for next in 1...3 { h.willChange(from: state); state = next }
        #expect(h.canUndo && !h.canRedo)
        state = h.undo(current: state) ?? -1; #expect(state == 2)
        state = h.undo(current: state) ?? -1; #expect(state == 1)
        #expect(h.canRedo)
        state = h.redo(current: state) ?? -1; #expect(state == 2)
        state = h.redo(current: state) ?? -1; #expect(state == 3)
        #expect(h.redo(current: state) == nil)
    }

    @Test func aNewEditClearsTheRedoStack() {
        var h = EditorHistory<Int>()
        h.willChange(from: 0)
        let back = h.undo(current: 1)
        #expect(back == 0 && h.canRedo)
        h.willChange(from: 0)
        #expect(!h.canRedo)
    }

    @Test func draggingASliderIsOneUndoStep() {
        var h = EditorHistory<Int>()
        var state = 0
        for (i, v) in [1, 2, 3, 4, 5].enumerated() { h.willChange(from: state, key: "opacity", at: Double(i) * 0.1); state = v }
        #expect(h.undoStack.count == 1)
        #expect(h.undo(current: state) == 0)                        // one undo returns to before the drag
        h.clear()
        h.willChange(from: 0, key: "opacity", at: 0); h.willChange(from: 1, key: "scale", at: 0.1)
        #expect(h.undoStack.count == 2)                             // different properties are separate steps
        h.willChange(from: 2, key: "scale", at: 5)
        #expect(h.undoStack.count == 3)                             // a long pause starts a new step
    }

    @Test func historyIsBounded() {
        var h = EditorHistory<Int>()
        h.limit = 5
        for i in 0..<50 { h.willChange(from: i) }
        #expect(h.undoStack.count == 5 && h.undoStack.last == 49)
        #expect(EditorHistory<Int>().undoStack.isEmpty)
        var empty = EditorHistory<Int>()
        #expect(empty.undo(current: 1) == nil)
    }
}

@Suite struct ZoneAndSyntheticAudioTests {
    func lightScene(zones: [InteractionZone]) -> Scene {
        Scene(name: "z", layers: [SceneLayer(id: "l", content: .solid(RGBA(0, 0, 0, 0)))], zones: zones)
    }

    @Test func hoverZonesAddTheirAmountWhileThePointerIsInside() {
        let zone = InteractionZone(id: "z", x: 0.5, y: 0, width: 0.5, height: 0.5, trigger: .hover, layerID: "l", property: .brightness, amount: 0.4)
        let s = lightScene(zones: [zone])
        func brightness(_ x: Double, _ y: Double, active: Bool = true) -> Double {
            SceneEvaluator.resolve(s, time: 0, input: SceneInput(pointerX: x, pointerY: y, pointerActive: active))[0].effects.brightness
        }
        #expect(abs(brightness(0.5, 0.5) - 0.4) < 1e-9)              // pointer in the top-right quarter (x right, y up)
        #expect(brightness(-0.5, 0.5) == 0 && brightness(0.5, -0.5) == 0)
        #expect(brightness(0.5, 0.5, active: false) == 0)            // cursor on another display
    }

    @Test func clickZonesRespondToClicksInsideThemAndFade() {
        let zone = InteractionZone(id: "z", x: 0, y: 0, width: 0.5, height: 1, trigger: .click, layerID: "l", property: .scale, amount: 0.5)
        let s = lightScene(zones: [zone])
        func scale(clickX: Double, pulse: Double) -> Double {
            SceneEvaluator.resolve(s, time: 0, input: SceneInput(clickX: clickX, clickY: 0, clickPulse: pulse))[0].scale
        }
        #expect(abs(scale(clickX: -0.5, pulse: 1) - 1.5) < 1e-9)
        #expect(abs(scale(clickX: -0.5, pulse: 0.5) - 1.25) < 1e-9)
        #expect(scale(clickX: 0.5, pulse: 1) == 1)                    // click outside the zone
    }

    @Test func zonesOnlyAffectTheirOwnLayerAndCountAsPointerUse() {
        let zone = InteractionZone(id: "z", x: 0, y: 0, width: 1, height: 1, layerID: "a", property: .brightness, amount: 1)
        let s = Scene(name: "s", layers: [SceneLayer(id: "a", content: .solid(.white)), SceneLayer(id: "b", content: .solid(.white))], zones: [zone])
        let r = SceneEvaluator.resolve(s, time: 0, input: SceneInput(pointerActive: true))
        #expect(r[0].effects.brightness == 1 && r[1].effects.brightness == 0)
        #expect(s.reactsToPointer)
        #expect(!Scene(name: "n", layers: s.layers).reactsToPointer)
    }

    @Test func zonesAreValidatedAndRoundTrip() throws {
        let good = InteractionZone(id: "z", x: 0.1, y: 0.1, width: 0.2, height: 0.2, layerID: "l", property: .opacity, amount: 0.2)
        let s = lightScene(zones: [good])
        #expect(try SceneCodec.decode(try SceneCodec.encode(s)) == s)
        for bad in [InteractionZone(id: "z", x: 0.9, y: 0, width: 0.5, height: 0.5, layerID: "l", property: .opacity, amount: 1),
                    InteractionZone(id: "z", x: 0, y: 0, width: 0, height: 0.5, layerID: "l", property: .opacity, amount: 1),
                    InteractionZone(id: "z", x: 0, y: 0, width: 0.5, height: 0.5, layerID: "ghost", property: .opacity, amount: 1),
                    InteractionZone(id: "z", x: 0, y: 0, width: 0.5, height: 0.5, layerID: "l", property: .opacity, amount: .nan)] {
            #expect(throws: SceneError.self) { try SceneCodec.validate(lightScene(zones: [bad])) }
        }
        #expect(throws: SceneError.self) { try SceneCodec.validate(lightScene(zones: [good, good])) }
        let old = try SceneCodec.decode(Data(#"{"version":1,"name":"o","background":{"r":0,"g":0,"b":0,"a":1},"layers":[]}"#.utf8))
        #expect(old.zones.isEmpty)                                    // files from before zones existed still load
    }

    @Test func syntheticAudioIsLivelyDeterministicAndInRange() {
        let a = SyntheticAudio.frame(at: 1.3), b = SyntheticAudio.frame(at: 1.3), c = SyntheticAudio.frame(at: 2.9)
        #expect(a == b && a != c)
        for t in stride(from: 0.0, to: 10, by: 0.37) {
            let f = SyntheticAudio.frame(at: t)
            #expect(f.bands.allSatisfy { $0 >= 0 && $0 <= 1 } && f.bass >= 0 && f.bass <= 1 && f.level <= 1 && f.waveform.allSatisfy { abs($0) <= 1 })
        }
        #expect(SyntheticAudio.frame(at: 3.0).beatSerial == 6 && SyntheticAudio.frame(at: 3.6).beatSerial == 7)          // two beats per second
    }
}
