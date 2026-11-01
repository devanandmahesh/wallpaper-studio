import Testing
import Foundation
import StudioCore
@testable import WallpaperStudio

private func utc() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { utc().date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }

@MainActor
@Suite struct SchedulerServiceTests {
    func controller() -> ScheduleController {
        ScheduleController(store: ScheduleStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID().uuidString)/schedule.json")))
    }
    func rule(_ id: String, _ s: Int, _ e: Int, wallpaper: String) -> ScheduleRule { ScheduleRule(id: id, name: id, startMinute: s, endMinute: e, wallpaperID: wallpaper) }

    @Test func theActiveRuleIsAppliedAtStartAndOnlyOnce() {
        let c = controller()
        c.add(rule("day", 8 * 60, 20 * 60, wallpaper: "sunny"))
        var applied: [String] = []
        var clock = at(2, 12)
        let service = SchedulerService(controller: c, now: { clock }, calendar: utc()) { applied.append($0.wallpaperID) }
        service.start()
        #expect(applied == ["sunny"])
        service.evaluate(); service.evaluate()
        #expect(applied == ["sunny"])                              // same rule: nothing to redo (a manual change would stick)
        clock = at(2, 15)
        service.evaluate()
        #expect(applied == ["sunny"])
        service.stop()
    }

    @Test func boundariesSwitchTheWallpaperAndTheTimerIsArmedForTheNextOne() {
        let c = controller()
        c.add(rule("day", 8 * 60, 20 * 60, wallpaper: "sunny"))
        c.add(rule("night", 20 * 60, 8 * 60, wallpaper: "moon"))
        var applied: [String] = []
        var clock = at(2, 12)
        let service = SchedulerService(controller: c, now: { clock }, calendar: utc()) { applied.append($0.wallpaperID) }
        service.start()
        #expect(service.nextFire == at(2, 20))
        clock = at(2, 20, 1); service.evaluate()
        #expect(applied == ["sunny", "moon"] && service.nextFire == at(3, 8))
        clock = at(3, 3); service.evaluate()
        #expect(applied == ["sunny", "moon"])                      // still the overnight rule
        clock = at(3, 8, 1); service.evaluate()
        #expect(applied.last == "sunny")
        service.stop()
    }

    @Test func gapsBetweenRulesKeepTheLastWallpaper() {
        let c = controller()
        c.add(rule("morning", 8 * 60, 9 * 60, wallpaper: "dawn"))
        var applied: [String] = []
        var clock = at(2, 8, 30)
        let service = SchedulerService(controller: c, now: { clock }, calendar: utc()) { applied.append($0.wallpaperID) }
        service.start()
        clock = at(2, 10); service.evaluate()
        #expect(applied == ["dawn"])                               // no rule now: nothing is forced
        clock = at(3, 8, 10); service.evaluate()
        #expect(applied == ["dawn", "dawn"])                       // the rule comes round again and re-applies
        service.stop()
    }

    @Test func editingTheScheduleReactsImmediately() {
        let c = controller()
        c.add(rule("a", 0, 1000, wallpaper: "one"))
        var applied: [String] = []
        let service = SchedulerService(controller: c, now: { at(2, 5) }, calendar: utc()) { applied.append($0.wallpaperID) }
        service.start()
        c.update("a") { $0.wallpaperID = "two" }
        #expect(applied == ["one", "two"])
        c.update("a") { $0.isEnabled = false }
        #expect(applied == ["one", "two"] && service.nextFire == nil)
        c.remove("a")
        #expect(c.rules.isEmpty)
        service.stop()
    }

    @Test func theControllerValidatesAndPersists() {
        let store = ScheduleStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID().uuidString)/schedule.json"))
        let c = ScheduleController(store: store)
        #expect(!c.add(ScheduleRule(name: "bad", startMinute: 5, endMinute: 5, wallpaperID: "x")))
        #expect(c.add(rule("ok", 60, 120, wallpaper: "x")))
        c.update("ok") { $0.startMinute = 120 }                     // would become start == end: refused
        #expect(c.rules[0].startMinute == 60)
        #expect(ScheduleController(store: store).rules.map(\.id) == ["ok"])
        for i in 0..<60 { c.add(rule("r\(i)", 10, 20, wallpaper: "x")) }
        #expect(c.rules.count == 50)                                // bounded
    }
}

@MainActor
final class FakeAutomationTarget: AutomationTarget {
    var log: [String] = []
    var isPaused = false
    var titles: Set<String> = ["night waves"]
    func nextWallpaper() { log.append("next") }
    func setPaused(_ paused: Bool) { isPaused = paused; log.append(paused ? "pause" : "resume") }
    func setDisplayMode(_ mode: DisplayMode) { log.append("mode:\(mode.rawValue)") }
    func setPerformanceProfile(_ profile: PerformanceProfile) { log.append("profile:\(profile.rawValue)") }
    func show(_ section: SidebarSection) { log.append("show:\(section.rawValue)") }
    func playLibraryItem(titled title: String) async -> Bool {
        guard titles.contains(title.lowercased()) else { return false }
        log.append("play:\(title)")
        return true
    }
}

@MainActor
@Suite struct AutomationRouterTests {
    @Test func linksDriveTheApp() async {
        let target = FakeAutomationTarget()
        let router = AutomationRouter(target: target)
        for link in ["next", "pause", "toggle", "toggle", "resume", "mode?value=span", "profile?value=battery", "open?section=editor", "set?title=Night%20Waves"] {
            #expect(await router.handle(URL(string: "wallpaperstudio://\(link)")!), "\(link)")
        }
        #expect(target.log == ["next", "pause", "resume", "pause", "resume", "mode:span", "profile:batterySaver", "show:editor", "play:Night Waves"])
    }

    @Test func unknownLinksAndMissingWallpapersChangeNothing() async {
        let target = FakeAutomationTarget()
        let router = AutomationRouter(target: target)
        #expect(!(await router.handle(URL(string: "wallpaperstudio://delete-everything")!)))
        #expect(!(await router.handle(URL(string: "https://example.com/next")!)))
        #expect(!(await router.handle(URL(string: "wallpaperstudio://set?title=Nope")!)))
        #expect(target.log.isEmpty && router.lastResult.contains("no wallpaper"))
    }
}
