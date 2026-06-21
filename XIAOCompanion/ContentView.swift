import Combine
import SwiftUI

private enum NotificationFilter: String, CaseIterable, Identifiable {
    case all, okx, binance, bybit, simple, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .okx: return "OKX"
        case .binance: return "Binance"
        case .bybit: return "Bybit"
        case .simple: return "Simple"
        case .other: return "Другое"
        }
    }
    var source: AppSource? { self == .all ? nil : AppSource(rawValue: rawValue) }
}

struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("lifecycleMode") private var lifecycleMode = LifecycleMode.update.rawValue

    var body: some View {
        TabView {
            NotificationsView()
                .tabItem { Label("Уведомления", systemImage: "bell.badge.fill") }
            SystemLogView()
                .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
            SettingsView(autoReconnect: $autoReconnect, lifecycleMode: $lifecycleMode)
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
        }
        .tint(.indigo)
        .onAppear { applySettings() }
        .onChange(of: autoReconnect) { _ in applySettings() }
        .onChange(of: lifecycleMode) { _ in applySettings() }
    }

    private func applySettings() {
        ble.autoReconnect = autoReconnect
        ble.lifecycleMode = LifecycleMode(rawValue: lifecycleMode) ?? .update
    }
}

private struct NotificationsView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var filter: NotificationFilter = .all

    private var records: [NotificationRecord] {
        guard let source = filter.source else { return ble.store.notifications }
        return ble.store.notifications.filter { $0.source == source }
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    EmptyState(icon: "bell.slash", title: "Нет уведомлений",
                               detail: ble.connectedName == nil ? "Подключите XIAO в разделе «Настройки»." : "Полученные уведомления появятся здесь.")
                } else {
                    List(records) { record in
                        NotificationRow(record: record)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 10) {
                    NavigationLink {
                        ModuleStatusView()
                    } label: {
                        ConnectionBanner()
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(NotificationFilter.allCases) { item in
                                Button(item.title) { filter = item }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .foregroundStyle(filter == item ? .white : .primary)
                                    .background(filter == item ? Color.indigo : Color(.secondarySystemBackground), in: Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("XIAO Notify")
        }
    }
}

private struct ConnectionBanner: View {
    @EnvironmentObject private var ble: BLEManager
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ble.bridgeReady && ble.ancsReady ? Color.green : (ble.connectedName == nil ? Color.red : Color.orange))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(ble.connectedName ?? "Модуль не подключён").font(.subheadline.weight(.semibold))
                Text(ble.bridgeReady && ble.ancsReady ? "ANCS и канал данных готовы" : (ble.connectedName == nil ? "Откройте настройки для подключения" : "Подготовка канала уведомлений…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
    }
}

private struct ModuleStatusView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var now = Date()
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var status: ModuleStatus { ble.moduleStatus }
    private var isStale: Bool {
        guard let updated = status.lastUpdated else { return true }
        return now.timeIntervalSince(updated) > 10
    }

    private var stateTitle: String {
        switch status.state {
        case "ready": return "Готов"
        case "pairing": return "Сопряжение"
        case "discovering_ancs": return "Поиск ANCS"
        case "connected": return "Подключён"
        case "advertising": return "Ожидает телефон"
        case "offline": return "Нет связи"
        default: return status.state
        }
    }

    private var stateColor: Color {
        if !status.lastError.isEmpty && status.state != "ready" { return .red }
        switch status.state {
        case "ready": return .green
        case "pairing", "discovering_ancs", "connected": return .orange
        case "advertising": return .blue
        default: return .red
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Circle().fill(stateColor).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stateTitle).font(.headline)
                        Text(isStale ? "Данные устарели" : "Статус актуален")
                            .font(.caption).foregroundStyle(isStale ? .orange : .secondary)
                    }
                }
            }

            Section("Соединение") {
                LabeledContent("Bluetooth", value: ble.bluetoothState)
                LabeledContent("Устройство", value: ble.connectedName ?? "Не подключено")
                LabeledContent("UUID", value: ble.connectedIdentifier?.uuidString ?? "—")
                LabeledContent("RSSI", value: status.rssi.map { "\($0) dBm" } ?? "—")
                LabeledContent("Последний пакет", value: status.lastPacketAt?.formatted(date: .omitted, time: .standard) ?? "—")
            }

            Section("Модуль") {
                LabeledContent("Прошивка", value: status.firmwareVersion)
                LabeledContent("Состояние", value: stateTitle)
                LabeledContent("Время работы", value: formatUptime(status.uptimeMS))
                LabeledContent("ANCS-сессия", value: status.sessionID)
            }

            Section("ANCS") {
                LabeledContent("Уведомления", value: ble.ancsReady ? "Готовы" : "Не готовы")
                LabeledContent("Приложение подписано", value: ble.bridgeReady ? "Да" : "Нет")
                LabeledContent("Попыток обнаружения", value: "\(status.ancsAttempts)")
            }

            Section("Передача") {
                LabeledContent("Передано", value: "\(status.forwarded)")
                LabeledContent("Подтверждено", value: "\(status.acknowledged)")
                LabeledContent("Ожидает ACK", value: "\(status.queuePending)")
                LabeledContent("Ёмкость очереди", value: "\(status.queueCapacity)")
                LabeledContent("Потеряно", value: "\(status.dropped)")
                if status.queueCapacity > 0 {
                    ProgressView(value: Double(status.queuePending), total: Double(status.queueCapacity))
                        .tint(status.queuePending == status.queueCapacity ? .red : .indigo)
                }
            }

            Section("Диагностика") {
                LabeledContent("Подключений", value: "\(status.reconnects)")
                LabeledContent("Последняя ошибка", value: status.lastError.isEmpty ? "Нет" : status.lastError)
                if status.lastErrorUptimeMS > 0 {
                    LabeledContent("Ошибка на времени", value: formatUptime(status.lastErrorUptimeMS))
                }
            }
        }
        .navigationTitle("Статус модуля")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                ble.refreshModuleStatus()
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
        }
        .onAppear {
            now = Date()
            ble.refreshModuleStatus()
        }
        .onReceive(timer) { date in
            now = date
            ble.refreshModuleStatus()
        }
    }

    private func formatUptime(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1000
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if days > 0 { return "\(days) д \(hours) ч \(minutes) мин" }
        if hours > 0 { return "\(hours) ч \(minutes) мин \(seconds) с" }
        return "\(minutes) мин \(seconds) с"
    }
}

private struct NotificationRow: View {
    let record: NotificationRecord
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SourceIcon(source: record.source, name: record.appName, appID: record.appID)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(record.appName.isEmpty ? record.source.title : record.appName)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(record.receivedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                }
                if !record.title.isEmpty { Text(record.title).font(.body.weight(.semibold)) }
                if !record.message.isEmpty { Text(record.message).font(.subheadline).foregroundStyle(.secondary) }
                if record.isRemoved {
                    Label("Удалено из Центра уведомлений", systemImage: "xmark.circle")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(record.isRemoved ? 0.65 : 1)
    }
}

private struct SourceIcon: View {
    let source: AppSource
    let name: String
    let appID: String

    var initials: String {
        let base = name.isEmpty ? appID : name
        let parts = base.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let value = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return String((value.isEmpty ? "?" : value).prefix(2)).uppercased()
    }

    var generatedColor: Color {
        let hash = (name + appID).unicodeScalars.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1.value) }
        return Color(hue: Double(abs(hash % 360)) / 360, saturation: 0.62, brightness: 0.78)
    }

    var body: some View {
        Group {
            if source == .other {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(generatedColor.gradient)
                    Text(initials).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            } else {
                Image(source.rawValue).resizable().scaledToFit()
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityLabel(source == .other ? initials : source.title)
    }
}

private struct SystemLogView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var confirmClear = false
    var body: some View {
        NavigationStack {
            Group {
                if ble.store.logs.isEmpty {
                    EmptyState(icon: "list.bullet.rectangle", title: "Журнал пуст", detail: "События модуля и Bluetooth появятся здесь.")
                } else {
                    List(ble.store.logs) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(entry.level))
                                .foregroundStyle(color(entry.level)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.subheadline.weight(.semibold))
                                if !entry.detail.isEmpty { Text(entry.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Журнал")
            .toolbar { Button("Очистить") { confirmClear = true }.disabled(ble.store.logs.isEmpty) }
            .confirmationDialog("Очистить журнал?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Очистить", role: .destructive) { ble.store.clearLogs() }
            }
        }
    }

    private func icon(_ level: String) -> String { level == "error" ? "exclamationmark.octagon.fill" : (level == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill") }
    private func color(_ level: String) -> Color { level == "error" ? .red : (level == "warning" ? .orange : .indigo) }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var ble: BLEManager
    @Binding var autoReconnect: Bool
    @Binding var lifecycleMode: String
    @State private var confirmNotifications = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Состояние") {
                    LabeledContent("Bluetooth", value: ble.bluetoothState)
                    LabeledContent("Устройство", value: ble.connectedName ?? "Не подключено")
                    LabeledContent("ANCS", value: ble.ancsReady ? "Готов" : "Не готов")
                    LabeledContent("Канал данных", value: ble.bridgeReady ? "Готов" : "Не готов")
                }

                Section("Подключение") {
                    Toggle("Автоматически подключаться", isOn: $autoReconnect)
                    Button(ble.isScanning ? "Остановить поиск" : "Найти XIAO Notify") {
                        ble.isScanning ? ble.stopScanning() : ble.startScanning()
                    }
                    if ble.connectedName == nil {
                        Button("Подключить сохранённое устройство") { ble.reconnectSaved() }
                    } else {
                        Button("Отключиться", role: .destructive) { autoReconnect = false; ble.disconnect() }
                    }
                    ForEach(ble.devices) { device in
                        Button { ble.connect(to: device) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.rssi != 0 { Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }

                Section("События ANCS") {
                    Picker("Обработка", selection: $lifecycleMode) {
                        ForEach(LifecycleMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }
                    Text("Режим определяет, как Modified и Removed влияют на историю.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Хранилище") {
                    LabeledContent("Уведомлений", value: "\(ble.store.notifications.count) / 1000")
                    LabeledContent("Событий журнала", value: "\(ble.store.logs.count) / 1000")
                    Button("Очистить уведомления", role: .destructive) { confirmNotifications = true }
                        .disabled(ble.store.notifications.isEmpty)
                }

                Section("О приложении") {
                    LabeledContent("XIAO Notify", value: "1.2.0")
                    Text("Уведомления передаются модулем XIAO nRF52840 через Apple Notification Center Service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .confirmationDialog("Удалить все уведомления?", isPresented: $confirmNotifications, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { ble.store.clearNotifications() }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView().environmentObject(BLEManager()) }
}
