import AlarmKit
import SwiftUI
import FitheWakeCore

/// The app's only contact with AlarmKit.
@MainActor final class NativeAlarmScheduler: AlarmScheduling {
    private let manager = AlarmManager.shared
    private var observers: [Task<Void, Never>] = []

    var authorized: Bool { manager.authorizationState == .authorized }

    func authorize() async throws {
        var state = manager.authorizationState
        if state == .notDetermined {
            state = try await manager.requestAuthorization()
            // Use the returned state. A synchronous authorizationState re-query
            // from this continuation deadlocked with mobiletimerd on iOS 27.2.
            // Resume on a fresh main-queue turn after the XPC callback unwinds.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        guard state == .authorized else { throw WakeError.unauthorized }
    }
    func schedule(id: UUID, date: Date, options: WakeOptions) async throws {
        guard options.isValid else { throw WakeError.invalidPlan }
        guard date > Date() else { throw WakeError.expired }
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: AppInfo.name), stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"), secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"), secondaryButtonBehavior: .countdown)
        let attributes = AlarmAttributes<WakeMetadata>(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(), tintColor: .pink)
        let configuration = AlarmManager.AlarmConfiguration(countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: Double(options.snoozeMinutes * 60)), schedule: .fixed(date), attributes: attributes, sound: options.progressiveSound ? .named("Dawn.wav") : .default)
        _ = try await manager.schedule(id: id, configuration: configuration)
    }
    func scheduledIDs() throws -> Set<UUID> { Set(try manager.alarms.map(\.id)) }
    func cancel(id: UUID) throws { if try scheduledIDs().contains(id) { try manager.cancel(id: id) } }
    func stop(id: UUID) throws { try manager.stop(id: id) }
    func snooze(id: UUID) throws { try manager.countdown(id: id) }

    /// The first of `ids` that is ringing now.
    func alerting(among ids: Set<UUID>) throws -> UUID? {
        try manager.alarms.first { ids.contains($0.id) && $0.state == .alerting }?.id
    }
    /// Calls `changed` on every alarm update and `revoked` when alarm permission is
    /// taken away, for the life of the app.
    func observe(changed: @escaping @MainActor () -> Void, revoked: @escaping @MainActor () -> Void) {
        observers = [
            Task { [manager] in for await _ in manager.alarmUpdates { changed() } },
            Task { [manager] in
                for await state in manager.authorizationUpdates where state != .authorized {
                    // The yielded value is authoritative. Do not synchronously
                    // re-enter the authorization XPC callback.
                    revoked()
                }
            },
        ]
    }
}

@MainActor final class DiskSessionStore: SessionStore {
    private let url: URL
    init() throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        url = directory.appendingPathComponent("session.json")
    }
    func load() throws -> Session? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
    }
    func save(_ session: Session?) throws {
        if let session {
            try JSONEncoder().encode(session).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
