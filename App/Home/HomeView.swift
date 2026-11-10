import SwiftUI
import FitheWakeCore

/// Raw values are the UITab identifiers.
private enum WakeTab: String { case tonight, fitbit }

/// The app after onboarding: Tonight and Fitbit tabs, the editor, and the ringing screen.
struct HomeView: View {
    @Environment(\.wakeAtmosphere) private var sky
    let model: AppModel
    @State private var tab = WakeTab.tonight
    @State private var showEditor = false

    var body: some View {
        SystemTabs(model: model, selection: $tab, edit: { showEditor = true })
            .ignoresSafeArea()
            .overlay {
                // While an owned alarm rings, Stop and Snooze own the whole screen.
                if let id = model.activeID {
                    RingingTakeover(model: model, id: id)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.activeID)
            .tint(sky.action.color)
            .sensoryFeedback(.selection, trigger: tab)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: showEditor) { _, opened in opened }
            .sheet(isPresented: $showEditor) { AlarmEditor(model: model) }
            // Checks that fail on their own. An alert can’t appear under the editor sheet.
            .alarmProblemAlert(Binding(get: { showEditor ? nil : model.problem }, set: { model.problem = $0 }))
    }
}

/// Full-screen ringing state. One primary action (Stop), one secondary (Snooze),
/// both large and thumb-reachable at the bottom; the current time is the headline.
private struct RingingTakeover: View {
    @Environment(\.wakeAtmosphere) private var sky
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: AppModel
    let id: UUID
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 96
    @State private var stopped = 0
    @State private var problem: AlarmProblem?

    var body: some View {
        ZStack {
            NightBackground()
            CrownGlassArtwork()
                .frame(height: typeSize.isAccessibilitySize ? 460 : 360)
                .offset(y: -30)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Spacer(minLength: 120)
                Text(LocalDayClock.greeting(at: model.now))
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(sky.highlight.color)
                Text(model.now, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: clockSize, weight: .semibold, design: .rounded))
                    .tracking(-clockSize * 0.035).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.45)
                    .contentTransition(.numericText())
                    .accessibilityLabel(model.now.formatted(date: .omitted, time: .shortened))
                Label("Alarm ringing", systemImage: "alarm.waves.left.and.right.fill")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(sky.highlight.color)
                    .padding(.top, 8)
                Spacer()
                VStack(spacing: 12) {
                    Button {
                        stopped += 1
                        Task { problem = await model.stopAlarm(id) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("ringingStop")
                    Button { Task { problem = await model.snoozeAlarm(id) } } label: {
                        Label(model.snoozeMinutes(for: id).map { "Snooze \($0) min" } ?? "Snooze", systemImage: "zzz")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("ringingSnooze")
                }
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .disabled(model.working)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
        }
        .sensoryFeedback(.success, trigger: stopped)
        .alarmProblemAlert($problem)
        .accessibilityAddTraits(.isModal)
    }
}

/// The actual system tab controller owns all glass, selection lens, hit testing,
/// safe areas and accessibility. Its detached item presents an action without
/// replacing the selected destination or creating a hand-drawn navigation bar.
private struct SystemTabs: UIViewControllerRepresentable {
    let model: AppModel
    @Binding var selection: WakeTab
    let edit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        let coordinator = context.coordinator
        let sky = context.environment.wakeAtmosphere
        controller.delegate = coordinator
        coordinator.refreshContent(typeSize: context.environment.dynamicTypeSize, sky: sky)
        let tonight = UITab(title: "Tonight", image: UIImage(systemName: "moon.fill"), identifier: WakeTab.tonight.rawValue) { _ in
            coordinator.tonight
        }
        tonight.accessibilityIdentifier = "tonightTab"
        let fitbit = UITab(title: "Fitbit", image: UIImage(systemName: "waveform.path.ecg"), identifier: WakeTab.fitbit.rawValue) { _ in
            coordinator.fitbit
        }
        fitbit.accessibilityIdentifier = "fitbitTab"
        let edit = UITab(title: "Edit alarm", image: UIImage(systemName: "alarm"), identifier: "edit") { _ in
            UIViewController()
        }
        edit.accessibilityIdentifier = "editAlarm"
        controller.tabs = [tonight, fitbit, edit]
        if #available(iOS 27.0, *) { controller.prominentTabIdentifier = "edit" }
        controller.selectedTab = tonight
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let sky = context.environment.wakeAtmosphere
        controller.tabBar.tintColor = UIColor(sky.action.color)
        controller.view.backgroundColor = UIColor(sky.bottom.color)
        if coordinator.typeSize != context.environment.dynamicTypeSize || coordinator.sky != sky {
            coordinator.refreshContent(typeSize: context.environment.dynamicTypeSize, sky: sky)
        }
        if controller.selectedTab?.identifier != selection.rawValue {
            controller.selectedTab = controller.tabs.first { $0.identifier == selection.rawValue }
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var parent: SystemTabs
        var typeSize: DynamicTypeSize?
        var sky: DayAtmosphere?
        let tonight = UIHostingController(rootView: AnyView(EmptyView()))
        let fitbit = UIHostingController(rootView: AnyView(EmptyView()))

        init(parent: SystemTabs) { self.parent = parent }

        func refreshContent(typeSize: DynamicTypeSize, sky: DayAtmosphere) {
            self.typeSize = typeSize
            self.sky = sky
            tonight.rootView = AnyView(TonightView(model: parent.model, showFitbit: { [weak self] in
                self?.parent.selection = .fitbit
            }, edit: { [weak self] in
                self?.parent.edit()
            }).environment(\.dynamicTypeSize, typeSize)
                .environment(\.wakeAtmosphere, sky).tint(sky.action.color))
            fitbit.rootView = AnyView(FitbitView(model: parent.model).environment(\.dynamicTypeSize, typeSize)
                .environment(\.wakeAtmosphere, sky).tint(sky.action.color))
            tonight.view.backgroundColor = .clear
            fitbit.view.backgroundColor = .clear
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab.identifier == "edit" {
                parent.edit()
                return false
            }
            return true
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            guard let destination = WakeTab(rawValue: selectedTab.identifier) else { return }
            // Programmatic selection during representable updates must not echo
            // an unchanged value back into SwiftUI state.
            if parent.selection != destination { parent.selection = destination }
        }
    }
}
