import XCTest
import NightLab
@testable import FitheWakeCore

/// Safety properties of hr-night-3.0 on synthetic nights. These nights are
/// literature-shaped, not recordings: they prove the rules behave as designed,
/// not that the engine is accurate on a real sleeper.
final class NightEngineTests: XCTestCase {
    private let start = EvaluationBench.start

    /// A night, an engine fed it up to the reading that makes it decide, that
    /// reading and the plan. Changing one thing about that reading must stop it.
    private func primed() throws -> (night: SyntheticNight, engine: NightEngine, next: HeartSample, plan: WakePlan) {
        let (night, plan) = EvaluationBench.nights(early: false, seeds: 0..<1)[0]
        var probe = NightEngine()
        let k = try XCTUnwrap(night.samples.firstIndex { probe.ingest($0, now: $0.date, plan: plan) != nil })
        var engine = NightEngine()
        for sample in night.samples[..<k] { _ = engine.ingest(sample, now: sample.date, plan: plan) }
        var control = engine
        XCTAssertNotNil(control.ingest(night.samples[k], now: night.samples[k].date, plan: plan))
        return (night, engine, night.samples[k], plan)
    }

    func testNeverWakesInOrJustAfterDeepSleep() {
        for (smoothing, separation) in [(1, 1.0), (5, 1.0), (5, 0.5), (5, 0.25)] {
            for early in [false, true] {
                let s = EvaluationBench.summarize(early: early, count: 25,
                                                  Conditions(smoothing: smoothing, separation: separation, seedOffset: 777))
                XCTAssertEqual(s.deep, 0, "N3 wake: \(s)")
                XCTAssertEqual(s.nearDeep, 0, "Wake within 3 min of N3: \(s)")
                XCTAssertEqual(s.outsideWindow, 0, "Outside window: \(s)")
            }
        }
    }

    func testWakesEarlyOnMostMornings() {
        let s = EvaluationBench.summarize(early: false, count: 25, Conditions(seedOffset: 31))
        XCTAssertGreaterThanOrEqual(s.fired, 20, "\(s)")
    }

    func testDeepSleepThroughTheWholeWindowFallsBackToDeadline() {
        var rng = SeededGenerator(seed: 5)
        var hypnogram = NightSimulator.typicalHypnogram(cycles: 2, rng: &rng)
        hypnogram.append((.n3, 50))
        let night = NightSimulator.night(start: start, hypnogram: hypnogram, seed: 5)
        let deadline = start.addingTimeInterval(Double(night.epochs.count) * 30 - 60)
        var engine = NightEngine()
        let plan = WakePlan(deadline: deadline, options: WakeOptions(windowMinutes: 30))
        for sample in night.samples where sample.date < deadline.addingTimeInterval(-15) {
            XCTAssertNil(engine.ingest(sample, now: sample.date, plan: plan))
        }
        XCTAssertEqual(engine.snapshot.state, .deepSleep)
    }

    func testFlatSignalNeverWakes() {
        var engine = NightEngine()
        let plan = WakePlan(deadline: start.addingTimeInterval(4 * 3600), options: WakeOptions(windowMinutes: 60))
        for second in stride(from: 0, to: 4 * 3600 - 30, by: 1) {
            let date = start.addingTimeInterval(Double(second))
            XCTAssertNil(engine.ingest(HeartSample(date: date, bpm: 58), now: date, plan: plan))
        }
        XCTAssertEqual(engine.snapshot.state, .unstable)
    }

    func testNeedsTwoHoursOfHistory() {
        var rng = SeededGenerator(seed: 9)
        let full = NightSimulator.night(start: start, hypnogram: NightSimulator.typicalHypnogram(cycles: 5, rng: &rng), seed: 9)
        let deadline = start.addingTimeInterval(Double(full.epochs.count) * 30 - 60)
        let plan = WakePlan(deadline: deadline, options: WakeOptions(windowMinutes: 60))
        // Monitoring starts only 100 minutes before the window closes.
        var engine = NightEngine()
        for sample in full.samples where sample.date >= deadline.addingTimeInterval(-100 * 60) {
            XCTAssertNil(engine.ingest(sample, now: sample.date, plan: plan))
        }
    }

    func testGapRequiresTenFreshMinutesButKeepsTheNight() throws {
        let (night, primedEngine, next, plan) = try primed()
        var engine = primedEngine
        // The wearable goes quiet for a minute, just as the engine was about to decide.
        let resume = next.date.addingTimeInterval(60)
        for sample in night.samples where sample.date >= resume && sample.date < resume.addingTimeInterval(9.5 * 60) {
            XCTAssertNil(engine.ingest(sample, now: sample.date, plan: plan), "Decided before 10 fresh minutes")
        }
        XCTAssertEqual(engine.snapshot.coveredSeconds, 2 * 3600, "The night so far was kept")
    }

    func testTwoHoursWithoutReadingsStartsANewNight() {
        let (night, plan) = EvaluationBench.nights(early: false, seeds: 0..<1)[0]
        for (gap, kept) in [(100.0, true), (130.0, false)] {
            var engine = NightEngine()
            let evening = night.samples.filter { $0.date < plan.windowStart }
            for sample in evening { _ = engine.ingest(sample, now: sample.date, plan: plan) }
            let resume = evening.last!.date.addingTimeInterval(gap * 60)
            let later = WakePlan(deadline: resume.addingTimeInterval(4 * 3600))
            for (i, sample) in evening.prefix(600).enumerated() {
                let date = resume.addingTimeInterval(Double(i))
                _ = engine.ingest(HeartSample(date: date, bpm: sample.bpm), now: date, plan: later)
            }
            if kept { XCTAssertEqual(engine.snapshot.coveredSeconds, 2 * 3600) }
            else { XCTAssertLessThanOrEqual(engine.snapshot.coveredSeconds, 600) }
        }
    }

    func testUnusableReadingsFailClosed() throws {
        let (_, primedEngine, next, plan) = try primed()
        let d = next.date
        for bad in [HeartSample(date: d, bpm: .nan), HeartSample(date: d, bpm: 200),
                    HeartSample(date: d, bpm: next.bpm, contact: false), HeartSample(date: d, bpm: next.bpm, rr: [3]),
                    HeartSample(date: d.addingTimeInterval(60), bpm: next.bpm), HeartSample(date: d.addingTimeInterval(-16), bpm: next.bpm)] {
            var engine = primedEngine
            XCTAssertNil(engine.ingest(bad, now: d, plan: plan), "\(bad)")
            XCTAssertEqual(engine.snapshot.state, .invalidSignal, "\(bad)")
        }
    }

    func testInvalidPlanOrClockFailsClosed() throws {
        let (_, primedEngine, next, plan) = try primed()
        var broken = plan; broken.options.windowMinutes = Int.max
        var engine = primedEngine
        XCTAssertNil(engine.ingest(next, now: next.date, plan: broken))
        XCTAssertEqual(engine.snapshot.state, .invalidSignal)
        let huge = Date(timeIntervalSince1970: 1e100)
        engine = primedEngine
        XCTAssertNil(engine.ingest(HeartSample(date: huge, bpm: 60), now: huge, plan: WakePlan(deadline: huge)))
        XCTAssertEqual(engine.snapshot.state, .invalidSignal)
    }

    func testNoDecisionInTheFinalTenSecondsOrWithSmartWakeOff() throws {
        let (_, primedEngine, next, plan) = try primed()
        var engine = primedEngine
        XCTAssertNil(engine.ingest(next, now: next.date, plan: WakePlan(deadline: next.date.addingTimeInterval(10), options: plan.options)))
        XCTAssertEqual(engine.snapshot.state, .expired)
        var off = plan; off.options.smartEnabled = false
        engine = primedEngine
        XCTAssertNil(engine.ingest(next, now: next.date, plan: off))
        XCTAssertEqual(engine.snapshot.state, .disabled)
    }
}

final class NightPipelineTests: XCTestCase {
    /// The engine decides again in a new process; the lifecycle still arms one early alarm.
    @MainActor func testOneEarlyAlarmAcrossRestartsAndTheFinalAlarmStays() async throws {
        let (night, bench) = EvaluationBench.nights(early: false, seeds: 0..<1)[0]
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let end = utc.dateComponents([.hour, .minute], from: bench.deadline)
        let rule = WakeSchedule(hour: end.hour!, minute: end.minute!, options: bench.options)
        let s = FakeScheduler(), store = MemoryStore()
        var lifecycle = try makeLifecycle(s, store, calendar: utc)
        try await lifecycle.arm(rule, now: EvaluationBench.start)
        let plan = try XCTUnwrap(lifecycle.session).plan
        for _ in 0..<2 {
            var engine = NightEngine()
            let fired = try XCTUnwrap(NightReplay.run(&engine, night: night, plan: plan).fired)
            try await lifecycle.early(now: fired)
            XCTAssertTrue(s.ids.contains(plan.id))
            XCTAssertEqual(s.ids.count, 2, "One early alarm, even from a new process and engine")
            lifecycle = try makeLifecycle(s, store, calendar: utc)
            try lifecycle.reconcile(now: fired)
        }
    }
}
