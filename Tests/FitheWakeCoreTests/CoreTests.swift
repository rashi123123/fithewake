import XCTest
@testable import FitheWakeCore

final class RecoveryTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func testSilentConnectionRetriesWithBackoff() {
        var recovery = HeartRateRecovery(now: start)
        XCTAssertFalse(recovery.shouldReconnect(at: start.addingTimeInterval(19)))
        XCTAssertTrue(recovery.shouldReconnect(at: start.addingTimeInterval(20)))
        XCTAssertFalse(recovery.shouldReconnect(at: start.addingTimeInterval(49)))
        XCTAssertTrue(recovery.shouldReconnect(at: start.addingTimeInterval(50)))
        XCTAssertFalse(recovery.shouldReconnect(at: start.addingTimeInterval(109)))
        XCTAssertTrue(recovery.shouldReconnect(at: start.addingTimeInterval(110)))
        XCTAssertFalse(recovery.shouldReconnect(at: start.addingTimeInterval(229)))
        XCTAssertTrue(recovery.shouldReconnect(at: start.addingTimeInterval(230)))
    }
    func testPacketsResetSilenceAndBackoff() {
        var recovery = HeartRateRecovery(now: start)
        XCTAssertTrue(recovery.shouldReconnect(at: start.addingTimeInterval(20)))
        recovery.receivedPacket(at: start.addingTimeInterval(25))
        XCTAssertFalse(recovery.shouldReconnect(at: start.addingTimeInterval(44)))
        XCTAssertTrue(recovery.shouldReconnect(at: start.addingTimeInterval(45)))
    }
    func testRegularPacketsAndClockRollbackDoNotReconnect() {
        var recovery = HeartRateRecovery(now: start)
        XCTAssertFalse(recovery.shouldReconnect(at: start.addingTimeInterval(-60)))
        for step in 1...100 {
            let now = start.addingTimeInterval(Double(step * 10))
            recovery.receivedPacket(at: now)
            XCTAssertFalse(recovery.shouldReconnect(at: now.addingTimeInterval(5)))
        }
    }
}

final class ParserTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func testEightAndSixteenBit() throws {
        XCTAssertEqual(try HeartRateParser.parse([0, 72], at: start).bpm, 72)
        XCTAssertEqual(try HeartRateParser.parse([1, 44, 1], at: start).bpm, 300)
    }
    func testRRContactAndEnergy() throws {
        let s = try HeartRateParser.parse([30, 60, 1, 0, 0, 4, 0, 2], at: start)
        XCTAssertEqual(s.rr, [1, 0.5]); XCTAssertEqual(s.contact, true)
        XCTAssertNil(try HeartRateParser.parse([0, 60], at: start).rr)
        XCTAssertNil(try HeartRateParser.parse([2, 60], at: start).contact)
        XCTAssertEqual(try HeartRateParser.parse([4, 60], at: start).contact, false)
    }
    func testMalformed() {
        for b: [UInt8] in [[], [1], [1, 60], [8, 60, 0], [16, 60], [16, 60, 1], [0, 60, 0], [224, 60]] {
            XCTAssertThrowsError(try HeartRateParser.parse(b, at: start))
        }
    }
}

final class WakePlanTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func testFallDSTFirstOccurrenceAndOptionClamps() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        let date = c.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0))!
        let wake = try XCTUnwrap(WakePlan.next(hour: 1, minute: 30, after: date, calendar: c))
        XCTAssertEqual(wake.timeIntervalSince(date), 5400)
        XCTAssertEqual(WakeOptions(windowMinutes: 0).windowMinutes, 10)
        XCTAssertEqual(WakeOptions(windowMinutes: 100).windowMinutes, 60)
        XCTAssertEqual(WakeOptions(snoozeMinutes: 0).snoozeMinutes, 1)
        XCTAssertEqual(WakeOptions(snoozeMinutes: 99).snoozeMinutes, 30)
    }
    func testMidnightAndDST() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        let before = c.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
        let next = try XCTUnwrap(WakePlan.next(hour: 2, minute: 30, after: before, calendar: c))
        XCTAssertGreaterThan(next, before); XCTAssertEqual(c.component(.hour, from: next), 3)
        let night = c.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 23))!
        let morning = try XCTUnwrap(WakePlan.next(hour: 7, minute: 0, after: night, calendar: c))
        XCTAssertEqual(c.component(.day, from: morning), 8)
    }
    func testInvalidTimesHaveNoNextMorning() {
        XCTAssertNil(WakePlan.next(hour: 24, minute: 0, after: start))
        XCTAssertNil(WakePlan.next(hour: 10, minute: -1, after: start))
    }
    func testUsableSampleRule() {
        XCTAssertTrue(HeartSample(date: start, bpm: 60, rr: [1]).isUsable)
        XCTAssertTrue(HeartSample(date: start, bpm: 60, contact: nil).isUsable)
        for bad in [HeartSample(date: start, bpm: .nan), HeartSample(date: start, bpm: 34), HeartSample(date: start, bpm: 191),
                    HeartSample(date: start, bpm: 60, contact: false), HeartSample(date: start, bpm: 60, rr: [.nan]),
                    HeartSample(date: start, bpm: 60, rr: [0]), HeartSample(date: start, bpm: 60, rr: [3])] {
            XCTAssertFalse(bad.isUsable, "\(bad)")
        }
        let s = HeartSample(date: start, bpm: 60)
        XCTAssertTrue(s.isFresh(at: start.addingTimeInterval(15)))
        XCTAssertFalse(s.isFresh(at: start.addingTimeInterval(16)))
        XCTAssertFalse(s.isFresh(at: start.addingTimeInterval(-1)), "A reading from the future is not fresh")
    }
}
