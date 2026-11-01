import CoreGraphics

/// Plain-data description of a connected display.
public struct DisplayDescriptor: Identifiable, Equatable, Sendable {
    public let id: UInt32          // CGDirectDisplayID: can change between reconnects
    public let uuid: String        // stable identity of the physical display, used to remember settings
    public let name: String
    public let frame: CGRect       // global desktop coordinates, points (AppKit: origin bottom-left)
    public let scale: Double
    public let maxFPS: Int
    public let isMain: Bool

    public var width: Double { frame.width }
    public var height: Double { frame.height }

    public init(id: UInt32, uuid: String? = nil, name: String, frame: CGRect, scale: Double, maxFPS: Int, isMain: Bool) {
        self.id = id; self.uuid = uuid ?? "display-\(id)"; self.name = name; self.frame = frame
        self.scale = scale; self.maxFPS = maxFPS; self.isMain = isMain
    }
}

/// What to do to bring the set of wallpaper sessions in line with the connected displays.
public struct DisplayPlan: Equatable, Sendable {
    public let added: [UInt32]     // need a new session, in display order
    public let removed: [UInt32]   // session must be torn down
    public let kept: [UInt32]      // session stays; only its frame may need updating
}

public enum DisplayReconciler {
    /// Pure diff between existing sessions and the desired display list. Duplicate ids in `desired` are ignored.
    public static func plan(existing: Set<UInt32>, desired: [UInt32]) -> DisplayPlan {
        var seen = Set<UInt32>()
        let unique = desired.filter { seen.insert($0).inserted }
        return DisplayPlan(
            added: unique.filter { !existing.contains($0) },
            removed: existing.subtracting(seen).sorted(),
            kept: unique.filter { existing.contains($0) }
        )
    }
}
