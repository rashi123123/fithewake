import SwiftUI

/// Why an alarm change or check did not go through.
enum AlarmProblem: Equatable {
    case alarmsDenied, changeFailed, cannotVerify, cannotRecover
    var message: String {
        switch self {
        case .alarmsDenied: "Alarms are off for \(AppInfo.name). Turn them on in Settings, then try again."
        case .changeFailed: "Could not complete the alarm change. Check iPhone permissions and try again. Your previous alarm has not been intentionally removed."
        case .cannotVerify: "Cannot verify your iPhone alarm. Check permissions and try again."
        case .cannotRecover: "Unable to recover your alarm. Existing iPhone alarms have not been removed."
        }
    }
}

extension View {
    /// Shows `problem` as an alert; dismissing it clears it.
    func alarmProblemAlert(_ problem: Binding<AlarmProblem?>) -> some View {
        modifier(AlarmProblemAlert(problem: problem))
    }
}

private struct AlarmProblemAlert: ViewModifier {
    @Environment(\.openURL) private var openURL
    @Binding var problem: AlarmProblem?
    func body(content: Content) -> some View {
        content.alert("Alarm needs attention",
                      isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }),
                      presenting: problem) { problem in
            if problem == .alarmsDenied { Button("Open Settings") { openURL(.appSettings) } }
            Button("OK", role: .cancel) {}
        } message: { Text($0.message) }
    }
}
