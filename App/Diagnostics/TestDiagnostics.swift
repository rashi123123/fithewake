import Foundation
import Observation
import FitheWakeCore

/// Local operational metadata, never raw BPM/RR, device identifiers or names.
@MainActor @Observable final class TestDiagnostics {
    struct Event: Codable { let date: Date; let kind: String; let detail: String }
    struct Report: Codable {
        var algorithm = NightEngine.version
        var startedAt = Date()
        var validPackets = 0
        var interruptions = 0
        var coveredSeconds: Double = 0
        var largestObservedGap: Double = 0
        var events: [Event] = []
    }
    private(set) var report = Report()
    private(set) var storageError: String?
    private var lastSample: Date?
    private var lastSave = Date.distantPast
    private let url: URL?
    init() {
        url = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("test-diagnostics.json")
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do { report = try JSONDecoder().decode(Report.self, from: data) }
        catch { record("report_unreadable", "The saved report could not be read; started a new one") }
    }
    func sample(at date: Date) {
        report.validPackets += 1
        if let lastSample {
            let gap = date.timeIntervalSince(lastSample)
            if gap > 0 {
                report.largestObservedGap = max(report.largestObservedGap, gap)
                if gap <= HeartSample.maxAge { report.coveredSeconds += gap }
            }
        }
        lastSample = date
        if date.timeIntervalSince(lastSave) >= 60 { save() }
    }
    func interruption() {
        report.interruptions += 1
        // Keep lastSample to measure the outage on the next usable packet.
        if report.events.last?.kind != "signal_interrupted" { record("signal_interrupted", "Waiting for fresh signal") }
    }
    func record(_ kind: String, _ detail: String) {
        report.events.append(Event(date: Date(), kind: kind, detail: detail))
        if report.events.count > 300 { report.events.removeFirst(report.events.count - 300) }
        save()
    }
    func save() {
        do {
            guard let url else { throw CocoaError(.fileWriteUnknown) }
            try JSONEncoder().encode(report).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil; lastSave = Date()
        } catch { storageError = "Could not save the local test report." }
    }
    func clear() { report = Report(); lastSample = nil; save() }
    /// A shareable copy of the report, or nil with `storageError` set.
    func export() -> URL? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppInfo.name)-Test-Report.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(report).write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return output
        } catch { storageError = "Could not prepare the test report."; return nil }
    }
}
