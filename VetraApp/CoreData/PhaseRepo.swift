// MARK: - PhaseRepositoryCoreData

import CoreData
import Combine

final class PhaseRepositoryCoreData: PhaseRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<[PhaseModel], Never>([])
    private var saveObserver: AnyCancellable?
    private let saveEventsQueue = DispatchQueue(label: "PuffRepositoryCoreData.saveEvents")

    init(context: NSManagedObjectContext) {
        self.context = context
        loadFromStoreAndPublish()

        // Observe ALL saves, but:
        //  - ignore saves from THIS context
        //  - only react if Puff/Phase changed
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
                      // only if the change set touches Puff/Phase
                      self.noteTouchesPuffOrPhase(note)
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

    func fetchPhases() -> AnyPublisher<[PhaseModel], Never> {
        subject.eraseToAnyPublisher()
    }

    private func loadFromStoreAndPublish() {
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

    private func noteTouchesPuffOrPhase(_ note: Notification) -> Bool {
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
