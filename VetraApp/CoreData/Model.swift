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

protocol PhaseRepositoryProtocol {
  func fetchPhases() -> AnyPublisher<[PhaseModel], Never>
}
protocol SessionLifetimeRepositoryProtocol {
  func loadSession() -> AnyPublisher<SessionLifetimeModel, Never>
}
protocol ActivePhaseRepositoryProtocol {
  func loadActivePhase() -> AnyPublisher<ActivePhaseModel, Never>
  func saveActivePhase(_ active: ActivePhaseModel)
}
protocol PuffRepositoryProtocol {
  func loadPuffs() -> AnyPublisher<[PuffModel], Never>
  func addPuff(_ puff: PuffModel)
}


// Shared Core Data context
let viewContext = PersistenceController.preview.container.viewContext

// MARK: - PhaseRepositoryCoreData

class PhaseRepositoryCoreData: PhaseRepositoryProtocol {
    func fetchPhases() -> AnyPublisher<[PhaseModel], Never> {
        Future { promise in
            let request: NSFetchRequest<Phase> = Phase.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Phase.index, ascending: true)]

            do {
                let phaseEntities = try viewContext.fetch(request)
                let phases: [PhaseModel] = phaseEntities.map { phase in
                    let puffs = (phase.puff?.array as? [Puff] ?? []).map { puff in
                        PuffModel(
                            puffNumber: Int(puff.puffNumber),
                            timestamp: puff.timestamp ?? Date(),
                            duration: puff.duration,
                            phaseIndex: Int(phase.index)
                        )
                    }

                    return PhaseModel(
                        phaseIndex: Int(phase.index),
                        duration: phase.duration,
                        maxPuffs: Int(phase.maxPuffs),
                        puffs: puffs
                    )
                }

                promise(.success(phases))
            } catch {
                print("Failed to fetch phases: \(error)")
                promise(.success([]))
            }
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - SessionLifetimeRepositoryCoreData

class SessionLifetimeRepositoryCoreData: SessionLifetimeRepositoryProtocol {
    func loadSession() -> AnyPublisher<SessionLifetimeModel, Never> {
        Future { promise in
            let request: NSFetchRequest<SessionLifetime> = SessionLifetime.fetchRequest()
            request.fetchLimit = 1

            do {
                guard let entity = try viewContext.fetch(request).first else {
                    promise(.success(.init(userId: "", allPhases: [], startedAt: Date(), totalPuffsTaken: 0, phasesCompleted: 0)))
                    return
                }

                let phaseEntities = (entity.phases?.array as? [Phase] ?? [])
                let phases: [PhaseModel] = phaseEntities.map { phase in
                    let puffs = (phase.puff?.array as? [Puff] ?? []).map { puff in
                        PuffModel(
                            puffNumber: Int(puff.puffNumber),
                            timestamp: puff.timestamp ?? Date(),
                            duration: puff.duration,
                            phaseIndex: Int(phase.index)
                        )
                    }

                    return PhaseModel(
                        phaseIndex: Int(phase.index),
                        duration: phase.duration,
                        maxPuffs: Int(phase.maxPuffs),
                        puffs: puffs
                    )
                }

                let model = SessionLifetimeModel(
                    userId: entity.userId ?? "",
                    allPhases: phases,
                    startedAt: entity.startedAt ?? Date(),
                    totalPuffsTaken: Int(entity.totalPuffsTaken),
                    phasesCompleted: Int(entity.phasesCompleted)
                )

                promise(.success(model))
            } catch {
                print("Failed to load session: \(error)")
                promise(.success(.init(userId: "", allPhases: [], startedAt: Date(), totalPuffsTaken: 0, phasesCompleted: 0)))
            }
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - ActivePhaseRepositoryCoreData

class ActivePhaseRepositoryCoreData: ActivePhaseRepositoryProtocol {
    private let subject = CurrentValueSubject<ActivePhaseModel, Never>(
        ActivePhaseModel(phaseIndex: 0, phaseStartDate: Date())
    )

    init() {
        loadFromStore()
    }

    private func loadFromStore() {
        let request: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
        request.fetchLimit = 1
        if let entity = try? viewContext.fetch(request).first {
            let model = ActivePhaseModel(
                phaseIndex: Int(entity.phaseIndex),
                phaseStartDate: entity.phaseStartDate ?? Date()
            )
            subject.send(model)
        }
    }

    func loadActivePhase() -> AnyPublisher<ActivePhaseModel, Never> {
        subject.eraseToAnyPublisher()
    }

    func saveActivePhase(_ active: ActivePhaseModel) {
        let request: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
        request.fetchLimit = 1
        let entity = (try? viewContext.fetch(request).first) ?? ActivePhase(context: viewContext)

        entity.phaseIndex = Int16(active.phaseIndex)
        entity.phaseStartDate = active.phaseStartDate

        try? viewContext.save()
        subject.send(active)
    }
}

// MARK: - PuffRepositoryCoreData

class PuffRepositoryCoreData: PuffRepositoryProtocol {
    private let subject = CurrentValueSubject<[PuffModel], Never>([])

    init() {
        loadAll()
    }

    private func loadAll() {
        let request: NSFetchRequest<Puff> = Puff.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Puff.timestamp, ascending: true)]

        if let entities = try? viewContext.fetch(request) {
            let puffs = entities.map { puff in
                return PuffModel(
                    puffNumber: Int(puff.puffNumber),
                    timestamp: puff.timestamp ?? Date(),
                    duration: puff.duration,
                    phaseIndex: Int(puff.phase?.index ?? 0)
                )
            }
            subject.send(puffs)
        }
    }

    func loadPuffs() -> AnyPublisher<[PuffModel], Never> {
        subject.eraseToAnyPublisher()
    }

    func addPuff(_ puff: PuffModel) {
        let entity = Puff(context: viewContext)
        entity.puffNumber = Int16(puff.puffNumber)
        entity.timestamp = puff.timestamp
        entity.duration = puff.duration
        
        if let phaseEnt = fetchPhase(by: puff.phaseIndex) {
            entity.phase = phaseEnt
        }

        try? viewContext.save()

        var current = subject.value
        current.append(puff)
        subject.send(current)
    }

    private func fetchPhase(by index: Int) -> Phase? {
        let request: NSFetchRequest<Phase> = Phase.fetchRequest()
        request.predicate = NSPredicate(format: "index == %d", index)
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first
    }
}
