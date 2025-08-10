import XCTest
import Combine
import CoreData
@testable import VetraApp

final class MainViewModelTests: XCTestCase {

    func testStateAndRatioFromPuffsAndActivePhase() {
        let ctx = TestCoreDataStack.makeContext()

        // Seed session with one phase: maxPuffs=3, duration=60s
        let session = SessionLifetime(context: ctx)
        session.userId = "u1"
        session.startedAt = Date()
        session.totalPuffsTaken = 0
        session.phasesCompleted = 0

        let phase = Phase(context: ctx)
        phase.index = 0
        phase.maxPuffs = 3
        phase.duration = 60
        session.addToPhases(phase)

        // ActivePhase index 0 started 10s ago
        let active = ActivePhase(context: ctx)
        active.phaseIndex = 0
        active.phaseStartDate = Date().addingTimeInterval(-10)

        // Two puffs in phase 0
        let p1 = Puff(context: ctx); p1.puffNumber = 1; p1.timestamp = Date(); p1.duration = 1.0; p1.phase = phase
        let p2 = Puff(context: ctx); p2.puffNumber = 2; p2.timestamp = Date(); p2.duration = 1.0; p2.phase = phase

        try? ctx.save()

        let vm = MainViewModel(context: ctx)

        // Allow async publishers to deliver (session+active+puffs)
        let exp = expectation(description: "computed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(vm.ratioString, "2/3")
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertGreaterThan(vm.progress, 0.0)
        XCTAssertLessThan(vm.progress, 1.0)
        XCTAssertFalse(vm.timeRemainingString.isEmpty)
    }
}
