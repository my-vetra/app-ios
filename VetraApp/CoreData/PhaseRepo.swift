// MARK: - PhaseRepositoryCoreData

import CoreData
import Combine

final class PhaseRepositoryCoreData: PhaseRepositoryProtocol {
    private let context: NSManagedObjectContext
    private let subject = CurrentValueSubject<[PhaseModel], Never>([])
    private let activeSubject = CurrentValueSubject<PhaseModel, Never>(
        .init(phaseIndex: 0, duration: 0, startDate: nil, maxPuffs: 0, puffs: [])
    )
    private var saveObserver: AnyCancellable?
    private let saveEventsQueue = DispatchQueue(label: "PhaseRepositoryCoreData.saveEvents")

    init(context: NSManagedObjectContext) {
        self.context = context
        context.perform{ self.loadFromStoreAndPublish() }

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

    func loadPhases() -> AnyPublisher<[PhaseModel], Never> { subject.eraseToAnyPublisher() }
    func loadActivePhase() -> AnyPublisher<PhaseModel, Never> { activeSubject.eraseToAnyPublisher() }

    private func loadFromStoreAndPublish() {
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
                startDate: phase.startDate,
                maxPuffs: Int(phase.maxPuffs),
                puffs: puffs
            )
        }
        DispatchQueue.main.async {
            self.subject.send(phases)
            print(phases)
            if let active = phases.reversed().first(where: { $0.startDate != nil }) {
                self.activeSubject.send(active)
            } else {        }
        }
    }
    
    func updatePhase(_ partialPhase: PartialPhaseModel, synchronously: Bool = false) {
        let work = {
            if let phaseEnt = self.fetchPhase(by: partialPhase.phaseIndex) {
                phaseEnt.startDate = partialPhase.phaseStartDate
                try? self.context.save()
                self.loadFromStoreAndPublish()
            }
        }
        synchronously ? context.performAndWait(work) : context.perform(work)
    }
    
    func updatePhases(_ partialPhases: [PartialPhaseModel], synchronously: Bool = false) {
        guard !partialPhases.isEmpty else { return }

        let work = {
            // Prefetch all Phase rows needed by this batch
            let needed = Set(partialPhases.map { $0.phaseIndex })
            let phaseLookup = self.fetchPhasesOnQueue(by: needed)

            for a in partialPhases {
                let phase = phaseLookup[a.phaseIndex] // nil if missing (by design)
                phase?.startDate = a.phaseStartDate
            }
            try? self.context.save()
            self.loadFromStoreAndPublish()
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
    
    func getActivePhaseIndex() -> Int {
        var result = 0
        context.performAndWait {
            let r: NSFetchRequest<Phase> = Phase.fetchRequest()
            r.includesPendingChanges = true
            r.predicate = NSPredicate(format: "%K != nil", #keyPath(Phase.startDate))
            r.sortDescriptors = [NSSortDescriptor(keyPath: \Phase.index, ascending: false)]
            r.fetchLimit = 1
            if let top = try? context.fetch(r).first {
                result = Int(top.index)
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
