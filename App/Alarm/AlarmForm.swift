import SwiftUI
import FitheWakeCore

/// The alarm being edited, shared by the editor and onboarding: seeded from the
/// saved rule and turned back into a rule on save.
struct AlarmForm {
    var time: Date
    var days: Set<Int>
    var options: WakeOptions

    @MainActor init(model: AppModel) {
        let saved = model.schedule
        time = model.plan?.deadline ?? WakePlan.next(hour: 7, minute: 0, after: model.now) ?? model.now
        // A new alarm starts on the locale's working days: most alarms are for work,
        // and one tap on a day changes it. "One time" is still a choice (no days).
        days = saved?.weekdays ?? RepeatDays.workdays
        var options = saved?.options ?? WakeOptions()
        options.windowMinutes = Self.nearest(options.windowMinutes, in: WakeOptions.windowChoices)
        options.snoozeMinutes = Self.nearest(options.snoozeMinutes, in: WakeOptions.snoozeChoices)
        self.options = options
    }

    var rule: WakeSchedule {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
        return WakeSchedule(hour: parts.hour ?? 0, minute: parts.minute ?? 0, weekdays: days, options: options)
    }
    func next(after now: Date) -> Date? { rule.occurrences(after: now, limit: 1, calendar: .autoupdatingCurrent).first }

    func nextText(at now: Date) -> String? {
        next(after: now).map { "Next: \($0.formatted(.dateTime.weekday(.wide).hour().minute())) · \(sleepLeft(until: $0, from: now))" }
    }
    var repeatText: String {
        days.isEmpty ? "Rings once, then turns off."
            : "\(RepeatDays.summary(days)). Each morning is its own iPhone alarm, so it rings even if \(AppInfo.name) is closed."
    }
    var windowText: String {
        let end = time.formatted(date: .omitted, time: .shortened)
        guard options.smartEnabled else { return "Rings at \(end), like a regular alarm." }
        let start = time.addingTimeInterval(Double(-options.windowMinutes * 60)).formatted(date: .omitted, time: .shortened)
        return "Wakes you between \(start) and \(end), in lighter sleep if your Fitbit shows it. Otherwise the alarm rings at \(end)."
    }

    private static func nearest(_ value: Int, in choices: [Int]) -> Int {
        choices.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}

/// Presentation of a repeat rule, in the person's own calendar (first weekday,
/// weekend days and short day names all follow the locale).
enum RepeatDays {
    static var calendar: Calendar { .autoupdatingCurrent }
    /// Weekdays in display order, starting from the locale's first weekday.
    static var ordered: [Int] { (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 } }
    static var weekend: Set<Int> {
        // Ask the calendar about each weekday's next date: weekend days differ by region.
        Set((1...7).filter { day in
            calendar.nextDate(after: Date(), matching: DateComponents(weekday: day), matchingPolicy: .nextTime)
                .map(calendar.isDateInWeekend) ?? false
        })
    }
    static var workdays: Set<Int> { Set(1...7).subtracting(weekend) }
    static func summary(_ days: Set<Int>) -> String {
        if days.isEmpty { return "One time" }
        if days.count == 7 { return "Every day" }
        if days == workdays { return "Weekdays" }
        if days == weekend { return "Weekends" }
        let names = calendar.shortWeekdaySymbols
        return ordered.filter(days.contains).map { names[$0 - 1] }.formatted(.list(type: .and, width: .narrow))
    }
}

func sleepLeft(until date: Date, from now: Date) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    return minutes >= 60 ? "in \(minutes / 60) h \(minutes % 60) min" : "in \(minutes) min"
}

/// Seven round day toggles in the locale's week order. Each is a 44-point target
/// with the full day name and a selected trait for VoiceOver.
struct WeekdayPicker: View {
    @Environment(\.wakeAtmosphere) private var sky
    @Binding var days: Set<Int>
    var body: some View {
        let calendar = RepeatDays.calendar
        HStack(spacing: 0) {
            ForEach(RepeatDays.ordered, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(on ? Color.white : sky.secondary.color)
                        .background(Circle().fill(on ? sky.action.color : sky.highlight.color.opacity(0.08)))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.standaloneWeekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("repeatDay\(day)")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}
