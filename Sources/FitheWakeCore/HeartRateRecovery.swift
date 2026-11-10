import Foundation

/// Detect a silent transport without reconnecting on every foreground timer tick.
/// Invalid/contact-loss packets still prove that Bluetooth is delivering data.
public struct HeartRateRecovery: Sendable {
    private var lastPacket: Date
    private var lastAttempt: Date?
    private var attempts = 0
    public init(now: Date) { lastPacket = now }
    public func packetAge(at now: Date) -> TimeInterval { now.timeIntervalSince(lastPacket) }
    public mutating func receivedPacket(at now: Date) {
        lastPacket = now; attempts = 0; lastAttempt = nil
    }
    public mutating func shouldReconnect(at now: Date) -> Bool {
        guard now.timeIntervalSince(lastPacket) >= 20 else { return false }
        let delay = min(120.0, 30.0 * pow(2, Double(min(max(attempts - 1, 0), 2))))
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < delay { return false }
        lastAttempt = now; attempts += 1
        return true
    }
}
