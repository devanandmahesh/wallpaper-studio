import Testing
import Foundation
@testable import StudioCore

private func calendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

/// 2026-11-02 is a Monday (weekday 2).
private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    calendar().date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

@Suite struct ScheduleTests {
    let cal = calendar()
    func rule(_ name: String, _ s: Int, _ e: Int, days: Set<Int> = Set(1...7), enabled: Bool = true) -> ScheduleRule {
        ScheduleRule(id: name, name: name, startMinute: s, endMinute: e, weekdays: days, wallpaperID: "w-\(name)", isEnabled: enabled)
    }

    @Test func rulesValidateTheirFields() {
        #expect(rule("a", 0, 60).isValid)
        for bad in [rule("a", 5, 5), rule("a", -1, 60), rule("a", 0, 1440), rule("a", 0, 60, days: []), rule("a", 0, 60, days: [0]), rule("a", 0, 60, days: [8])] {
            #expect(!bad.isValid)
        }
        var noWallpaper = rule("a", 0, 60); noWallpaper.wallpaperID = ""
        #expect(!noWallpaper.isValid)
        #expect(rule("a", 1320, 420).isOvernight && ScheduleRule.format(75) == "01:15" && rule("a", 480, 1200).timeDescription == "08:00 – 20:00")
    }

    @Test func aDaytimeRuleCoversItsHoursOnItsDaysOnly() {
        let day = rule("day", 8 * 60, 20 * 60, days: [2, 3, 4, 5, 6])        // weekdays
        #expect(ScheduleEvaluator.activeRule(in: [day], at: date(2, 12), calendar: cal)?.id == "day")        // Monday noon
        #expect(ScheduleEvaluator.activeRule(in: [day], at: date(2, 8, 0), calendar: cal)?.id == "day")      // start is inclusive
        #expect(ScheduleEvaluator.activeRule(in: [day], at: date(2, 20, 0), calendar: cal) == nil)           // end is exclusive
        #expect(ScheduleEvaluator.activeRule(in: [day], at: date(2, 7, 59), calendar: cal) == nil)
        #expect(ScheduleEvaluator.activeRule(in: [day], at: date(7, 12), calendar: cal) == nil)              // Saturday
        #expect(ScheduleEvaluator.activeRule(in: [day], at: date(8, 12), calendar: cal) == nil)              // Sunday
    }

    @Test func anOvernightRuleRunsPastMidnightIntoTheNextDay() {
        let night = rule("night", 22 * 60, 6 * 60, days: [6])                   // starts on Friday night
        #expect(ScheduleEvaluator.activeRule(in: [night], at: date(6, 23), calendar: cal)?.id == "night")   // Fri 23:00
        #expect(ScheduleEvaluator.activeRule(in: [night], at: date(7, 3), calendar: cal)?.id == "night")    // Sat 03:00 belongs to Friday's start
        #expect(ScheduleEvaluator.activeRule(in: [night], at: date(7, 6), calendar: cal) == nil)             // ended at 06:00
        #expect(ScheduleEvaluator.activeRule(in: [night], at: date(7, 23), calendar: cal) == nil)            // Saturday evening is not a start day
        #expect(ScheduleEvaluator.activeRule(in: [night], at: date(6, 3), calendar: cal) == nil)             // Fri 03:00 follows Thursday
    }

    @Test func sundayNightRunsIntoMonday() {
        let night = rule("night", 23 * 60, 2 * 60, days: [1])                   // Sunday start
        #expect(ScheduleEvaluator.activeRule(in: [night], at: date(2, 1), calendar: cal)?.id == "night")    // Monday 01:00
        let saturday = rule("sat", 23 * 60, 2 * 60, days: [7])
        #expect(ScheduleEvaluator.activeRule(in: [saturday], at: date(8, 1), calendar: cal)?.id == "sat")    // Sunday 01:00 wraps 7 → 1
    }

    @Test func disabledAndInvalidRulesNeverApply() {
        #expect(ScheduleEvaluator.activeRule(in: [rule("off", 0, 1000, enabled: false), rule("bad", 5, 5)], at: date(2, 12), calendar: cal) == nil)
    }

    @Test func overlappingRulesPreferTheMostRecentlyStarted() {
        let all = rule("all-day", 0, 23 * 60)
        let evening = rule("evening", 18 * 60, 23 * 60)
        #expect(ScheduleEvaluator.activeRule(in: [all, evening], at: date(2, 19), calendar: cal)?.id == "evening")
        #expect(ScheduleEvaluator.activeRule(in: [all, evening], at: date(2, 10), calendar: cal)?.id == "all-day")
        let twin1 = rule("one", 600, 700), twin2 = rule("two", 600, 700)
        #expect(ScheduleEvaluator.activeRule(in: [twin1, twin2], at: date(2, 10, 30), calendar: cal)?.id == "one")        // ties: list order
    }

    @Test func theNextChangeIsTheNearestBoundary() {
        let day = rule("day", 8 * 60, 20 * 60, days: [2])
        #expect(ScheduleEvaluator.nextChange(in: [day], after: date(2, 7), calendar: cal) == date(2, 8))
        #expect(ScheduleEvaluator.nextChange(in: [day], after: date(2, 8), calendar: cal) == date(2, 20))         // strictly after "now"
        #expect(ScheduleEvaluator.nextChange(in: [day], after: date(2, 21), calendar: cal) == date(9, 8))         // next Monday
        #expect(ScheduleEvaluator.nextChange(in: [], after: date(2, 7), calendar: cal) == nil)
        #expect(ScheduleEvaluator.nextChange(in: [rule("off", 0, 60, enabled: false)], after: date(2, 7), calendar: cal) == nil)
        let a = rule("a", 600, 700), b = rule("b", 9 * 60 + 30, 800)
        #expect(ScheduleEvaluator.nextChange(in: [a, b], after: date(2, 9), calendar: cal) == date(2, 9, 30))
    }

    @Test func daylightSavingChangesDoNotBreakBoundaries() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let night = rule("night", 22 * 60, 6 * 60)
        // US clocks go back on 2026-11-01 02:00 → the night of Oct 31/Nov 1 is 25 hours long.
        let after = ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let next = ScheduleEvaluator.nextChange(in: [night], after: after, calendar: ny)
        #expect(next == ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 22)))
        let atFive = ny.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 5))!
        #expect(ScheduleEvaluator.activeRule(in: [night], at: atFive, calendar: ny)?.id == "night")
    }

    @Test func theScheduleSurvivesRestartsAndDamage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID().uuidString)")
        let store = ScheduleStore(url: dir.appendingPathComponent("schedule.json"))
        #expect(store.load().rules.isEmpty)
        var state = ScheduleState()
        state.rules = [rule("a", 0, 60), rule("bad", 5, 5)]
        try store.save(state)
        #expect(store.load().rules.map(\.id) == ["a"])                         // invalid rules are dropped on load
        try Data("{ broken".utf8).write(to: store.url)
        #expect(store.load().rules.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.url.appendingPathExtension("corrupt").path))
    }
}

@Suite struct URLCommandTests {
    func parse(_ s: String) -> URLCommand? { URLCommand.parse(URL(string: s)!) }

    @Test func simpleCommandsParse() {
        #expect(parse("wallpaperstudio://next") == .next)
        #expect(parse("wallpaperstudio://pause") == .pause)
        #expect(parse("wallpaperstudio://resume") == .resume && parse("wallpaperstudio://play") == .resume)
        #expect(parse("wallpaperstudio://toggle") == .togglePause)
        #expect(parse("WALLPAPERSTUDIO://NEXT") == .next)                       // case-insensitive scheme and host
    }

    @Test func parametersAreParsedAndValidated() {
        #expect(parse("wallpaperstudio://set?title=Night%20Waves") == .set(title: "Night Waves"))
        #expect(parse("wallpaperstudio://set?title=%20%20") == nil && parse("wallpaperstudio://set") == nil)
        #expect(parse("wallpaperstudio://set?title=\(String(repeating: "x", count: 500))") == nil)
        #expect(parse("wallpaperstudio://set?title=a%00b") == nil)
        #expect(parse("wallpaperstudio://mode?value=span") == .mode(.span) && parse("wallpaperstudio://mode?value=different") == .mode(.independent))
        #expect(parse("wallpaperstudio://mode?value=nope") == nil)
        #expect(parse("wallpaperstudio://profile?value=battery") == .profile(.batterySaver) && parse("wallpaperstudio://profile?value=Adaptive") == .profile(.adaptive))
        #expect(parse("wallpaperstudio://open?section=editor") == .open(.editor) && parse("wallpaperstudio://open?section=bogus") == nil)
    }

    @Test func foreignSchemesPathsAndUnknownCommandsAreIgnored() {
        #expect(parse("https://next") == nil && parse("file:///etc/passwd") == nil)
        #expect(parse("wallpaperstudio://delete") == nil && parse("wallpaperstudio://export?path=/tmp/x") == nil)
        #expect(parse("wallpaperstudio://next/extra/path") == nil)
        #expect(parse("wallpaperstudio:") == nil)
    }

    @Test func commandsRoundTripThroughTheirLinks() {
        let all: [URLCommand] = [.next, .pause, .resume, .togglePause, .set(title: "Café & Co #1"), .mode(.independent), .profile(.balanced), .open(.settings)]
        for c in all { #expect(URLCommand.parse(c.url) == c, "\(c)") }
    }

    @Test func theCloudSeamNeverClaimsToBeOnline() async {
        let status = await OfflineCloudService().status()
        if case .unavailable(let reason) = status { #expect(reason.contains("offline")) } else { Issue.record("expected unavailable") }
    }
}
