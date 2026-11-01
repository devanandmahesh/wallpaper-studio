import Foundation

/// "Between 20:00 and 07:00 on weekdays, show this wallpaper."
public struct ScheduleRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var startMinute: Int              // minutes after midnight, 0..<1440
    public var endMinute: Int                // may be smaller than start: the rule then runs overnight
    public var weekdays: Set<Int>            // Calendar weekdays: 1 = Sunday … 7 = Saturday; for overnight rules, the day it *starts*
    public var wallpaperID: String           // a library item
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, startMinute: Int, endMinute: Int, weekdays: Set<Int> = Set(1...7),
                wallpaperID: String, isEnabled: Bool = true) {
        self.id = id; self.name = name; self.startMinute = startMinute; self.endMinute = endMinute
        self.weekdays = weekdays; self.wallpaperID = wallpaperID; self.isEnabled = isEnabled
    }

    public var isValid: Bool {
        (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) && startMinute != endMinute
            && !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) } && !wallpaperID.isEmpty && name.count <= 100
    }

    public var isOvernight: Bool { startMinute > endMinute }

    public var timeDescription: String { "\(Self.format(startMinute)) – \(Self.format(endMinute))" }
    public static func format(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// Minutes since this rule most recently started, or nil if it is not running at `date`.
    func elapsed(at date: Date, calendar: Calendar) -> Int? {
        guard isEnabled, isValid else { return nil }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, let hour = c.hour, let minute = c.minute else { return nil }
        let now = hour * 60 + minute
        if !isOvernight {
            return weekdays.contains(weekday) && now >= startMinute && now < endMinute ? now - startMinute : nil
        }
        if weekdays.contains(weekday) && now >= startMinute { return now - startMinute }          // evening part
        let yesterday = weekday == 1 ? 7 : weekday - 1
        if weekdays.contains(yesterday) && now < endMinute { return now + 1440 - startMinute }     // after midnight
        return nil
    }
}

public enum ScheduleEvaluator {
    /// The rule that applies at `date`. If several overlap, the one that started most recently wins; ties go to the earlier rule in the list.
    public static func activeRule(in rules: [ScheduleRule], at date: Date, calendar: Calendar = .current) -> ScheduleRule? {
        var best: (rule: ScheduleRule, elapsed: Int)?
        for rule in rules {
            guard let e = rule.elapsed(at: date, calendar: calendar) else { continue }
            if best == nil || e < best!.elapsed { best = (rule, e) }
        }
        return best?.rule
    }

    /// The next moment (after `date`) at which any enabled rule really starts or ends, within the next eight days.
    /// Wall-clock times are built with the calendar (not by adding minutes), so daylight-saving changes stay correct.
    public static func nextChange(in rules: [ScheduleRule], after date: Date, calendar: Calendar = .current) -> Date? {
        var earliest: Date?
        let startOfToday = calendar.startOfDay(for: date)
        func moment(_ day: Date, _ minute: Int) -> Date? {
            calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
        }
        for rule in rules where rule.isEnabled && rule.isValid {
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
                let weekday = calendar.component(.weekday, from: day)
                let yesterday = weekday == 1 ? 7 : weekday - 1
                var candidates: [Date] = []
                if rule.weekdays.contains(weekday), let start = moment(day, rule.startMinute) { candidates.append(start) }
                // The end falls on the same day for ordinary rules, on the day after the start day for overnight ones.
                let endsToday = rule.isOvernight ? rule.weekdays.contains(yesterday) : rule.weekdays.contains(weekday)
                if endsToday, let end = moment(day, rule.endMinute) { candidates.append(end) }
                for c in candidates where c > date { if earliest == nil || c < earliest! { earliest = c } }
            }
        }
        return earliest
    }
}

public struct ScheduleState: Codable, Equatable, Sendable {
    public var version = 1
    public var rules: [ScheduleRule] = []
    public init() {}
}

/// JSON persistence for the schedule. Like the other stores, a damaged file yields defaults and is kept aside.
public struct ScheduleStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> ScheduleState {
        guard let data = try? Data(contentsOf: url) else { return ScheduleState() }
        if var state = try? JSONDecoder().decode(ScheduleState.self, from: data), state.version <= 1 {
            state.rules = state.rules.filter(\.isValid)
            return state
        }
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        return ScheduleState()
    }

    public func save(_ state: ScheduleState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
