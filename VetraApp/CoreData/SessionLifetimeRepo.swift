// MARK: - SessionLifetimeRepositoryCoreData

import CoreData
import Combine


final class SessionLifetimeRepositoryCoreData: SessionLifetimeRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<SessionLifetimeModel, Never>(
        .init(userId: "", allPhases: [], startedAt: Date(), totalPuffsTaken: 0, phasesCompleted: 0)
    )
    private var saveObserver: AnyCancellable?
    private let saveEventsQueue = DispatchQueue(label: "SessionLifetimeRepositoryCoreData.saveEvents")

    init(context: NSManagedObjectContext) {
        self.context = context
        loadFromStoreAndPublish()

        // Observe ALL saves, but:
        //  - ignore saves from THIS context
        //  - only react if Session/Puff/Phase changed
        //  - debounce bursts to avoid UI spam
        saveObserver = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave, object: nil)
            .compactMap { [weak self] note -> Notification? in
                guard let self = self,
                      let savingCtx = note.object as? NSManagedObjectContext,
                      // ignore our own saves entirely
                      savingCtx !== self.context,
                      // only merge from the same PSC
                      savingCtx.persistentStoreCoordinator === self.context.persistentStoreCoordinator,
                      // only if the change set touches Session/Puff/Phase
                      self.noteTouchesSessionOrPhaseOrPuff(note)
                else { return nil }
                return note
            }
            // coalesce rapid-fire saves from other contexts
            .debounce(for: .milliseconds(200), scheduler: saveEventsQueue)
            .sink { [weak self] note in
                guard let self = self else { return }
                self.context.perform {
                    // merge the latest external changes (safe even if we then refetch)
                    self.context.mergeChanges(fromContextDidSave: note)
                    // now produce fresh models
                    self.loadFromStoreAndPublish()
                }
            }
    }

    deinit { saveObserver?.cancel() }

    func loadSession() -> AnyPublisher<SessionLifetimeModel, Never> {
        subject.eraseToAnyPublisher()
    }

    private func loadFromStoreAndPublish() {
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
