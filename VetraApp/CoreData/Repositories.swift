//// Repositories.swift
//import Foundation
//import Combine
//import CoreData
//
//// MARK: - Shared helper: detect if a save note touches a given entity type
//private extension Notification {
//    func touches<T: NSManagedObject>(_ type: T.Type) -> Bool {
//        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
//        for key in keys {
//            if let set = userInfo?[key] as? Set<NSManagedObject>,
//               set.contains(where: { $0 is T }) {
//                return true
//            }
//        }
//        return false
//    }
//}
//
//// MARK: - PhaseRepositoryCoreData (live-updating)
//final class PhaseRepositoryCoreData: PhaseRepositoryProtocol {
//    private let context: NSManagedObjectContext
//    private let subject = CurrentValueSubject<[PhaseModel], Never>([])
//    private var saveObserver: AnyCancellable?
//
//    init(context: NSManagedObjectContext) {
//        self.context = context
//        reload()
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: context)
//            .sink { [weak self] note in
//                guard let self else { return }
//                // phases list changes if Phase or Puff changed
//                if note.touches(Phase.self) || note.touches(Puff.self) {
//                    self.reload()
//                }
//            }
//    }
//
//    func fetchPhases() -> AnyPublisher<[PhaseModel], Never> {
//        subject.eraseToAnyPublisher()
//    }
//
//    private func reload() {
//        context.perform {
//            let req: NSFetchRequest<Phase> = Phase.fetchRequest()
//            req.sortDescriptors = [NSSortDescriptor(keyPath: \Phase.index, ascending: true)]
//            let models: [PhaseModel]
//            do {
//                let phases = try self.context.fetch(req)
//                models = phases.map { phase in
//                    let puffEntities = (phase.puff?.array as? [Puff] ?? [])
//                        .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
//                    let puffs = puffEntities.map { puff in
//                        PuffModel(
//                            puffNumber: Int(puff.puffNumber),
//                            timestamp: puff.timestamp ?? Date(),
//                            duration: puff.duration,
//                            phaseIndex: Int(phase.index)
//                        )
//                    }
//                    return PhaseModel(
//                        phaseIndex: Int(phase.index),
//                        duration: phase.duration,
//                        maxPuffs: Int(phase.maxPuffs),
//                        puffs: puffs
//                    )
//                }
//            } catch {
//                print("PhaseRepositoryCoreData.reload error: \(error)")
//                models = []
//            }
//            DispatchQueue.main.async { self.subject.send(models) }
//        }
//    }
//}
//
//// MARK: - SessionLifetimeRepositoryCoreData (live-updating)
//final class SessionLifetimeRepositoryCoreData: SessionLifetimeRepositoryProtocol {
//    private let context: NSManagedObjectContext
//    private let subject = CurrentValueSubject<SessionLifetimeModel, Never>(
//        SessionLifetimeModel(userId: "", allPhases: [], startedAt: Date(), totalPuffsTaken: 0, phasesCompleted: 0)
//    )
//    private var saveObserver: AnyCancellable?
//
//    init(context: NSManagedObjectContext) {
//        self.context = context
//        reload()
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: context)
//            .sink { [weak self] note in
//                guard let self else { return }
//                // session view depends on SessionLifetime + Phase + Puff
//                if note.touches(SessionLifetime.self) || note.touches(Phase.self) || note.touches(Puff.self) {
//                    self.reload()
//                }
//            }
//    }
//
//    func loadSession() -> AnyPublisher<SessionLifetimeModel, Never> {
//        subject.eraseToAnyPublisher()
//    }
//
//    private func reload() {
//        context.perform {
//            let req: NSFetchRequest<SessionLifetime> = SessionLifetime.fetchRequest()
//            req.fetchLimit = 1
//            let model: SessionLifetimeModel
//            do {
//                if let entity = try self.context.fetch(req).first {
//                    let phaseEntities = (entity.phases?.array as? [Phase] ?? [])
//                    let phases: [PhaseModel] = phaseEntities.map { phase in
//                        let puffEntities = (phase.puff?.array as? [Puff] ?? [])
//                        let puffs = puffEntities.map { puff in
//                            PuffModel(
//                                puffNumber: Int(puff.puffNumber),
//                                timestamp: puff.timestamp ?? Date(),
//                                duration: puff.duration,
//                                phaseIndex: Int(phase.index)
//                            )
//                        }
//                        return PhaseModel(
//                            phaseIndex: Int(phase.index),
//                            duration: phase.duration,
//                            maxPuffs: Int(phase.maxPuffs),
//                            puffs: puffs
//                        )
//                    }
//                    model = SessionLifetimeModel(
//                        userId: entity.userId ?? "",
//                        allPhases: phases,
//                        startedAt: entity.startedAt ?? Date(),
//                        totalPuffsTaken: Int(entity.totalPuffsTaken),
//                        phasesCompleted: Int(entity.phasesCompleted)
//                    )
//                } else {
//                    model = SessionLifetimeModel(userId: "", allPhases: [], startedAt: Date(), totalPuffsTaken: 0, phasesCompleted: 0)
//                }
//            } catch {
//                print("SessionLifetimeRepositoryCoreData.reload error: \(error)")
//                model = SessionLifetimeModel(userId: "", allPhases: [], startedAt: Date(), totalPuffsTaken: 0, phasesCompleted: 0)
//            }
//            DispatchQueue.main.async { self.subject.send(model) }
//        }
//    }
//}
//
//// MARK: - ActivePhaseRepositoryCoreData (live-updating)
//final class ActivePhaseRepositoryCoreData: ActivePhaseRepositoryProtocol {
//    private let context: NSManagedObjectContext
//    private let subject = CurrentValueSubject<ActivePhaseModel, Never>(
//        ActivePhaseModel(phaseIndex: 0, phaseStartDate: Date())
//    )
//    private var saveObserver: AnyCancellable?
//
//    init(context: NSManagedObjectContext) {
//        self.context = context
//        loadFromStoreAndPublish()
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: context)
//            .sink { [weak self] note in
//                guard let self else { return }
//                if note.touches(ActivePhase.self) {
//                    self.loadFromStoreAndPublish()
//                }
//            }
//    }
//
//    func loadActivePhase() -> AnyPublisher<ActivePhaseModel, Never> {
//        subject.eraseToAnyPublisher()
//    }
//
//    func saveActivePhase(_ active: ActivePhaseModel) {
//        context.perform {
//            let req: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
//            req.fetchLimit = 1
//            let entity = (try? self.context.fetch(req).first) ?? ActivePhase(context: self.context)
//            entity.phaseIndex = Int16(active.phaseIndex)
//            entity.phaseStartDate = active.phaseStartDate
//            try? self.context.save()
//            // DidSave observer will republish; doing it here too is optional.
//        }
//    }
//
//    private func loadFromStoreAndPublish() {
//        context.perform {
//            let req: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
//            req.fetchLimit = 1
//            let model: ActivePhaseModel
//            if let entity = try? self.context.fetch(req).first {
//                model = ActivePhaseModel(
//                    phaseIndex: Int(entity.phaseIndex),
//                    phaseStartDate: entity.phaseStartDate ?? Date()
//                )
//            } else {
//                model = ActivePhaseModel(phaseIndex: 0, phaseStartDate: Date())
//            }
//            DispatchQueue.main.async { self.subject.send(model) }
//        }
//    }
//}
//
//// MARK: - PuffRepositoryCoreData (live-updating)
//final class PuffRepositoryCoreData: PuffRepositoryProtocol {
//    private let context: NSManagedObjectContext
//    private let subject = CurrentValueSubject<[PuffModel], Never>([])
//    private var saveObserver: AnyCancellable?
//
//    init(context: NSManagedObjectContext) {
//        self.context = context
//        reloadAll()
//        saveObserver = NotificationCenter.default
//            .publisher(for: .NSManagedObjectContextDidSave, object: context)
//            .sink { [weak self] note in
//                guard let self else { return }
//                if note.touches(Puff.self) {
//                    self.reloadAll()
//                }
//            }
//    }
//
//    func loadPuffs() -> AnyPublisher<[PuffModel], Never> {
//        subject.eraseToAnyPublisher()
//    }
//
//    func addPuff(_ puff: PuffModel) {
//        context.perform {
//            let entity = Puff(context: self.context)
//            entity.puffNumber = Int16(puff.puffNumber)
//            entity.timestamp  = puff.timestamp
//            entity.duration   = puff.duration
//
//            if let phaseEnt = self.fetchPhase(by: puff.phaseIndex) {
//                entity.phase = phaseEnt
//            }
//            try? self.context.save()
//
//            // We can rely on DidSave to reload; optional immediate append:
//            // var current = self.subject.value
//            // current.append(puff)
//            // DispatchQueue.main.async { self.subject.send(current) }
//        }
//    }
//
//    // MARK: - Helpers used by SyncBridge
//    func exists(puffNumber: Int) -> Bool {
//        var result = false
//        context.performAndWait {
//            let req: NSFetchRequest<Puff> = Puff.fetchRequest()
//            req.predicate = NSPredicate(format: "puffNumber == %d", puffNumber)
//            req.fetchLimit = 1
//            result = (try? self.context.fetch(req).isEmpty == false) ?? false
//        }
//        return result
//    }
//
//    func maxPuffNumber() -> Int {
//        var maxVal = 0
//        context.performAndWait {
//            let req: NSFetchRequest<Puff> = Puff.fetchRequest()
//            req.sortDescriptors = [NSSortDescriptor(key: "puffNumber", ascending: false)]
//            req.fetchLimit = 1
//            if let top = try? self.context.fetch(req).first {
//                maxVal = Int(top.puffNumber)
//            }
//        }
//        return maxVal
//    }
//
//    // MARK: - Internal
//    private func reloadAll() {
//        context.perform {
//            let req: NSFetchRequest<Puff> = Puff.fetchRequest()
//            req.sortDescriptors = [NSSortDescriptor(keyPath: \Puff.timestamp, ascending: true)]
//            let models: [PuffModel]
//            if let entities = try? self.context.fetch(req) {
//                models = entities.map { puff in
//                    PuffModel(
//                        puffNumber: Int(puff.puffNumber),
//                        timestamp: puff.timestamp ?? Date(),
//                        duration: puff.duration,
//                        phaseIndex: Int(puff.phase?.index ?? 0)
//                    )
//                }
//            } else {
//                models = []
//            }
//            DispatchQueue.main.async { self.subject.send(models) }
//        }
//    }
//
//    private func fetchPhase(by index: Int) -> Phase? {
//        var result: Phase?
//        context.performAndWait {
//            let req: NSFetchRequest<Phase> = Phase.fetchRequest()
//            req.predicate = NSPredicate(format: "index == %d", index)
//            req.fetchLimit = 1
//            result = try? self.context.fetch(req).first
//        }
//        return result
//    }
//}
