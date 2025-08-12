import XCTest
import Combine
import CoreData
@testable import VetraApp

final class SyncBridgeTests: XCTestCase {
    let testQueue = DispatchQueue.main

    // Minimal mock conforming to PuffsSource
    final class MockSource: PuffsSource {
        let puffsBatchPublisher = PassthroughSubject<[PuffModel], Never>()
        let puffsBackfillComplete = PassthroughSubject<Void, Never>()
        let activePhasePublisher = PassthroughSubject<PartialPhaseModel, Never>()
        let connectionPublisher = PassthroughSubject<Bool, Never>()

        var requests: [(UInt16, UInt8?)] = []
        func requestPuffs(startAfter: UInt16, maxCount: UInt8?) {
            requests.append((startAfter, maxCount))
        }
        func readActivePhase() { /* no-op */ }
    }

    func testInitialRequestUsesLastSeen() {
        let ctx = TestCoreDataStack().makeBackgroundContext()

        // seed one puff so lastSeen == 7
        let seed = Puff(context: ctx)
        seed.puffNumber = 7
        try? ctx.save()

        let src = MockSource()
        let bridge = SyncBridge(source: src, context: ctx, processingQueue: testQueue)

        // simulate connect
        src.connectionPublisher.send(true); drain(testQueue)

        // last call should be startAfter=7
        XCTAssertEqual(src.requests.last?.0, 7)
    }

    func testGapTriggersRetryFromSameLastSeen() {
        let ctx = TestCoreDataStack().makeBackgroundContext()
        let src = MockSource()
        let bridge = SyncBridge(source: src, context: ctx, processingQueue: testQueue)

        src.connectionPublisher.send(true); drain(testQueue)
        XCTAssertEqual(src.requests.last?.0, 0)

        // Device sends a batch starting at #2 (gap from 0)
        src.puffsBatchPublisher.send([PuffModel(puffNumber: 2, timestamp: Date(), duration: 1, phaseIndex: 1)]); drain(testQueue)

        // Bridge should re-request from lastSeen = 0 (no progress)
        XCTAssertEqual(src.requests.last?.0, 0)
    }

    func testDedupAndAdvanceKeepsPulling() {
        let ctx = TestCoreDataStack().makeBackgroundContext()
        let src = MockSource()
        let bridge = SyncBridge(source: src, context: ctx, processingQueue: testQueue)

        src.connectionPublisher.send(true); drain(testQueue)

        XCTAssertEqual(src.requests.last?.0, 0)

        // Ingest 1,2 → should move lastSeen to 2 and immediately request from 2
        src.puffsBatchPublisher.send([
            PuffModel(puffNumber: 1, timestamp: Date(), duration: 1, phaseIndex: 1),
            PuffModel(puffNumber: 2, timestamp: Date(), duration: 1, phaseIndex: 1)
        ]); drain(testQueue)

        XCTAssertEqual(src.requests.last?.0, 2)

        // Re-send 2 (duplicate) → should not advance lastSeen
        src.puffsBatchPublisher.send([
            PuffModel(puffNumber: 2, timestamp: Date(), duration: 1, phaseIndex: 1)
        ]); drain(testQueue)


        // Last request still from 2
        XCTAssertEqual(src.requests.last?.0, 2)
    }

    func testActivePhaseIsSaved() {
        let ctx = TestCoreDataStack().makeBackgroundContext()
        let src = MockSource()
        let bridge = SyncBridge(source: src, context: ctx, processingQueue: testQueue)

        let date = Date(timeIntervalSince1970: 12345)
        src.activePhasePublisher.send(PartialPhaseModel(phaseIndex: 3, phaseStartDate: date)); drain(testQueue)


        // fetch from store
        let req: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
        req.fetchLimit = 1
        let ap = try? ctx.fetch(req).first
        XCTAssertNotNil(ap)
        XCTAssertEqual(ap?.phaseIndex, 3)
        XCTAssertEqual(ap?.phaseStartDate, date)
    }
}
