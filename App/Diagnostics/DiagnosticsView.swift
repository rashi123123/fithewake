import SwiftUI
import FitheWakeCore

struct DiagnosticsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmTest = false
    @State private var exportURL: URL?
    @State private var problem: AlarmProblem?
    var body: some View {
        NavigationStack {
            List {
                Section("Tonight") {
                    if let problem = problem ?? model.problem { Text(problem.message).font(.footnote).foregroundStyle(.orange) }
                    LabeledContent("Final alarm", value: model.readiness)
                    LabeledContent("Heart rate", value: model.receiving ? "Fresh" : "Not receiving")
                    LabeledContent("Engine", value: model.snapshot.state.rawValue)
                    Text(model.smartStatus.text).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Test the iPhone alarm") {
                    if let testAlarm = model.testAlarm {
                        LabeledContent("Test alarm", value: testAlarm.date.formatted(date: .omitted, time: .standard))
                        Text(model.testAlarmVerified ? "Test alarm ready" : "Checking test alarm").accessibilityIdentifier("testAlarmReadiness")
                        Button("Cancel test alarm", role: .destructive) { Task { problem = await model.cancelTestAlarm() } }
                            .accessibilityIdentifier("cancelTestAlarm")
                    } else {
                        Button("Test alarm in 1 minute", systemImage: "alarm") { confirmTest = true }
                            .accessibilityIdentifier("scheduleTestAlarm")
                    }
                    Text("Uses a separate alarm. Your wake-up time stays unchanged. Lock the iPhone and check that you hear it, then test Snooze and Stop.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Local test report") {
                    LabeledContent("Valid packets", value: "\(model.diagnostics.report.validPackets)")
                    LabeledContent("Observed coverage", value: "\(Int(model.diagnostics.report.coveredSeconds / 60)) min")
                    LabeledContent("Signal interruptions", value: "\(model.diagnostics.report.interruptions)")
                    LabeledContent("Largest observed gap", value: "\(Int(model.diagnostics.report.largestObservedGap)) sec")
                    LabeledContent("Algorithm", value: model.diagnostics.report.algorithm)
                    Button("Prepare report", systemImage: "doc.text") { exportURL = model.diagnostics.export() }.accessibilityIdentifier("prepareReport")
                    if let exportURL { ShareLink("Share test report", item: exportURL).accessibilityIdentifier("shareReport") }
                    if let error = model.diagnostics.storageError { Text(error).foregroundStyle(.orange) }
                    Text("Stored on this iPhone. Includes timestamps, counts and decisions, without raw heart-rate readings or device IDs. Nothing is uploaded automatically.").font(.footnote).foregroundStyle(.secondary)
                    Button("Clear report", role: .destructive) { model.diagnostics.clear(); exportURL = nil }
                }
                Section("Before an overnight test") {
                    Text("1. Save your alarm and check Alarm ready.")
                    Text("2. Enable heart-rate sharing and wait for a fresh reading.")
                    Text("3. Keep an independent alarm while testing. Do not force-quit \(AppInfo.name).")
                    Text("4. In the morning, export the report and note actual wake time, any interruptions and battery use.")
                    Text("Smart Wake is an experimental heart-rate rule, not validated sleep-stage detection. A successful software test does not establish overnight reliability.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Testing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sound a test alarm in one minute?", isPresented: $confirmTest) {
                Button("Schedule test alarm") { Task { problem = await model.scheduleTestAlarm() } }
            } message: { Text("This will make sound, including in Silent Mode. Your wake-up alarm stays unchanged.") }
            .disabled(model.working)
        }
    }
}
