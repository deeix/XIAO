import Combine
import CoreBluetooth
import Foundation

enum AppSource: String, Codable, CaseIterable, Identifiable {
    case okx, binance, bybit, simple, gmail, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .okx: return "OKX"
        case .binance: return "Binance"
        case .bybit: return "Bybit"
        case .simple: return "Simple"
        case .gmail: return "Gmail"
        case .other: return "Другое"
        }
    }

    static func detect(source: String?, appID: String?, appName: String?) -> AppSource {
        if let source, let exact = AppSource(rawValue: source.lowercased()) { return exact }
        let value = "\(appID ?? "") \(appName ?? "")".lowercased()
        if value.contains("gmail") || value.contains("googlemail") || value.contains("com.google.gmail") { return .gmail }
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
    var sessionID: String?
    var sequence: UInt32?
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

struct ModuleStatus: Equatable {
    var firmwareVersion = "—"
    var state = "offline"
    var sessionID = "—"
    var uptimeMS: UInt64 = 0
    var queuePending: UInt32 = 0
    var queueCapacity: UInt32 = 0
    var forwarded: UInt32 = 0
    var acknowledged: UInt32 = 0
    var dropped: UInt32 = 0
    var reconnects: UInt32 = 0
    var ancsAttempts: UInt32 = 0
    var lastError = ""
    var lastErrorUptimeMS: UInt64 = 0
    var lastPacketAt: Date?
    var lastUpdated: Date?
    var rssi: Int?
}

struct BridgePacket: Decodable {
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
    let sessionID: String?
    let sequence: UInt32?
    let state: String?
    let firmwareVersion: String?
    let uptimeMS: UInt64?
    let ancsReady: Bool?
    let subscribed: Bool?
    let forwarded: UInt32?
    let acknowledged: UInt32?
    let dropped: UInt32?
    let queuePending: UInt32?
    let queueCapacity: UInt32?
    let reconnects: UInt32?
    let ancsAttempts: UInt32?
    let lastError: String?
    let lastErrorUptimeMS: UInt64?

    enum CodingKeys: String, CodingKey {
        case v, type, uid, event, source, app, category, title, message, detail, level, state
        case appID = "app_id"
        case sessionID = "session_id"
        case sequence = "seq"
        case firmwareVersion = "firmware_version"
        case uptimeMS = "uptime_ms"
        case ancsReady = "ancs_ready"
        case subscribed, forwarded, dropped, reconnects
        case acknowledged = "acked"
        case queuePending = "queue_pending"
        case queueCapacity = "queue_capacity"
        case ancsAttempts = "ancs_attempts"
        case lastError = "last_error"
        case lastErrorUptimeMS = "last_error_ms"
    }
}

struct BLEDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

enum JSONLineBufferError: Error {
    case overflow
}

struct JSONLineBuffer {
    private(set) var data = Data()
    let limit: Int

    init(limit: Int = 16_384) {
        self.limit = limit
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        data.append(chunk)
        guard data.count <= limit else {
            data.removeAll(keepingCapacity: true)
            throw JSONLineBufferError.overflow
        }
        var frames: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let frame = Data(data.prefix(upTo: newline))
            data.removeSubrange(...newline)
            if !frame.isEmpty { frames.append(frame) }
        }
        return frames
    }

    mutating func reset() {
        data.removeAll(keepingCapacity: true)
    }
}

final class AppStore: ObservableObject {
    @Published private(set) var notifications: [NotificationRecord] = []
    @Published private(set) var logs: [SystemLogEntry] = []

    private let limit = 1000
    private let persistenceQueue = DispatchQueue(label: "com.xiao.notify.persistence", qos: .utility)
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

    func process(packet: BridgePacket, mode: LifecycleMode, completion: @escaping (Bool) -> Void) {
        guard packet.type == "notification", let uid = packet.uid else {
            completion(false)
            return
        }

        let session = packet.sessionID ?? "legacy"
        if let sequence = packet.sequence,
           notifications.contains(where: { $0.sessionID == session && $0.sequence == sequence }) {
            completion(true)
            return
        }

        let event = packet.event ?? "Added"
        if mode == .addedOnly && event != "Added" {
            completion(true)
            return
        }

        let existingIndex = notifications.firstIndex {
            ($0.sessionID ?? "legacy") == session && $0.uid == uid
        }

        if event == "Removed", existingIndex == nil {
            addLog("Removed без исходного уведомления", detail: "Сессия \(session), UID \(uid)", level: "warning")
            completion(true)
            return
        }

        let source = AppSource.detect(source: packet.source, appID: packet.appID, appName: packet.app)
        if mode == .update, let index = existingIndex {
            updateRecord(at: index, packet: packet, event: event, source: source)
        } else {
            var base = existingIndex.map { notifications[$0] }
            let record = NotificationRecord(
                id: UUID(), uid: uid, sessionID: session, sequence: packet.sequence,
                event: event, source: source == .other ? (base?.source ?? .other) : source,
                appID: nonEmpty(packet.appID) ?? base?.appID ?? "",
                appName: nonEmpty(packet.app) ?? base?.appName ?? source.title,
                category: nonEmpty(packet.category) ?? base?.category ?? "Other",
                title: nonEmpty(packet.title) ?? base?.title ?? "",
                message: nonEmpty(packet.message) ?? base?.message ?? "",
                receivedAt: Date(), isRemoved: event == "Removed"
            )
            base = nil
            notifications.insert(record, at: 0)
        }

        trim(&notifications)
        persistNotifications(completion: completion)
    }

    func addLog(_ title: String, detail: String = "", level: String = "info") {
        logs.insert(SystemLogEntry(id: UUID(), date: Date(), level: level, title: title, detail: detail), at: 0)
        trim(&logs)
        persistLogs()
    }

    func clearNotifications() {
        notifications.removeAll()
        persistNotifications { _ in }
    }

    func clearLogs() {
        logs.removeAll()
        persistLogs()
    }

    private func updateRecord(at index: Int, packet: BridgePacket, event: String, source: AppSource) {
        notifications[index].event = event
        notifications[index].sequence = packet.sequence ?? notifications[index].sequence
        notifications[index].isRemoved = event == "Removed"
        if let value = nonEmpty(packet.app) { notifications[index].appName = value }
        if let value = nonEmpty(packet.appID) { notifications[index].appID = value }
        if let value = nonEmpty(packet.category) { notifications[index].category = value }
        if let value = nonEmpty(packet.title) { notifications[index].title = value }
        if let value = nonEmpty(packet.message) { notifications[index].message = value }
        if source != .other { notifications[index].source = source }
        notifications[index].receivedAt = Date()
        let updated = notifications.remove(at: index)
        notifications.insert(updated, at: 0)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func trim<T>(_ values: inout [T]) {
        if values.count > limit { values.removeLast(values.count - limit) }
    }

    private func persistNotifications(completion: @escaping (Bool) -> Void) {
        let snapshot = notifications
        let url = notificationsURL
        persistenceQueue.async {
            let success: Bool
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                success = true
            } catch {
                success = false
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    private func persistLogs() {
        let snapshot = logs
        let url = logsURL
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
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
    @Published var connectedIdentifier: UUID?
    @Published var isScanning = false
    @Published var bridgeReady = false
    @Published var ancsReady = false
    @Published var moduleStatus = ModuleStatus()

    let store = AppStore()
    var autoReconnect = true
    var lifecycleMode: LifecycleMode = .update

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var receiveBuffer = JSONLineBuffer()
    private var reconnectWorkItem: DispatchWorkItem?
    private var storeCancellable: AnyCancellable?
    private let savedPeripheralKey = "savedPeripheralIdentifier"
    private let restoreIdentifier = "com.xiao.notify.central"
    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    override init() {
        super.init()
        storeCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
        if attachAlreadyConnectedPeripheral() { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
        connectedIdentifier = device.id
        store.addLog("Подключение", detail: device.name)
        central.connect(device.peripheral)
    }

    func reconnectSaved() {
        guard central.state == .poweredOn else { return }
        guard let id = savedIdentifier else {
            startScanning()
            return
        }
        guard let saved = central.retrievePeripherals(withIdentifiers: [id]).first else {
            startScanning()
            return
        }
        peripheral = saved
        saved.delegate = self
        connectedIdentifier = saved.identifier
        if saved.state == .connected {
            connectedName = saved.name ?? "XIAO Notify"
            restoreOrDiscoverBridge(on: saved)
        } else if saved.state != .connecting {
            connectedName = "Подключение…"
            central.connect(saved)
        }
        store.addLog("Автоподключение", detail: saved.name ?? id.uuidString)
    }

    func disconnect() {
        autoReconnect = false
        reconnectWorkItem?.cancel()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func refreshModuleStatus() {
        requestSnapshot()
        if peripheral?.state == .connected { peripheral?.readRSSI() }
    }

    private var savedIdentifier: UUID? {
        guard let text = UserDefaults.standard.string(forKey: savedPeripheralKey) else { return nil }
        return UUID(uuidString: text)
    }

    @discardableResult
    private func attachAlreadyConnectedPeripheral() -> Bool {
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            .filter { $0.identifier == savedIdentifier || ($0.name ?? "").caseInsensitiveCompare("XIAO Notify") == .orderedSame }
        guard let item = connected.first else { return false }
        let device = BLEDevice(id: item.identifier, peripheral: item, name: item.name ?? "XIAO Notify", rssi: 0)
        devices = [device]
        store.addLog("Найден подключённый XIAO", detail: "Восстанавливаем канал приложения")
        connect(to: device)
        return true
    }

    private func requestSnapshot() {
        writeCommand(["v": 2, "command": "status"])
    }

    private func sendAcknowledgement(sessionID: String, sequence: UInt32) {
        writeCommand(["v": 2, "command": "ack", "session_id": sessionID, "seq": sequence])
    }

    private func writeCommand(_ object: [String: Any]) {
        guard let peripheral, peripheral.state == .connected, let rxCharacteristic,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let type: CBCharacteristicWriteType = rxCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: type) else {
            store.addLog("Команда BLE слишком длинная", detail: "\(data.count) байт", level: "error")
            return
        }
        peripheral.writeValue(data, for: rxCharacteristic, type: type)
    }

    private func ingest(_ data: Data) {
        let frames: [Data]
        do {
            frames = try receiveBuffer.append(data)
        } catch {
            store.addLog("Ошибка протокола", detail: "Входной буфер переполнен", level: "error")
            return
        }
        for frame in frames {
            do {
                let packet = try JSONDecoder().decode(BridgePacket.self, from: frame)
                moduleStatus.lastPacketAt = Date()
                handle(packet)
            } catch {
                store.addLog("Повреждённый пакет", detail: error.localizedDescription, level: "error")
            }
        }
    }

    private func handle(_ packet: BridgePacket) {
        if let version = packet.v, version > 2 {
            store.addLog("Новая версия протокола", detail: "Версия \(version)", level: "warning")
        }
        switch packet.type {
        case "notification":
            store.process(packet: packet, mode: lifecycleMode) { [weak self] persisted in
                guard let self else { return }
                if persisted, let session = packet.sessionID, let sequence = packet.sequence {
                    self.sendAcknowledgement(sessionID: session, sequence: sequence)
                } else if !persisted {
                    self.store.addLog("Уведомление не сохранено", detail: "ACK не отправлен", level: "error")
                }
            }
        case "status":
            updateStatus(from: packet)
            if packet.event != "snapshot" {
                store.addLog(statusTitle(packet.event), detail: statusDetail(packet))
            }
        case "log":
            if packet.level == "error" {
                moduleStatus.lastError = packet.detail ?? packet.event ?? "Ошибка модуля"
                moduleStatus.lastErrorUptimeMS = packet.uptimeMS ?? moduleStatus.lastErrorUptimeMS
            }
            store.addLog(statusTitle(packet.event), detail: packet.detail ?? "", level: packet.level ?? "info")
        default:
            store.addLog("Неизвестный тип пакета", detail: packet.type, level: "warning")
        }
    }

    private func updateStatus(from packet: BridgePacket) {
        ancsReady = packet.ancsReady ?? ancsReady
        bridgeReady = packet.subscribed ?? bridgeReady
        moduleStatus.firmwareVersion = packet.firmwareVersion ?? moduleStatus.firmwareVersion
        moduleStatus.state = packet.state ?? moduleStatus.state
        moduleStatus.sessionID = packet.sessionID ?? moduleStatus.sessionID
        moduleStatus.uptimeMS = packet.uptimeMS ?? moduleStatus.uptimeMS
        moduleStatus.queuePending = packet.queuePending ?? moduleStatus.queuePending
        moduleStatus.queueCapacity = packet.queueCapacity ?? moduleStatus.queueCapacity
        moduleStatus.forwarded = packet.forwarded ?? moduleStatus.forwarded
        moduleStatus.acknowledged = packet.acknowledged ?? moduleStatus.acknowledged
        moduleStatus.dropped = packet.dropped ?? moduleStatus.dropped
        moduleStatus.reconnects = packet.reconnects ?? moduleStatus.reconnects
        moduleStatus.ancsAttempts = packet.ancsAttempts ?? moduleStatus.ancsAttempts
        moduleStatus.lastError = packet.lastError ?? moduleStatus.lastError
        moduleStatus.lastErrorUptimeMS = packet.lastErrorUptimeMS ?? moduleStatus.lastErrorUptimeMS
        moduleStatus.lastUpdated = Date()
    }

    private func statusDetail(_ packet: BridgePacket) -> String {
        var detail = packet.detail ?? ""
        if let sent = packet.forwarded, let dropped = packet.dropped {
            detail += " · передано \(sent), потеряно \(dropped)"
        }
        return detail
    }

    private func statusTitle(_ event: String?) -> String {
        switch event {
        case "ancs_ready": return "ANCS готов"
        case "bridge_ready": return "Канал уведомлений готов"
        case "snapshot": return "Состояние модуля"
        case "ancs_enable_failed": return "Ошибка ANCS"
        case "ancs_discovery_exhausted": return "ANCS не найден"
        case "unknown_command": return "Неизвестная команда"
        default: return event ?? "Событие модуля"
        }
    }

    private func resetConnectionState(clearPeripheral: Bool) {
        connectedName = nil
        connectedIdentifier = nil
        bridgeReady = false
        ancsReady = false
        rxCharacteristic = nil
        txCharacteristic = nil
        receiveBuffer.reset()
        moduleStatus = ModuleStatus()
        if clearPeripheral { peripheral = nil }
    }

    private func restoreOrDiscoverBridge(on peripheral: CBPeripheral) {
        peripheral.delegate = self
        if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
            if let characteristics = service.characteristics {
                configure(characteristics, on: peripheral)
            } else {
                peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
            }
        } else {
            peripheral.discoverServices([serviceUUID])
        }
    }

    private func configure(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) {
        rxCharacteristic = characteristics.first(where: { $0.uuid == rxUUID })
        txCharacteristic = characteristics.first(where: { $0.uuid == txUUID })
        guard rxCharacteristic != nil, let txCharacteristic else {
            bridgeReady = false
            store.addLog("Неполный BLE-сервис", detail: "RX или TX не найдена", level: "error")
            return
        }
        if txCharacteristic.isNotifying {
            bridgeReady = true
            refreshModuleStatus()
        } else {
            peripheral.setNotifyValue(true, for: txCharacteristic)
        }
    }

    private func scheduleReconnect(_ item: CBPeripheral) {
        guard autoReconnect else { return }
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, self.central.state == .poweredOn else { return }
            self.store.addLog("Повторное подключение")
            if item.state == .disconnected { self.central.connect(item) }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "Включён"
            store.addLog("Bluetooth включён")
            if autoReconnect { reconnectSaved() }
        case .poweredOff:
            bluetoothState = "Выключен"
            central.stopScan()
            isScanning = false
            reconnectWorkItem?.cancel()
            resetConnectionState(clearPeripheral: false)
            store.addLog("Bluetooth выключен", level: "warning")
        case .unauthorized:
            bluetoothState = "Нет доступа"
            resetConnectionState(clearPeripheral: false)
            store.addLog("Нет доступа к Bluetooth", level: "error")
        case .unsupported:
            bluetoothState = "Не поддерживается"
            resetConnectionState(clearPeripheral: true)
            store.addLog("Bluetooth LE не поддерживается", level: "error")
        case .resetting:
            bluetoothState = "Перезапуск"
            resetConnectionState(clearPeripheral: false)
            store.addLog("Bluetooth перезапускается", level: "warning")
        case .unknown:
            bluetoothState = "Инициализация"
        @unknown default:
            bluetoothState = "Неизвестно"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""
        let isSaved = peripheral.identifier == savedIdentifier
        guard isSaved || name.caseInsensitiveCompare("XIAO Notify") == .orderedSame else { return }
        let device = BLEDevice(id: peripheral.identifier, peripheral: peripheral,
                               name: name.isEmpty ? "XIAO Notify" : name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device) }
        if autoReconnect && isSaved { connect(to: device) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectWorkItem?.cancel()
        self.peripheral = peripheral
        connectedName = peripheral.name ?? "XIAO Notify"
        connectedIdentifier = peripheral.identifier
        bridgeReady = false
        ancsReady = false
        receiveBuffer.reset()
        moduleStatus.state = "connected"
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedPeripheralKey)
        store.addLog("Устройство подключено", detail: peripheral.identifier.uuidString)
        restoreOrDiscoverBridge(on: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetConnectionState(clearPeripheral: false)
        store.addLog("Не удалось подключиться", detail: error?.localizedDescription ?? "Без описания", level: "error")
        scheduleReconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetConnectionState(clearPeripheral: false)
        store.addLog("Связь потеряна", detail: error?.localizedDescription ?? "Устройство отключено", level: "warning")
        scheduleReconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: {
            $0.identifier == savedIdentifier
        }) ?? (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        peripheral = restored
        restored.delegate = self
        connectedIdentifier = restored.identifier
        store.addLog("Состояние Bluetooth восстановлено")
        if restored.state == .connected {
            connectedName = restored.name ?? "XIAO Notify"
            restoreOrDiscoverBridge(on: restored)
        } else if restored.state == .disconnected, autoReconnect {
            central.connect(restored)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            store.addLog("Ошибка поиска сервиса", detail: error.localizedDescription, level: "error")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            store.addLog("Сервис XIAO Notify не найден", level: "error")
            bridgeReady = false
            return
        }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            store.addLog("Ошибка канала BLE", detail: error.localizedDescription, level: "error")
            return
        }
        configure(service.characteristics ?? [], on: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            bridgeReady = false
            store.addLog("Не удалось подписаться", detail: error.localizedDescription, level: "error")
            return
        }
        guard characteristic.uuid == txUUID, characteristic.isNotifying, rxCharacteristic != nil else { return }
        bridgeReady = true
        store.addLog("Подписка BLE активна")
        refreshModuleStatus()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            store.addLog("Ошибка чтения BLE", detail: error.localizedDescription, level: "error")
            return
        }
        guard characteristic.uuid == txUUID, let data = characteristic.value else { return }
        ingest(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error {
            store.addLog("Не удалось прочитать RSSI", detail: error.localizedDescription, level: "warning")
            return
        }
        moduleStatus.rssi = RSSI.intValue
    }
}
