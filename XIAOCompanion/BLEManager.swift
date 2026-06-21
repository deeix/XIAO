import CoreBluetooth
import Foundation

enum AppSource: String, Codable, CaseIterable, Identifiable {
    case okx, binance, bybit, simple, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .okx: return "OKX"
        case .binance: return "Binance"
        case .bybit: return "Bybit"
        case .simple: return "Simple"
        case .other: return "Другое"
        }
    }

    static func detect(source: String?, appID: String?, appName: String?) -> AppSource {
        if let source, let exact = AppSource(rawValue: source.lowercased()) { return exact }
        let value = "\(appID ?? "") \(appName ?? "")".lowercased()
        if value.contains("simple") || value.contains("app.simple.com") { return .simple }
        if value.contains("binance") { return .binance }
        if value.contains("bybit") { return .bybit }
        if value.contains("okx") || value.contains("okex") { return .okx }
        return .other
    }
}

enum LifecycleMode: String, CaseIterable, Identifiable {
    case update, separate, addedOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .update: return "Обновлять запись"
        case .separate: return "Хранить события отдельно"
        case .addedOnly: return "Только Added"
        }
    }
}

struct NotificationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let uid: UInt32
    var event: String
    var source: AppSource
    var appID: String
    var appName: String
    var category: String
    var title: String
    var message: String
    var receivedAt: Date
    var isRemoved: Bool
}

struct SystemLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let level: String
    let title: String
    let detail: String
}

fileprivate struct BridgePacket: Decodable {
    let v: Int?
    let type: String
    let uid: UInt32?
    let event: String?
    let source: String?
    let appID: String?
    let app: String?
    let category: String?
    let title: String?
    let message: String?
    let detail: String?
    let level: String?
    let ancsReady: Bool?
    let subscribed: Bool?
    let forwarded: UInt32?
    let dropped: UInt32?

    enum CodingKeys: String, CodingKey {
        case v, type, uid, event, source, app, category, title, message, detail, level
        case appID = "app_id"
        case ancsReady = "ancs_ready"
        case subscribed, forwarded, dropped
    }
}

struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

final class AppStore: ObservableObject {
    @Published private(set) var notifications: [NotificationRecord] = []
    @Published private(set) var logs: [SystemLogEntry] = []
    private let limit = 1000
    private let queue = DispatchQueue(label: "com.xiao.notify.persistence", qos: .utility)
    private let notificationsURL: URL
    private let logsURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XIAONotify", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        notificationsURL = base.appendingPathComponent("notifications.json")
        logsURL = base.appendingPathComponent("system-log.json")
        notifications = Self.read([NotificationRecord].self, from: notificationsURL) ?? []
        logs = Self.read([SystemLogEntry].self, from: logsURL) ?? []
    }

    fileprivate func process(packet: BridgePacket, mode: LifecycleMode) {
        guard packet.type == "notification", let uid = packet.uid else { return }
        let event = packet.event ?? "Added"
        if mode == .addedOnly && event != "Added" { return }

        let source = AppSource.detect(source: packet.source, appID: packet.appID, appName: packet.app)
        if mode == .update, let index = notifications.firstIndex(where: { $0.uid == uid }) {
            notifications[index].event = event
            notifications[index].isRemoved = event == "Removed"
            if let value = packet.app, !value.isEmpty { notifications[index].appName = value }
            if let value = packet.appID, !value.isEmpty { notifications[index].appID = value }
            if let value = packet.title, !value.isEmpty { notifications[index].title = value }
            if let value = packet.message, !value.isEmpty { notifications[index].message = value }
            notifications[index].source = source == .other ? notifications[index].source : source
            notifications[index].receivedAt = Date()
            let updated = notifications.remove(at: index)
            notifications.insert(updated, at: 0)
        } else {
            let record = NotificationRecord(
                id: UUID(), uid: uid, event: event, source: source,
                appID: packet.appID ?? "", appName: packet.app?.isEmpty == false ? packet.app! : source.title,
                category: packet.category ?? "Other", title: packet.title ?? "",
                message: packet.message ?? "", receivedAt: Date(), isRemoved: event == "Removed"
            )
            notifications.insert(record, at: 0)
        }
        trim(&notifications)
        persistNotifications()
    }

    func addLog(_ title: String, detail: String = "", level: String = "info") {
        logs.insert(SystemLogEntry(id: UUID(), date: Date(), level: level, title: title, detail: detail), at: 0)
        trim(&logs)
        persistLogs()
    }

    func clearNotifications() { notifications.removeAll(); persistNotifications() }
    func clearLogs() { logs.removeAll(); persistLogs() }

    private func trim<T>(_ values: inout [T]) {
        if values.count > limit { values.removeLast(values.count - limit) }
    }

    private func persistNotifications() { write(notifications, to: notificationsURL) }
    private func persistLogs() { write(logs, to: logsURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

final class BLEManager: NSObject, ObservableObject {
    @Published var bluetoothState = "Инициализация"
    @Published var devices: [BLEDevice] = []
    @Published var connectedName: String?
    @Published var isScanning = false
    @Published var bridgeReady = false
    @Published var ancsReady = false

    let store = AppStore()
    var autoReconnect = true
    var lifecycleMode: LifecycleMode = .update

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var receiveBuffer = Data()
    private var reconnectWorkItem: DispatchWorkItem?
    private let savedPeripheralKey = "savedPeripheralIdentifier"
    private let restoreIdentifier = "com.xiao.notify.central"
    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    func startScanning() {
        guard central.state == .poweredOn else {
            store.addLog("Поиск не запущен", detail: "Bluetooth недоступен", level: "warning")
            return
        }
        devices.removeAll()
        addConnectedPeripherals()
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        store.addLog("Поиск устройства начат")
    }

    func stopScanning() {
        central.stopScan()
        isScanning = false
    }

    func connect(to device: BLEDevice) {
        stopScanning()
        UserDefaults.standard.set(device.id.uuidString, forKey: savedPeripheralKey)
        peripheral = device.peripheral
        peripheral?.delegate = self
        connectedName = "Подключение…"
        store.addLog("Подключение", detail: device.name)
        central.connect(device.peripheral)
    }

    func reconnectSaved() {
        guard central.state == .poweredOn else { return }
        guard let text = UserDefaults.standard.string(forKey: savedPeripheralKey), let id = UUID(uuidString: text) else {
            startScanning()
            return
        }
        if let saved = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = saved
            saved.delegate = self
            connectedName = "Подключение…"
            central.connect(saved)
            store.addLog("Автоподключение", detail: saved.name ?? id.uuidString)
        } else {
            startScanning()
        }
    }

    func disconnect() {
        autoReconnect = false
        reconnectWorkItem?.cancel()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    private func addConnectedPeripherals() {
        for item in central.retrieveConnectedPeripherals(withServices: [serviceUUID]) {
            let device = BLEDevice(id: item.identifier, peripheral: item, name: item.name ?? "XIAO Notify Bridge", rssi: 0)
            if !devices.contains(where: { $0.id == device.id }) { devices.append(device) }
        }
    }

    private func requestSnapshot() {
        guard let peripheral, let rxCharacteristic else { return }
        let data = Data("{\"v\":1,\"command\":\"status\"}\n".utf8)
        let type: CBCharacteristicWriteType = rxCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: rxCharacteristic, type: type)
    }

    private func ingest(_ data: Data) {
        receiveBuffer.append(data)
        if receiveBuffer.count > 16_384 {
            receiveBuffer.removeAll()
            store.addLog("Ошибка протокола", detail: "Входной буфер переполнен", level: "error")
            return
        }

        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let frame = receiveBuffer.prefix(upTo: newline)
            receiveBuffer.removeSubrange(...newline)
            guard !frame.isEmpty else { continue }
            do {
                let packet = try JSONDecoder().decode(BridgePacket.self, from: Data(frame))
                handle(packet)
            } catch {
                store.addLog("Повреждённый пакет", detail: error.localizedDescription, level: "error")
            }
        }
    }

    private func handle(_ packet: BridgePacket) {
        if let version = packet.v, version > 1 {
            store.addLog("Новая версия протокола", detail: "Версия \(version)", level: "warning")
        }
        switch packet.type {
        case "notification": store.process(packet: packet, mode: lifecycleMode)
        case "status":
            ancsReady = packet.ancsReady ?? ancsReady
            bridgeReady = packet.subscribed ?? bridgeReady
            var detail = packet.detail ?? ""
            if let sent = packet.forwarded, let dropped = packet.dropped { detail += " · передано \(sent), потеряно \(dropped)" }
            store.addLog(statusTitle(packet.event), detail: detail)
        case "log": store.addLog(statusTitle(packet.event), detail: packet.detail ?? "", level: packet.level ?? "info")
        default: store.addLog("Неизвестный тип пакета", detail: packet.type, level: "warning")
        }
    }

    private func statusTitle(_ event: String?) -> String {
        switch event {
        case "ancs_ready": return "ANCS готов"
        case "bridge_ready": return "Канал уведомлений готов"
        case "snapshot": return "Состояние модуля"
        case "ancs_enable_failed": return "Ошибка ANCS"
        case "unknown_command": return "Неизвестная команда"
        default: return event ?? "Событие модуля"
        }
    }

    private func scheduleReconnect(_ item: CBPeripheral) {
        guard autoReconnect else { return }
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, self.central.state == .poweredOn else { return }
            self.store.addLog("Повторное подключение")
            self.central.connect(item)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothState = "Включён"; store.addLog("Bluetooth включён"); if autoReconnect { reconnectSaved() }
        case .poweredOff: bluetoothState = "Выключен"; store.addLog("Bluetooth выключен", level: "warning")
        case .unauthorized: bluetoothState = "Нет доступа"; store.addLog("Нет доступа к Bluetooth", level: "error")
        case .unsupported: bluetoothState = "Не поддерживается"; store.addLog("Bluetooth LE не поддерживается", level: "error")
        case .resetting: bluetoothState = "Перезапуск"; store.addLog("Bluetooth перезапускается", level: "warning")
        case .unknown: bluetoothState = "Инициализация"
        @unknown default: bluetoothState = "Неизвестно"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "XIAO Notify Bridge"
        let device = BLEDevice(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device } else { devices.append(device) }
        if autoReconnect, UserDefaults.standard.string(forKey: savedPeripheralKey) == peripheral.identifier.uuidString { connect(to: device) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        connectedName = peripheral.name ?? "XIAO Notify Bridge"
        bridgeReady = false
        ancsReady = false
        receiveBuffer.removeAll()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedPeripheralKey)
        store.addLog("Устройство подключено", detail: peripheral.identifier.uuidString)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectedName = nil
        store.addLog("Не удалось подключиться", detail: error?.localizedDescription ?? "Без описания", level: "error")
        scheduleReconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedName = nil; bridgeReady = false; ancsReady = false; rxCharacteristic = nil
        store.addLog("Связь потеряна", detail: error?.localizedDescription ?? "Устройство отключено", level: "warning")
        scheduleReconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored; restored.delegate = self; connectedName = restored.name ?? "XIAO Notify Bridge"
        store.addLog("Состояние Bluetooth восстановлено")
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { store.addLog("Ошибка поиска сервиса", detail: error.localizedDescription, level: "error"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            store.addLog("Сервис XIAO Notify не найден", level: "error"); return
        }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { store.addLog("Ошибка канала BLE", detail: error.localizedDescription, level: "error"); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == rxUUID { rxCharacteristic = characteristic }
            if characteristic.uuid == txUUID { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { store.addLog("Не удалось подписаться", detail: error.localizedDescription, level: "error"); return }
        guard characteristic.uuid == txUUID, characteristic.isNotifying else { return }
        bridgeReady = true
        store.addLog("Подписка BLE активна")
        requestSnapshot()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { store.addLog("Ошибка чтения BLE", detail: error.localizedDescription, level: "error"); return }
        guard characteristic.uuid == txUUID, let data = characteristic.value else { return }
        ingest(data)
    }
}
