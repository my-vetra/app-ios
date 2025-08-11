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

// MARK: - PhaseRepositoryCoreData

final class PhaseRepositoryCoreData: PhaseRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<[PhaseModel], Never>([])
    private var saveObserver: AnyCancellable?

    init(context: NSManagedObjectContext) {
        self.context = context
        reloadAll()

        // Observe ANY save in the same PSC, merge, then republish if Phase/Puff touched
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: nil)
//            .sink { [weak self] note in
//                guard let self = self,
//                      let savingCtx = note.object as? NSManagedObjectContext,
//                      savingCtx.persistentStoreCoordinator === self.context.persistentStoreCoordinator
//                else { return }
//                self.context.perform {
//                    self.context.mergeChanges(fromContextDidSave: note)
//                    if self.noteTouchesPhaseOrPuff(note) {
//                        self.reloadAll()
//                    }
//                }
//            }
        saveObserver = NotificationCenter.default
          .publisher(for: .NSManagedObjectContextDidSave, object: context) // not nil
          .sink { [weak self] note in
            guard let self = self else { return }
            self.context.perform {
              self.context.mergeChanges(fromContextDidSave: note)
              if self.noteTouchesPhaseOrPuff(note) {
                self.reloadAll()
              }
            }
          }
    }

    func fetchPhases() -> AnyPublisher<[PhaseModel], Never> {
        subject.eraseToAnyPublisher()
    }

    private func reloadAll() {
        context.perform {
            let request: NSFetchRequest<Phase> = Phase.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Phase.index, ascending: true)]
            request.relationshipKeyPathsForPrefetching = ["puff"]

            let phaseEntities: [Phase] = (try? self.context.fetch(request)) ?? []
            let phases: [PhaseModel] = phaseEntities.map { phase in
                // Ensure stable order for puffs
                let puffEntities = (phase.puff?.array as? [Puff] ?? []).sorted {
                    let at = $0.timestamp ?? .distantPast
                    let bt = $1.timestamp ?? .distantPast
                    return at == bt ? $0.puffNumber < $1.puffNumber : at < bt
                }
                let puffs = puffEntities.map { puff in
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
            DispatchQueue.main.async { self.subject.send(phases) }
        }
    }

    private func noteTouchesPhaseOrPuff(_ note: Notification) -> Bool {
        // Old (problematic) version:
        // func containsRelevant(_ key: String) -> Bool {
        //     guard let set = note.userInfo?[key] as? Set<NSManagedObject> else { return false }
        //     return set.contains { $0 is Phase || $0 is Puff }
        // }
        // return containsRelevant(NSInsertedObjectsKey)
        //     || containsRelevant(NSUpdatedObjectsKey)
        //     || containsRelevant(NSDeletedObjectsKey)

        // Hardened version: safely read NSSet and inspect entity names
        guard let ui = note.userInfo else { return false }
        for k in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            guard let nsset = ui[k] as? NSSet, nsset.count > 0 else { continue }
            for case let mo as NSManagedObject in nsset {
                if let name = mo.entity.name, name == "Phase" || name == "Puff" {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - SessionLifetimeRepositoryCoreData

final class SessionLifetimeRepositoryCoreData: SessionLifetimeRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<SessionLifetimeModel, Never>(
        .init(userId: "", allPhases: [], startedAt: Date(), totalPuffsTaken: 0, phasesCompleted: 0)
    )
    private var saveObserver: AnyCancellable?

    init(context: NSManagedObjectContext) {
        self.context = context
        reload()

        // Observe ANY save in PSC, merge, then republish if relevant entities touched
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: nil)
//            .sink { [weak self] note in
//                guard let self = self,
//                      let savingCtx = note.object as? NSManagedObjectContext,
//                      savingCtx.persistentStoreCoordinator === self.context.persistentStoreCoordinator
//                else { return }
//                self.context.perform {
//                    self.context.mergeChanges(fromContextDidSave: note)
//                    if self.noteTouchesSessionOrPhaseOrPuff(note) {
//                        self.reload()
//                    }
//                }
//            }
        saveObserver = NotificationCenter.default
          .publisher(for: .NSManagedObjectContextDidSave, object: context) // not nil
          .sink { [weak self] note in
            guard let self = self else { return }
            self.context.perform {
              self.context.mergeChanges(fromContextDidSave: note)
              if self.noteTouchesSessionOrPhaseOrPuff(note) {
                self.reload()
              }
            }
          }
    }

    func loadSession() -> AnyPublisher<SessionLifetimeModel, Never> {
        subject.eraseToAnyPublisher()
    }

    private func reload() {
        context.perform {
            let request: NSFetchRequest<SessionLifetime> = SessionLifetime.fetchRequest()
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["phases", "phases.puff"]

            guard let entity = try? self.context.fetch(request).first else {
                DispatchQueue.main.async {
                    self.subject.send(.init(userId: "", allPhases: [], startedAt: Date(),
                                            totalPuffsTaken: 0, phasesCompleted: 0))
                }
                return
            }

            let phaseEntities = (entity.phases?.array as? [Phase] ?? [])
            let phases: [PhaseModel] = phaseEntities.map { phase in
                let puffEntities = (phase.puff?.array as? [Puff] ?? []).sorted {
                    let at = $0.timestamp ?? .distantPast
                    let bt = $1.timestamp ?? .distantPast
                    return at == bt ? $0.puffNumber < $1.puffNumber : at < bt
                }
                let puffs = puffEntities.map { puff in
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

            DispatchQueue.main.async { self.subject.send(model) }
        }
    }

    private func noteTouchesSessionOrPhaseOrPuff(_ note: Notification) -> Bool {
        // Old (problematic) version:
        // func containsRelevant(_ key: String) -> Bool {
        //     guard let set = note.userInfo?[key] as? Set<NSManagedObject> else { return false }
        //     return set.contains { $0 is SessionLifetime || $0 is Phase || $0 is Puff }
        // }
        // return containsRelevant(NSInsertedObjectsKey)
        //     || containsRelevant(NSUpdatedObjectsKey)
        //     || containsRelevant(NSDeletedObjectsKey)

        // Hardened version: safely read NSSet and inspect entity names
        guard let ui = note.userInfo else { return false }
        for k in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            guard let nsset = ui[k] as? NSSet, nsset.count > 0 else { continue }
            for case let mo as NSManagedObject in nsset {
                if let name = mo.entity.name,
                   name == "SessionLifetime" || name == "Phase" || name == "Puff" {
                    return true
                }
            }
        }
        return false
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

        // Observe ANY save in PSC; merge, filter, then reload one row
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: nil)
//            .sink { [weak self] note in
//                guard let self = self,
//                      let savingCtx = note.object as? NSManagedObjectContext,
//                      savingCtx.persistentStoreCoordinator === self.context.persistentStoreCoordinator
//                else { return }
//                self.context.perform {
//                    self.context.mergeChanges(fromContextDidSave: note)
//                    if self.noteTouchesActivePhase(note) {
//                        self.loadFromStoreAndPublish()
//                    }
//                }
//            }
        saveObserver = NotificationCenter.default
          .publisher(for: .NSManagedObjectContextDidSave, object: context) // not nil
          .sink { [weak self] note in
            guard let self = self else { return }
            self.context.perform {
              self.context.mergeChanges(fromContextDidSave: note)
              if self.noteTouchesActivePhase(note) {
                self.loadFromStoreAndPublish()
              }
            }
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
            DispatchQueue.main.async { self.subject.send(model) }
        }
    }
    
    func activePhaseIndex() -> Int {
        var result = -1
        context.performAndWait {
            let req: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
            req.fetchLimit = 1
            if let entity = try? context.fetch(req).first {
                result = Int(entity.phaseIndex)
            }
        }
        return result
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
        // Old (problematic) version:
        // func containsActivePhase(_ key: String) -> Bool {
        //     guard let set = note.userInfo?[key] as? Set<NSManagedObject> else { return false }
        //     return set.contains { $0 is ActivePhase }
        // }
        // return containsActivePhase(NSInsertedObjectsKey)
        //     || containsActivePhase(NSUpdatedObjectsKey)
        //     || containsActivePhase(NSDeletedObjectsKey)

        // Hardened version: safely read NSSet and inspect entity names
        guard let ui = note.userInfo else { return false }
        for k in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            guard let nsset = ui[k] as? NSSet, nsset.count > 0 else { continue }
            for case let mo as NSManagedObject in nsset {
                if let name = mo.entity.name, name == "ActivePhase" {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - PuffRepositoryCoreData

final class PuffRepositoryCoreData: PuffRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<[PuffModel], Never>([])
    private var saveObserver: AnyCancellable?

    init(context: NSManagedObjectContext) {
        self.context = context
        reloadAll()

        // Observe ANY save in PSC; merge and reload if Puff (or Phase index) changed
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: nil)
//            .sink { [weak self] note in
//                guard let self = self,
//                      let savingCtx = note.object as? NSManagedObjectContext,
//                      savingCtx.persistentStoreCoordinator === self.context.persistentStoreCoordinator
//                else { return }
//                self.context.perform {
//                    self.context.mergeChanges(fromContextDidSave: note)
//                    if self.noteTouchesPuffOrPhase(note) {
//                        self.reloadAll()
//                    }
//                }
//            }
        saveObserver = NotificationCenter.default
          .publisher(for: .NSManagedObjectContextDidSave, object: context) // not nil
          .sink { [weak self] note in
            guard let self = self else { return }
            self.context.perform {
              self.context.mergeChanges(fromContextDidSave: note)
              if self.noteTouchesPuffOrPhase(note) {
                self.reloadAll()
              }
            }
          }
    }

    func loadPuffs() -> AnyPublisher<[PuffModel], Never> { subject.eraseToAnyPublisher() }

    private func reloadAll() {
        context.perform {
            let req: NSFetchRequest<Puff> = Puff.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(keyPath: \Puff.timestamp, ascending: true)]
            let models: [PuffModel] = (try? self.context.fetch(req))?.map {
                PuffModel(
                    puffNumber: Int($0.puffNumber),
                    timestamp: $0.timestamp ?? Date(),
                    duration:  $0.duration,
                    // ⚠️ relies on relationship; ensure Phase rows exist
                    phaseIndex: Int($0.phase?.index ?? 0)
                )
            } ?? []
            DispatchQueue.main.async { self.subject.send(models) }
        }
    }

    func addPuff(_ puff: PuffModel, synchronously: Bool = false) {
        let work = {
            let e = Puff(context: self.context)
            e.puffNumber = Int16(puff.puffNumber)
            e.timestamp  = puff.timestamp
            e.duration   = puff.duration
            if let phaseEnt = self.fetchPhase(by: puff.phaseIndex) { e.phase = phaseEnt }
            try? self.context.save()
        }
        synchronously ? context.performAndWait(work) : context.perform(work)
    }

    func addPuffs(_ puffs: [PuffModel], synchronously: Bool = false) {
        guard !puffs.isEmpty else { return }
        let work = {
            for p in puffs {
                let e = Puff(context: self.context)
                e.puffNumber = Int16(p.puffNumber)
                e.timestamp  = p.timestamp
                e.duration   = p.duration
                if let phaseEnt = self.fetchPhase(by: p.phaseIndex) { e.phase = phaseEnt }
            }
            try? self.context.save()
        }
        synchronously ? context.performAndWait(work) : context.perform(work)
    }

    private func fetchPhase(by index: Int) -> Phase? {
        var res: Phase?
        context.performAndWait {
            let r: NSFetchRequest<Phase> = Phase.fetchRequest()
            r.predicate = NSPredicate(format: "index == %d", index)
            r.fetchLimit = 1
            res = try? self.context.fetch(r).first
        }
        return res
    }

    func exists(puffNumber: Int) -> Bool {
        var result = false
        context.performAndWait {
            let request: NSFetchRequest<Puff> = Puff.fetchRequest()
            request.predicate = NSPredicate(format: "puffNumber == %d", puffNumber)
            request.fetchLimit = 1
            result = (try? self.context.fetch(request).isEmpty == false) ?? false
        }
        return result
    }

    func maxPuffNumber() -> Int {
        var result = 0
        context.performAndWait {
            let r: NSFetchRequest<Puff> = Puff.fetchRequest()
            r.includesPendingChanges = true
            r.sortDescriptors = [NSSortDescriptor(keyPath: \Puff.puffNumber, ascending: false)]
            r.fetchLimit = 1
            if let top = try? context.fetch(r).first {
                result = Int(top.puffNumber)
            }
        }
        return result
    }

    private func noteTouchesPuffOrPhase(_ note: Notification) -> Bool {
        // Already hardened version
        guard let ui = note.userInfo else { return false }
        for k in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            guard let nsset = ui[k] as? NSSet, nsset.count > 0 else { continue }
            for case let mo as NSManagedObject in nsset {
                if let name = mo.entity.name, name == "Puff" || name == "Phase" {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - NSExpressionDescription helper

//private extension NSExpressionDescription {
//    static var maxPuffNumber: NSExpressionDescription {
//        let ed = NSExpressionDescription()
//        ed.name = "maxPuffNumber"
//        // Use KVC collection operator so in-memory evaluation is safe
//        ed.expression = NSExpression(forKeyPath: "@max.puffNumber")
//        ed.expressionResultType = .integer64AttributeType // safer than 32
//        return ed
//    }
//}
