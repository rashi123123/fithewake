import SwiftUI
import CoreBluetooth

/// Getting heart rate from a Fitbit. Shown in onboarding and on the Fitbit tab;
/// the sharing path follows Google Health's menus.
enum FitbitSetup {
    static let wear = SetupStep(symbol: "applewatch", title: "Wear your Fitbit snugly",
                                detail: "Keep the sensor against your skin with a comfortable, secure fit.")
    static let share = SetupStep(symbol: "antenna.radiowaves.left.and.right", title: "Turn on heart-rate sharing",
                                 detail: "In Google Health: Connections → Fitbit Air → Share heart rate → Get started.")
}

/// Connects to one wearable found by a scan.
struct DeviceButton: View {
    let ble: FitbitCentral
    let device: CBPeripheral
    var body: some View {
        Button("Connect \(FitbitCentral.name(device))", systemImage: "applewatch") { ble.connect(device) }
    }
}
