import XCTest
@testable import XIAOCompanion

final class OKXOrderAnalyzerTests: XCTestCase {
    private let prices = [
        "EUR": 0.938,
        "GBP": 0.782,
        "CZK": 22.48,
        "PLN": 3.85,
        "MDL": 18.39
    ]

    func testCompletedOrderCalculatesProfit() {
        let now = date(2026, 6, 29, 23, 0)
        let records = fullOrder(
            orderID: "260624033645744",
            fiat: "100,00",
            currency: "EUR",
            simple: "115.820272",
            baseDate: now
        )

        let stats = OKXOrderAnalyzer.analyze(records: records, period: .day, prices: prices, calendar: calendar, now: now)

        XCTAssertEqual(stats.completedCount, 1)
        XCTAssertEqual(stats.orders.first?.status, .completed)
        XCTAssertEqual(stats.orders.first?.expectedUSDT ?? 0, 100 / 0.938, accuracy: 0.001)
        XCTAssertEqual(stats.orders.first?.simpleUSDC ?? 0, 115.820272, accuracy: 0.000001)
        XCTAssertEqual(stats.orders.first?.profitPercent ?? 0, 0.08639, accuracy: 0.0001)
    }

    func testChangingPriceChangesProfit() {
        let now = date(2026, 6, 29, 23, 0)
        let records = fullOrder(
            orderID: "260624033645744",
            fiat: "100,00",
            currency: "EUR",
            simple: "115.820272",
            baseDate: now
        )

        let first = OKXOrderAnalyzer.analyze(records: records, period: .day, prices: ["EUR": 0.938], calendar: calendar, now: now)
        let second = OKXOrderAnalyzer.analyze(records: records, period: .day, prices: ["EUR": 0.890], calendar: calendar, now: now)

        XCTAssertNotEqual(first.orders.first?.profitUSDC, second.orders.first?.profitUSDC)
        XCTAssertLessThan(second.orders.first?.profitUSDC ?? 0, first.orders.first?.profitUSDC ?? 0)
    }

    func testPeriodsFilterOrders() {
        let now = date(2026, 6, 30, 23, 0)
        let today = fullOrder(orderID: "260624033645744", fiat: "100,00", currency: "EUR", simple: "115.820272", baseDate: now)
        let yesterday = fullOrder(orderID: "260624033645745", fiat: "100,00", currency: "EUR", simple: "115.820272", baseDate: date(2026, 6, 29, 23, 0))

        let day = OKXOrderAnalyzer.analyze(records: today + yesterday, period: .day, prices: prices, calendar: calendar, now: now)
        let week = OKXOrderAnalyzer.analyze(records: today + yesterday, period: .week, prices: prices, calendar: calendar, now: now)
        let month = OKXOrderAnalyzer.analyze(records: today + yesterday, period: .month, prices: prices, calendar: calendar, now: now)

        XCTAssertEqual(day.completedCount, 1)
        XCTAssertEqual(week.completedCount, 2)
        XCTAssertEqual(month.completedCount, 2)
    }

    func testPaidOrderWithoutSimpleIsActive() {
        let now = date(2026, 6, 29, 23, 0)
        let records = [
            okx(orderID: "260624033645744", title: "P2P-ордер оплачен", date: now),
            gmail(orderID: "260624033645744", fiat: "100,00", currency: "EUR", date: now.addingTimeInterval(30))
        ]

        let stats = OKXOrderAnalyzer.analyze(records: records, period: .day, prices: prices, calendar: calendar, now: now)

        XCTAssertEqual(stats.completedCount, 0)
        XCTAssertEqual(stats.activeCount, 1)
        XCTAssertEqual(stats.orders.first?.status, .paid)
    }

    func testSimpleAboveTwentyPercentStaysUnmatched() {
        let now = date(2026, 6, 29, 23, 0)
        let records = [
            okx(orderID: "260624033645744", title: "P2P-ордер оплачен", date: now),
            gmail(orderID: "260624033645744", fiat: "100,00", currency: "EUR", date: now.addingTimeInterval(30)),
            simple(amount: "130.00", date: now.addingTimeInterval(60))
        ]

        let stats = OKXOrderAnalyzer.analyze(records: records, period: .day, prices: prices, calendar: calendar, now: now)

        XCTAssertEqual(stats.completedCount, 0)
        XCTAssertNil(stats.orders.first?.simpleUSDC)
        XCTAssertEqual(stats.unmatchedSimpleCount, 1)
    }

    func testDuplicateSimpleDoesNotDoubleCount() {
        let now = date(2026, 6, 29, 23, 0)
        var records = fullOrder(
            orderID: "260624033645744",
            fiat: "100,00",
            currency: "EUR",
            simple: "115.820272",
            baseDate: now
        )
        records.append(simple(amount: "115.820272", date: now.addingTimeInterval(65)))

        let stats = OKXOrderAnalyzer.analyze(records: records, period: .day, prices: prices, calendar: calendar, now: now)

        XCTAssertEqual(stats.completedCount, 1)
        XCTAssertEqual(stats.simpleTotal, 115.820272, accuracy: 0.000001)
        XCTAssertEqual(stats.unmatchedSimpleCount, 0)
    }

    func testUnknownCurrencyIsIncomplete() {
        let now = date(2026, 6, 29, 23, 0)
        let records = [
            okx(orderID: "260624033645744", title: "P2P-ордер оплачен", date: now),
            gmail(orderID: "260624033645744", fiat: "100,00", currency: "CHF", date: now.addingTimeInterval(30))
        ]

        let stats = OKXOrderAnalyzer.analyze(records: records, period: .day, prices: prices, calendar: calendar, now: now)

        XCTAssertEqual(stats.orders.first?.status, .incomplete)
        XCTAssertEqual(stats.missingPriceCurrencies, ["CHF"])
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func fullOrder(orderID: String, fiat: String, currency: String, simple simpleAmount: String, baseDate: Date) -> [NotificationRecord] {
        [
            okx(orderID: orderID, title: "P2P-ордер ожидает оплаты от покупателя", date: baseDate),
            gmail(orderID: orderID, fiat: fiat, currency: currency, date: baseDate.addingTimeInterval(30)),
            okx(orderID: orderID, title: "P2P-ордер оплачен", date: baseDate.addingTimeInterval(60)),
            simple(amount: simpleAmount, date: baseDate.addingTimeInterval(90))
        ]
    }

    private func okx(orderID: String, title: String, date: Date) -> NotificationRecord {
        NotificationRecord(
            id: UUID(),
            uid: UInt32.random(in: 1...10_000),
            sessionID: "TEST",
            sequence: nil,
            event: "Added",
            source: .okx,
            appID: "com.okex.OKEx",
            appName: "OKX",
            category: "Other",
            title: title,
            message: "Покупатель в P2P-ордере \(orderID) должен перечислить оплату.",
            receivedAt: date,
            isRemoved: false
        )
    }

    private func gmail(orderID: String, fiat: String, currency: String, date: Date) -> NotificationRecord {
        NotificationRecord(
            id: UUID(),
            uid: UInt32.random(in: 1...10_000),
            sessionID: "TEST",
            sequence: nil,
            event: "Added",
            source: .other,
            appID: "com.google.Gmail",
            appName: "Gmail",
            category: "Email",
            title: "OKX",
            message: "Новый P2P-ордер: 5744 Получен новый P2P-ордер: \(orderID) (\(fiat) \(currency)).",
            receivedAt: date,
            isRemoved: false
        )
    }

    private func simple(amount: String, date: Date) -> NotificationRecord {
        NotificationRecord(
            id: UUID(),
            uid: UInt32.random(in: 1...10_000),
            sessionID: "TEST",
            sequence: nil,
            event: "Added",
            source: .simple,
            appID: "app.simple.com",
            appName: "Simple",
            category: "Other",
            title: "Карта пополнена",
            message: "\(amount) USDC зачислено на ••••.",
            receivedAt: date,
            isRemoved: false
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour, minute: minute).date!
    }
}
