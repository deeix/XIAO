import Foundation

enum OKXOrderPeriod: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "День"
        case .week: return "Неделя"
        case .month: return "Месяц"
        }
    }

    func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .day:
            return calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 604_800)
        case .month:
            return calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 2_592_000)
        }
    }
}

enum OKXOrderStatus: String, Codable {
    case inProgress = "В работе"
    case paid = "Оплачен"
    case completed = "Завершён"
    case incomplete = "Неполные данные"
}

enum OKXOrderEventKind: String, Codable {
    case pending = "OKX ожидает оплаты"
    case gmail = "Gmail сумма"
    case paid = "OKX оплачен"
    case simple = "Simple зачислено"
}

struct OKXOrderTimelineEvent: Identifiable, Equatable {
    let id: UUID
    let kind: OKXOrderEventKind
    let date: Date
    let title: String
    let message: String
}

struct OKXOrderSummary: Identifiable, Equatable {
    let id: String
    let fiatAmount: Double?
    let fiatCurrency: String?
    let usdtPrice: Double?
    let expectedUSDT: Double?
    let simpleUSDC: Double?
    let profitUSDC: Double?
    let profitPercent: Double?
    let status: OKXOrderStatus
    let firstEventAt: Date
    let lastEventAt: Date
    let history: [OKXOrderTimelineEvent]

    var isCompleted: Bool { status == .completed }
}

struct OKXPeriodStats: Equatable {
    let period: OKXOrderPeriod
    let interval: DateInterval
    let orders: [OKXOrderSummary]
    let unmatchedSimpleCount: Int
    let missingPriceCurrencies: [String]

    var completedCount: Int { orders.filter(\.isCompleted).count }

    var activeCount: Int {
        orders.filter { $0.status != .completed }.count
    }

    var expectedTotal: Double {
        orders.compactMap(\.expectedUSDT).reduce(0, +)
    }

    var simpleTotal: Double {
        orders.compactMap(\.simpleUSDC).reduce(0, +)
    }

    var profitTotal: Double {
        orders.compactMap(\.profitUSDC).reduce(0, +)
    }

    var profitPercent: Double? {
        guard expectedTotal > 0 else { return nil }
        return simpleTotal / expectedTotal - 1
    }

    var fiatTotals: [(currency: String, amount: Double)] {
        let grouped = Dictionary(grouping: orders) { $0.fiatCurrency ?? "" }
        return grouped
            .compactMap { currency, orders in
                guard !currency.isEmpty else { return nil }
                let total = orders.compactMap(\.fiatAmount).reduce(0, +)
                return (currency: currency, amount: total)
            }
            .sorted { $0.currency < $1.currency }
    }
}

enum OKXPriceStore {
    static let eurKey = "okxUSDTPriceEUR"
    static let gbpKey = "okxUSDTPriceGBP"
    static let czkKey = "okxUSDTPriceCZK"
    static let plnKey = "okxUSDTPricePLN"
    static let mdlKey = "okxUSDTPriceMDL"

    static let defaults: [String: Double] = [
        "EUR": 0.938,
        "GBP": 0.782,
        "CZK": 22.48,
        "PLN": 3.85,
        "MDL": 18.39
    ]
}

enum OKXOrderAnalyzer {
    static func analyze(
        records: [NotificationRecord],
        period: OKXOrderPeriod,
        prices: [String: Double],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> OKXPeriodStats {
        let interval = period.interval(containing: now, calendar: calendar)
        let relevant = records.filter { interval.contains($0.receivedAt) && !$0.isRemoved }
        var builders: [String: OrderBuilder] = [:]
        var simpleEvents: [SimpleCredit] = []

        for record in relevant {
            if let event = parseOKXEvent(record) {
                var builder = builders[event.orderID, default: OrderBuilder(orderID: event.orderID)]
                builder.apply(event, record: record)
                builders[event.orderID] = builder
                continue
            }

            if let gmail = parseGmailEvent(record) {
                var builder = builders[gmail.orderID, default: OrderBuilder(orderID: gmail.orderID)]
                builder.apply(gmail, record: record)
                builders[gmail.orderID] = builder
                continue
            }

            if let simple = parseSimpleCredit(record) {
                simpleEvents.append(simple)
            }
        }

        simpleEvents = deduplicateSimpleCredits(simpleEvents)

        var usedSimpleIDs = Set<UUID>()
        var matchedBuilders = builders.values.sorted { $0.anchorDate < $1.anchorDate }

        for index in matchedBuilders.indices {
            guard let expected = matchedBuilders[index].expectedUSDT(prices: prices) else { continue }
            guard let match = bestSimpleMatch(
                for: matchedBuilders[index],
                expected: expected,
                simpleEvents: simpleEvents,
                usedSimpleIDs: usedSimpleIDs
            ) else { continue }
            usedSimpleIDs.insert(match.id)
            matchedBuilders[index].simpleCredit = match
            matchedBuilders[index].history.append(match.timelineEvent)
        }

        let orders = matchedBuilders
            .map { $0.summary(prices: prices) }
            .sorted { $0.lastEventAt > $1.lastEventAt }

        let missing = Set(orders.compactMap { order -> String? in
            guard let currency = order.fiatCurrency, order.usdtPrice == nil else { return nil }
            return currency
        })

        return OKXPeriodStats(
            period: period,
            interval: interval,
            orders: orders,
            unmatchedSimpleCount: simpleEvents.filter { !usedSimpleIDs.contains($0.id) }.count,
            missingPriceCurrencies: missing.sorted()
        )
    }

    private static func parseOKXEvent(_ record: NotificationRecord) -> ParsedOrderEvent? {
        guard record.source == .okx || record.appName.localizedCaseInsensitiveContains("OKX") else { return nil }
        let text = combinedText(record)
        let lowered = text.lowercased()
        let kind: OKXOrderEventKind
        if lowered.contains("p2p-ордер ожидает оплаты") || lowered.contains("p2p ордер ожидает оплаты") {
            kind = .pending
        } else if lowered.contains("p2p-ордер оплачен") || lowered.contains("p2p ордер оплачен") {
            kind = .paid
        } else {
            return nil
        }
        guard let orderID = longestDigitRun(in: text) else { return nil }
        return ParsedOrderEvent(orderID: orderID, kind: kind)
    }

    private static func parseGmailEvent(_ record: NotificationRecord) -> ParsedGmailEvent? {
        let appText = "\(record.appName) \(record.appID)".lowercased()
        let text = combinedText(record)
        guard appText.contains("gmail") || record.title.localizedCaseInsensitiveContains("OKX") else { return nil }
        guard text.localizedCaseInsensitiveContains("OKX"),
              text.localizedCaseInsensitiveContains("P2P"),
              let orderID = longestDigitRun(in: text),
              let amount = parseFiatAmount(in: text) else { return nil }
        return ParsedGmailEvent(orderID: orderID, amount: amount.value, currency: amount.currency)
    }

    private static func parseSimpleCredit(_ record: NotificationRecord) -> SimpleCredit? {
        guard record.source == .simple || record.appName.localizedCaseInsensitiveContains("Simple") else { return nil }
        guard let amount = parseUSDCAmount(in: combinedText(record)) else { return nil }
        let event = OKXOrderTimelineEvent(
            id: record.id,
            kind: .simple,
            date: record.receivedAt,
            title: record.title,
            message: record.message
        )
        return SimpleCredit(id: record.id, amount: amount, date: record.receivedAt, timelineEvent: event)
    }

    private static func bestSimpleMatch(
        for builder: OrderBuilder,
        expected: Double,
        simpleEvents: [SimpleCredit],
        usedSimpleIDs: Set<UUID>
    ) -> SimpleCredit? {
        let maximum = expected * 1.2
        let candidates = simpleEvents.filter {
            !usedSimpleIDs.contains($0.id) && $0.amount >= expected && $0.amount <= maximum
        }
        let anchor = builder.paidAt ?? builder.gmailAt ?? builder.pendingAt ?? builder.anchorDate
        let afterAnchor = candidates.filter { $0.date >= anchor }
        let pool = afterAnchor.isEmpty ? candidates : afterAnchor
        return pool.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(anchor)) < abs(rhs.date.timeIntervalSince(anchor))
        }
    }

    private static func deduplicateSimpleCredits(_ credits: [SimpleCredit]) -> [SimpleCredit] {
        var result: [SimpleCredit] = []
        for credit in credits.sorted(by: { $0.date < $1.date }) {
            let duplicate = result.contains {
                abs($0.amount - credit.amount) < 0.000001 &&
                abs($0.date.timeIntervalSince(credit.date)) <= 90
            }
            if !duplicate { result.append(credit) }
        }
        return result
    }

    private static func combinedText(_ record: NotificationRecord) -> String {
        "\(record.title) \(record.message)"
    }

    private static func longestDigitRun(in text: String) -> String? {
        let matches = regexMatches(pattern: #"(?<!\d)\d{8,}(?!\d)"#, in: text)
        return matches.max { $0.count < $1.count }
    }

    private static func parseFiatAmount(in text: String) -> (value: Double, currency: String)? {
        let pattern = #"\(([0-9][0-9\s.,]*)\s*([A-Z]{3})\)"#
        let match = regexCapture(pattern: pattern, in: text)
        guard match.count == 2 else { return nil }
        guard let value = parseLocalizedNumber(match[0]) else { return nil }
        return (value, match[1].uppercased())
    }

    private static func parseUSDCAmount(in text: String) -> Double? {
        let pattern = #"([0-9][0-9\s.,]*)\s*USDC"#
        guard let match = regexCapture(pattern: pattern, in: text).first else { return nil }
        return parseLocalizedNumber(match)
    }

    private static func parseLocalizedNumber(_ raw: String) -> Double? {
        var value = raw.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
        if value.contains(",") && value.contains(".") {
            value = value.replacingOccurrences(of: ".", with: "")
            value = value.replacingOccurrences(of: ",", with: ".")
        } else if value.contains(",") {
            value = value.replacingOccurrences(of: ",", with: ".")
        }
        return Double(value)
    }

    private static func regexMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func regexCapture(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap {
            guard let range = Range(match.range(at: $0), in: text) else { return nil }
            return String(text[range])
        }
    }
}

private struct ParsedOrderEvent {
    let orderID: String
    let kind: OKXOrderEventKind
}

private struct ParsedGmailEvent {
    let orderID: String
    let amount: Double
    let currency: String
}

private struct SimpleCredit: Equatable {
    let id: UUID
    let amount: Double
    let date: Date
    let timelineEvent: OKXOrderTimelineEvent
}

private struct OrderBuilder {
    let orderID: String
    var fiatAmount: Double?
    var fiatCurrency: String?
    var pendingAt: Date?
    var paidAt: Date?
    var gmailAt: Date?
    var simpleCredit: SimpleCredit?
    var history: [OKXOrderTimelineEvent] = []

    var anchorDate: Date {
        paidAt ?? gmailAt ?? pendingAt ?? history.map(\.date).min() ?? .distantPast
    }

    mutating func apply(_ event: ParsedOrderEvent, record: NotificationRecord) {
        switch event.kind {
        case .pending:
            pendingAt = record.receivedAt
        case .paid:
            paidAt = record.receivedAt
        case .gmail, .simple:
            break
        }
        history.append(OKXOrderTimelineEvent(
            id: record.id,
            kind: event.kind,
            date: record.receivedAt,
            title: record.title,
            message: record.message
        ))
    }

    mutating func apply(_ event: ParsedGmailEvent, record: NotificationRecord) {
        fiatAmount = event.amount
        fiatCurrency = event.currency
        gmailAt = record.receivedAt
        history.append(OKXOrderTimelineEvent(
            id: record.id,
            kind: .gmail,
            date: record.receivedAt,
            title: record.title,
            message: record.message
        ))
    }

    func expectedUSDT(prices: [String: Double]) -> Double? {
        guard let fiatAmount = fiatAmount,
              let currency = fiatCurrency,
              let price = prices[currency],
              price > 0 else { return nil }
        return fiatAmount / price
    }

    func summary(prices: [String: Double]) -> OKXOrderSummary {
        let price = fiatCurrency.flatMap { prices[$0] }.flatMap { $0 > 0 ? $0 : nil }
        let expected = expectedUSDT(prices: prices)
        let simple = simpleCredit?.amount
        let profit = expected.flatMap { expected in simple.map { $0 - expected } }
        let percent = expected.flatMap { expected in simple.map { $0 / expected - 1 } }
        let sortedHistory = history.sorted { $0.date < $1.date }
        let first = sortedHistory.first?.date ?? .distantPast
        let last = sortedHistory.last?.date ?? .distantPast

        let status: OKXOrderStatus
        if simple != nil, expected != nil, paidAt != nil {
            status = .completed
        } else if fiatCurrency != nil && price == nil {
            status = .incomplete
        } else if paidAt != nil {
            status = .paid
        } else {
            status = .inProgress
        }

        return OKXOrderSummary(
            id: orderID,
            fiatAmount: fiatAmount,
            fiatCurrency: fiatCurrency,
            usdtPrice: price,
            expectedUSDT: expected,
            simpleUSDC: simple,
            profitUSDC: profit,
            profitPercent: percent,
            status: status,
            firstEventAt: first,
            lastEventAt: last,
            history: sortedHistory
        )
    }
}
