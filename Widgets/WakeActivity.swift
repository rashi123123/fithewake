import SwiftUI
import WidgetKit
import ActivityKit
import AlarmKit

@main struct WakeActivity: Widget {
    @ViewBuilder private func countdown(_ state: AlarmPresentationState) -> some View {
        switch state.mode {
        case .countdown(let countdown): Text(countdown.fireDate, style: .timer).monospacedDigit()
        case .paused: Text("Paused")
        case .alert: Text("Wake up")
        @unknown default: Text(AppInfo.name)
        }
    }
    private func symbol(_ state: AlarmPresentationState) -> String {
        switch state.mode {
        case .countdown: "zzz"
        case .paused: "pause.fill"
        default: "alarm.waves.left.and.right.fill"
        }
    }
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<WakeMetadata>.self) { context in
            HStack { Image(systemName: "sunrise.fill"); Text(AppInfo.name); Spacer(); countdown(context.state) }
                .padding().activityBackgroundTint(Color.purple.opacity(0.25))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label(AppInfo.name, systemImage: "sunrise.fill") }
                DynamicIslandExpandedRegion(.bottom) { countdown(context.state) }
            } compactLeading: { Image(systemName: "sunrise.fill") }
              compactTrailing: { Image(systemName: symbol(context.state)) }
              minimal: { Image(systemName: "alarm") }
        }
    }
}
