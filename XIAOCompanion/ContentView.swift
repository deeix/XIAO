import Combine
import Foundation
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

    var source: AppSource? {
        self == .all ? nil : AppSource(rawValue: rawValue)
    }
}

private enum AppTheme {
    static let accent = Color(red: 0.18, green: 0.35, blue: 0.86)
    static let success = Color(red: 0.16, green: 0.61, blue: 0.36)
    static let warning = Color(red: 0.89, green: 0.55, blue: 0.18)
    static let danger = Color(red: 0.83, green: 0.27, blue: 0.27)
    static let surface = Color(.secondarySystemBackground)
    static let elevated = Color(.systemBackground)
    static let grouped = Color(.systemGroupedBackground)
}

struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("lifecycleMode") private var lifecycleMode = LifecycleMode.update.rawValue
    @AppStorage(OKXPriceStore.eurKey) private var eurPrice = OKXPriceStore.defaults["EUR"] ?? 0.938
    @AppStorage(OKXPriceStore.gbpKey) private var gbpPrice = OKXPriceStore.defaults["GBP"] ?? 0.782
    @AppStorage(OKXPriceStore.czkKey) private var czkPrice = OKXPriceStore.defaults["CZK"] ?? 22.48
    @AppStorage(OKXPriceStore.plnKey) private var plnPrice = OKXPriceStore.defaults["PLN"] ?? 3.85
    @AppStorage(OKXPriceStore.mdlKey) private var mdlPrice = OKXPriceStore.defaults["MDL"] ?? 18.39

    private var okxPrices: [String: Double] {
        [
            "EUR": eurPrice,
            "GBP": gbpPrice,
            "CZK": czkPrice,
            "PLN": plnPrice,
            "MDL": mdlPrice
        ]
    }

    var body: some View {
        TabView {
            NotificationsView()
                .tabItem { Label("Уведомления", systemImage: "bell.badge.fill") }
            OKXOrdersView(prices: okxPrices)
                .tabItem { Label("Ордера", systemImage: "tag.fill") }
            SystemLogView()
                .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
            SettingsView(
                autoReconnect: $autoReconnect,
                lifecycleMode: $lifecycleMode,
                eurPrice: $eurPrice,
                gbpPrice: $gbpPrice,
                czkPrice: $czkPrice,
                plnPrice: $plnPrice,
                mdlPrice: $mdlPrice
            )
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
        }
        .tint(AppTheme.accent)
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

    private var removedCount: Int {
        records.filter(\.isRemoved).count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.grouped.ignoresSafeArea()

                if records.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            header
                            EmptyState(
                                icon: "bell.slash",
                                title: "Пока нет уведомлений",
                                detail: ble.connectedName == nil
                                    ? "Подключите XIAO Notify в настройках, чтобы история начала наполняться."
                                    : "Полученные уведомления появятся здесь автоматически."
                            )
                            .padding(.top, 40)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            header
                            LazyVStack(spacing: 12) {
                                ForEach(records) { record in
                                    NotificationRow(record: record)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("XIAO Notify")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            NavigationLink {
                ModuleStatusView()
            } label: {
                ConnectionBanner()
            }
            .buttonStyle(.plain)

            FilterBar(selection: $filter)

            HStack(spacing: 10) {
                StatBadge(value: "\(records.count)", label: "в ленте", color: AppTheme.accent)
                StatBadge(value: "\(removedCount)", label: "удалено", color: AppTheme.warning)
                StatBadge(value: ble.connectedName == nil ? "Off" : "On", label: "модуль", color: ble.connectedName == nil ? AppTheme.danger : AppTheme.success)
            }
        }
    }
}

private struct OKXOrdersView: View {
    @EnvironmentObject private var ble: BLEManager
    let prices: [String: Double]
    @State private var period: OKXOrderPeriod = .day

    private var stats: OKXPeriodStats {
        OKXOrderAnalyzer.analyze(records: ble.store.notifications, period: period, prices: prices)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.grouped.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        Picker("Период", selection: $period) {
                            ForEach(OKXOrderPeriod.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        OKXStatsCard(stats: stats)

                        if stats.orders.isEmpty {
                            EmptyState(
                                icon: "tag.slash",
                                title: "Ордеров пока нет",
                                detail: "Когда придут уведомления OKX, Gmail и Simple, сделки появятся здесь автоматически."
                            )
                            .padding(.top, 24)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(stats.orders) { order in
                                    NavigationLink {
                                        OKXOrderDetailView(order: order)
                                    } label: {
                                        OKXOrderRow(order: order)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Ордера")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct OKXStatsCard: View {
    let stats: OKXPeriodStats

    private var warningText: String? {
        var parts: [String] = []
        if stats.unmatchedSimpleCount > 0 {
            parts.append("Simple без ордера: \(stats.unmatchedSimpleCount)")
        }
        if !stats.missingPriceCurrencies.isEmpty {
            parts.append("Нет цены: \(stats.missingPriceCurrencies.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Статистика")
                        .font(.headline)
                    Text(periodRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(title: stats.period.title, color: AppTheme.accent)
            }

            MetricsGrid(items: [
                MetricItem(title: "Сделок", value: "\(stats.completedCount)", tint: AppTheme.success),
                MetricItem(title: "В работе", value: "\(stats.activeCount)", tint: stats.activeCount > 0 ? AppTheme.warning : AppTheme.success),
                MetricItem(title: "Оборот", value: fiatTotalText, tint: AppTheme.accent),
                MetricItem(title: "Simple", value: formatUSDC(stats.simpleTotal), tint: AppTheme.accent),
                MetricItem(title: "Прибыль", value: formatProfit(stats.profitTotal), tint: stats.profitTotal >= 0 ? AppTheme.success : AppTheme.danger),
                MetricItem(title: "%", value: formatPercent(stats.profitPercent), tint: (stats.profitPercent ?? 0) >= 0 ? AppTheme.success : AppTheme.danger)
            ])

            if let warningText = warningText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.warning)
                    Text(warningText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(18)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private var periodRange: String {
        let start = stats.interval.start.formatted(date: .abbreviated, time: .omitted)
        let endDate = stats.interval.end.addingTimeInterval(-1)
        let end = endDate.formatted(date: .abbreviated, time: .omitted)
        return start == end ? start : "\(start) - \(end)"
    }

    private var fiatTotalText: String {
        let values = stats.fiatTotals.map { formatMoney($0.amount, currency: $0.currency) }
        return values.isEmpty ? "—" : values.joined(separator: "\n")
    }
}

private struct OKXOrderRow: View {
    let order: OKXOrderSummary

    private var statusColor: Color {
        switch order.status {
        case .completed: return AppTheme.success
        case .paid: return AppTheme.accent
        case .inProgress: return AppTheme.warning
        case .incomplete: return AppTheme.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ордер \(shortOrderID)")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(order.lastEventAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(title: order.status.rawValue, color: statusColor)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fiat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fiatText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Ожидалось")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatUSDT(order.expectedUSDT))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(formatUSDC(order.simpleUSDC))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(profitText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle((order.profitUSDC ?? 0) >= 0 ? AppTheme.success : AppTheme.danger)
            }
        }
        .padding(14)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(statusColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var shortOrderID: String {
        order.id.count > 8 ? String(order.id.suffix(8)) : order.id
    }

    private var fiatText: String {
        guard let amount = order.fiatAmount, let currency = order.fiatCurrency else { return "—" }
        return formatMoney(amount, currency: currency)
    }

    private var profitText: String {
        guard let profit = order.profitUSDC else { return "—" }
        return "\(formatProfit(profit)) / \(formatPercent(order.profitPercent))"
    }
}

private struct OKXOrderDetailView: View {
    let order: OKXOrderSummary

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SectionCard(title: "Итог", symbol: "chart.line.uptrend.xyaxis") {
                    InfoRow(label: "ID", value: order.id, multiline: true)
                    InfoRow(label: "Статус", value: order.status.rawValue)
                    InfoRow(label: "Fiat", value: fiatText)
                    InfoRow(label: "Цена 1 USDT", value: priceText)
                    InfoRow(label: "Ожидалось", value: formatUSDT(order.expectedUSDT))
                    InfoRow(label: "Simple", value: formatUSDC(order.simpleUSDC))
                    InfoRow(label: "Прибыль", value: profitText)
                }

                SectionCard(title: "История", symbol: "clock.arrow.circlepath") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(order.history) { event in
                            OKXTimelineRow(event: event)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(AppTheme.grouped)
        .navigationTitle("Ордер")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fiatText: String {
        guard let amount = order.fiatAmount, let currency = order.fiatCurrency else { return "—" }
        return formatMoney(amount, currency: currency)
    }

    private var priceText: String {
        guard let price = order.usdtPrice, let currency = order.fiatCurrency else { return "—" }
        return formatMoney(price, currency: currency)
    }

    private var profitText: String {
        guard let profit = order.profitUSDC else { return "—" }
        return "\(formatProfit(profit)) / \(formatPercent(order.profitPercent))"
    }
}

private struct OKXTimelineRow: View {
    let event: OKXOrderTimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.kind.rawValue)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(event.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !event.title.isEmpty {
                    Text(event.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                if !event.message.isEmpty {
                    Text(event.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var icon: String {
        switch event.kind {
        case .pending: return "hourglass"
        case .gmail: return "envelope.fill"
        case .paid: return "checkmark.seal.fill"
        case .simple: return "creditcard.fill"
        }
    }
}

private struct ConnectionBanner: View {
    @EnvironmentObject private var ble: BLEManager

    private var stateColor: Color {
        if ble.bridgeReady && ble.ancsReady { return AppTheme.success }
        if ble.connectedName == nil { return AppTheme.danger }
        return AppTheme.warning
    }

    private var stateTitle: String {
        if ble.bridgeReady && ble.ancsReady { return "Готов" }
        if ble.connectedName == nil { return "Нет связи" }
        return "Подготовка"
    }

    private var subtitle: String {
        if ble.bridgeReady && ble.ancsReady { return "ANCS и канал данных активны" }
        if ble.connectedName == nil { return "Откройте настройки и подключите модуль" }
        return "Соединение есть, канал уведомлений поднимается"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.16))
                    .frame(width: 42, height: 42)
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(ble.connectedName ?? "Модуль не подключен")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(title: stateTitle, color: stateColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(stateColor.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
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
        case "connected": return "Подключен"
        case "advertising": return "Ждет телефон"
        case "offline": return "Нет связи"
        default: return status.state
        }
    }

    private var stateColor: Color {
        if !status.lastError.isEmpty && status.state != "ready" { return AppTheme.danger }
        switch status.state {
        case "ready": return AppTheme.success
        case "pairing", "discovering_ancs", "connected": return AppTheme.warning
        case "advertising": return AppTheme.accent
        default: return AppTheme.danger
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatusHeroCard(
                    title: stateTitle,
                    subtitle: isStale ? "Данные устарели, модуль давно не отвечал" : "Статус регулярно обновляется каждые 3 секунды",
                    color: stateColor,
                    badge: isStale ? "Нет ответа" : "Актуально"
                )

                SectionCard(title: "Подключение", symbol: "antenna.radiowaves.left.and.right") {
                    InfoRow(label: "Bluetooth", value: ble.bluetoothState)
                    InfoRow(label: "Устройство", value: ble.connectedName ?? "Не подключено")
                    InfoRow(label: "UUID", value: ble.connectedIdentifier?.uuidString ?? "—")
                    InfoRow(label: "RSSI", value: status.rssi.map { "\($0) dBm" } ?? "—")
                    InfoRow(label: "Последний пакет", value: status.lastPacketAt?.formatted(date: .omitted, time: .standard) ?? "—", multiline: true)
                }

                SectionCard(title: "Модуль", symbol: "cpu") {
                    MetricsGrid(items: [
                        MetricItem(title: "Прошивка", value: status.firmwareVersion, tint: AppTheme.accent),
                        MetricItem(title: "Состояние", value: stateTitle, tint: stateColor),
                        MetricItem(title: "Время работы", value: formatUptime(status.uptimeMS), tint: AppTheme.accent),
                        MetricItem(title: "ANCS-сессия", value: status.sessionID, tint: AppTheme.warning)
                    ])
                }

                SectionCard(title: "ANCS и доставка", symbol: "tray.full") {
                    MetricsGrid(items: [
                        MetricItem(title: "ANCS", value: ble.ancsReady ? "Готов" : "Не готов", tint: ble.ancsReady ? AppTheme.success : AppTheme.warning),
                        MetricItem(title: "Подписка", value: ble.bridgeReady ? "Активна" : "Нет", tint: ble.bridgeReady ? AppTheme.success : AppTheme.warning),
                        MetricItem(title: "Попыток", value: "\(status.ancsAttempts)", tint: AppTheme.accent),
                        MetricItem(title: "ACK в очереди", value: "\(status.queuePending)", tint: status.queuePending > 0 ? AppTheme.warning : AppTheme.success)
                    ])

                    Divider().padding(.vertical, 4)

                    InfoRow(label: "Передано", value: "\(status.forwarded)")
                    InfoRow(label: "Подтверждено", value: "\(status.acknowledged)")
                    InfoRow(label: "Емкость очереди", value: "\(status.queueCapacity)")
                    InfoRow(label: "Потеряно", value: "\(status.dropped)")

                    if status.queueCapacity > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Заполнение очереди")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(status.queuePending) / \(status.queueCapacity)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(status.queuePending), total: Double(status.queueCapacity))
                                .tint(status.queuePending == status.queueCapacity ? AppTheme.danger : AppTheme.accent)
                        }
                        .padding(.top, 6)
                    }
                }

                SectionCard(title: "Диагностика", symbol: "wrench.and.screwdriver") {
                    InfoRow(label: "Переподключений", value: "\(status.reconnects)")
                    InfoRow(label: "Последняя ошибка", value: status.lastError.isEmpty ? "Нет" : status.lastError, multiline: true)
                    if status.lastErrorUptimeMS > 0 {
                        InfoRow(label: "Ошибка на времени", value: formatUptime(status.lastErrorUptimeMS))
                    }
                }
            }
            .padding(16)
        }
        .background(AppTheme.grouped)
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

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.appName.isEmpty ? record.source.title : record.appName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(record.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(record.receivedAt, style: .time)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }

                if !record.title.isEmpty {
                    Text(record.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }

                if !record.message.isEmpty {
                    Text(record.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 8) {
                    StatusPill(
                        title: record.event,
                        color: record.isRemoved ? AppTheme.warning : AppTheme.accent
                    )
                    if record.isRemoved {
                        Text("Удалено из Центра уведомлений")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(record.isRemoved ? AppTheme.warning.opacity(0.16) : Color.black.opacity(0.05), lineWidth: 1)
        )
        .opacity(record.isRemoved ? 0.72 : 1)
        .shadow(color: Color.black.opacity(0.035), radius: 6, y: 2)
    }
}

private struct SourceIcon: View {
    let source: AppSource
    let name: String
    let appID: String

    private var initials: String {
        let base = name.isEmpty ? appID : name
        let parts = base.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let value = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return String((value.isEmpty ? "?" : value).prefix(2)).uppercased()
    }

    private var generatedColor: Color {
        let hash = (name + appID).unicodeScalars.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1.value) }
        return Color(hue: Double(abs(hash % 360)) / 360, saturation: 0.62, brightness: 0.78)
    }

    var body: some View {
        Group {
            if source == .other {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(generatedColor.gradient)
                    Text(initials)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            } else {
                Image(source.rawValue)
                    .resizable()
                    .scaledToFit()
                    .padding(source == .simple ? 0 : 5)
                    .background(source == .simple ? Color.clear : AppTheme.elevated)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
        )
        .accessibilityLabel(source == .other ? initials : source.title)
    }
}

private struct SystemLogView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var confirmClear = false

    private var infoCount: Int {
        ble.store.logs.filter { $0.level == "info" }.count
    }

    private var warningCount: Int {
        ble.store.logs.filter { $0.level == "warning" }.count
    }

    private var errorCount: Int {
        ble.store.logs.filter { $0.level == "error" }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.grouped.ignoresSafeArea()

                if ble.store.logs.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            logHeader
                            EmptyState(
                                icon: "list.bullet.rectangle",
                                title: "Журнал пока пуст",
                                detail: "События подключения, потери связи и состояние модуля появятся здесь."
                            )
                            .padding(.top, 40)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            logHeader

                            LazyVStack(spacing: 10) {
                                ForEach(ble.store.logs) { entry in
                                    LogRow(entry: entry)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Журнал")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                Button("Очистить") { confirmClear = true }
                    .disabled(ble.store.logs.isEmpty)
            }
            .confirmationDialog("Очистить журнал?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Очистить", role: .destructive) { ble.store.clearLogs() }
            }
        }
    }

    private var logHeader: some View {
        HStack(spacing: 10) {
            StatBadge(value: "\(infoCount)", label: "info", color: AppTheme.accent)
            StatBadge(value: "\(warningCount)", label: "warning", color: AppTheme.warning)
            StatBadge(value: "\(errorCount)", label: "error", color: AppTheme.danger)
        }
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.09))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var ble: BLEManager
    @Binding var autoReconnect: Bool
    @Binding var lifecycleMode: String
    @Binding var eurPrice: Double
    @Binding var gbpPrice: Double
    @Binding var czkPrice: Double
    @Binding var plnPrice: Double
    @Binding var mdlPrice: Double
    @State private var confirmNotifications = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    settingsHero

                    SectionCard(title: "Подключение", symbol: "dot.radiowaves.left.and.right") {
                        Toggle("Подключаться автоматически", isOn: $autoReconnect)
                            .tint(AppTheme.accent)

                        Divider()

                        Button(ble.isScanning ? "Остановить поиск" : "Найти XIAO Notify") {
                            ble.isScanning ? ble.stopScanning() : ble.startScanning()
                        }
                        .buttonStyle(PrimaryActionButtonStyle())

                        if ble.connectedName == nil {
                            Button("Подключить сохраненное устройство") {
                                ble.reconnectSaved()
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                        } else {
                            Button("Отключиться", role: .destructive) {
                                autoReconnect = false
                                ble.disconnect()
                            }
                            .buttonStyle(SecondaryActionButtonStyle(roleColor: AppTheme.danger))
                        }

                        if !ble.devices.isEmpty {
                            Divider().padding(.vertical, 2)
                            Text("Найденные устройства")
                                .font(.subheadline.weight(.semibold))
                            ForEach(ble.devices) { device in
                                Button {
                                    ble.connect(to: device)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle()
                                                .fill(AppTheme.accent.opacity(0.1))
                                                .frame(width: 36, height: 36)
                                            Image(systemName: "dot.radiowaves.left.and.right")
                                                .foregroundStyle(AppTheme.accent)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .foregroundStyle(.primary)
                                                .font(.subheadline.weight(.semibold))
                                            Text(device.id.uuidString)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if device.rssi != 0 {
                                            Text("\(device.rssi) dBm")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(12)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    SectionCard(title: "Обработка уведомлений", symbol: "slider.horizontal.3") {
                        Picker("Режим", selection: $lifecycleMode) {
                            ForEach(LifecycleMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        Text("Выбор определяет, как события Modified и Removed влияют на историю уведомлений.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SectionCard(title: "Цена 1 USDT", symbol: "tag") {
                        USDTPriceField(currency: "EUR", price: $eurPrice)
                        USDTPriceField(currency: "GBP", price: $gbpPrice)
                        USDTPriceField(currency: "CZK", price: $czkPrice)
                        USDTPriceField(currency: "PLN", price: $plnPrice)
                        USDTPriceField(currency: "MDL", price: $mdlPrice)
                        Text("Эти цены используются для расчёта ожидаемого USDT и прибыли во вкладке «Ордера».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SectionCard(title: "Хранилище", symbol: "internaldrive") {
                        InfoRow(label: "Уведомлений", value: "\(ble.store.notifications.count) / 1000")
                        InfoRow(label: "Событий журнала", value: "\(ble.store.logs.count) / 1000")
                        Button("Очистить уведомления", role: .destructive) {
                            confirmNotifications = true
                        }
                        .buttonStyle(SecondaryActionButtonStyle(roleColor: AppTheme.danger))
                        .disabled(ble.store.notifications.isEmpty)
                    }

                    SectionCard(title: "О приложении", symbol: "info.circle") {
                        InfoRow(label: "Версия", value: "1.2.0")
                        Text("XIAO Notify получает события через ANCS, хранит историю локально и не требует внешнего сервера.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(AppTheme.grouped)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog("Удалить все уведомления?", isPresented: $confirmNotifications, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { ble.store.clearNotifications() }
            }
        }
    }

    private var settingsHero: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Состояние приложения")
                    .font(.headline)
                Text(ble.connectedName ?? "XIAO Notify пока не подключен")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                StatusPill(title: ble.bluetoothState, color: ble.connectedName == nil ? AppTheme.warning : AppTheme.success)
                Text(ble.bridgeReady ? "Канал готов" : "Канал не готов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct USDTPriceField: View {
    let currency: String
    @Binding var price: Double

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.decimalSeparator = "."
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currency)
                    .font(.subheadline.weight(.semibold))
                Text("за 1 USDT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("0", value: $price, formatter: Self.formatter)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 128)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                )
        }
    }
}

private struct FilterBar: View {
    @Binding var selection: NotificationFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NotificationFilter.allCases) { item in
                    Button(item.title) {
                        selection = item
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selection == item ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(selection == item ? AppTheme.accent : AppTheme.elevated, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(selection == item ? AppTheme.accent : Color.black.opacity(0.05), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct StatBadge: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct StatusHeroCard: View {
    let title: String
    let subtitle: String
    let color: Color
    let badge: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(title: badge, color: color)
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text("Состояние модуля и канала определяется по последнему статус-пакету.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var multiline = false

    var body: some View {
        HStack(alignment: multiline ? .top : .center, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(multiline ? nil : 1)
        }
    }
}

private struct MetricItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let tint: Color
}

private struct MetricsGrid: View {
    let items: [MetricItem]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Capsule()
                        .fill(item.tint.opacity(0.8))
                        .frame(width: 28, height: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private func formatMoney(_ value: Double, currency: String) -> String {
    "\(formatDecimal(value, fractionDigits: value >= 100 ? 2 : 3)) \(currency)"
}

private func formatUSDT(_ value: Double?) -> String {
    guard let value = value else { return "—" }
    return "\(formatDecimal(value, fractionDigits: 2)) USDT"
}

private func formatUSDC(_ value: Double?) -> String {
    guard let value = value else { return "—" }
    return "\(formatDecimal(value, fractionDigits: 2)) USDC"
}

private func formatProfit(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : ""
    return "\(sign)\(formatDecimal(value, fractionDigits: 2)) USDC"
}

private func formatPercent(_ value: Double?) -> String {
    guard let value = value else { return "—" }
    let percent = value * 100
    let sign = percent >= 0 ? "+" : ""
    return "\(sign)\(formatDecimal(percent, fractionDigits: 2))%"
}

private func formatDecimal(_ value: Double, fractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    formatter.locale = Locale(identifier: "ru_RU")
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
}

private struct LogRow: View {
    let entry: SystemLogEntry

    private var tint: Color {
        switch entry.level {
        case "error": return AppTheme.danger
        case "warning": return AppTheme.warning
        default: return AppTheme.accent
        }
    }

    private var icon: String {
        switch entry.level {
        case "error": return "exclamationmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.accent.opacity(configuration.isPressed ? 0.88 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    var roleColor = AppTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(roleColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(roleColor.opacity(configuration.isPressed ? 0.16 : 0.1))
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(BLEManager())
    }
}
