import SwiftUI
import Charts
import FitheWakeCore

struct FitbitView: View {
    @Environment(\.wakeAtmosphere) private var sky
    let model: AppModel
    @State private var showHelp = false
    /// nil until the person toggles it: setup follows the live signal, open while
    /// there is no reading, and only a deliberate toggle plays the selection haptic.
    @State private var setupChoice: Bool?
    private var showSetup: Binding<Bool> {
        Binding(get: { setupChoice ?? !model.receiving }, set: { setupChoice = $0 })
    }
    @ScaledMetric(relativeTo: .largeTitle) private var readingSize: CGFloat = 64
    private static let checkStep = SetupStep(symbol: "heart.text.clipboard", title: "Check for a recent reading",
                                             detail: "Look for Receiving heart rate. A Bluetooth connection alone isn’t enough.")
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(model.ble.wearableName).font(.title3.weight(.semibold))
                            Spacer()
                            ReceivingHeart(receiving: model.receiving)
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                        }
                        Text("Heart rate").font(.subheadline)
                            .foregroundStyle(sky.secondary.color)
                            .padding(.top, 24)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(model.bpm.map(String.init) ?? "—")
                                .font(.system(size: readingSize, weight: .semibold, design: .rounded))
                                .monospacedDigit().tracking(-readingSize * 0.025)
                            Text("bpm").font(.body.weight(.medium))
                                .foregroundStyle(sky.secondary.color)
                        }
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.top, 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(model.receiving ? "\(model.bpm ?? 0) bpm, live reading" : "No recent reading")
                        .accessibilityIdentifier("liveHeartRate")
                        if model.receiving, let first = model.recentBPM.first,
                           model.now.timeIntervalSince(first.date) >= 60 {
                            HeartTrace(points: model.recentBPM, now: model.now)
                                .padding(.top, 14)
                        }
                        Label(model.receiving ? "Receiving heart rate" : "No recent heart rate",
                              systemImage: model.receiving ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(model.receiving ? sky.action.color : Color.orange)
                            .padding(.top, 8)
                        Text(model.receiving ? "Keep heart-rate sharing on overnight." : "Check sharing in Google Health and keep your Fitbit close.")
                            .font(.footnote).foregroundStyle(sky.secondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 22, trailing: 4))
                }.listRowBackground(Color.clear)
                Section {
                    DisclosureGroup(isExpanded: showSetup) {
                        ForEach([FitbitSetup.wear, FitbitSetup.share, Self.checkStep], id: \.self) { step in
                            InfoRow(marker: .symbol(step.symbol), title: step.title, detail: step.detail).padding(.vertical, 6)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connection setup").font(.subheadline.weight(.semibold))
                            Text("Three steps before you sleep").font(.caption)
                                .foregroundStyle(sky.secondary.color)
                        }.padding(.vertical, 5)
                    }
                    .accessibilityIdentifier("fitbitSetup")
                }.listRowBackground(sky.surface.color)
                Section {
                    Text(model.ble.status).font(.footnote).foregroundStyle(sky.secondary.color)
                        .accessibilityIdentifier("connectionStatus")
                    ForEach(model.ble.devices, id: \.identifier) { device in
                        DeviceButton(ble: model.ble, device: device)
                    }
                    Button(model.ble.requested ? "Pause monitoring" : "Connect wearable", systemImage: model.ble.requested ? "pause" : "antenna.radiowaves.left.and.right") { model.ble.requested ? model.ble.pause() : model.ble.start() }
                        .accessibilityIdentifier("toggleMonitoring")
                    if model.ble.requested {
                        Button("Reconnect wearable", systemImage: "arrow.clockwise") { model.ble.reconnect() }
                    }
                    Button("Choose another wearable") { model.ble.chooseAnotherDevice() }
                    Link("Open iPhone permissions", destination: .appSettings)
                } header: { Text("Your connection") }
                footer: {
                    Text("Only fresh readings animate the heart. Monitoring can pause if iOS stops the app. Your final alarm is scheduled separately.")
                        .foregroundStyle(sky.secondary.color)
                }.listRowBackground(sky.surface.color)
            }
            .scrollContentBackground(.hidden)
            .background { DetailBackground() }
            .navigationTitle("Fitbit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connection help", systemImage: "questionmark") { showHelp = true }.tint(.primary)
                }
            }
            .sensoryFeedback(.selection, trigger: setupChoice)
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    List {
                        Section("If the readings stop") {
                            Text("Bring your Fitbit close to your iPhone.")
                            Text("Check that heart-rate sharing is still on in Google Health.")
                            Text("Check that your Fitbit is against your skin.")
                        }.listRowBackground(sky.surface.color)
                        Section { Text("Your final alarm stays scheduled even when heart-rate readings stop.") }
                            .listRowBackground(sky.surface.color)
                    }
                    .scrollContentBackground(.hidden)
                    .background { DetailBackground() }
                    .navigationTitle("Connection help").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

/// The last few minutes of live heart rate. Display only; it never feeds Smart Wake.
private struct HeartTrace: View {
    @Environment(\.wakeAtmosphere) private var sky
    let points: [AppModel.BPMPoint]
    let now: Date
    private var low: Double { points.map(\.bpm).min() ?? 50 }
    private var high: Double { points.map(\.bpm).max() ?? 70 }
    /// The chart spans the real data (up to 10 minutes), so a fresh stream
    /// fills the width instead of collapsing against the right edge.
    private var from: Date { max(points.first?.date ?? now, now.addingTimeInterval(-AppModel.traceSpan)) }
    private var spanLabel: String {
        let minutes = max(1, Int((now.timeIntervalSince(from) / 60).rounded()))
        return "Last \(minutes) min"
    }
    var body: some View {
        let floor = (low - 4).rounded(.down)
        let ceiling = max(high + 4, floor + 14).rounded(.up)
        VStack(alignment: .leading, spacing: 8) {
            Chart(points) { point in
                AreaMark(x: .value("Time", point.date),
                         yStart: .value("Floor", floor), yEnd: .value("BPM", point.bpm))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [sky.ring.color.opacity(0.22), sky.ring.color.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value("BPM", point.bpm))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(sky.ring.color)
            }
            .chartXScale(domain: from...now)
            .chartYScale(domain: floor...ceiling)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 96)
            HStack {
                Text(spanLabel)
                Spacer()
                Text("\(Int(low))–\(Int(high)) bpm")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(sky.secondary.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate, \(spanLabel.lowercased()), between \(Int(low)) and \(Int(high)) beats per minute")
        .accessibilityIdentifier("heartTrace")
    }
}
