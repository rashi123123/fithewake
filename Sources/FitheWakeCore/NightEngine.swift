import Foundation

/// Why the engine chose to ring early.
public struct WakeDecision: Equatable, Sendable {
    public let reason: String
}
public enum EstimatorState: String, Sendable {
    case disabled, collecting, beforeWindow, evaluating, unstable, candidate, expired, interrupted, invalidSignal
    /// Deep-sleep signs in the last few minutes; waiting.
    case deepSleep
}
public struct EstimatorSnapshot: Equatable, Sendable {
    public var state: EstimatorState = .collecting
    /// Valid history so far, capped at `NightEngine.requiredSeconds`.
    public var coveredSeconds = 0
    public init() {}
}

/// Smart Wake engine "hr-night-3.0". Evidence and sources: docs/SMART_WAKE_RESEARCH.md.
///
/// Goal: inside the wake window, ring early only at a moment that is very
/// probably NOT deep sleep, preferably right after a natural arousal. Otherwise
/// do nothing; the final alarm always rings at the set time.
///
/// What the literature says, and how it is used here:
/// - N3 does not have a lower heart rate than N2. It is marked by unusual
///   STABILITY: little slow variability (Herzig 2018; Long 2017; Yoon 2018).
///   Stability = SD of detrended 5-second means over the last 5 minutes, ranked
///   against this person's own night, so sensor smoothing and personal scale cancel.
/// - Cardiac changes lead EEG stage changes by about 5–12 minutes, so after any
///   deep-like moment there is a 10-minute lockout (Brandenberger 2001; Jurysta 2003).
/// - Arousals (+6–14 bpm for 10–15 s) and awakenings (+15 bpm or more, sustained)
///   are the most reliable heart-rate events (Azarbarzin 2014; Griefahn 2008).
///   Waking right after an arousal predicts lower sleepiness (Stephan 2025).
/// - Very high variability looks like REM, which is no better than N3 for
///   grogginess (Stephan 2025), so the "quiet light sleep" path excludes it.
///
/// Inside the wake window it rings early on the first of:
/// - an arousal: a brief rise well above this moment's own variability;
/// - being awake: the last minute 15 bpm or more above the ten before (this one
///   also rings during the deep-sleep lockout);
/// - an ascending step: the last 3 minutes above the 10 before, and less steady;
/// - in the second half only, three of the last four epochs looking like light
///   sleep (middle stability, not deep, not REM-like).
/// The first half of the window asks for larger rises. Nothing fires with under
/// 2 hours of history, in the first 10 minutes after a gap, on a flat stream or
/// an unusable reading, or in the final 10 seconds. Ringing only once per
/// morning is `AlarmLifecycle.early`'s rule.
/// RR intervals are ignored: the Fitbit Air is not known to send them.
public struct NightEngine: Sendable {
    public static let version = "hr-night-3.0"
    static let epoch = 30.0
    /// Valid history needed before any early wake: 2 hours (240 epochs).
    static let minimumHistoryEpochs = 240
    public static let requiredSeconds = minimumHistoryEpochs * Int(epoch)
    /// Contiguous epochs after any gap before a decision (paths 2 and 3).
    static let freshEpochs = 20
    static let lockoutEpochs = 20
    static let referenceEpochs = 480
    /// No readings for this long starts a new night.
    static let newNightEpochs = 240
    /// The longest look back (13 minutes, in the ascending step) plus a minute.
    static let ringSeconds = 840.0

    public private(set) var snapshot = EstimatorSnapshot()

    struct Epoch { let index: Int; let level: Double; let stability: Double? }
    /// This night's own scale: typical level, its spread, and every stability seen.
    struct Reference { let median: Double; let spread: Double; let stabilities: [Double] }
    private var ring: [(t: Double, bpm: Double)] = []
    private var night: [Epoch] = []
    private var run = 0                                  // contiguous valid epochs
    private var flags: [Bool] = []                       // deep-like, last 4 epochs
    private var light: [Bool] = []                       // light-like, last 4 epochs
    private var reference: Reference?
    private var lastDeep: Int?
    private var lastTransient: Int?
    private var openIndex: Int?
    private var lastDate: Date?
    private var lastNow: Date?

    public init() {}

    public mutating func interrupt() {
        ring.removeAll(keepingCapacity: true); run = 0; flags = []; light = []
        openIndex = nil; lastDate = nil
        snapshot.state = .interrupted
    }

    public mutating func ingest(_ sample: HeartSample, now: Date, plan: WakePlan) -> WakeDecision? {
        defer { lastNow = now }
        guard now.timeIntervalSince1970.isFinite, sample.date.timeIntervalSince1970.isFinite,
              abs(now.timeIntervalSince1970) < 1e12, abs(sample.date.timeIntervalSince1970) < 1e12,
              plan.isValid else { interrupt(); snapshot.state = .invalidSignal; return nil }
        if let lastNow, now < lastNow { interrupt() }
        guard plan.options.smartEnabled else { interrupt(); snapshot.state = .disabled; return nil }
        guard now < plan.earlyWakeWindow.upperBound else { snapshot.state = .expired; return nil }
        guard sample.isUsable, sample.isFresh(at: now) else {
            interrupt(); snapshot.state = .invalidSignal; return nil
        }
        if let lastDate {
            guard sample.date > lastDate else { return nil }
            if sample.date.timeIntervalSince(lastDate) > HeartSample.maxAge { interrupt() }
        }
        let t = sample.date.timeIntervalSince1970
        if let newest = night.last, t / Self.epoch - Double(newest.index) > Double(Self.newNightEpochs) {
            night.removeAll(); lastDeep = nil; lastTransient = nil; reference = nil
        }
        lastDate = sample.date

        let index = Int(floor(t / Self.epoch))
        var closed = false
        if let open = openIndex, open != index { close(open); closed = true }
        openIndex = index
        ring.append((t, sample.bpm))
        if let cut = ring.firstIndex(where: { $0.t >= t - Self.ringSeconds }), cut > 0 { ring.removeFirst(cut) }
        if ring.count > 2000 { ring.removeFirst(ring.count - 2000) } // packet storms
        snapshot.coveredSeconds = min(night.count, Self.minimumHistoryEpochs) * Int(Self.epoch)

        guard let decision = decide(t: t, index: index, epochClosed: closed, now: now, plan: plan) else { return nil }
        snapshot.state = .candidate
        return decision
    }

    // MARK: - Epoch features

    private mutating func close(_ index: Int) {
        let start = Double(index) * Self.epoch, end = start + Self.epoch
        let values = self.values(after: start - 0.001, through: end - 0.001)
        guard values.count >= 10 else { run = 0; flags = []; light = []; return }
        run = (night.last?.index == index - 1 && run > 0) ? run + 1 : 1
        let stability = run >= 10 ? Self.stability(Array(ring.drop(while: { $0.t < end - 300 }).prefix(while: { $0.t < end }))) : nil
        night.append(Epoch(index: index, level: Self.median(values), stability: stability))
        if night.count > 1440 { night.removeFirst(night.count - 1440) }
        reference = buildReference()

        guard let stability, let ref = reference else { flags = []; light = []; return }
        let rank = Self.rank(stability, in: ref.stabilities)
        let z = (Self.median(self.values(after: end - 120.001, through: end - 0.001)) - ref.median) / ref.spread
        let recentTransient = lastTransient.map { index - $0 <= 10 } ?? false
        // Deep sleep is defined by steadiness, not by a low rate: N3 runs at about the
        // N2 rate and the morning circadian rise lifts both. Only a clearly awake
        // level (z > 3) vetoes it; erring towards "deep" only delays a wake.
        flags = Array((flags + [rank < 0.3 && z <= 3 && !recentTransient]).suffix(4))
        light = Array((light + [(0.4...0.85).contains(rank) && z > -0.5]).suffix(4))
        if flags.filter({ $0 }).count >= 3 || (rank < 0.15 && z <= 3) { lastDeep = index }
    }

    private func buildReference() -> Reference? {
        let recent = night.suffix(Self.referenceEpochs)
        let stabilities = recent.compactMap(\.stability).sorted()
        guard stabilities.count >= 60 else { return nil }
        let levels = recent.map(\.level)
        let median = Self.median(levels)
        let mad = Self.median(levels.map { abs($0 - median) }) * 1.4826
        return Reference(median: median, spread: max(1, mad), stabilities: stabilities)
    }

    // MARK: - Decision

    private mutating func decide(t: Double, index: Int, epochClosed: Bool, now: Date, plan: WakePlan) -> WakeDecision? {
        guard night.count >= Self.minimumHistoryEpochs else { snapshot.state = .collecting; return nil }
        guard now >= plan.earlyWakeWindow.lowerBound else { snapshot.state = .beforeWindow; return nil }
        guard let ref = reference else { snapshot.state = .collecting; return nil }
        // A flat or saturated stream cannot show sleep depth. Wait for the deadline.
        guard Self.percentile(ref.stabilities, 0.9) - Self.percentile(ref.stabilities, 0.1) >= 0.3 else {
            snapshot.state = .unstable; return nil
        }
        // This moment's own variability; unknown right after sparse readings, which
        // rules out the paths that compare against it.
        let local = night.last?.stability
        let locked = lastDeep.map { index - $0 <= Self.lockoutEpochs } ?? false
        // Sleep is worth keeping: the first half of the window needs clearer events.
        let window = plan.deadline.timeIntervalSince(plan.windowStart)
        let urgency = now.timeIntervalSince(plan.windowStart) / max(window, 1)
        let firstHalf = urgency < 0.5
        // 2. Arousal: a brief acceleration well beyond this moment's own variability.
        if run >= Self.freshEpochs, let local, let peak = readings(t, from: 3, to: 0),
           let baseline = readings(t, from: 75, to: 15) {
            let needed = firstHalf ? max(8, 3 * local) : max(6, 2 * local)
            if peak.reduce(0, +) / Double(peak.count) - Self.median(baseline) >= needed {
                lastTransient = index
                if !locked {
                    return WakeDecision(reason: "Arousal: brief heart-rate rise, no deep-sleep signs for 10 min")
                }
            }
        }
        guard epochClosed else {
            snapshot.state = run < Self.freshEpochs ? .collecting : locked ? .deepSleep : .evaluating; return nil
        }
        // 1. Already awake: a sustained step well above the previous ten minutes.
        if let lastMinute = readings(t, from: 60, to: 0), let before = readings(t, from: 660, to: 60) {
            let base = Self.median(before)
            if Self.median(lastMinute) - base >= max(15, 3 * ref.spread), lastMinute.allSatisfy({ $0 >= base + 8 }) {
                return WakeDecision(reason: "Awake: heart rate up 15+ bpm for a minute")
            }
        }
        guard run >= Self.freshEpochs else { snapshot.state = .collecting; return nil }
        // 2b. Ascending step: the last 3 minutes above the 10 before, and less steady.
        // Not REM-like (top 15% variability), which is no better than N3 to wake from.
        if !locked, let local, (0.5...0.85).contains(Self.rank(local, in: ref.stabilities)),
           let three = readings(t, from: 180, to: 0), let ten = readings(t, from: 780, to: 180),
           Self.median(three) - Self.median(ten) >= (firstHalf ? max(5, 1.5 * ref.spread) : max(3, ref.spread)) {
            lastTransient = index
            return WakeDecision(reason: "Lighter sleep: heart rate stepped up and became less steady")
        }
        guard !locked else { snapshot.state = .deepSleep; return nil }
        // 3. Quiet light sleep, only in the second half of the window.
        if !firstHalf, light.count == 4, light.filter({ $0 }).count >= 3 {
            return WakeDecision(reason: "Light sleep: steady pattern without deep-sleep signs for 10 min")
        }
        snapshot.state = .evaluating
        return nil
    }

    /// Readings from `from` to `to` seconds before `t`, or nil when fewer than two
    /// thirds of them arrived. Wearables send about one reading a second.
    private func readings(_ t: Double, from: Double, to: Double) -> [Double]? {
        let v = values(after: t - from, through: t - to)
        return v.count * 3 >= Int(from - to) * 2 ? v : nil
    }
    /// Ring values with from < t <= to (the ring is time-ordered).
    private func values(after from: Double, through to: Double) -> [Double] {
        var lo = 0, hi = ring.count
        while lo < hi { let mid = (lo + hi) / 2; if ring[mid].t <= from { lo = mid + 1 } else { hi = mid } }
        var out: [Double] = []
        var i = lo
        while i < ring.count, ring[i].t <= to { out.append(ring[i].bpm); i += 1 }
        return out
    }

    // MARK: - Statistics

    /// SD of the residuals of 5-second means after removing a straight-line trend.
    /// Slow (≈ 0.04–0.15 Hz) variability survives; sensor jitter and drift do not.
    static func stability(_ points: [(t: Double, bpm: Double)]) -> Double? {
        guard let first = points.first else { return nil }
        var sums: [Int: (sum: Double, n: Double)] = [:]
        for p in points {
            let b = Int((p.t - first.t) / 5)
            sums[b, default: (0, 0)].sum += p.bpm; sums[b, default: (0, 0)].n += 1
        }
        guard sums.count >= 50 else { return nil }
        let keys = sums.keys.sorted()
        let xs = keys.map(Double.init), ys = keys.map { sums[$0]!.sum / sums[$0]!.n }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        let slope = sxx > 0 ? zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / sxx : 0
        let residuals = zip(xs, ys).map { $1 - (my + slope * ($0 - mx)) }
        return sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count))
    }
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = p * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = min(sorted.count - 1, low + 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
    static func median(_ values: [Double]) -> Double { percentile(values.sorted(), 0.5) }
    /// Mid-rank in 0...1: ties count half, so a flat stream ranks 0.5, never extreme.
    static func rank(_ value: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0.5 }
        var below = 0, equal = 0
        for v in sorted { if v < value { below += 1 } else if v == value { equal += 1 } else { break } }
        return (Double(below) + 0.5 * Double(equal)) / Double(sorted.count)
    }
}
