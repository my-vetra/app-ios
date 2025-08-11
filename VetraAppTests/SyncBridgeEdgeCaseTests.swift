import XCTest
import Combine
import CoreData
@testable import VetraApp

final class SyncBridgeEdgeCaseTests: XCTestCase {

    final class MockSource: PuffsSource {
        let puffsBatchPublisher = PassthroughSubject<[PuffModel], Never>()
        let puffsBackfillComplete = PassthroughSubject<Void, Never>()
        let activePhasePublisher = PassthroughSubject<ActivePhaseModel, Never>()
        let connectionPublisher = PassthroughSubject<Bool, Never>()

        var requests: [(UInt16, UInt8?)] = []
        func requestPuffs(startAfter: UInt16, maxCount: UInt8?) { requests.append((startAfter, maxCount)) }
        func readActivePhase() {}
    }

    func testOverlapDedup() {
        let ctx = TestCoreDataStack().makeBackgroundContext()
        let src = MockSource()
        let bridge = SyncBridge(source: src, context: ctx, processingQueue: DispatchQueue.main)

        src.connectionPublisher.send(true); drainMain()
        XCTAssertEqual(src.requests.last?.0, 0)

        // First batch: 1..10
        src.puffsBatchPublisher.send((1...10).map { PuffModel(puffNumber: $0, timestamp: Date(), duration: 1, phaseIndex: 0) }); drainMain()
        XCTAssertEqual(src.requests.last?.0, 10)

        // Overlap batch: 9..12 (9,10 duplicates)
        src.puffsBatchPublisher.send((9...12).map { PuffModel(puffNumber: $0, timestamp: Date(), duration: 1, phaseIndex: 0) }); drainMain()
        // Should advance to 12 and request from 12
        XCTAssertEqual(src.requests.last?.0, 12)

        withExtendedLifetime(bridge) {}
    }

    func testOutOfOrderTriggersReRequestAndStopsAfterRetries() {
        let ctx = TestCoreDataStack().makeBackgroundContext()
        let src = MockSource()
        let bridge = SyncBridge(source: src, context: ctx, processingQueue: DispatchQueue.main)

        src.connectionPublisher.send(true); drainMain()
        XCTAssertEqual(src.requests.last?.0, 0)

        // Device keeps sending [3,4] (gap) three times — we retry 3 times then stop
        for _ in 0..<3 {
            src.puffsBatchPublisher.send([3,4].map { PuffModel(puffNumber: $0, timestamp: Date(), duration: 1, phaseIndex: 0) })
            XCTAssertEqual(src.requests.last?.0, 0)
        }
        // Fourth time: we give up (no new request enqueued by guard)
        let prevCount = src.requests.count
        src.puffsBatchPublisher.send([3,4].map { PuffModel(puffNumber: $0, timestamp: Date(), duration: 1, phaseIndex: 0) })
        XCTAssertEqual(src.requests.count, prevCount)

        withExtendedLifetime(bridge) {}
    }

    func testDoneFlipsCatchingUp() {
        let ctx = TestCoreDataStack().makeBackgroundContext()
        let src = MockSource()
        let bridge = SyncBridge(source: src, context: ctx)

        src.connectionPublisher.send(true); drainMain()
        XCTAssertEqual(src.requests.last?.0, 0)

        // Send a small batch then "done"
        src.puffsBatchPublisher.send([PuffModel(puffNumber: 1, timestamp: Date(), duration: 1, phaseIndex: 0)]); drainMain()
        src.puffsBackfillComplete.send(()); drainMain()

        // After done, a new batch should NOT trigger an automatic pull
        let prev = src.requests.count
        src.puffsBatchPublisher.send([PuffModel(puffNumber: 2, timestamp: Date(), duration: 1, phaseIndex: 0)]); drainMain()
        XCTAssertEqual(src.requests.count, prev + 0) // no extra request

        withExtendedLifetime(bridge) {}
    }
}
