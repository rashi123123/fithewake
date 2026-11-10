import Foundation
import FitheWakeCore

/// Deterministic synthetic nights for testing wake engines. The stage effects are
/// literature-shaped approximations (see docs/SMART_WAKE_RESEARCH.md), not data from
/// any real person; they exist to check safety properties, not to prove accuracy.
public enum SleepStage: Sendable {
    case wake, n1, n2, n3, rem
}

public struct SyntheticNight: Sendable {
    public struct Epoch: Sendable { public let start: Date; public let stage: SleepStage }
    public let samples: [HeartSample]
    public let epochs: [Epoch]
    /// Ground-truth stage at a moment (30-second epochs).
    public func stage(at date: Date) -> SleepStage? {
        guard let first = epochs.first, date >= first.start else { return nil }
        let index = Int(date.timeIntervalSince(first.start) / 30)
        return index < epochs.count ? epochs[index].stage : nil
    }
}

/// SplitMix64: tiny, fast and reproducible across platforms.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func gaussian() -> Double {
        let u1 = max(Double.ulpOfOne, Double.random(in: 0..<1, using: &self))
        let u2 = Double.random(in: 0..<1, using: &self)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

public enum NightSimulator {
    /// Per-stage heart-rate shape, relative to the sleeper's N2 rate. Literature
    /// (Herzig 2018, Boudreau 2013, Trinder 2001): N2 and N3 have about the same
    /// mean heart rate; N3 is marked by unusually LOW slow variability (half the LF
    /// power of N2); REM is ~2 bpm higher with twice the variability; wake is
    /// clearly higher. `slow` is the SD of a ~10-second fluctuation in bpm.
    struct Profile { var offset: Double; var slow: Double; var jitter: Double; var rmssd: Double; var arousalsPerHour: Double }
    static func profile(_ stage: SleepStage) -> Profile {
        switch stage {
        case .n3: Profile(offset: -0.2, slow: 0.7, jitter: 0.5, rmssd: 0.067, arousalsPerHour: 1)
        case .n2: Profile(offset: 0, slow: 1.3, jitter: 0.6, rmssd: 0.071, arousalsPerHour: 6)
        case .n1: Profile(offset: 1.5, slow: 1.8, jitter: 0.8, rmssd: 0.060, arousalsPerHour: 8)
        case .rem: Profile(offset: 2.0, slow: 2.6, jitter: 0.9, rmssd: 0.080, arousalsPerHour: 6)
        case .wake: Profile(offset: 14, slow: 3.0, jitter: 1.2, rmssd: 0.040, arousalsPerHour: 0)
        }
    }

    /// `separation` < 1 shrinks every difference between stages towards N2, to
    /// check that an engine stays safe when the signal is less informative.
    static func scaled(_ p: Profile, _ k: Double) -> Profile {
        let n2 = profile(.n2)
        return Profile(offset: n2.offset + (p.offset - n2.offset) * k, slow: n2.slow + (p.slow - n2.slow) * k,
                       jitter: n2.jitter + (p.jitter - n2.jitter) * k, rmssd: n2.rmssd + (p.rmssd - n2.rmssd) * k,
                       arousalsPerHour: p.arousalsPerHour)
    }

    /// A typical adult night: deep sleep concentrated early, REM lengthening
    /// towards morning, brief awakenings between later cycles. `cycles` of ~90 min.
    public static func typicalHypnogram(cycles: Int = 5, rng: inout SeededGenerator) -> [(SleepStage, Int)] {
        var plan: [(SleepStage, Int)] = [(.wake, 10), (.n1, 5)]
        for cycle in 0..<cycles {
            let late = Double(cycle) / Double(max(1, cycles - 1))
            let deep = Int((40.0 * (1 - late)).rounded()) + Int.random(in: 0...6, using: &rng)
            let rem = Int((8 + 22 * late).rounded()) + Int.random(in: 0...6, using: &rng)
            let n2 = 90 - deep - rem + Int.random(in: -8...8, using: &rng)
            plan += [(.n2, max(10, n2 / 2))]
            if deep > 4 { plan += [(.n3, deep)] }
            plan += [(.n2, max(5, n2 / 2)), (.rem, rem)]
            if cycle >= 2 && Bool.random(using: &rng) { plan += [(.wake, Int.random(in: 1...3, using: &rng)), (.n1, 3)] }
        }
        return plan
    }

    /// Builds 1 Hz samples around `deepHR`, the sleeper's N2/N3 heart rate.
    /// Includes overnight drift, arousal surges (+6–14 bpm for 10–15 s, then a
    /// small dip; Nalivaiko 2007, Griefahn 2008), fast entry into wake, optional
    /// RR intervals. `arousalsPerHour` scales every stage's rate.
    /// `smoothing` > 1 averages the last N raw values, like a wearable that
    /// broadcasts a smoothed rate (the Fitbit Air's exact filter is not public).
    public static func night(start: Date, hypnogram: [(SleepStage, Int)], deepHR: Double = 54,
                             includeRR: Bool = true, arousalsPerHour: Double = 6,
                             smoothing: Int = 1,
                             separation: Double = 1, seed: UInt64 = 1) -> SyntheticNight {
        var rng = SeededGenerator(seed: seed)
        var epochs: [SyntheticNight.Epoch] = []
        var stages: [SleepStage] = []
        for (stage, minutes) in hypnogram {
            for _ in 0..<(minutes * 2) {
                epochs.append(.init(start: start.addingTimeInterval(Double(epochs.count) * 30), stage: stage))
            }
            stages += Array(repeating: stage, count: minutes * 60)
        }
        let total = stages.count
        var samples: [HeartSample] = []
        samples.reserveCapacity(total)
        var level = deepHR + profile(stages.first ?? .wake).offset
        var slow = 0.0
        var surge: (peak: Double, length: Int, age: Int)?
        var raw: [Double] = []
        let decay = exp(-1.0 / 10)
        for second in 0..<total {
            let stage = stages[second]
            let p = scaled(profile(stage), separation)
            let progress = Double(second) / Double(max(1, total))
            // Circadian shape: falls through the first half, rises before morning.
            let drift = -2.0 * sin(.pi * min(1, progress * 1.6)) + (progress > 0.8 ? (progress - 0.8) * 15 : 0)
            let target = deepHR + p.offset + drift
            level += (target - level) / (stage == .wake ? 15 : 60) // awakenings are abrupt
            slow = decay * slow + sqrt(1 - decay * decay) * p.slow * rng.gaussian()
            if surge == nil, Double.random(in: 0..<1, using: &rng) < p.arousalsPerHour * arousalsPerHour / 6 / 3600 {
                surge = (Double.random(in: 6...14, using: &rng), Int.random(in: 10...15, using: &rng), 0)
            }
            var arousal = 0.0
            if let s = surge {
                let phase = Double(s.age) / Double(s.length)
                arousal = phase < 1 ? s.peak * sin(.pi * phase) : -2.5 * sin(.pi * (phase - 1)) // then a dip
                surge = s.age + 1 < s.length * 2 ? (s.peak, s.length, s.age + 1) : nil
            }
            let remBurst = stage == .rem ? 1.5 * separation * sin(Double(second) / 23) * sin(Double(second) / 71) : 0
            raw.append(level + slow + arousal + remBurst + p.jitter * rng.gaussian())
            if raw.count > max(1, smoothing) { raw.removeFirst() }
            let bpm = (raw.reduce(0, +) / Double(raw.count)).rounded()
            var rr: [Double]? = nil
            if includeRR {
                let mean = 60 / bpm
                rr = [max(0.3, mean + p.rmssd / 1.41 * rng.gaussian())]
            }
            samples.append(HeartSample(date: start.addingTimeInterval(Double(second)), bpm: bpm, contact: true, rr: rr))
        }
        return SyntheticNight(samples: samples, epochs: epochs)
    }
}
