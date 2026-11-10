import Foundation
import FitheWakeCore

/// Replays a synthetic night through the engine the way the app feeds it: samples
/// in order, `now` = arrival time, and `interrupt()` once a reading is no longer fresh.
public enum NightReplay {
    public struct Outcome: Sendable { public let fired: Date?; public let stage: SleepStage?; public let minutesEarly: Double }
    public static func run(_ engine: inout NightEngine, night: SyntheticNight, plan: WakePlan) -> Outcome {
        var last: Date?
        for sample in night.samples {
            if let last, sample.date.timeIntervalSince(last) > HeartSample.maxAge { engine.interrupt() }
            last = sample.date
            guard sample.date < plan.deadline else { break }
            if engine.ingest(sample, now: sample.date, plan: plan) != nil {
                return Outcome(fired: sample.date, stage: night.stage(at: sample.date),
                               minutesEarly: plan.deadline.timeIntervalSince(sample.date) / 60)
            }
        }
        return Outcome(fired: nil, stage: nil, minutesEarly: 0)
    }
}

public struct EvaluationSummary: CustomStringConvertible, Sendable {
    public var nights = 0, fired = 0, deep = 0, nearDeep = 0, light = 0, rem = 0, awake = 0
    public var outsideWindow = 0
    public var minutesEarly: [Double] = []
    public var description: String {
        let early = minutesEarly.isEmpty ? 0 : minutesEarly.reduce(0, +) / Double(minutesEarly.count)
        return "nights \(nights) fired \(fired) | N3 \(deep) nearN3 \(nearDeep) | N1/N2 \(light) REM \(rem) wake \(awake) | outside \(outsideWindow) | mean early \(String(format: "%.1f", early)) min"
    }
}

/// How the sensor and sleeper vary between evaluation runs.
public struct Conditions: Sendable {
    /// Wearable smoothing: average of the last N raw values.
    public var smoothing = 1
    /// Arousals per hour in N2 (other stages scale with it).
    public var arousals = 6.0
    /// 1 = literature-shaped stage differences; smaller is a less informative signal.
    public var separation = 1.0
    public var seedOffset: UInt64 = 0
    public init(smoothing: Int = 1, arousals: Double = 6, separation: Double = 1, seedOffset: UInt64 = 0) {
        self.smoothing = smoothing; self.arousals = arousals; self.separation = separation; self.seedOffset = seedOffset
    }
}

public enum EvaluationBench {
    public static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Morning scenario: the alarm is at the natural end of the night.
    /// Early scenario: the alarm lands ~3 h in, where deep sleep is common.
    public static func nights(early: Bool, seeds: Range<Int>, _ c: Conditions = Conditions()) -> [(SyntheticNight, WakePlan)] {
        seeds.map { seed in
            var rng = SeededGenerator(seed: (UInt64(seed) &+ c.seedOffset) &* 7919 &+ (early ? 17 : 3))
            let hypnogram = NightSimulator.typicalHypnogram(cycles: 5, rng: &rng)
            let deepHR = Double(Int.random(in: 46...64, using: &rng))
            let night = NightSimulator.night(start: start, hypnogram: hypnogram, deepHR: deepHR,
                                             includeRR: seed % 3 != 0, arousalsPerHour: c.arousals,
                                             smoothing: c.smoothing, separation: c.separation,
                                             seed: UInt64(seed) &+ c.seedOffset &+ 99)
            let length = Double(night.epochs.count) * 30
            let deadline = start.addingTimeInterval(early ? 3 * 3600 + Double(seed % 40) * 60 : length - 60)
            return (night, WakePlan(deadline: deadline, options: WakeOptions(windowMinutes: 30)))
        }
    }

    public static func summarize(early: Bool, count: Int = 100, _ c: Conditions = Conditions()) -> EvaluationSummary {
        var summary = EvaluationSummary()
        for (night, plan) in nights(early: early, seeds: 0..<count, c) {
            var engine = NightEngine()
            let outcome = NightReplay.run(&engine, night: night, plan: plan)
            summary.nights += 1
            guard let fired = outcome.fired, let stage = outcome.stage else { continue }
            summary.fired += 1
            summary.minutesEarly.append(outcome.minutesEarly)
            if !plan.earlyWakeWindow.contains(fired) { summary.outsideWindow += 1 }
            let recent = (0...6).compactMap { night.stage(at: fired.addingTimeInterval(Double(-$0) * 30)) }
            switch stage {
            case .n3: summary.deep += 1
            case .rem: summary.rem += 1
            case .wake: summary.awake += 1
            case .n1, .n2: summary.light += 1
            }
            if stage != .n3 && recent.contains(.n3) { summary.nearDeep += 1 }
        }
        return summary
    }
}
