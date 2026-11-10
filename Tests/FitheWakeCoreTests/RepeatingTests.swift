import XCTest
@testable import FitheWakeCore

final class RepeatingTests: XCTestCase {
    func day(_ date: Date) -> Int { testCalendar.component(.day, from: date) }
    /// 7:00 on that November morning.
    func morning(_ day: Int) -> Date { testCalendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 7))! }
    func days(_ session: Session?) -> [Int] { session.map { ([$0.plan] + $0.upcoming).map { day($0.deadline) } } ?? [] }

    func testOccurrencesFollowWeekdaysAndOneTime() {
        let dates = weekdays.occurrences(after: friday, calendar: testCalendar)
        XCTAssertEqual(dates, [9, 10, 11, 12, 13].map(morning), "Skips the weekend")
        XCTAssertEqual(WakeSchedule(hour: 7, minute: 0).occurrences(after: friday, calendar: testCalendar), [morning(7)])
        let daily = WakeSchedule(hour: 6, minute: 30, weekdays: Set(1...7)).occurrences(after: friday, calendar: testCalendar)
        XCTAssertEqual(daily.count, 7)
        XCTAssertTrue(WakeSchedule(hour: 7, minute: 0, weekdays: [9]).occurrences(after: friday).isEmpty)
    }

    func testDaylightSavingKeepsWallClockTime() {
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        let before = ny.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 22))!
        let dates = WakeSchedule(hour: 7, minute: 0, weekdays: Set(1...7)).occurrences(after: before, calendar: ny)
        XCTAssertTrue(dates.allSatisfy { ny.component(.hour, from: $0) == 7 })
    }

    @MainActor func testArmsEveryMorningAndPromotesAfterEachOne() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(weekdays, now: friday)
        let session = try XCTUnwrap(e.session), armed = [session.plan] + session.upcoming
        XCTAssertEqual(days(session), [9, 10, 11, 12, 13])
        XCTAssertEqual(s.ids, Set(armed.map(\.id))); XCTAssertTrue(e.verified)

        // Monday's alarm is still ringing or snoozed: no promotion.
        let monday = morning(9).addingTimeInterval(120)
        try e.reconcile(now: monday)
        XCTAssertEqual(e.session?.plan.id, armed[0].id)
        // Stopped: Tuesday becomes current, nothing else is touched.
        try s.stop(id: armed[0].id)
        try e.reconcile(now: monday)
        XCTAssertEqual(e.session?.plan.id, armed[1].id); XCTAssertTrue(e.verified)
        XCTAssertEqual(s.ids, Set(armed.dropFirst().map(\.id)))
        XCTAssertEqual(store.value, e.session)
    }

    @MainActor func testPromotionRetiresTheOldEarlyAlarm() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(weekdays, now: friday)
        try await e.early(now: morning(9).addingTimeInterval(-600))
        let early = try XCTUnwrap(e.session?.earlyID), first = try XCTUnwrap(e.session).plan.id
        try s.stop(id: early); try s.stop(id: first)
        try e.reconcile(now: morning(9).addingTimeInterval(1))
        XCTAssertEqual(day(try XCTUnwrap(e.session).plan.deadline), 10)
        XCTAssertNil(e.session?.earlyID); XCTAssertFalse(try XCTUnwrap(e.session).earlyAttempted)
    }

    @MainActor func testPromotionWaitsForASnoozedEarlyAlarm() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(weekdays, now: friday)
        try await e.early(now: morning(9).addingTimeInterval(-600))
        let early = try XCTUnwrap(e.session?.earlyID)
        try e.snooze(id: early, now: morning(9).addingTimeInterval(-590))
        try s.stop(id: try XCTUnwrap(e.session).plan.id) // the final alarm rang and was stopped
        try e.reconcile(now: morning(9).addingTimeInterval(60))
        XCTAssertEqual(day(try XCTUnwrap(e.session).plan.deadline), 9)
        XCTAssertTrue(s.ids.contains(early))
        try e.dismiss(id: early, now: morning(9).addingTimeInterval(60))
        XCTAssertEqual(day(try XCTUnwrap(e.session).plan.deadline), 10)
    }

    @MainActor func testSkipNextCancelsOnlyThatMorning() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(weekdays, now: friday)
        let later = try XCTUnwrap(e.session).upcoming
        try await e.early(now: morning(9).addingTimeInterval(-300))
        try e.skipNext(now: friday)
        XCTAssertEqual(days(e.session), [10, 11, 12, 13])
        XCTAssertEqual(s.ids, Set(later.map(\.id)), "The skipped morning and its early alarm are cancelled")
        XCTAssertTrue(e.verified)

        let once = try makeLifecycle()
        try await once.arm(tonight(10), now: friday)
        XCTAssertThrowsError(try once.skipNext(now: friday), "A one-time alarm has no next morning") {
            XCTAssertEqual($0 as? WakeError, .noAlarm)
        }
    }

    @MainActor func testTopUpKeepsAWeekArmed() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(weekdays, now: friday)
        let afterMonday = morning(9).addingTimeInterval(60)
        try s.stop(id: try XCTUnwrap(e.session).plan.id)
        try e.reconcile(now: afterMonday)
        try await e.topUp(now: afterMonday)
        XCTAssertEqual(days(e.session), [10, 11, 12, 13, 16, 17])
        XCTAssertEqual(s.ids, Set(try XCTUnwrap(e.session).alarmIDs))
    }

    @MainActor func testTopUpNeverBringsBackASkippedMorning() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(weekdays, now: friday)
        try e.skipNext(now: friday)
        try await e.topUp(now: friday)
        XCTAssertEqual(days(e.session), [10, 11, 12, 13])
        XCTAssertFalse(s.scheduledDates.contains(morning(9)))
    }

    @MainActor func testFailedLaterMorningIsRetiredThenAddedBack() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s), wednesday = morning(11)
        s.failSchedule = { $0 == wednesday }
        try await e.arm(weekdays, now: friday)
        XCTAssertTrue(e.verified)
        XCTAssertEqual(days(e.session), [9, 10, 12, 13])
        XCTAssertFalse(s.scheduledDates.contains(morning(11)))

        s.failSchedule = { _ in false }
        try await e.topUp(now: friday)
        XCTAssertEqual(days(e.session), [9, 10, 11, 12, 13])
        XCTAssertEqual(s.scheduledDates, Set([9, 10, 11, 12, 13].map(morning)))
    }

    /// The app was not opened all week: every armed morning has rung.
    @MainActor func testArmsTheRuleAgainOnceEveryMorningIsOver() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(weekdays, now: friday)
        let last = try XCTUnwrap(e.session?.upcoming.last).id
        let saturday = morning(14)
        s.ids = [last] // Friday's alarm is still ringing
        try e.reconcile(now: saturday)
        try await e.topUp(now: saturday)
        XCTAssertEqual(e.session?.plan.id, last)

        s.ids = []
        try await e.topUp(now: saturday)
        XCTAssertEqual(days(e.session), [16, 17, 18, 19, 20]); XCTAssertTrue(e.verified)
    }

    @MainActor func testCrashDuringReplacementRestoresTheWholeOldSchedule() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(weekdays, now: friday)
        let old = try XCTUnwrap(e.session)
        var journal: Session?, alarms: Set<UUID> = []
        s.onSchedule = { _ in if journal == nil { journal = store.value; alarms = s.ids } }
        try await e.arm(WakeSchedule(hour: 6, minute: 0, weekdays: [2, 3, 4, 5, 6]), now: friday)

        // The crash left the old alarms, and one of the new later mornings got through.
        let crashed = FakeScheduler(), crashedStore = MemoryStore()
        crashed.ids = alarms.union([try XCTUnwrap(journal).upcoming[1].id])
        crashedStore.value = journal
        let recovered = try makeLifecycle(crashed, crashedStore)
        try recovered.reconcile(now: friday)
        XCTAssertEqual(recovered.session?.plan, old.plan)
        XCTAssertEqual(recovered.session?.upcoming, old.upcoming)
        XCTAssertEqual(recovered.session?.schedule, weekdays)
        XCTAssertEqual(crashed.ids, Set(old.alarmIDs), "The orphaned new morning is cancelled")
        XCTAssertTrue(recovered.verified)
    }

    @MainActor func testDisarmCancelsEveryMorning() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(weekdays, now: friday)
        try e.disarm()
        XCTAssertTrue(s.ids.isEmpty); XCTAssertNil(store.value)
    }
}
