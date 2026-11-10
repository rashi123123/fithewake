import SwiftUI

struct SmartWakeHelp: View {
    @Environment(\.wakeAtmosphere) private var sky
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("One window. One final alarm.") {
                    Text("Choose the latest time you want to wake up. Smart Wake may ring earlier within your chosen window, using heart-rate changes from your Fitbit.")
                }.listRowBackground(sky.surface.color)
                Section("Your alarm comes first") {
                    Text("If no earlier wake-up is triggered, the alarm rings at your set time. It stays scheduled on the iPhone even if your Fitbit disconnects.")
                }.listRowBackground(sky.surface.color)
                Section("Heart rate is a hint") {
                    Text("Smart Wake is experimental. Heart rate alone cannot reliably identify a sleep stage or guarantee an easier wake-up.")
                }.listRowBackground(sky.surface.color)
            }
            .scrollContentBackground(.hidden)
            .background { DetailBackground() }
            .navigationTitle("Smart Wake").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
