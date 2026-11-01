import AppKit
import StudioCore

/// Funnels the scattered AppKit notifications into one event stream.
final class SystemEventMonitor {
    enum Event { case sleep, wake, screensChanged, spaceChanged }

    var handler: ((Event) -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification], .sleep)
        observe(ws, [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification], .wake)
        observe(ws, [NSWorkspace.activeSpaceDidChangeNotification], .spaceChanged)
        observe(.default, [NSApplication.didChangeScreenParametersNotification], .screensChanged)
    }

    deinit { tokens.forEach { $0.0.removeObserver($0.1) } }

    private func observe(_ center: NotificationCenter, _ names: [Notification.Name], _ event: Event) {
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Log.engine.debug("System event: \(String(describing: event))")
                self?.handler?(event)
            }
            tokens.append((center, token))
        }
    }
}
