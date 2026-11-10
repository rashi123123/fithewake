import SwiftUI
import FitheWakeCore

struct AlarmEditor: View {
    @Environment(\.wakeAtmosphere) private var sky
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var form: AlarmForm
    @State private var problem: AlarmProblem?

    init(model: AppModel) {
        self.model = model
        _form = State(initialValue: AlarmForm(model: model))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Wake up by", selection: $form.time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                        .accessibilityIdentifier("wakeTimePicker")
                } footer: {
                    if let next = form.nextText(at: model.now) {
                        Text(next).monospacedDigit().accessibilityIdentifier("nextAlarmDate")
                    }
                }.listRowBackground(sky.surface.color)
                Section {
                    WeekdayPicker(days: $form.days)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } header: {
                    Text("Repeat")
                } footer: {
                    Text(form.repeatText).accessibilityIdentifier("repeatSummary")
                }.listRowBackground(sky.surface.color)
                Section {
                    Toggle("Smart Wake", isOn: $form.options.smartEnabled.animation(.snappy)).accessibilityIdentifier("smartWakeToggle")
                    if form.options.smartEnabled {
                        Picker("Window", selection: $form.options.windowMinutes) {
                            ForEach(WakeOptions.windowChoices, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("wakeWindowPicker")
                    }
                } footer: {
                    Text(form.windowText).monospacedDigit().accessibilityIdentifier("windowRange")
                }.listRowBackground(sky.surface.color)
                Section("Sound") {
                    Picker("Snooze", selection: $form.options.snoozeMinutes) {
                        ForEach(WakeOptions.snoozeChoices, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Gentle sound", isOn: $form.options.progressiveSound)
                }.listRowBackground(sky.surface.color)
            }
            .font(.subheadline)
            .scrollContentBackground(.hidden)
            .background { DetailBackground() }
            .navigationTitle(model.plan == nil ? "New alarm" : "Edit alarm").navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.working)
            .sensoryFeedback(.selection, trigger: form.days)
            .alarmProblemAlert($problem)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .labelStyle(.iconOnly).tint(.primary).disabled(model.working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) {
                        Task {
                            problem = await model.setAlarm(form.rule)
                            if problem == nil {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            }
                        }
                    }.disabled(model.working || form.next(after: model.now) == nil).accessibilityIdentifier("armAlarm")
                }
            }
        }
        .tint(sky.action.color)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
