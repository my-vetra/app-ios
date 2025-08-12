import SwiftUI
import Combine
import CoreData

// MARK: - Models (Pure Swift)
struct PuffModel: Identifiable {
    let puffNumber: Int
    let timestamp: Date
    let duration: TimeInterval
    let phaseIndex: Int
    var id: Int { puffNumber }
}

struct PhaseModel: Identifiable {
    let phaseIndex: Int
    let duration: TimeInterval
    let startDate: Date?
    let maxPuffs: Int
    var puffs: [PuffModel]
    var puffsTaken: Int { puffs.count }
    var id: Int { phaseIndex }
}

struct SessionLifetimeModel: Identifiable {
    let userId: String
    let allPhases: [PhaseModel]
    let startedAt: Date
    var totalPuffsTaken: Int
    var phasesCompleted: Int
    var id: String { userId }
}

struct PartialPhaseModel {
    var phaseIndex: Int
    var phaseStartDate: Date
}

// MARK: - Protocols
protocol PhaseRepositoryProtocol {
    func loadPhases() -> AnyPublisher<[PhaseModel], Never>
    func loadActivePhase() -> AnyPublisher<PhaseModel, Never>
    func updatePhase(_ activePhase: PartialPhaseModel, synchronously: Bool)
    func updatePhases(_ activePhases: [PartialPhaseModel], synchronously: Bool)
    func getActivePhaseIndex() -> Int
}
protocol SessionLifetimeRepositoryProtocol {
    func loadSession() -> AnyPublisher<SessionLifetimeModel, Never>
}
protocol ActivePhaseRepositoryProtocol {
    func loadActivePhase() -> AnyPublisher<PartialPhaseModel, Never>
    func saveActivePhase(_ active: PartialPhaseModel)
    func activePhaseIndex() -> Int   // -1 if none present
}
protocol PuffRepositoryProtocol {
    func loadPuffs() -> AnyPublisher<[PuffModel], Never>
    func addPuff(_ puff: PuffModel, synchronously: Bool)
    func addPuffs(_ puffs: [PuffModel], synchronously: Bool)
    func exists(puffNumber: Int) -> Bool
    func maxPuffNumber() -> Int
}
