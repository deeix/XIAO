import XCTest
@testable import XIAOCompanion

final class ProtocolTests: XCTestCase {
    func testJSONLinesFragmentedAtEveryByte() throws {
        let json = notification(session: "SESSION-UTF8", sequence: 11, uid: 9, event: "Added", title: "Карта пополнена")
        let bytes = Data((json + "\n").utf8)
        var buffer = JSONLineBuffer()
        var frames: [Data] = []
        for byte in bytes {
            frames += try buffer.append(Data([byte]))
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(BridgePacket.self, from: frames[0]).title, "Карта пополнена")
    }

    func testResetDropsFrameInterruptedByDisconnect() throws {
        var buffer = JSONLineBuffer()
        XCTAssertTrue(try buffer.append(Data("{\"v\":2".utf8)).isEmpty)
        buffer.reset()
        let complete = Data("{\"v\":1,\"type\":\"status\"}\n".utf8)
        let frames = try buffer.append(complete)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(BridgePacket.self, from: frames[0]).type, "status")
    }

    func testStatusV2Decoding() throws {
        let packet = try decode("""
        {"v":2,"type":"status","firmware_version":"1.2.0","state":"ready","session_id":"ABC-1","uptime_ms":12345,"queue_pending":2,"queue_capacity":32,"acked":9,"last_error":""}
        """)
        XCTAssertEqual(packet.v, 2)
        XCTAssertEqual(packet.firmwareVersion, "1.2.0")
        XCTAssertEqual(packet.state, "ready")
        XCTAssertEqual(packet.queueCapacity, 32)
        XCTAssertEqual(packet.acknowledged, 9)
    }

    func testSameUIDInDifferentSessionsCreatesTwoRecords() throws {
        let store = AppStore()
        store.clearNotifications()
        let first = try decode(notification(session: "SESSION-A", sequence: 1, uid: 42, event: "Added", title: "Первое"))
        let second = try decode(notification(session: "SESSION-B", sequence: 2, uid: 42, event: "Added", title: "Второе"))

        process(first, in: store)
        process(second, in: store)

        XCTAssertEqual(store.notifications.count, 2)
        XCTAssertEqual(Set(store.notifications.compactMap(\.sessionID)), Set(["SESSION-A", "SESSION-B"]))
    }

    func testDuplicateSequenceIsIdempotent() throws {
        let store = AppStore()
        store.clearNotifications()
        let packet = try decode(notification(session: "SESSION-A", sequence: 7, uid: 55, event: "Added", title: "Один раз"))

        process(packet, in: store)
        process(packet, in: store)

        XCTAssertEqual(store.notifications.count, 1)
    }

    func testUnknownRemovedDoesNotCreateBlankRecord() throws {
        let store = AppStore()
        store.clearNotifications()
        let removed = try decode("""
        {"v":2,"type":"notification","session_id":"SESSION-A","seq":8,"uid":999,"event":"Removed"}
        """)

        process(removed, in: store)

        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(store.logs.first?.title, "Removed без исходного уведомления")
    }

    func testModifiedUpdatesOnlyCurrentSession() throws {
        let store = AppStore()
        store.clearNotifications()
        process(try decode(notification(session: "SESSION-A", sequence: 1, uid: 10, event: "Added", title: "До")), in: store)
        process(try decode(notification(session: "SESSION-A", sequence: 2, uid: 10, event: "Modified", title: "После")), in: store)

        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertEqual(store.notifications.first?.title, "После")
        XCTAssertEqual(store.notifications.first?.sequence, 2)
    }

    func testKnownApplicationSourceDetection() {
        XCTAssertEqual(AppSource.detect(source: nil, appID: "app.simple.com", appName: "Simple"), .simple)
        XCTAssertEqual(AppSource.detect(source: nil, appID: "com.okex.OKEx", appName: "OKX"), .okx)
        XCTAssertEqual(AppSource.detect(source: nil, appID: "com.binance.dev", appName: "Binance"), .binance)
        XCTAssertEqual(AppSource.detect(source: nil, appID: "com.bybit.app", appName: "Bybit"), .bybit)
        XCTAssertEqual(AppSource.detect(source: nil, appID: "com.google.Gmail", appName: "Gmail"), .gmail)
        XCTAssertEqual(AppSource.detect(source: nil, appID: "com.apple.MobileSMS", appName: "Сообщения"), .other)
    }

    private func process(_ packet: BridgePacket, in store: AppStore, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = expectation(description: "packet persisted")
        var persisted = false
        store.process(packet: packet, mode: .update) { result in
            persisted = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(persisted, file: file, line: line)
    }

    private func decode(_ json: String) throws -> BridgePacket {
        try JSONDecoder().decode(BridgePacket.self, from: Data(json.utf8))
    }

    private func notification(session: String, sequence: UInt32, uid: UInt32, event: String, title: String) -> String {
        """
        {"v":2,"type":"notification","session_id":"\(session)","seq":\(sequence),"uid":\(uid),"event":"\(event)","source":"simple","app_id":"app.simple.com","app":"Simple","title":"\(title)","message":"Текст"}
        """
    }
}
