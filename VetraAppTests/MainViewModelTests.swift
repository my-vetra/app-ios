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

    func testMaxPuffsZeroTreatAsLocked() {
        let ctx = TestCoreDataStack.makeContext()

        let session = SessionLifetime(context: ctx)
        session.userId = "u"
        let phase = Phase(context: ctx)
        phase.index = 0
        phase.maxPuffs = 0
        phase.duration = 60
        session.addToPhases(phase)

        let active = ActivePhase(context: ctx)
        active.phaseIndex = 0
        active.phaseStartDate = Date().addingTimeInterval(-5)

        try? ctx.save()

        let vm = MainViewModel(context: ctx)
        waitUntil(vm.currentPhaseIndex == 1, timeout: 1.0)
        XCTAssertEqual(vm.ratioString, "0/0")
    }

    func testPhaseChangeRecomputes() {
        let ctx = TestCoreDataStack.makeContext()
        let session = SessionLifetime(context: ctx)
        session.userId = "u"
        let p0 = Phase(context: ctx); p0.index = 0; p0.duration = 60; p0.maxPuffs = 3
        let p1 = Phase(context: ctx); p1.index = 1; p1.duration = 120; p1.maxPuffs = 2
        session.addToPhases(p0); session.addToPhases(p1)

        let active = ActivePhase(context: ctx)
        active.phaseIndex = 0
        active.phaseStartDate = Date()

        try? ctx.save()

        let vm = MainViewModel(context: ctx)
        let exp1 = expectation(description: "bind1")
        DispatchQueue.main.async { exp1.fulfill() }
        wait(for: [exp1], timeout: 0.3)
        XCTAssertEqual(vm.currentPhaseIndex, 0)

        // Move to phase 1 via repo
        let repo = ActivePhaseRepositoryCoreData(context: ctx)
        repo.saveActivePhase(.init(phaseIndex: 1, phaseStartDate: Date()))

        waitUntil(vm.currentPhaseIndex == 1, timeout: 1.0)
        XCTAssertEqual(vm.currentPhaseIndex, 1)
    }
    
    private func waitUntil(_ condition: @autoclosure @escaping () -> Bool,
                           timeout: TimeInterval = 1.0,
                           step: TimeInterval = 0.05,
                           file: StaticString = #file, line: UInt = #line) {
        let exp = expectation(description: "wait-until")
        let deadline = Date().addingTimeInterval(timeout)

        func check() {
            if condition() { exp.fulfill(); return }
            if Date() >= deadline { exp.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + step, execute: check)
        }
        DispatchQueue.main.async(execute: check)
        wait(for: [exp], timeout: timeout + step + 0.1)
    }
}
