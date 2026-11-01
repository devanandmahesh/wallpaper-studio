import Foundation

/// Live signals that can drive a layer property. (Audio bands join this list with the audio engine.)
public enum InputSource: String, Codable, Sendable, CaseIterable {
    case pointerX, pointerY      // -1...1 across the display, y up
    case pointerSpeed            // 0...1, screen heights per second (clamped)
    case clickPulse              // 1 at a click, fading to 0
    case keyPulse                // rises with typing activity, fades to 0
    case audioLevel, audioBass, audioMid, audioTreble   // 0...1 from the audio analysis
    case audioBeat               // 1 at each detected beat, fading to 0
}

/// "Add `gain × source` to this property": the simple, declarative way to make a layer react.
/// Example: light x = 0.5 base, binding pointerX gain 0.5 → the light follows the cursor across the whole display.
public struct InputBinding: Codable, Equatable, Sendable {
    public var source: InputSource
    public var target: AnimatableProperty
    public var gain: Double
    public init(source: InputSource, target: AnimatableProperty, gain: Double) {
        self.source = source; self.target = target; self.gain = gain
    }

    public var usesPointer: Bool { [.pointerX, .pointerY, .pointerSpeed, .clickPulse].contains(source) }
    public var usesKeys: Bool { source == .keyPulse }
    public var usesAudio: Bool { [.audioLevel, .audioBass, .audioMid, .audioTreble, .audioBeat].contains(source) }
}
