import CoreBluetooth
import FitheWakeCore
import Observation
import OSLog

/// The Bluetooth heart-rate connection. It remembers across launches whether
/// monitoring runs, whether the person paused it, and which wearable to use.
/// The app model decides when an alarm needs it.
@MainActor @Observable final class FitbitCentral: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onSample: ((HeartSample) -> Void)?
    var onInterruption: (() -> Void)?
    /// Diagnostics: an event name and its detail.
    var onEvent: ((String, String) -> Void)?
    private(set) var status = "Connect your wearable to enable Smart Wake"
    private(set) var devices: [CBPeripheral] = []
    private(set) var latest: HeartSample?
    private(set) var requested = false
    /// The chosen wearable, or the one the app is made for until one is chosen.
    var wearableName: String { peripheral.map(Self.name) ?? "Fitbit Air" }
    var bluetoothDenied: Bool { [.denied, .restricted].contains(CBCentralManager.authorization) }

    private enum Key {
        static let running = "monitoringRequested"
        static let paused = "monitoringPaused"
        static let device = "deviceID"
    }
    private let defaults = UserDefaults.standard
    private var paused: Bool { defaults.bool(forKey: Key.paused) }
    private var savedDevice: UUID? { defaults.string(forKey: Key.device).flatMap(UUID.init(uuidString:)) }
    private var bluetoothAllowed: Bool { CBCentralManager.authorization == .allowedAlways }

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var watchdog: Timer?
    private var recovery = HeartRateRecovery(now: Date())
    private var recoveryCount = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? AppInfo.name, category: "Bluetooth")
    private let service = CBUUID(string: "180D")
    private let measurement = CBUUID(string: "2A37")
    private var drill = SilentStreamDrill()

    override init() {
        super.init()
        // Creating the manager shows the Bluetooth permission prompt. Before the person has
        // answered it, wait until they tap Connect so the prompt arrives with its reason.
        // Once answered, create it at launch, which state restoration needs.
        if CBCentralManager.authorization != .notDetermined { makeManager() }
    }
    private func makeManager() {
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "heartRate"])
    }

    // MARK: Intents

    /// Explicit user action. The first time, iOS asks for Bluetooth.
    func start() {
        defaults.set(false, forKey: Key.paused)
        if manager == nil { makeManager() }
        guard !requested else { return }
        onEvent?("monitoring", "Started")
        begin()
        scan()
    }
    /// Explicit user action: stop, and stay stopped across launches until `start()`.
    func pause() {
        stop()
        defaults.set(true, forKey: Key.paused)
        onEvent?("monitoring", "Paused by user")
    }
    /// Nothing needs heart rate any more. A later alarm may start it again.
    func stop() {
        defaults.set(false, forKey: Key.running)
        guard requested else { return }
        requested = false; watchdog?.invalidate(); watchdog = nil
        manager?.stopScan(); devices = []
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        interrupt("Monitoring paused")
    }
    /// An alarm wants heart rate. Starts only if Bluetooth was allowed earlier, so
    /// saving an alarm never shows the permission prompt.
    func startIfAllowed() {
        if bluetoothAllowed { start() }
    }
    /// At launch: continue what ran before, unless the person paused it.
    func resume(alarmNeedsHeartRate: Bool) {
        guard !paused, defaults.bool(forKey: Key.running) || (alarmNeedsHeartRate && bluetoothAllowed) else { return }
        start()
    }
    func chooseAnotherDevice() {
        stop(); peripheral = nil
        defaults.removeObject(forKey: Key.device)
        start()
    }
    func reconnect() {
        guard requested else { return }
        recovery = HeartRateRecovery(now: Date())
        recoverConnection()
    }
    /// Use this wearable from now on: the person picked it, or it was saved.
    func connect(_ device: CBPeripheral) {
        guard requested else { return }
        if peripheral?.identifier != device.identifier {
            if let previous = peripheral { manager?.cancelPeripheralConnection(previous) }
            interrupt("Connecting to \(Self.name(device))")
            recovery = HeartRateRecovery(now: Date())
        }
        select(device)
        defaults.set(device.identifier.uuidString, forKey: Key.device)
        manager?.stopScan(); devices = []
        resumeConnection(device)
    }
    static func name(_ device: CBPeripheral) -> String { device.name ?? "Heart-rate device" }

    // MARK: Connection

    /// iOS runs the timer only while it gives the app time; there is no
    /// background polling entitlement or timing promise.
    private func checkSignal() {
        drill.write("watchdog", self)
        guard requested, manager?.state == .poweredOn, peripheral != nil else { return }
        if let latest, !latest.isFresh(at: Date()) { interrupt("No fresh heart rate · checking connection") }
        if recovery.shouldReconnect(at: Date()) { recoverConnection() }
    }
    private func begin() {
        requested = true
        defaults.set(true, forKey: Key.running)
        recovery = HeartRateRecovery(now: Date())
        startWatchdog()
    }
    private func select(_ device: CBPeripheral) {
        peripheral = device; device.delegate = self
    }
    private func interrupt(_ message: String) {
        latest = nil; status = message; onInterruption?()
    }
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSignal() }
        }
    }
    private static func message(for state: CBManagerState) -> String {
        switch state {
        case .unauthorized: "Bluetooth permission denied · enable it in Settings"
        case .unknown, .resetting: "Waiting for Bluetooth"
        default: "Turn on Bluetooth to connect your wearable"
        }
    }
    private func scan() {
        guard requested else { return }
        guard let manager, manager.state == .poweredOn else { status = Self.message(for: manager?.state ?? .unknown); return }
        if let savedDevice, let saved = manager.retrievePeripherals(withIdentifiers: [savedDevice]).first {
            connect(saved)
        } else {
            devices = []; status = "Searching · enable Share heart rate on your Fitbit"
            manager.scanForPeripherals(withServices: [service])
        }
    }
    private func resumeConnection(_ device: CBPeripheral) {
        guard requested, let manager, manager.state == .poweredOn else { return }
        switch device.state {
        case .connected:
            status = "Connected · waiting for fresh heart rate"
            device.discoverServices([service])
        case .disconnected:
            status = "Connecting to \(Self.name(device))"
            manager.connect(device)
        case .connecting: status = "Connecting to \(Self.name(device))"
        case .disconnecting: status = "Reconnecting · waiting for Bluetooth"
        @unknown default: break
        }
    }
    private func recoverConnection() {
        guard requested, let manager, manager.state == .poweredOn else { return }
        recoveryCount += 1
        interrupt("No fresh heart rate · reconnecting automatically")
        drill.write("reconnecting", self)
        logger.notice("Restarting silent heart-rate connection; attempt \(self.recoveryCount)")
        guard let peripheral else { scan(); return }
        switch peripheral.state {
        case .connected, .connecting:
            // A successful BLE connection may have a silent notification stream.
            // Recreate the connection/subscription rather than trusting isNotifying.
            manager.cancelPeripheralConnection(peripheral)
        case .disconnected: manager.connect(peripheral)
        case .disconnecting: break // didDisconnect will reconnect if still requested.
        @unknown default: break
        }
    }
    private func isSelected(_ device: CBPeripheral) -> Bool { peripheral?.identifier == device.identifier }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan() } else { interrupt(Self.message(for: central.state)) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard requested, self.peripheral == nil else { return }
        if !devices.contains(where: { $0.identifier == peripheral.identifier }) { devices.append(peripheral) }
        status = "Select your wearable below"
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isSelected(peripheral), requested else { central.cancelPeripheralConnection(peripheral); return }
        logger.info("Heart-rate transport connected; discovering service")
        peripheral.delegate = self
        status = "Connected · waiting for fresh heart rate"
        peripheral.discoverServices([service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isSelected(peripheral), requested else { return }
        interrupt("Connection failed · retrying automatically")
        logger.error("Heart-rate connection failed")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isSelected(peripheral) else { return }
        guard requested else { return }
        interrupt("Reconnecting to \(Self.name(peripheral))")
        logger.info("Heart-rate transport disconnected; reconnecting")
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard !paused, defaults.bool(forKey: Key.running), let savedDevice,
              let saved = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: { $0.identifier == savedDevice }) else { return }
        select(saved)
        begin()
        status = "Restoring connection · waiting for fresh heart rate"
        resumeConnection(saved)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isSelected(peripheral), requested else { return }
        guard error == nil, let heart = peripheral.services?.first(where: { $0.uuid == service }) else {
            status = "Heart Rate Service unavailable · retrying automatically"; return
        }
        peripheral.discoverCharacteristics([measurement], for: heart)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isSelected(peripheral), requested else { return }
        guard error == nil, let c = service.characteristics?.first(where: { $0.uuid == measurement }), c.properties.contains(.notify) else {
            status = "Heart-rate notifications unavailable · retrying automatically"; return
        }
        peripheral.setNotifyValue(true, for: c)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isSelected(peripheral), requested, characteristic.uuid == measurement else { return }
        if error != nil || !characteristic.isNotifying {
            interrupt("Heart-rate subscription failed · retrying automatically")
            logger.error("Heart-rate notification subscription failed")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isSelected(peripheral), requested, characteristic.uuid == measurement, !drill.silencing else { return }
        guard error == nil, let data = characteristic.value else {
            interrupt("Cannot read heart rate · checking connection"); return
        }
        recovery.receivedPacket(at: Date())
        guard let sample = try? HeartRateParser.parse(Array(data), at: Date()), sample.isUsable else {
            drill.invalidPackets += 1; drill.write("invalid-packet", self)
            interrupt("No usable heart rate · check wearable contact"); return
        }
        latest = sample; status = "Receiving live heart rate"; onSample?(sample)
        drill.received(self)
        if drill.shouldSilence() {
            logger.notice("QA: disabling heart-rate notifications once")
            peripheral.setNotifyValue(false, for: characteristic)
            drill.write("silence-injected", self)
        }
    }

    /// `LaunchFlag.silentStreamOnce`: turns notifications off once after the first
    /// good reading, so a UI test can watch the real recovery path bring them back.
    /// Progress goes to Documents/qa-heart-rate.json.
    @MainActor private struct SilentStreamDrill {
        let enabled = LaunchFlag.silentStreamOnce.isSet
        var injected = false
        var silenceUntil: Date?
        var receivedAfterRecovery = false
        var validPackets = 0
        var invalidPackets = 0
        /// Buffered callbacks during the outage are ignored, including the ones a
        /// restored connection sends while re-enabling its subscription.
        var silencing: Bool { silenceUntil.map { Date() < $0 } ?? false }

        mutating func received(_ central: FitbitCentral) {
            guard enabled else { return }
            validPackets += 1
            if injected && central.recoveryCount > 0 { receivedAfterRecovery = true; write("receiving-after-recovery", central) }
        }
        mutating func shouldSilence() -> Bool {
            guard enabled, !injected else { return false }
            injected = true; silenceUntil = Date().addingTimeInterval(25)
            return true
        }
        func write(_ phase: String, _ central: FitbitCentral) {
            guard enabled, let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let record: [String: Any] = ["injectedSilence": injected, "recoveries": central.recoveryCount, "phase": phase,
                "receivedAfterRecovery": receivedAfterRecovery, "validPackets": validPackets, "invalidPackets": invalidPackets,
                "packetAge": central.recovery.packetAge(at: Date()), "requested": central.requested,
                "peripheralState": central.peripheral?.state.rawValue ?? -1, "status": central.status]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys) {
                try? data.write(to: directory.appendingPathComponent("qa-heart-rate.json"), options: .atomic)
            }
        }
    }
}
