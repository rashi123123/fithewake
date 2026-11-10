import SwiftUI
import FitheWakeCore

struct TonightView: View {
    @Environment(\.wakeAtmosphere) private var sky
    let model: AppModel
    let showFitbit: () -> Void
    let edit: () -> Void
    @State private var showHelp = false
    @State private var showIntro = false
    @State private var showDiagnostics = false
    @State private var confirmDisarm = false
    @State private var confirmSkip = false
    @State private var confirmUp = false
    @State private var problem: AlarmProblem?
    @AppStorage("displayName") private var displayName = ""
    @State private var nameDraft = ""
    @State private var showNameEditor = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var placeholderSize: CGFloat = 78
    private var greeting: String {
        let greeting = LocalDayClock.greeting(at: model.now)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? greeting : "\(greeting), \(name)"
    }
    private var wideType: Bool { typeSize.isAccessibilitySize }
    private var nextDate: Date { model.time }
    /// "Tomorrow morning": the day and part of day, above the digits. It carries
    /// AM/PM, so the digits stand alone and sit on the same axis as every other line.
    private var dayPhrase: String {
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.component(.hour, from: nextDate)
        let part = hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"
        if calendar.isDateInToday(nextDate) { return part == "evening" ? "Tonight" : "This \(part)" }
        if calendar.isDateInTomorrow(nextDate) { return "Tomorrow \(part)" }
        return "\(nextDate.formatted(.dateTime.weekday(.wide))) \(part)"
    }
    /// "Weekdays · in 7 h 12 min": how often, and how much night is left.
    private var statusText: String {
        guard model.ready else { return model.readiness }
        let repeatText = RepeatDays.summary(model.schedule?.weekdays ?? [])
        return nextDate > model.now ? "\(repeatText) · \(sleepLeft(until: nextDate, from: model.now))" : repeatText
    }
    private var shortTime: String { nextDate.formatted(date: .omitted, time: .shortened) }
    private var nextMorningAfterSkip: String {
        guard let later = model.upcoming.first?.deadline else { return "" }
        return later.formatted(.dateTime.weekday(.wide).hour().minute())
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    crownHero
                    VStack(spacing: 0) {
                        smartWake
                        CardDivider().padding(.horizontal, 18)
                        wearable
                    }
                    .wakeCard()
                    .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 32)
                }
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden(true, for: .top)
            .background { NightBackground().ignoresSafeArea() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(greeting)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(sky.secondary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .accessibilityIdentifier("personalGreeting")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(displayName.isEmpty ? "Add your name" : "Edit name", systemImage: "person.crop.circle") {
                            nameDraft = displayName
                            showNameEditor = true
                        }
                        Button("How Smart Wake works", systemImage: "info.circle") { showHelp = true }
                        Button("Introduction", systemImage: "sparkles") { showIntro = true }
                            .accessibilityIdentifier("openIntroduction")
                        Button("Testing & diagnostics", systemImage: "checkmark.shield") { showDiagnostics = true }
                            .accessibilityIdentifier("openDiagnostics")
                    } label: {
                        Label("Alarm options", systemImage: "ellipsis")
                    }.tint(.primary).accessibilityIdentifier("alarmOptions")
                }
            }
            .sheet(isPresented: $showHelp) { SmartWakeHelp() }
            .fullScreenCover(isPresented: $showIntro) {
                OnboardingFlow(model: model, replay: true) { showIntro = false }
                    .environment(\.wakeAtmosphere, sky).tint(sky.action.color)
            }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView(model: model) }
            .alarmProblemAlert($problem)
            .confirmationDialog("Turn off your wake-up alarm?", isPresented: $confirmDisarm) {
                Button("Turn off alarm", role: .destructive) { Task { problem = await model.disarm() } }
            } message: {
                Text(model.repeats ? "No alarm will ring on any day until you set it again." : "The \(shortTime) alarm won’t ring.")
            }
            .confirmationDialog("Skip \(nextDate.formatted(.dateTime.weekday(.wide)))’s alarm?", isPresented: $confirmSkip) {
                Button("Skip \(nextDate.formatted(.dateTime.weekday(.wide)))", role: .destructive) { Task { problem = await model.skipNext() } }
            } message: { Text("Only this morning. \(nextMorningAfterSkip) stays on.") }
            .confirmationDialog("Turn off the \(shortTime) alarm?", isPresented: $confirmUp) {
                Button("Turn off \(shortTime)", role: .destructive) { Task { problem = await model.finishMorning() } }
            } message: {
                Text(model.upcoming.isEmpty ? "You’re up, so the final alarm won’t ring." : "You’re up, so it won’t ring this morning. \(nextMorningAfterSkip) stays on.")
            }
            .alert("Your name", isPresented: $showNameEditor) {
                TextField("First name", text: $nameDraft)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    displayName = String(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                }
            } message: {
                Text("Used for your greeting. Saved on this iPhone. Leave empty to hide it.")
            }
        }
    }

    private var crownHero: some View {
        VStack(spacing: 0) {
            Text(model.plan == nil ? "Wake up by" : dayPhrase)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(sky.highlight.color)
                .accessibilityIdentifier("alarmDay")
            Group {
                if model.plan != nil {
                    // Touching the clock edits it, like the Clock app. The detached
                    // tab action stays as the accessible, discoverable path.
                    EditorialTime(date: model.time)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: edit)
                        .accessibilityAction(named: "Edit wake-up time", edit)
                } else {
                    Text("—:—").font(.system(size: placeholderSize, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.45)
                        .foregroundStyle(sky.secondary.color)
                        .accessibilityLabel("No alarm set")
                }
            }.accessibilityIdentifier("alarmTime")
            if model.plan == nil {
                // One clear next action for the empty state, next to where it matters.
                Button("Set wake-up time", systemImage: "alarm", action: edit)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .buttonStyle(.glassProminent)
                    .padding(.top, 14)
                    .accessibilityIdentifier("setWakeTime")
            } else {
                readiness.padding(.top, 2)
                heroActions.padding(.top, 16)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, wideType ? 140 : 124)
        .frame(maxWidth: .infinity, minHeight: wideType ? 450 : 350, alignment: .top)
        .background(alignment: .top) {
            CrownGlassArtwork()
                .frame(height: wideType ? 460 : 360)
                .offset(y: -30)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottomLeading) {
            if CrownIntroProbe.enabled {
                Text(CrownIntroProbe.shared.summary).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).accessibilityIdentifier("introProbe")
            }
        }
    }

    /// The everyday changes live next to the time they change: skip one morning,
    /// or, after Smart Wake rang early, turn off the final alarm. Both confirm,
    /// because a missed alarm cannot be undone.
    @ViewBuilder private var heroActions: some View {
        if model.upEarly {
            Button("I’m up · turn off \(shortTime)", systemImage: "sun.max") { confirmUp = true }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("finishMorning")
        } else if model.ready {
            HStack(spacing: 10) {
                if model.repeats && !model.upcoming.isEmpty {
                    Button("Skip \(nextDate.formatted(.dateTime.weekday(.abbreviated)))", systemImage: "forward.end") { confirmSkip = true }
                        .accessibilityLabel("Skip \(nextDate.formatted(.dateTime.weekday(.wide)))’s alarm")
                        .accessibilityIdentifier("skipNext")
                }
                Button("Turn off", systemImage: "bell.slash") { confirmDisarm = true }
                    .accessibilityIdentifier("turnOffAlarm")
            }
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .buttonStyle(.glass)
            .tint(sky.secondary.color)
            .disabled(model.working)
        }
    }

    /// A single text line (not a chip): it reads as information, not a button.
    /// Problems use orange plus a warning symbol, so color is never the only cue.
    private var readiness: some View {
        let ok = model.ready
        let symbol = model.working ? "hourglass" : ok ? (model.repeats ? "repeat" : "checkmark.circle.fill") : "exclamationmark.triangle.fill"
        let tone = ok ? sky.highlight.color : Color.orange
        return Text("\(Text(Image(systemName: symbol)).foregroundStyle(tone))  \(statusText)")
            .font(.system(.footnote, design: .rounded).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(ok ? sky.secondary.color : Color.orange)
            .multilineTextAlignment(.center)
            .accessibilityLabel(model.readiness)
            .accessibilityValue(ok ? statusText : "")
            .accessibilityIdentifier("alarmReadiness")
    }

    private var smartWake: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Wake")
                        .font(.system(.headline, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text(!model.ready ? "No active wake window" : model.smart ? "Between \(model.windowStart.formatted(date: .omitted, time: .shortened)) and \(shortTime)" : "Off · rings at \(shortTime)")
                        .monospacedDigit()
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(sky.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wakeWindowBadge")
                }
                Spacer(minLength: 0)
                Button { showHelp = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless).tint(sky.secondary.color)
                .accessibilityLabel("How Smart Wake works")
                .accessibilityIdentifier("smartWakeInfo")
                .padding(.trailing, -12).padding(.top, -7)
            }
            // Progress only means something once the window is open; an empty
            // bar before that read as a stalled loading indicator.
            if model.ready && model.smart && model.now >= model.windowStart {
                WakeWindowTrack(start: model.windowStart, end: model.time, now: model.now)
            }
            Text(model.smartStatus.text)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(model.smartStatus.warning ? Color.orange : sky.secondary.color)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("smartWakeStatus")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .accessibilityElement(children: .contain)
    }

    private var wearable: some View {
        Button(action: showFitbit) {
            let layout = wideType
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                HStack(alignment: .top, spacing: 12) {
                    ReceivingHeart(receiving: model.receiving)
                        .frame(width: 22).padding(.top, 1).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.ble.wearableName).font(.system(.subheadline, design: .rounded).weight(.medium))
                        Text(model.receiving ? "Receiving heart rate" : "No recent reading")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(model.receiving ? sky.secondary.color : Color.orange)
                    }
                }
                if !wideType { Spacer(minLength: 0) }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    BPMReadout(bpm: model.bpm)
                    Image(systemName: "chevron.right").font(.caption2.weight(.medium))
                        .foregroundStyle(sky.secondary.color.opacity(0.65)).padding(.leading, 7)
                }.fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 16).padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityIdentifier("fitbitStatus")
        .accessibilityLabel(model.receiving ? "\(model.ble.wearableName), receiving heart rate, \(model.bpm ?? 0) beats per minute. Connection details." : "\(model.ble.wearableName), no recent heart rate. Connection details.")
    }
}

/// The wake window as a track that fills as the window passes.
private struct WakeWindowTrack: View {
    @Environment(\.wakeAtmosphere) private var sky
    let start: Date
    let end: Date
    let now: Date
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 6
    private var progress: Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / span))
    }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(sky.highlight.color.opacity(0.14))
                Capsule().fill(sky.action.color)
                    .frame(width: max(progress > 0 ? height : 0, width * progress))
                if progress > 0 && progress < 1 {
                    Circle().fill(.white)
                        .frame(width: height * 2, height: height * 2)
                        .shadow(color: sky.ring.color.opacity(0.9), radius: 5)
                        .offset(x: width * progress - height)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height * 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wake window")
        .accessibilityValue(progress <= 0 ? "Not open yet" : progress >= 1 ? "Ended" : "\(Int(progress * 100)) percent passed")
        .accessibilityIdentifier("wakeWindowTrack")
    }
}

private struct EditorialTime: View {
    let date: Date
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 88
    /// Digits only, like the Lock Screen. The day phrase above ("Tomorrow morning")
    /// carries AM/PM, so the digits share one center axis with every line around
    /// them; a trailing suffix pulled the visual center off to one side.
    var body: some View {
        Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .tracking(-size * 0.035).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.45)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("alarmDigits")
            .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
    }
}
