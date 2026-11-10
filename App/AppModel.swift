import SwiftUI
import FitheWakeCore

/// A status line, and whether it warns that Smart Wake cannot work tonight.
struct StatusLine: Equatable { let text: String; var warning = false }

/// A one-minute alarm with its own ID, so a test never touches the wake-up plan.
struct TestAlarm: Codable, Equatable {
    static let options = WakeOptions(smartEnabled: false)
    let id: UUID
    let date: Date
}

@MainActor @Observable final class AppModel {
    // One BLE central and one pair of AlarmKit observers per app process.
    static let shared = AppModel()
    let ble = FitbitCentral()
    let diagnostics = TestDiagnostics()
    private var lifecycle: AlarmLifecycle?
    private(set) var plan: WakePlan?
    private(set) var schedule: WakeSchedule?
    private(set) var upcoming: [WakePlan] = []
    private(set) var ready = false
    /// Alarm checks that fail outside any change the person asked for.
    var problem: AlarmProblem?
    private(set) var activeID: UUID?
    private(set) var working = false
    private(set) var now = Date()
    private(set) var snapshot = EstimatorSnapshot()
    private(set) var testAlarm: TestAlarm?
    private(set) var testAlarmVerified = false
    /// Display-only trace of the current continuous stream (last 10 minutes).
    /// It never feeds the estimator and is cleared with the reading on any interruption.
    struct BPMPoint: Identifiable, Equatable { let date: Date; let bpm: Double; var id: Date { date } }
    private(set) var recentBPM: [BPMPoint] = []
    static let traceSpan: TimeInterval = 600
    /// One engine for the whole night: re-arming must not discard hours of sleep history.
    private var engine = NightEngine()
    /// When mornings were last added, and the alarms that were armed and live then.
    private var lastTopUp: (date: Date, alarms: [Set<UUID>])?
    private var lastSampleRefresh = Date.distantPast
    private var earlyBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var timeZoneObservation: NSObjectProtocol?
    private let scheduler = NativeAlarmScheduler()
    private static let testAlarmKey = "testAlarm"

    var time: Date { plan?.deadline ?? now }
    var smart: Bool { plan?.options.smartEnabled ?? true }
    var repeats: Bool { schedule?.repeats == true && plan != nil }
    /// The early alarm already went off (or was attempted) this morning and the
    /// final alarm is still ahead: offer to turn that one morning off.
    var upEarly: Bool {
        ready && activeID == nil && lifecycle?.session?.earlyAttempted == true && now >= windowStart && now < time
    }
    var windowStart: Date { plan?.windowStart ?? now }
    var bpm: Int? {
        guard let sample = ble.latest, sample.isFresh(at: now) else { return nil }
        return Int(sample.bpm)
    }
    var receiving: Bool { bpm != nil }
    var readiness: String {
        if activeID != nil { return "Alarm ringing" }
        if working { return "Checking alarm" }
        if ready { return "Alarm ready" }
        if plan == nil { return "No alarm set" }
        if time <= now { return "Alarm finished" }
        return "Check alarm"
    }
    var smartStatus: StatusLine {
        let t = time.formatted(date: .omitted, time: .shortened)
        guard ready else { return StatusLine(text: "Set an alarm to start Smart Wake.") }
        guard smart else { return StatusLine(text: "Smart Wake is off. Your alarm rings at \(t).") }
        if lifecycle?.session?.earlyAttempted == true { return StatusLine(text: "Smart Wake rang early. Your \(t) alarm is still set.") }
        let tonight = time.timeIntervalSince(now) <= 14 * 3600
        guard ble.requested else { return StatusLine(text: "Connect your Fitbit for Smart Wake. Your alarm still rings at \(t).", warning: tonight) }
        guard tonight else { return StatusLine(text: "Smart Wake starts tonight. Wear your Fitbit to bed.") }
        guard receiving else { return StatusLine(text: "Waiting for your Fitbit’s heart rate. Your alarm still rings at \(t).", warning: true) }
        let required = NightEngine.requiredSeconds
        if snapshot.coveredSeconds < required {
            return StatusLine(text: "Learning your sleeping heart rate · \(snapshot.coveredSeconds / 60)/\(required / 60) min")
        }
        if now < windowStart { return StatusLine(text: "Watching your sleep. Smart Wake opens at \(windowStart.formatted(date: .omitted, time: .shortened)).") }
        switch snapshot.state {
        case .deepSleep: return StatusLine(text: "Wake window open · deep sleep now, waiting for it to pass.")
        case .unstable: return StatusLine(text: "Wake window open · signal too flat to read sleep depth. Alarm at \(t).")
        default: return StatusLine(text: "Wake window open · looking for light sleep.")
        }
    }
    func snoozeMinutes(for id: UUID) -> Int? {
        id == testAlarm?.id ? TestAlarm.options.snoozeMinutes : plan?.options.snoozeMinutes
    }

    init() {
        do { lifecycle = try AlarmLifecycle(scheduler: scheduler, store: DiskSessionStore()) }
        catch { problem = .cannotRecover }
        if let data = UserDefaults.standard.data(forKey: Self.testAlarmKey) {
            do { testAlarm = try JSONDecoder().decode(TestAlarm.self, from: data) }
            catch { diagnostics.record("test_alarm_unreadable", "A test alarm may remain in the Clock app") }
        }
        ble.onInterruption = { [weak self] in
            self?.forgetStream(); self?.diagnostics.interruption()
        }
        ble.onEvent = { [weak self] in self?.diagnostics.record($0, $1) }
        ble.onSample = { [weak self] in self?.received($0) }
        scheduler.observe(changed: { [weak self] in self?.refresh() }, revoked: { [weak self] in self?.ready = false })
        // Armed mornings are fixed instants. After a time-zone change, re-plan the
        // rule so "7:00 on weekdays" stays 7:00 local time (AlarmKit cannot move them).
        timeZoneObservation = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rule = self.schedule, self.ready, self.activeID == nil else { return }
                self.diagnostics.record("time_zone_changed", TimeZone.current.identifier)
                if let problem = await self.arm(rule) { self.problem = problem }
            }
        }
        refresh()
        ble.resume(alarmNeedsHeartRate: ready && smart)
        diagnostics.record("app_opened", "\(NightEngine.version); session restored and queried")
    }
    func tick() {
        now = Date()
        if plan != nil && now >= time && ready { refresh() }
    }
    /// `reporting: false` after a change that failed: its own alert already
    /// explains a failed check, and two alerts cannot show at once.
    func refresh(reporting: Bool = true) {
        // Alarm and authorization updates may arrive during an awaited change.
        // Reconcile only after it finishes; never query AlarmKit reentrantly.
        guard !working else { return }
        now = Date()
        guard let lifecycle else { ready = false; return }
        do {
            let before = plan?.id
            try lifecycle.reconcile(now: now)
            show(lifecycle.session)
            if let before, let id = plan?.id, before != id { diagnostics.record("next_morning", "Now armed for \(time.ISO8601Format())") }
            let ids = try scheduler.scheduledIDs()
            activeID = try scheduler.alerting(among: Set((lifecycle.session?.alarmIDs ?? []) + [testAlarm?.id].compactMap { $0 }))
            let newReady = lifecycle.verified && scheduler.authorized && (plan?.deadline ?? .distantPast) > now
            if ready != newReady { diagnostics.record("deadline_verification", newReady ? "Verified" : "Not ready") }
            if ready && !newReady && (plan?.deadline ?? .distantFuture) <= now && upcoming.isEmpty {
                stopMonitoring("Final deadline reached")
            }
            ready = newReady
            testAlarmVerified = testAlarm.map { ids.contains($0.id) } ?? false
            if let testAlarm, !ids.contains(testAlarm.id) { forgetTestAlarm() }
            topUp(live: ids)
        } catch {
            ready = false
            if reporting { problem = .cannotVerify }
            diagnostics.record("alarm_query_failed", String(describing: type(of: error)))
        }
    }

    // MARK: Changes the person asked for. Each returns why it failed, for the view that asked.

    func setAlarm(_ rule: WakeSchedule) async -> AlarmProblem? {
        if let problem = await arm(rule) { return problem }
        if rule.options.smartEnabled { ble.startIfAllowed() } else { stopMonitoring("Smart Wake off") }
        return nil
    }
    /// Skips only the next morning of a repeating alarm.
    func skipNext() async -> AlarmProblem? {
        await run {
            guard let lifecycle else { throw WakeError.noAlarm }
            let skipped = time
            try lifecycle.skipNext(now: Date())
            diagnostics.record("morning_skipped", "Skipped \(skipped.ISO8601Format()) by user")
        }
    }
    /// After an early wake: turn off this morning's final alarm.
    func finishMorning() async -> AlarmProblem? {
        if upcoming.isEmpty { return await disarm() }
        return await skipNext()
    }
    func disarm() async -> AlarmProblem? {
        await run {
            guard let lifecycle else { throw WakeError.noAlarm }
            try lifecycle.disarm(); show(nil)
            stopMonitoring("Alarm turned off")
            diagnostics.record("deadline_cancelled", "Explicit user action")
        }
    }
    func stopAlarm(_ id: UUID) async -> AlarmProblem? {
        await run {
            guard let lifecycle else { throw WakeError.noAlarm }
            try lifecycle.dismiss(id: id, now: Date()); diagnostics.record("alarm_stopped", "Explicit in-app action")
        }
    }
    func snoozeAlarm(_ id: UUID) async -> AlarmProblem? {
        await run {
            guard let lifecycle else { throw WakeError.noAlarm }
            try lifecycle.snooze(id: id, now: Date()); diagnostics.record("alarm_snoozed", "Explicit in-app action")
        }
    }
    func scheduleTestAlarm() async -> AlarmProblem? {
        await run {
            guard testAlarm == nil else { throw WakeError.busy }
            try await scheduler.authorize()
            let alarm = TestAlarm(id: UUID(), date: Date().addingTimeInterval(60))
            // Saved before AlarmKit is asked, so a crash cannot leave an alarm this app does not know.
            UserDefaults.standard.set(try JSONEncoder().encode(alarm), forKey: Self.testAlarmKey)
            testAlarm = alarm
            try await scheduler.schedule(id: alarm.id, date: alarm.date, options: TestAlarm.options)
            guard try scheduler.scheduledIDs().contains(alarm.id) else { throw WakeError.unverifiedAlarm }
            diagnostics.record("test_alarm_scheduled", alarm.date.ISO8601Format())
        }
    }
    func cancelTestAlarm() async -> AlarmProblem? {
        await run {
            if let testAlarm { try scheduler.cancel(id: testAlarm.id) }
            forgetTestAlarm(); diagnostics.record("test_alarm_cancelled", "Only the dedicated test ID")
        }
    }

    // MARK: Private

    private func run(_ operation: () async throws -> Void) async -> AlarmProblem? {
        guard !working else { return .changeFailed }
        working = true
        var problem: AlarmProblem?
        do { try await operation() } catch {
            diagnostics.record("alarm_operation_failed", String(describing: type(of: error)))
            problem = error as? WakeError == .unauthorized ? .alarmsDenied : .changeFailed
        }
        working = false
        refresh(reporting: problem == nil)
        return problem
    }
    private func arm(_ rule: WakeSchedule) async -> AlarmProblem? {
        await run {
            guard let lifecycle else { throw WakeError.noAlarm }
            try await lifecycle.arm(rule, now: Date())
            show(lifecycle.session)
            diagnostics.record("deadline_armed", "Next \(time.ISO8601Format()); days \(rule.weekdays.sorted()); window \(rule.options.windowMinutes)m; smart \(rule.options.smartEnabled); mornings \(1 + upcoming.count)")
        }
    }
    /// Tries again as soon as an armed morning appears, rings out or is stopped,
    /// and otherwise every 10 minutes as days pass: `refresh` runs often, and each
    /// try ends in another `refresh`.
    private func topUp(live: Set<UUID>) {
        guard let lifecycle, let session = lifecycle.session, session.schedule.repeats, !working else { return }
        let alarms = [Set(session.alarmIDs), live.intersection(session.alarmIDs)]
        if let lastTopUp, lastTopUp.alarms == alarms, now.timeIntervalSince(lastTopUp.date) < 600 { return }
        lastTopUp = (now, alarms)
        let armed = session.alarmIDs.count
        Task {
            _ = await run { try await lifecycle.topUp(now: Date()) }
            if let count = lifecycle.session?.alarmIDs.count, count != armed { diagnostics.record("mornings_added", "\(count) alarms armed") }
        }
    }
    private func received(_ sample: HeartSample) {
        now = Date(); diagnostics.sample(at: sample.date)
        recentBPM.append(BPMPoint(date: sample.date, bpm: sample.bpm))
        let cutoff = sample.date.addingTimeInterval(-Self.traceSpan)
        if let first = recentBPM.firstIndex(where: { $0.date >= cutoff }), first > 0 { recentBPM.removeFirst(first) }
        // Bluetooth keeps the app running overnight; use it to notice that a morning
        // has finished, so the next one becomes current without opening the app.
        if let plan, now >= plan.deadline, now.timeIntervalSince(lastSampleRefresh) > 30 {
            lastSampleRefresh = now; refresh()
        }
        guard let plan, ready, !working, lifecycle?.session?.earlyAttempted != true else { return }
        let decision = engine.ingest(sample, now: now, plan: plan)
        let oldState = snapshot.state
        snapshot = engine.snapshot
        if oldState != snapshot.state { diagnostics.record("estimator", snapshot.state.rawValue) }
        if let decision {
            diagnostics.record("early_candidate", decision.reason)
            Task { await wakeEarly() }
        }
    }
    /// Runs in the background, so a failure is only recorded: the final alarm still rings.
    private func wakeEarly() async {
        earlyBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish early alarm scheduling") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.diagnostics.record("early_background_expired", "Final alarm remains independent")
                self.endEarlyBackgroundTask()
            }
        }
        defer { endEarlyBackgroundTask() }
        let problem = await run {
            guard let lifecycle else { throw WakeError.noAlarm }
            try await lifecycle.early(now: Date())
        }
        diagnostics.record(problem == nil ? "early_attempt_finished" : "early_attempt_unavailable", "Final deadline retained")
    }
    private func endEarlyBackgroundTask() {
        guard earlyBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(earlyBackgroundTask); earlyBackgroundTask = .invalid
    }
    /// Nothing needs heart rate any more.
    private func stopMonitoring(_ reason: String) {
        ble.stop(); forgetStream()
        diagnostics.record("monitoring_finished", reason)
    }
    private func forgetStream() {
        engine.interrupt(); snapshot = engine.snapshot; recentBPM.removeAll()
    }
    private func show(_ session: Session?) {
        plan = session?.plan; schedule = session?.schedule; upcoming = session?.upcoming ?? []
    }
    private func forgetTestAlarm() {
        testAlarm = nil; testAlarmVerified = false
        UserDefaults.standard.removeObject(forKey: Self.testAlarmKey)
    }
}
