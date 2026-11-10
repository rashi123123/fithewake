import SwiftUI
import FitheWakeCore

@main struct FitheWakeApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            // The sky follows the local hour; a once-a-minute update keeps it current.
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                AppRoot(model: model)
                    .environment(\.wakeAtmosphere, DayAtmosphere.at(timeline.date))
                    .transformEnvironment(\.dynamicTypeSize) { size in
                        if LaunchFlag.largeType.isSet { size = .accessibility2 }
                    }
            }
            .task {
                while !Task.isCancelled {
                    model.tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onChange(of: phase) { _, value in
                if value == .active { model.refresh() }
                else { model.diagnostics.save() }
            }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = LaunchFlag.keepAwake.isSet }
        }
    }
}

/// Onboarding until it is finished once, then the app. It can be replayed from
/// the Tonight screen's options menu.
private struct AppRoot: View {
    @Environment(\.wakeAtmosphere) private var sky
    let model: AppModel
    @AppStorage("onboarded") private var onboarded = false
    @State private var forced = LaunchFlag.onboarding.isSet

    private var showsOnboarding: Bool {
        !LaunchFlag.skipOnboarding.isSet && (forced || !onboarded)
    }

    var body: some View {
        ZStack {
            if showsOnboarding {
                OnboardingFlow(model: model) { forced = false; onboarded = true }
                    .transition(.opacity)
            } else {
                HomeView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: showsOnboarding)
        .tint(sky.action.color)
    }
}
