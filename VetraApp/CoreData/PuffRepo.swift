// MARK: - PuffRepositoryCoreData

import SwiftUI
import Combine
import CoreData

final class PuffRepositoryCoreData: PuffRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<[PuffModel], Never>([])
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

    func loadPuffs() -> AnyPublisher<[PuffModel], Never> { subject.eraseToAnyPublisher() }

    private func loadFromStoreAndPublish() {
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
            // Prefetch all Phase rows needed by this batch
            let needed = Set(puffs.map { $0.phaseIndex })
            let phaseLookup = self.fetchPhasesOnQueue(by: needed)

            for p in puffs {
                let e = Puff(context: self.context)
                e.puffNumber = Int16(p.puffNumber)
                e.timestamp  = p.timestamp
                e.duration   = p.duration
                e.phase      = phaseLookup[p.phaseIndex]  // nil if missing (by design)
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
    
    private func fetchPhasesOnQueue(by indices: Set<Int>) -> [Int: Phase] {
        guard !indices.isEmpty else { return [:] }

        var dict: [Int: Phase] = [:]
        let r: NSFetchRequest<Phase> = Phase.fetchRequest()
        r.includesPendingChanges = true             // see unsaved inserts in this ctx
        r.returnsObjectsAsFaults = false            // we’re about to deref properties
        r.fetchBatchSize = 256
        let nums = indices.map { NSNumber(value: $0) } as NSArray
        r.predicate = NSPredicate(format: "index IN %@", nums)

        if let phases = try? context.fetch(r) {
            for ph in phases {
                dict[Int(ph.index)] = ph
            }
        }
        return dict
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
