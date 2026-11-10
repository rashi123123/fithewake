import Foundation

@MainActor public protocol AlarmScheduling: AnyObject {
    func authorize() async throws
    func schedule(id: UUID, date: Date, options: WakeOptions) async throws
    func scheduledIDs() throws -> Set<UUID>
    func cancel(id: UUID) throws
    func stop(id: UUID) throws
    func snooze(id: UUID) throws
}

@MainActor public protocol SessionStore: AnyObject {
    func load() throws -> Session?
    func save(_ session: Session?) throws
}

/// What is armed, saved before every AlarmKit change so a crash never leaves an
/// alarm the app doesn't know about.
public struct Session: Codable, Equatable, Sendable {
    public internal(set) var schedule: WakeSchedule
    /// The current morning: the only one Smart Wake works on.
    public internal(set) var plan: WakePlan
    /// Later mornings, in order, each already armed as its own AlarmKit alarm.
    public internal(set) var upcoming: [WakePlan]
    /// Smart Wake has had its one try this morning.
    public internal(set) var earlyAttempted = false
    var earlyID: UUID?
    /// Alarms to cancel once the current morning is verified.
    var retiringIDs: [UUID] = []
    /// The session being replaced, kept until its replacement is verified.
    var previous: Rollback?

    struct Rollback: Codable, Equatable, Sendable {
        var schedule: WakeSchedule
        var plan: WakePlan
        var upcoming: [WakePlan]
    }

    init(schedule: WakeSchedule, plan: WakePlan, upcoming: [WakePlan]) {
        self.schedule = schedule; self.plan = plan; self.upcoming = upcoming
    }
    /// This morning's alarms: the final one, then the early one if any.
    var currentIDs: [UUID] { [plan.id] + (earlyID.map { [$0] } ?? []) }
    /// Every alarm this session owns, starting with the current final alarm.
    public var alarmIDs: [UUID] { currentIDs + upcoming.map(\.id) }

    /// The next armed morning becomes current.
    mutating func advance() {
        plan = upcoming.removeFirst(); earlyID = nil; earlyAttempted = false; previous = nil
    }
    /// Goes back to the replaced session. Its own early-wake state is unknown, so
    /// Smart Wake does not try again this morning.
    mutating func restore(_ old: Rollback, keeping ids: Set<UUID>) {
        retiringIDs += upcoming.map(\.id) + (earlyID.map { [$0] } ?? [])
        schedule = old.schedule; plan = old.plan; upcoming = old.upcoming.filter { ids.contains($0.id) }
        earlyID = nil; earlyAttempted = true; previous = nil
        let restored = Set([plan.id] + upcoming.map(\.id))
        retiringIDs.removeAll { restored.contains($0) }
    }
}

@MainActor public final class AlarmLifecycle {
    public private(set) var session: Session?
    public private(set) var verified = false
    private var busy = false
    private let scheduler: any AlarmScheduling
    private let store: any SessionStore
    private let calendar: Calendar

    public init(scheduler: any AlarmScheduling, store: any SessionStore, calendar: Calendar = .autoupdatingCurrent) throws {
        self.scheduler = scheduler; self.store = store; self.calendar = calendar
        session = try store.load()
        if let s = session {
            let plans = [s.plan] + s.upcoming + (s.previous.map { [$0.plan] + $0.upcoming } ?? [])
            guard s.schedule.isValid, plans.allSatisfy(\.isValid) else { throw WakeError.invalidPlan }
        }
    }

    /// Replaces whatever is armed with `rule`'s next mornings. The first one is
    /// scheduled and verified before anything else, then the later ones.
    public func arm(_ rule: WakeSchedule, now: Date) async throws {
        guard !busy else { throw WakeError.busy }
        let plans = rule.occurrences(after: now, calendar: calendar).map(rule.plan(at:))
        guard let plan = plans.first else { throw WakeError.invalidPlan }
        busy = true; defer { busy = false }
        try await scheduler.authorize()
        let old = session
        var next = Session(schedule: rule, plan: plan, upcoming: Array(plans.dropFirst()))
        if let old {
            next.previous = Session.Rollback(schedule: old.schedule, plan: old.plan, upcoming: old.upcoming)
            next.retiringIDs = old.retiringIDs + old.alarmIDs
        }
        try save(next); verified = false
        do {
            try await scheduler.schedule(id: plan.id, date: plan.deadline, options: plan.options)
            guard try scheduler.scheduledIDs().contains(plan.id) else { throw WakeError.unverifiedAlarm }
        } catch {
            // A schedule call can succeed in AlarmKit and still throw here. Keep the new
            // session unless a successful query proves the new alarm is absent.
            if let ids = try? scheduler.scheduledIDs(), !ids.contains(plan.id) { try save(old) }
            throw error
        }
        verified = true
        try await scheduleLater(next.upcoming)
        try settle(now: now)
    }

    /// Keeps a repeating rule's next week armed: adds any missing morning after the
    /// current one (so a skipped morning stays skipped), and arms the rule again once
    /// every armed morning is over.
    public func topUp(now: Date) async throws {
        guard !busy else { throw WakeError.busy }
        guard var s = session, s.schedule.repeats else { return }
        if s.upcoming.isEmpty, s.plan.deadline <= now {
            let ids = try scheduler.scheduledIDs()
            guard !s.currentIDs.contains(where: ids.contains) else { return } // still ringing or snoozed
            try await arm(s.schedule, now: now); return
        }
        let armed = Set(s.upcoming.map(\.deadline))
        let missing = s.schedule.occurrences(after: now, calendar: calendar)
            .filter { $0 > s.plan.deadline && !armed.contains($0) }.map(s.schedule.plan(at:))
        guard !missing.isEmpty else { return }
        busy = true; defer { busy = false }
        s.upcoming = (s.upcoming + missing).sorted { $0.deadline < $1.deadline }
        try save(s)
        try await scheduleLater(missing)
    }

    /// Explicit user action: skip the current morning. The next armed morning
    /// becomes current; nothing else changes.
    public func skipNext(now: Date) throws {
        guard !busy else { throw WakeError.busy }
        guard var s = session, !s.upcoming.isEmpty else { throw WakeError.noAlarm }
        let skipped = s.currentIDs
        s.retiringIDs += skipped; s.advance()
        try save(s)
        for id in skipped { try scheduler.cancel(id: id) }
        try settle(now: now)
    }

    /// Smart Wake decided: arm one early alarm a few seconds from now. At most once
    /// per morning, and never at the final alarm's expense.
    public func early(now: Date) async throws {
        guard !busy else { throw WakeError.busy }
        guard var s = session, !s.earlyAttempted, s.plan.options.smartEnabled, s.plan.earlyWakeWindow.contains(now) else { return }
        guard try scheduler.scheduledIDs().contains(s.plan.id) else { verified = false; throw WakeError.unverifiedAlarm }
        busy = true; defer { busy = false }
        let id = UUID()
        s.earlyAttempted = true; s.earlyID = id
        try save(s) // Saved first: no second try, even after a crash or a scheduling failure.
        try await scheduler.schedule(id: id, date: now.addingTimeInterval(5), options: s.plan.options)
        guard try scheduler.scheduledIDs().contains(id) else { throw WakeError.unverifiedAlarm }
    }

    public func reconcile(now: Date) throws {
        // AlarmKit's update stream can arrive while schedule() is suspended. Never
        // roll back an in-flight replacement from that intermediate state.
        guard !busy else { return }
        try settle(now: now)
    }
    public func dismiss(id: UUID, now: Date) throws { try scheduler.stop(id: id); try reconcile(now: now) }
    public func snooze(id: UUID, now: Date) throws { try scheduler.snooze(id: id); try reconcile(now: now) }

    /// Explicit user action, and the only way the final alarm is cancelled.
    public func disarm() throws {
        guard !busy else { throw WakeError.busy }
        if let s = session {
            // The final alarm goes last, so a failure part-way leaves it armed.
            for id in s.retiringIDs + s.alarmIDs.dropFirst() where id != s.plan.id { try scheduler.cancel(id: id) }
            try scheduler.cancel(id: s.plan.id)
        }
        try save(nil); verified = false
    }

    // MARK: -

    private func save(_ s: Session?) throws { try store.save(s); session = s }

    /// Arms later mornings. One that fails is retired, never left untracked;
    /// `topUp` adds it again later.
    private func scheduleLater(_ plans: [WakePlan]) async throws {
        for later in plans {
            do {
                try await scheduler.schedule(id: later.id, date: later.deadline, options: later.options)
            } catch {
                guard var s = session else { return }
                s.upcoming.removeAll { $0.id == later.id }; s.retiringIDs.append(later.id)
                try save(s)
            }
        }
    }

    private func settle(now: Date) throws {
        guard var s = session else { verified = false; return }
        verified = false
        let ids = try scheduler.scheduledIDs()
        // The replacement's first morning never reached AlarmKit: go back to the old session.
        if !ids.contains(s.plan.id), let old = s.previous, ids.contains(old.plan.id) {
            s.restore(old, keeping: ids); try save(s)
        }
        // A morning is over once its deadline has passed and none of its alarms is
        // still ringing or snoozed.
        while s.plan.deadline <= now, !s.currentIDs.contains(where: ids.contains), !s.upcoming.isEmpty {
            s.retiringIDs += s.currentIDs; s.advance(); try save(s)
        }
        verified = ids.contains(s.plan.id)
        if verified && !s.retiringIDs.isEmpty {
            let live = Set(s.alarmIDs)
            for id in s.retiringIDs where !live.contains(id) { try scheduler.cancel(id: id) }
            s.retiringIDs = []; s.previous = nil; try save(s)
        }
        // A missing alarm may have been turned off on purpose in the system UI, so
        // it is never re-created here.
    }
}
