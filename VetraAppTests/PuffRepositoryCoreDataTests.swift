import XCTest
import CoreData
@testable import VetraApp

final class PuffRepositoryCoreDataTests: XCTestCase {

    func testMaxAndExists() {
        let ctx = TestCoreDataStack.makeContext()
        let repo = PuffRepositoryCoreData(context: ctx)

        XCTAssertEqual(repo.maxPuffNumber(), 0)

        repo.addPuff(.init(puffNumber: 5, timestamp: Date(), duration: 1, phaseIndex: 0))
        XCTAssertTrue(repo.exists(puffNumber: 5))
        XCTAssertEqual(repo.maxPuffNumber(), 5)
    }

    func testLinksToExistingPhase() {
        let ctx = TestCoreDataStack.makeContext()

        // create Phase index 2
        let phase = Phase(context: ctx)
        phase.index = 2
        phase.maxPuffs = 3
        phase.duration = 60
        try? ctx.save()

        let repo = PuffRepositoryCoreData(context: ctx)
        repo.addPuff(.init(puffNumber: 10, timestamp: Date(), duration: 1.2, phaseIndex: 2))

        // fetch saved Puff entity and verify relationship
        let req: NSFetchRequest<Puff> = Puff.fetchRequest()
        req.predicate = NSPredicate(format: "puffNumber == %d", 10)
        let saved = try? ctx.fetch(req).first
        XCTAssertNotNil(saved?.phase)
        XCTAssertEqual(saved?.phase?.index, 2)
    }
}

final class RepositoryAdditionalTests: XCTestCase {

    func testAddManyPuffsPerformance() {
        let ctx = TestCoreDataStack.makeContext()
        let repo = PuffRepositoryCoreData(context: ctx)

        measure {
            repo.addPuffs((1...5000).map { PuffModel(puffNumber: $0, timestamp: Date(), duration: 0.5, phaseIndex: 0) })
            // wait a tick for observer -> reload
            waitForMainQueue(0.5)
            XCTAssertEqual(repo.maxPuffNumber(), 5000)
        }
    }

    func testAddPuffsFastNoCrash() {
        let ctx = TestCoreDataStack.makeContext()
        let repo = PuffRepositoryCoreData(context: ctx)

        let exp = expectation(description: "bulk")
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 1...200 {
                repo.addPuff(.init(puffNumber: i, timestamp: Date(), duration: 0.1, phaseIndex: 1))
            }
            DispatchQueue.main.async { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5.0)

        // Let the reload happen once
        waitForMainQueue(0.2)
        XCTAssertEqual(repo.maxPuffNumber(), 200)
    }
}
