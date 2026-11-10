import XCTest
@testable import FitheWakeCore

/// What every fake failure throws, so a test can tell it from a real error.
struct FakeError: Error, Equatable {}

/// Tests plan in one fixed time zone from one fixed evening, never from the clock.
let testCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c
}()
/// Friday 6 November 2026, 22:00 in New York (after the autumn clock change).
let friday = testCalendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 22))!
/// A one-time alarm at 22:`minute` on that Friday evening.
func tonight(_ minute: Int, _ options: WakeOptions = WakeOptions()) -> WakeSchedule {
    WakeSchedule(hour: 22, minute: minute, options: options)
}
let weekdays = WakeSchedule(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6])

@MainActor final class MemoryStore: SessionStore {
    var value: Session?
    var failSave = false
    func load() throws -> Session? { value }
    func save(_ session: Session?) throws {
        if failSave { throw FakeError() }
        value = session
    }
}

/// AlarmKit stand-in. Each knob makes one system call misbehave.
@MainActor final class FakeScheduler: AlarmScheduling {
    var ids: Set<UUID> = []
    var dates: [UUID: Date] = [:]
    var deny = false
    /// Scheduling an alarm for this date throws before scheduling anything.
    var failSchedule: (Date) -> Bool = { _ in false }
    /// Schedule calls report success but nothing is scheduled.
    var omit = false
    /// The alarm is scheduled, then the call throws and every later query fails.
    var failAfterSchedule = false
    var failQuery = false
    var failCancel = false
    /// Called at the start of every schedule call, before anything changes.
    var onSchedule: ((Date) -> Void)?
    private(set) var snoozed: UUID?
    func authorize() async throws { if deny { throw WakeError.unauthorized } }
    func schedule(id: UUID, date: Date, options: WakeOptions) async throws {
        onSchedule?(date)
        if failSchedule(date) { throw FakeError() }
        if !omit { ids.insert(id); dates[id] = date }
        if failAfterSchedule { failQuery = true; throw FakeError() }
    }
    func scheduledIDs() throws -> Set<UUID> {
        if failQuery { throw FakeError() }
        return ids
    }
    func cancel(id: UUID) throws {
        if failCancel { throw FakeError() }
        ids.remove(id)
    }
    func stop(id: UUID) throws { ids.remove(id) }
    func snooze(id: UUID) throws { snoozed = id }
    var scheduledDates: Set<Date> { Set(ids.compactMap { dates[$0] }) }
}

@MainActor func makeLifecycle(_ scheduler: FakeScheduler = FakeScheduler(), _ store: MemoryStore = MemoryStore(),
                              calendar: Calendar = testCalendar) throws -> AlarmLifecycle {
    try AlarmLifecycle(scheduler: scheduler, store: store, calendar: calendar)
}

/// `body` must throw `expected`.
@MainActor func assertThrows<E: Error & Equatable>(_ expected: E, _ body: () async throws -> Void,
                                                   file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("Did not throw", file: file, line: line) }
    catch { XCTAssertEqual(error as? E, expected, "\(error)", file: file, line: line) }
}
