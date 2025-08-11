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

struct ActivePhaseModel {
    var phaseIndex: Int
    var phaseStartDate: Date
}

// MARK: - Protocols
protocol PhaseRepositoryProtocol {
  func fetchPhases() -> AnyPublisher<[PhaseModel], Never>
}
protocol SessionLifetimeRepositoryProtocol {
  func loadSession() -> AnyPublisher<SessionLifetimeModel, Never>
}
protocol ActivePhaseRepositoryProtocol {
  func loadActivePhase() -> AnyPublisher<ActivePhaseModel, Never>
  func saveActivePhase(_ active: ActivePhaseModel)
  func activePhaseIndex() -> Int   // -1 if none present
}
protocol PuffRepositoryProtocol {
    func loadPuffs() -> AnyPublisher<[PuffModel], Never>
    func maxPuffNumber() -> Int
    func addPuff(_ puff: PuffModel, synchronously: Bool)
    func addPuffs(_ puffs: [PuffModel], synchronously: Bool)
    func exists(puffNumber: Int) -> Bool
}
