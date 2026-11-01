import AppKit
import CoreGraphics
import StudioCore

extension NSScreen {
    /// The CGDirectDisplayID, which (unlike the NSScreen instance) is stable across reconfiguration.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Identity of the physical display. Unlike the display id it survives unplugging and replugging.
    var displayUUID: String? {
        guard let id = displayID, let cfuuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfuuid) as String?
    }

    var descriptor: DisplayDescriptor? {
        guard let id = displayID else { return nil }
        return DisplayDescriptor(id: id, uuid: displayUUID, name: localizedName, frame: frame, scale: backingScaleFactor,
                                 maxFPS: maximumFramesPerSecond, isMain: self == NSScreen.main)
    }
}

/// Publishes the connected displays for the UI.
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = DisplayManager.snapshot()
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.displays = Self.snapshot() }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    static func snapshot() -> [DisplayDescriptor] { NSScreen.screens.compactMap(\.descriptor) }
}
