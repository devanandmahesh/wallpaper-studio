import Foundation
import StudioCore

/// Owns the persisted multi-display state (mode per display set, settings per physical display).
/// Every change is saved immediately and reported through `onChange` so the desktop can update.
final class DisplayLayoutController: ObservableObject {
    @Published private(set) var state: DisplayLayoutState
    var onChange: (() -> Void)?

    private let store: DisplayLayoutStore

    init(store: DisplayLayoutStore = DisplayLayoutController.defaultStore()) {
        self.store = store
        self.state = store.load()
    }

    static func defaultStore() -> DisplayLayoutStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return DisplayLayoutStore(url: base.appendingPathComponent("LiveWallpaper/displays.json"))
    }

    func mode(for displays: [DisplayDescriptor]) -> DisplayMode { state.mode(for: displays.map(\.uuid)) }

    func setMode(_ mode: DisplayMode, for displays: [DisplayDescriptor]) {
        mutate { $0.setMode(mode, for: displays.map(\.uuid)) }
    }

    func config(for uuid: String) -> DisplayConfig? { state.configs[uuid] }

    /// Edits a display's config, creating it from `defaults` the first time it is customised.
    func update(_ display: DisplayDescriptor, defaults: DisplayConfig, _ change: (inout DisplayConfig) -> Void) {
        mutate {
            var config = $0.configs[display.uuid] ?? defaults
            change(&config)
            $0.configs[display.uuid] = config
            $0.remember(name: display.name, uuid: display.uuid)
        }
    }

    func forget(uuid: String) { mutate { $0.forget(uuid: uuid) } }

    /// Records the names of connected displays so they can be listed later while unplugged.
    func noteConnected(_ displays: [DisplayDescriptor]) {
        var next = state
        for d in displays { next.remember(name: d.name, uuid: d.uuid) }
        if next != state { state = next; save() }
    }

    private func mutate(_ change: (inout DisplayLayoutState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        save()
        onChange?()
    }

    private func save() {
        do { try store.save(state) } catch { Log.engine.error("Could not save display layout: \(error.localizedDescription)") }
    }
}
