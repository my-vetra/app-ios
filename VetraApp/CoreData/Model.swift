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

// MARK: - PhaseRepositoryCoreData

final class PhaseRepositoryCoreData: PhaseRepositoryProtocol {
    private let context: NSManagedObjectContext
    init(context: NSManagedObjectContext) { self.context = context }

    func fetchPhases() -> AnyPublisher<[PhaseModel], Never> {
        Future { promise in
            let request: NSFetchRequest<Phase> = Phase.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Phase.index, ascending: true)]

            do {
                let phaseEntities = try self.context.fetch(request)
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

final class SessionLifetimeRepositoryCoreData: SessionLifetimeRepositoryProtocol {
    private let context: NSManagedObjectContext
    init(context: NSManagedObjectContext) { self.context = context }

    func loadSession() -> AnyPublisher<SessionLifetimeModel, Never> {
        Future { promise in
            let request: NSFetchRequest<SessionLifetime> = SessionLifetime.fetchRequest()
            request.fetchLimit = 1

            do {
                guard let entity = try self.context.fetch(request).first else {
                    promise(.success(.init(userId: "", allPhases: [], startedAt: Date(),
                                           totalPuffsTaken: 0, phasesCompleted: 0)))
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
                promise(.success(.init(userId: "", allPhases: [], startedAt: Date(),
                                       totalPuffsTaken: 0, phasesCompleted: 0)))
            }
        }
        .eraseToAnyPublisher()
    }
}

// MARK: - ActivePhaseRepositoryCoreData

import CoreData
import Combine

final class ActivePhaseRepositoryCoreData: ActivePhaseRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<ActivePhaseModel, Never>(
        ActivePhaseModel(phaseIndex: 0, phaseStartDate: Date())
    )
    private var saveObserver: AnyCancellable?

    init(context: NSManagedObjectContext) {
        self.context = context
        // Initial load
        loadFromStoreAndPublish()

        // Observe ANY save on this context and republish if ActivePhase changed
        saveObserver = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave, object: nil)
            .compactMap { $0.object as? NSManagedObjectContext }
            .filter { [weak self] ctx in
                guard let self = self else { return false }
                return ctx.persistentStoreCoordinator === self.context.persistentStoreCoordinator
            }
            .sink { [weak self] noteCtx in
                guard let self else { return }
                self.loadFromStoreAndPublish() // touches check can be skipped now; it's cheap to reload 1 row
            }
    }

    deinit { saveObserver?.cancel() }

    func loadActivePhase() -> AnyPublisher<ActivePhaseModel, Never> {
        subject.eraseToAnyPublisher()
    }


    func saveActivePhase(_ active: ActivePhaseModel) {
        context.performAndWait {
            let req: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
            req.fetchLimit = 1
            let entity = (try? context.fetch(req).first) ?? ActivePhase(context: context)

            entity.phaseIndex = Int16(active.phaseIndex)
            entity.phaseStartDate = active.phaseStartDate

            try? context.save()

            // Immediate publish for anyone subscribed to THIS repo instance
            let model = ActivePhaseModel(
                phaseIndex: Int(entity.phaseIndex),
                phaseStartDate: entity.phaseStartDate ?? Date()
            )
            subject.send(model)
        }
    }

    // MARK: - Internals

    private func loadFromStoreAndPublish() {
        context.perform {
            let request: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
            request.fetchLimit = 1
            let model: ActivePhaseModel
            if let entity = try? self.context.fetch(request).first {
                model = ActivePhaseModel(
                    phaseIndex: Int(entity.phaseIndex),
                    phaseStartDate: entity.phaseStartDate ?? Date()
                )
            } else {
                model = ActivePhaseModel(phaseIndex: 0, phaseStartDate: Date())
            }
            DispatchQueue.main.async { self.subject.send(model) }
        }
    }

    private func noteTouchesActivePhase(_ note: Notification) -> Bool {
        func containsActivePhase(_ key: String) -> Bool {
            guard let set = note.userInfo?[key] as? Set<NSManagedObject> else { return false }
            return set.contains { $0 is ActivePhase }
        }
        return containsActivePhase(NSInsertedObjectsKey)
            || containsActivePhase(NSUpdatedObjectsKey)
            || containsActivePhase(NSDeletedObjectsKey)
    }
}


// MARK: - PuffRepositoryCoreData

final class PuffRepositoryCoreData: PuffRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<[PuffModel], Never>([])

    init(context: NSManagedObjectContext) {
        self.context = context
        loadAll()
    }

    private func loadAll() {
        let request: NSFetchRequest<Puff> = Puff.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Puff.timestamp, ascending: true)]

        if let entities = try? context.fetch(request) {
            let puffs = entities.map { puff in
                PuffModel(
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
        let entity = Puff(context: context)
        entity.puffNumber = Int16(puff.puffNumber)
        entity.timestamp = puff.timestamp
        entity.duration = puff.duration

        if let phaseEnt = fetchPhase(by: puff.phaseIndex) {
            entity.phase = phaseEnt
        }

        try? context.save()

        var current = subject.value
        current.append(puff)
        subject.send(current)
    }

    private func fetchPhase(by index: Int) -> Phase? {
        let request: NSFetchRequest<Phase> = Phase.fetchRequest()
        request.predicate = NSPredicate(format: "index == %d", index)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }
}

// MARK: - Helpers used by SyncBridge
extension PuffRepositoryCoreData {
    func exists(puffNumber: Int) -> Bool {
        let request: NSFetchRequest<Puff> = Puff.fetchRequest()
        request.predicate = NSPredicate(format: "puffNumber == %d", puffNumber)
        request.fetchLimit = 1
        return (try? context.fetch(request).isEmpty == false) ?? false
    }
    
    func maxPuffNumber() -> Int {
        let request: NSFetchRequest<Puff> = Puff.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "puffNumber", ascending: false)]
        request.fetchLimit = 1
        guard let top = try? context.fetch(request).first else { return 0 }
        return Int(top.puffNumber)
    }
    
    func addPuffs(_ puffs: [PuffModel]) {
        context.perform {
            for p in puffs {
                let e = Puff(context: self.context)
                e.puffNumber = Int16(p.puffNumber)
                e.timestamp  = p.timestamp
                e.duration   = p.duration
                if let phaseEnt = self.fetchPhase(by: p.phaseIndex) {
                    e.phase = phaseEnt
                }
            }
            try? self.context.save()
            // Observer will call reloadAll() once
        }
    }
}


private extension NSExpressionDescription {
    static var maxPuffNumber: NSExpressionDescription {
        let ed = NSExpressionDescription()
        ed.name = "maxPuffNumber"
        ed.expression = NSExpression(forFunction: "max:",
                                     arguments: [NSExpression(forKeyPath: "puffNumber")])
        ed.expressionResultType = .integer32AttributeType
        return ed
    }
}
