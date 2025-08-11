// MARK: - ActivePhaseRepositoryCoreData

import CoreData
import Combine

final class ActivePhaseRepositoryCoreData: ActivePhaseRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<ActivePhaseModel, Never>(
        ActivePhaseModel(phaseIndex: 0, phaseStartDate: Date())
    )
    private var saveObserver: AnyCancellable?
    private let saveEventsQueue = DispatchQueue(label: "ActivePhaseRepositoryCoreData.saveEvents")

    init(context: NSManagedObjectContext) {
        self.context = context
        loadFromStoreAndPublish()

        // Observe ALL saves, but:
        //  - ignore saves from THIS context
        //  - only react if ActivePhase changed
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
                      // only if the change set touches ActivePhase
                      self.noteTouchesActivePhase(note)
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
