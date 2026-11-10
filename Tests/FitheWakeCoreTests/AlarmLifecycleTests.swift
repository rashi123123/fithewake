import XCTest
@testable import FitheWakeCore

/// One-time alarms: arming, replacing, recovering and the early alarm.
final class AlarmLifecycleTests: XCTestCase {
    @MainActor func testCrashBeforeOrAfterTheReplacementReachesAlarmKit() async throws {
        for scheduled in [false, true] {
            let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
            try await e.arm(tonight(10), now: friday)
            let old = try XCTUnwrap(e.session).plan
            // What a crash leaves behind at the moment AlarmKit is asked for the new alarm.
            var journal: Session?, alarms: Set<UUID> = []
            s.onSchedule = { _ in if journal == nil { journal = store.value; alarms = s.ids } }
            try await e.arm(tonight(15), now: friday)
            let new = try XCTUnwrap(journal).plan

            let crashed = FakeScheduler(), crashedStore = MemoryStore()
            crashed.ids = scheduled ? alarms.union([new.id]) : alarms
            crashedStore.value = journal
            let recovered = try makeLifecycle(crashed, crashedStore)
            try recovered.reconcile(now: friday)
            XCTAssertTrue(recovered.verified)
            XCTAssertEqual(recovered.session?.plan.id, scheduled ? new.id : old.id)
            XCTAssertEqual(crashed.ids, [scheduled ? new.id : old.id])
        }
    }

    @MainActor func testIntermediateUpdateCannotRollBackInFlightReplacement() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(tonight(10), now: friday)
        let old = try XCTUnwrap(e.session).plan.id
        s.onSchedule = { _ in
            try? e.reconcile(now: friday) // an AlarmKit update arriving mid-replacement
            XCTAssertNotEqual(store.value?.plan.id, old)
            XCTAssertTrue(s.ids.contains(old))
        }
        try await e.arm(tonight(15), now: friday)
        let new = try XCTUnwrap(e.session).plan.id
        XCTAssertNotEqual(new, old); XCTAssertEqual(s.ids, [new]); XCTAssertTrue(e.verified)
    }

    @MainActor func testFailuresBeforeTheAlarmIsVerifiedLeaveNothingArmed() async throws {
        let denied = FakeScheduler(); denied.deny = true
        let failing = FakeScheduler(); failing.failSchedule = { _ in true }
        let omitting = FakeScheduler(); omitting.omit = true
        let unsaved = MemoryStore(); unsaved.failSave = true
        let cases: [(FakeScheduler, MemoryStore, any Error)] = [
            (denied, MemoryStore(), WakeError.unauthorized), (failing, MemoryStore(), FakeError()),
            (omitting, MemoryStore(), WakeError.unverifiedAlarm), (FakeScheduler(), unsaved, FakeError()),
        ]
        for (s, store, expected) in cases {
            let e = try makeLifecycle(s, store)
            do { try await e.arm(tonight(10), now: friday); XCTFail("Armed despite \(expected)") }
            catch { XCTAssertEqual(String(describing: error), String(describing: expected)) }
            XCTAssertFalse(e.verified); XCTAssertNil(e.session); XCTAssertNil(store.value); XCTAssertTrue(s.ids.isEmpty)
        }
    }

    @MainActor func testFailedReplacementKeepsTheOldAlarm() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(tonight(10), now: friday)
        let old = try XCTUnwrap(e.session).plan
        s.failSchedule = { _ in true }
        await assertThrows(FakeError()) { try await e.arm(tonight(15), now: friday) }
        XCTAssertEqual(s.ids, [old.id]); XCTAssertEqual(store.value?.plan, old)
    }

    /// The schedule call threw, but the alarm may exist: keep the new session until
    /// AlarmKit can be asked again.
    @MainActor func testAmbiguousScheduleKeepsTheNewSession() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(tonight(15), now: friday)
        let old = try XCTUnwrap(e.session).plan
        s.failAfterSchedule = true
        await assertThrows(FakeError()) { try await e.arm(tonight(30), now: friday) }
        let new = try XCTUnwrap(store.value).plan
        XCTAssertEqual(new.deadline, friday.addingTimeInterval(1800))
        XCTAssertEqual(s.ids, [old.id, new.id]); XCTAssertFalse(e.verified)

        s.failAfterSchedule = false; s.failQuery = false
        let restored = try makeLifecycle(s, store)
        try restored.reconcile(now: friday)
        XCTAssertEqual(s.ids, [new.id]); XCTAssertTrue(restored.verified)
    }

    @MainActor func testQueryFailureRevokesVerification() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(tonight(15), now: friday)
        s.failQuery = true
        XCTAssertThrowsError(try e.reconcile(now: friday)) { XCTAssertEqual($0 as? FakeError, FakeError()) }
        XCTAssertFalse(e.verified)
    }

    @MainActor func testCleanupFailureNeverCancelsTheReplacement() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(tonight(15), now: friday)
        s.failCancel = true
        await assertThrows(FakeError()) { try await e.arm(tonight(30), now: friday) }
        let new = try XCTUnwrap(e.session).plan.id
        XCTAssertTrue(s.ids.contains(new)); XCTAssertTrue(e.verified)
        s.failCancel = false
        try e.reconcile(now: friday)
        XCTAssertEqual(s.ids, [new])
    }

    @MainActor func testCorruptSavedSessionFailsWithoutRemovingAlarms() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(tonight(15), now: friday)
        let ids = s.ids
        store.value?.plan.options.snoozeMinutes = -1
        XCTAssertThrowsError(try makeLifecycle(s, store)) { XCTAssertEqual($0 as? WakeError, .invalidPlan) }
        XCTAssertEqual(s.ids, ids)
    }

    @MainActor func testEarlyFailureKeepsTheFinalAlarmAndUsesUpTheTry() async throws {
        let s = FakeScheduler(), store = MemoryStore(), e = try makeLifecycle(s, store)
        try await e.arm(tonight(10), now: friday)
        let plan = try XCTUnwrap(e.session).plan
        s.failSchedule = { _ in true }
        await assertThrows(FakeError()) { try await e.early(now: friday) }
        XCTAssertEqual(s.ids, [plan.id])

        s.failSchedule = { _ in false }
        let restored = try makeLifecycle(s, store)
        try restored.reconcile(now: friday)
        XCTAssertTrue(restored.verified); XCTAssertTrue(try XCTUnwrap(restored.session).earlyAttempted)
        try await restored.early(now: friday)
        XCTAssertEqual(s.ids, [plan.id], "No second early alarm this morning")
    }

    @MainActor func testEarlyOnlyInsideTheWindowWithSmartWakeOn() async throws {
        let cases: [(WakeSchedule, Date)] = [
            (tonight(1), friday.addingTimeInterval(50)),                 // the final 10 seconds
            (tonight(59), friday),                                       // before the 30-minute window
            (tonight(10, WakeOptions(smartEnabled: false)), friday),
        ]
        for (rule, now) in cases {
            let s = FakeScheduler(), e = try makeLifecycle(s)
            try await e.arm(rule, now: friday)
            try await e.early(now: now)
            XCTAssertEqual(s.ids, [try XCTUnwrap(e.session).plan.id])
            XCTAssertFalse(try XCTUnwrap(e.session).earlyAttempted)
        }
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(tonight(1), now: friday)
        try await e.early(now: friday.addingTimeInterval(49))
        XCTAssertEqual(s.scheduledDates, [friday.addingTimeInterval(54), friday.addingTimeInterval(60)])
    }

    @MainActor func testSnoozeDismissReplaceAndDisarm() async throws {
        let s = FakeScheduler(), e = try makeLifecycle(s)
        try await e.arm(tonight(10), now: friday)
        let plan = try XCTUnwrap(e.session).plan.id
        try await e.early(now: friday)
        let early = try XCTUnwrap(e.session?.earlyID)
        XCTAssertEqual(s.ids, [plan, early])
        try e.snooze(id: early, now: friday)
        XCTAssertEqual(s.snoozed, early); XCTAssertTrue(s.ids.contains(plan))
        try e.dismiss(id: early, now: friday)
        XCTAssertEqual(s.ids, [plan]); XCTAssertTrue(e.verified)
        try await e.arm(tonight(15), now: friday)
        XCTAssertEqual(s.ids, [try XCTUnwrap(e.session).plan.id])
        try e.disarm()
        XCTAssertTrue(s.ids.isEmpty); XCTAssertNil(e.session)
    }
}
