import CoreBluetooth
import Foundation
import UserNotifications

struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

struct BLEEvent: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let date = Date()
}

final class BLEManager: NSObject, ObservableObject {
    @Published var bluetoothState = "Unknown"
    @Published var devices: [BLEDevice] = []
    @Published var events: [BLEEvent] = []
    @Published var connectedName: String?
    @Published var isScanning = false
    @Published var autoReconnect = true

    var apiEndpoint = ""
    var autoUpload = false

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private let savedPeripheralKey = "savedPeripheralIdentifier"
    private let centralRestoreIdentifier = "com.example.XIAOCompanion.central"
    private let xiaoBridgeServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: centralRestoreIdentifier
        ])
        requestNotificationPermission()
    }

    func startScanning() {
        guard central.state == .poweredOn else {
            addEvent(title: "Bluetooth is not ready", body: "Current state: \(bluetoothState)")
            return
        }

        devices.removeAll()
        isScanning = true
        addAlreadyConnectedPeripherals()
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        addEvent(title: "Scan started", body: "Looking for BLE peripherals.")
    }

    func stopScanning() {
        central.stopScan()
        isScanning = false
        addEvent(title: "Scan stopped", body: "No longer scanning.")
    }

    func connect(to device: BLEDevice) {
        stopScanning()
        savePeripheralIdentifier(device.id)
        connectedPeripheral = device.peripheral
        device.peripheral.delegate = self
        connectedName = "Connecting..."
        central.connect(device.peripheral)
    }

    func reconnectToSavedDevice() {
        guard central.state == .poweredOn else { return }
        guard let identifier = savedPeripheralIdentifier else {
            addEvent(title: "No saved device", body: "Connect to XIAO once, then reconnect will be automatic.")
            return
        }

        let peripherals = central.retrievePeripherals(withIdentifiers: [identifier])
        if let peripheral = peripherals.first {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            connectedName = "Reconnecting..."
            central.connect(peripheral)
            addEvent(title: "Reconnect started", body: identifier.uuidString)
        } else {
            startScanning()
            addEvent(title: "Saved device not cached", body: "Scanning for it now.")
        }
    }

    private func addAlreadyConnectedPeripherals() {
        let peripherals = central.retrieveConnectedPeripherals(withServices: [xiaoBridgeServiceUUID])
        peripherals.forEach { peripheral in
            let device = BLEDevice(id: peripheral.identifier,
                                   peripheral: peripheral,
                                   name: peripheral.name ?? "XIAO Bridge",
                                   rssi: 0)

            if !devices.contains(where: { $0.id == device.id }) {
                devices.append(device)
            }
        }

        if !peripherals.isEmpty {
            addEvent(title: "Found connected XIAO", body: "Tap it to attach the app.")
        }
    }

    func clearLog() {
        events.removeAll()
    }

    func sendTestEvent() {
        let payload: [String: Any] = [
            "source": "ios-test",
            "message": "Hello from XIAO Companion",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        upload(payload: payload)
    }

    private func addEvent(title: String, body: String) {
        events.insert(BLEEvent(title: title, body: body), at: 0)
        if events.count > 100 {
            events.removeLast()
        }
    }

    private func handleIncomingData(_ data: Data, characteristic: CBCharacteristic) {
        let text = String(data: data, encoding: .utf8)
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let body = text?.isEmpty == false ? text! : hex

        addEvent(title: "BLE packet", body: body)
        showLocalNotification(title: "XIAO sent data", body: body)

        guard autoUpload else { return }
        upload(payload: [
            "source": "xiao-ble",
            "characteristic": characteristic.uuid.uuidString,
            "text": text ?? "",
            "hex": hex,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
    }

    private func upload(payload: [String: Any]) {
        guard let url = URL(string: apiEndpoint), !apiEndpoint.isEmpty else {
            addEvent(title: "Upload skipped", body: "API endpoint is empty.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let error {
                    self?.addEvent(title: "Upload failed", body: error.localizedDescription)
                    return
                }

                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self?.addEvent(title: "Upload finished", body: "HTTP \(code)")
            }
        }.resume()
    }

    private var savedPeripheralIdentifier: UUID? {
        guard let value = UserDefaults.standard.string(forKey: savedPeripheralKey) else { return nil }
        return UUID(uuidString: value)
    }

    private func savePeripheralIdentifier(_ identifier: UUID) {
        UserDefaults.standard.set(identifier.uuidString, forKey: savedPeripheralKey)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func showLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(180))
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension BLEManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "On"
            if autoReconnect {
                reconnectToSavedDevice()
            }
        case .poweredOff:
            bluetoothState = "Off"
        case .unauthorized:
            bluetoothState = "Unauthorized"
        case .unsupported:
            bluetoothState = "Unsupported"
        case .resetting:
            bluetoothState = "Resetting"
        case .unknown:
            bluetoothState = "Unknown"
        @unknown default:
            bluetoothState = "Unknown"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unnamed Device"

        let device = BLEDevice(id: peripheral.identifier,
                               peripheral: peripheral,
                               name: name,
                               rssi: RSSI.intValue)

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }

        if autoReconnect, savedPeripheralIdentifier == peripheral.identifier {
            connect(to: device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedName = peripheral.name ?? "Connected"
        savePeripheralIdentifier(peripheral.identifier)
        addEvent(title: "Connected", body: peripheral.identifier.uuidString)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectedName = nil
        addEvent(title: "Connection failed", body: error?.localizedDescription ?? "Unknown error")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectedName = nil
        addEvent(title: "Disconnected", body: error?.localizedDescription ?? "No error")
        if autoReconnect {
            central.connect(peripheral)
            addEvent(title: "Reconnect queued", body: peripheral.identifier.uuidString)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let peripheral = peripherals.first else { return }

        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectedName = peripheral.name ?? "Restored"
        addEvent(title: "Bluetooth state restored", body: peripheral.identifier.uuidString)
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            addEvent(title: "Service discovery failed", body: error.localizedDescription)
            return
        }

        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            addEvent(title: "Characteristic discovery failed", body: error.localizedDescription)
            return
        }

        service.characteristics?.forEach { characteristic in
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
                addEvent(title: "Subscribed", body: characteristic.uuid.uuidString)
            }

            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            addEvent(title: "Read failed", body: error.localizedDescription)
            return
        }

        guard let data = characteristic.value else { return }
        handleIncomingData(data, characteristic: characteristic)
    }
}
