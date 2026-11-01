import SwiftUI
import StudioCore

final class ScheduleDraft: ObservableObject {
    @Published var name = "Evening"
    @Published var start = ScheduleDraft.time(20, 0)
    @Published var end = ScheduleDraft.time(7, 0)
    @Published var weekdays = Set(1...7)
    @Published var wallpaperID: String?

    static func time(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() }
    static func minutes(_ d: Date) -> Int { let c = Calendar.current.dateComponents([.hour, .minute], from: d); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }
}

/// "Show this wallpaper between these times on these days."
struct ScheduleSection: View {
    @ObservedObject var schedule: ScheduleController
    @ObservedObject var library: LibraryModel
    @StateObject private var draft = ScheduleDraft()
    private let dayNames = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule").font(.headline)
            Text("Switch wallpapers automatically by time of day. The right one is applied when the app starts and at every start or end time.")
                .font(.caption).foregroundColor(.secondary)
            ForEach(schedule.rules) { rule in row(rule) }
            if schedule.rules.isEmpty { Text("No rules yet.").font(.callout).foregroundColor(.secondary) }
            Divider()
            form
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private func title(for id: String) -> String { library.record(id: id)?.title ?? "(removed from library)" }

    private func row(_ rule: ScheduleRule) -> some View {
        HStack {
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { v in schedule.update(rule.id) { $0.isEnabled = v } })).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name).font(.callout.weight(.medium))
                Text("\(rule.timeDescription) · \(dayText(rule)) · \(title(for: rule.wallpaperID))").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button { schedule.remove(rule.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
        }
    }

    private func dayText(_ rule: ScheduleRule) -> String {
        rule.weekdays.count == 7 ? "every day" : dayNames.filter { rule.weekdays.contains($0.0) }.map(\.1).joined(separator: " ")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 150)
                DatePicker("From", selection: $draft.start, displayedComponents: .hourAndMinute).labelsHidden()
                Text("to")
                DatePicker("To", selection: $draft.end, displayedComponents: .hourAndMinute).labelsHidden()
                Menu(draft.wallpaperID.flatMap { library.record(id: $0)?.title } ?? "Choose wallpaper") {
                    ForEach(library.records.filter { !$0.isTrashed }.prefix(60)) { r in Button(r.title) { draft.wallpaperID = r.id } }
                }
                .frame(maxWidth: 200)
            }
            HStack(spacing: 6) {
                ForEach(dayNames, id: \.0) { day in
                    let on = draft.weekdays.contains(day.0)
                    Button(day.1) { if on { draft.weekdays.remove(day.0) } else { draft.weekdays.insert(day.0) } }
                        .buttonStyle(.plain).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.2)))
                        .foregroundColor(on ? .white : .primary)
                }
                Spacer()
                Button("Add Rule") {
                    guard let id = draft.wallpaperID else { return }
                    schedule.add(ScheduleRule(name: draft.name.isEmpty ? "Rule" : draft.name, startMinute: ScheduleDraft.minutes(draft.start),
                                              endMinute: ScheduleDraft.minutes(draft.end), weekdays: draft.weekdays, wallpaperID: id))
                }
                .disabled(draft.wallpaperID == nil || draft.weekdays.isEmpty || ScheduleDraft.minutes(draft.start) == ScheduleDraft.minutes(draft.end))
            }
            Text("An end time earlier than the start time runs overnight.").font(.caption).foregroundColor(.secondary)
        }
    }
}
