import SwiftUI
import FitheWakeCore

/// Three steps on the Crown Glass night:
/// 1. what the app promises,
/// 2. the wake-up time, which arms the real alarm and asks for alarm permission right there,
/// 3. the optional Fitbit, which asks for Bluetooth only when Connect is tapped.
struct OnboardingFlow: View {
    enum Step: Int, CaseIterable { case welcome, alarm, fitbit }

    @Environment(\.wakeAtmosphere) private var sky
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    let model: AppModel
    let replay: Bool
    let finish: () -> Void

    @State private var step = Step.welcome
    @State private var forward = true
    @State private var revealed = false
    @State private var form: AlarmForm
    @State private var problem: AlarmProblem?
    @ScaledMetric(relativeTo: .largeTitle) private var wordmarkSize: CGFloat = 50

    init(model: AppModel, replay: Bool = false, finish: @escaping () -> Void) {
        self.model = model
        self.replay = replay
        self.finish = finish
        _form = State(initialValue: AlarmForm(model: model))
    }

    var body: some View {
        ZStack(alignment: .top) {
            NightBackground().ignoresSafeArea()
            // The crown recedes a little once setup begins, so the controls lead.
            CrownGlassArtwork()
                .frame(height: 360)
                .padding(.top, 28)
                .opacity(step == .welcome ? 1 : 0.5)
                .offset(y: step == .welcome ? 0 : -26)
                .animation(.easeInOut(duration: 0.9), value: step)
                .ignoresSafeArea(edges: .top)
            VStack(spacing: 0) {
                header
                ScrollView {
                    page
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .sensoryFeedback(.selection, trigger: step)
        .sensoryFeedback(.selection, trigger: form.days)
        .sensoryFeedback(.success, trigger: model.receiving) { _, now in now && step == .fitbit }
        .onAppear { revealed = true }
    }

    // MARK: Chrome

    private var header: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == step ? sky.highlight.color : sky.highlight.color.opacity(0.22))
                        .frame(width: item == step ? 20 : 6, height: 6)
                }
            }
            .animation(pageAnimation, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            HStack {
                if step != .welcome {
                    Button("Back", systemImage: "chevron.left") { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .tint(.primary)
                        .transition(.opacity)
                        .accessibilityIdentifier("onboardingBack")
                }
                Spacer()
                if replay {
                    Button("Close", systemImage: "xmark") { finish() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .tint(.primary)
                }
            }
            .animation(pageAnimation, value: step)
        }
        .frame(height: 52)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var page: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .alarm: alarm
            case .fitbit: fitbit
            }
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(x: forward ? 36 : -36).combined(with: .opacity),
            removal: .offset(x: forward ? -36 : 36).combined(with: .opacity)))
    }

    private var pageAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.55, bounce: 0)
    }

    private func go(to next: Step) {
        guard next != step else { return }
        if step == .alarm { problem = nil }
        // Set the direction first, so the leaving page also uses it.
        forward = next.rawValue > step.rawValue
        Task { @MainActor in withAnimation(pageAnimation) { step = next } }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 0) {
            Text("Welcome to")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(sky.highlight.color)
                .modifier(Reveal(shown: revealed, order: 0))
            Text(AppInfo.name)
                .font(.system(size: wordmarkSize, weight: .semibold, design: .rounded))
                .tracking(-wordmarkSize * 0.03)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .modifier(Reveal(shown: revealed, order: 1))
            Text("A calmer way to wake up, guided by your Fitbit.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(sky.secondary.color)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .modifier(Reveal(shown: revealed, order: 2))
            VStack(alignment: .leading, spacing: 20) {
                InfoRow(marker: .symbol("alarm.fill"), title: "Always rings by your time",
                        detail: "A real iPhone alarm. It rings even if \(AppInfo.name) is closed.")
                InfoRow(marker: .symbol("waveform.path.ecg"), title: "Wakes you in lighter sleep",
                        detail: "In a window you choose, if your Fitbit’s heart rate shows it.")
                InfoRow(marker: .symbol("lock.fill"), title: "Stays on your iPhone",
                        detail: "No account. Heart rate is read live on this iPhone.")
            }
            .padding(.vertical, 22).padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wakeCard()
            .padding(.top, 30)
            .modifier(Reveal(shown: revealed, order: 3))
        }
        .padding(.top, 140)
    }

    private var alarm: some View {
        VStack(spacing: 0) {
            pageTitle(eyebrow: "Your alarm", title: "When do you want to be up?")
            VStack(spacing: 0) {
                DatePicker("Wake up by", selection: $form.time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 168)
                    .clipped()
                    .accessibilityIdentifier("onboardingTime")
                if let next = form.nextText(at: model.now) {
                    Text(next)
                        .font(.footnote).monospacedDigit()
                        .foregroundStyle(sky.secondary.color)
                        .padding(.bottom, 14)
                }
            }
            .wakeCard()
            .padding(.top, 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("Repeat").font(.subheadline.weight(.semibold))
                WeekdayPicker(days: $form.days).padding(.top, 10)
                Text(form.repeatText)
                    .font(.footnote).foregroundStyle(sky.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                CardDivider().padding(.vertical, 14)
                Text("Smart Wake window").font(.subheadline.weight(.semibold))
                Picker("Smart Wake window", selection: $form.options.windowMinutes) {
                    ForEach(WakeOptions.windowChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.top, 10)
                .accessibilityIdentifier("onboardingWindow")
                Text(form.windowText)
                    .font(.footnote).monospacedDigit()
                    .foregroundStyle(sky.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(18)
            .wakeCard()
            .padding(.top, 12)
        }
        .padding(.top, 44)
    }

    private var fitbit: some View {
        VStack(spacing: 0) {
            pageTitle(eyebrow: "Optional · Smart Wake", title: "Connect your Fitbit")
            Text("Smart Wake reads your Fitbit Air’s heart rate over Bluetooth. Your alarm rings without it.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(sky.secondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array([FitbitSetup.wear, FitbitSetup.share, connectStep].enumerated()), id: \.offset) { index, step in
                    InfoRow(marker: .number(index + 1), title: step.title, detail: step.detail)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wakeCard()
            .padding(.top, 22)
            if model.ble.requested || model.ble.bluetoothDenied {
                connection
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(pageAnimation, value: model.ble.requested)
        .padding(.top, 44)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ReceivingHeart(receiving: model.receiving)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.receiving ? "Receiving heart rate" : model.ble.bluetoothDenied ? "Bluetooth is off for \(AppInfo.name)" : "Looking for your Fitbit")
                        .font(.subheadline.weight(.semibold))
                    Text(model.receiving ? model.ble.wearableName : model.ble.status)
                        .font(.footnote).foregroundStyle(sky.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let bpm = model.bpm {
                    BPMReadout(bpm: bpm)
                } else if !model.ble.bluetoothDenied {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboardingConnection")
            ForEach(model.ble.devices, id: \.identifier) { device in
                DeviceButton(ble: model.ble, device: device)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.glass)
            }
            if model.ble.bluetoothDenied {
                Button("Open Settings", systemImage: "gear") { openURL(.appSettings) }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.glass)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wakeCard()
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        VStack(spacing: 4) {
            if step == .alarm, let problem {
                VStack(spacing: 6) {
                    Text(problem.message)
                        .font(.footnote).foregroundStyle(Color.orange)
                        .multilineTextAlignment(.center)
                    if problem == .alarmsDenied {
                        Button("Open Settings") { openURL(.appSettings) }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity)
            }
            primary
            // The same height on every page, so the primary button never jumps.
            secondary.frame(minHeight: 44)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background {
            // Lets scrolled content fade under the buttons instead of colliding with them.
            LinearGradient(colors: [sky.bottom.color.opacity(0), sky.bottom.color.opacity(0.92)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .modifier(Reveal(shown: revealed, order: 3))
        .animation(pageAnimation, value: problem)
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case .welcome:
            PrimaryButton(title: "Get started", symbol: "arrow.right", identifier: "onboardingStart") { go(to: .alarm) }
        case .alarm:
            PrimaryButton(title: model.plan == nil ? "Set alarm" : "Save alarm", symbol: "alarm",
                          identifier: "onboardingSetAlarm", working: model.working) {
                Task { await setAlarm() }
            }
            .disabled(model.working || form.next(after: model.now) == nil)
        case .fitbit:
            if model.receiving {
                PrimaryButton(title: "Done", symbol: "checkmark", identifier: "onboardingDone") { finish() }
            } else if model.ble.requested && !model.ble.bluetoothDenied {
                PrimaryButton(title: "Waiting for heart rate", symbol: nil, identifier: "onboardingWaiting", working: true) {}
                    .disabled(true)
            } else {
                PrimaryButton(title: "Connect Fitbit", symbol: "antenna.radiowaves.left.and.right",
                              identifier: "onboardingConnect") { model.ble.start() }
                    .disabled(model.ble.bluetoothDenied)
            }
        }
    }

    @ViewBuilder private var secondary: some View {
        switch step {
        case .welcome:
            EmptyView()
        case .alarm:
            SecondaryButton(title: model.plan == nil ? "Set it later" : "Keep my current alarm",
                            identifier: "onboardingSkipAlarm") { go(to: .fitbit) }
            .disabled(model.working)
        case .fitbit:
            if model.receiving {
                EmptyView()
            } else if model.ble.requested {
                // Monitoring keeps trying in the background; the Fitbit tab shows its progress.
                SecondaryButton(title: "Finish, keep looking", identifier: "onboardingFinish") { finish() }
            } else {
                SecondaryButton(title: "Not now", identifier: "onboardingNotNow") {
                    model.ble.pause()
                    finish()
                }
            }
        }
    }

    private func setAlarm() async {
        problem = await model.setAlarm(form.rule)
        if problem == nil { go(to: .fitbit) }
    }

    // MARK: Helpers

    private let connectStep = SetupStep(symbol: "antenna.radiowaves.left.and.right", title: "Connect below",
                                        detail: "\(AppInfo.name) asks to use Bluetooth, then finds your Fitbit.")

    private func pageTitle(eyebrow: String, title: String) -> some View {
        VStack(spacing: 4) {
            Text(eyebrow)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(sky.highlight.color)
            Text(title)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The welcome page's lines arrive one after another while the rings settle.
/// Reduce Motion: a plain fade.
private struct Reveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool
    let order: Int
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? .easeOut(duration: 0.3)
                       : .spring(duration: 1.1, bounce: 0).delay(0.5 + Double(order) * 0.14), value: shown)
    }
}

private struct PrimaryButton: View {
    let title: String
    let symbol: String?
    let identifier: String
    var working = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                Text(title)
                if let symbol, !working { Image(systemName: symbol).font(.body.weight(.semibold)) }
            }
            .font(.system(.body, design: .rounded).weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .accessibilityIdentifier(identifier)
    }
}

private struct SecondaryButton: View {
    @Environment(\.wakeAtmosphere) private var sky
    let title: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundStyle(sky.secondary.color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
    }
}
