import Foundation

/// What a wake-up does. Shared by the rule and by each morning armed from it.
public struct WakeOptions: Codable, Equatable, Sendable {
    /// What the app offers; the defaults below are among them.
    public static let windowChoices = [15, 20, 30, 45]
    public static let snoozeChoices = [5, 9, 10, 15]
    public static let windowRange = 10...60
    public static let snoozeRange = 1...30
    public var windowMinutes: Int
    public var smartEnabled: Bool
    public var snoozeMinutes: Int
    public var progressiveSound: Bool
    public init(windowMinutes: Int = 30, smartEnabled: Bool = true, snoozeMinutes: Int = 9, progressiveSound: Bool = false) {
        self.windowMinutes = min(Self.windowRange.upperBound, max(Self.windowRange.lowerBound, windowMinutes))
        self.snoozeMinutes = min(Self.snoozeRange.upperBound, max(Self.snoozeRange.lowerBound, snoozeMinutes))
        self.smartEnabled = smartEnabled; self.progressiveSound = progressiveSound
    }
    public var isValid: Bool { Self.windowRange.contains(windowMinutes) && Self.snoozeRange.contains(snoozeMinutes) }
}

/// One armed morning.
public struct WakePlan: Codable, Equatable, Sendable {
    public var id: UUID
    public var deadline: Date
    public var options: WakeOptions
    public var windowStart: Date { deadline.addingTimeInterval(-Double(options.windowMinutes) * 60) }
    /// When Smart Wake may ring early: the window, minus its last 10 seconds, so an
    /// early alarm never lands on top of the final one.
    public var earlyWakeWindow: Range<Date> {
        let end = deadline.addingTimeInterval(-10)
        return min(windowStart, end)..<end
    }
    public init(deadline: Date, options: WakeOptions = WakeOptions(), id: UUID = UUID()) {
        self.id = id; self.deadline = deadline; self.options = options
    }
    public var isValid: Bool { deadline.timeIntervalSince1970.isFinite && options.isValid }
    public static func next(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}

/// A wake-up rule. Each morning is armed as its own one-shot AlarmKit alarm, so a
/// single morning can be skipped without touching the others, and every armed
/// morning rings even if the app never runs again. AlarmKit's weekly recurrence
/// cannot skip one occurrence, which Smart Wake and "Skip tomorrow" both need.
public struct WakeSchedule: Codable, Equatable, Sendable {
    public var hour: Int
    public var minute: Int
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday. Empty means one morning only.
    public var weekdays: Set<Int>
    public var options: WakeOptions
    public init(hour: Int, minute: Int, weekdays: Set<Int> = [], options: WakeOptions = WakeOptions()) {
        self.hour = hour; self.minute = minute; self.weekdays = weekdays; self.options = options
    }
    public var repeats: Bool { !weekdays.isEmpty }
    public var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) && weekdays.allSatisfy { (1...7).contains($0) } && options.isValid
    }
    /// The next mornings strictly after `now`: one for a one-time rule, otherwise
    /// up to `limit` matching weekdays within the next eight days.
    public func occurrences(after now: Date, limit: Int = 7, calendar: Calendar = .current) -> [Date] {
        guard isValid else { return [] }
        var dates: [Date] = [], cursor = now
        while dates.count < (repeats ? limit : 1) {
            guard let next = WakePlan.next(hour: hour, minute: minute, after: cursor, calendar: calendar),
                  next.timeIntervalSince(now) <= 8 * 86_400 else { break }
            if !repeats || weekdays.contains(calendar.component(.weekday, from: next)) { dates.append(next) }
            cursor = next
        }
        return dates
    }
    public func plan(at deadline: Date) -> WakePlan { WakePlan(deadline: deadline, options: options) }
}

public struct HeartSample: Sendable {
    /// A reading older than this no longer describes the present.
    public static let maxAge: TimeInterval = 15
    public let date: Date
    public let bpm: Double
    public let contact: Bool?
    public let rr: [Double]?
    public init(date: Date, bpm: Double, contact: Bool? = nil, rr: [Double]? = nil) {
        self.date = date; self.bpm = bpm; self.contact = contact; self.rr = rr
    }
    /// A plausible reading from skin contact. Used by Bluetooth, the engine and the UI alike.
    public var isUsable: Bool {
        bpm.isFinite && (35...190).contains(bpm) && contact != false
            && (rr?.allSatisfy { $0.isFinite && (0.25...2).contains($0) } ?? true)
    }
    public func isFresh(at now: Date) -> Bool { (0...Self.maxAge).contains(now.timeIntervalSince(date)) }
}

public enum WakeError: Error { case malformedPacket, unauthorized, unverifiedAlarm, expired, busy, noAlarm, invalidPlan }
