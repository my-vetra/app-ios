//
//  Persistence.swift
//  VetraApp
//
//  Core Data stack with background writer, lightweight migration,
//  and idempotent seeding with clamped ActivePhase.
//

import Foundation
import CoreData

final class PersistenceController {
    #if DEBUG
    static let shared = PersistenceController(inMemory: true)
    #else
    static let shared = PersistenceController()
    #endif

    // In-memory preview store with sample graph
    @MainActor
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let viewContext = controller.container.viewContext

        // Seed mock Phases
        let durations: [Double] = [20, 120, 90]
        let puffsTaken: [Int16] = [10, 6, 6]
        let maxPuffs: [Int16] = [10, 8, 6]

        // Seed mock SessionLifetime
        let session = SessionLifetime(context: viewContext)
        session.userId = "preview-user"
        session.startedAt = Date()
        session.totalPuffsTaken = 10
        session.phasesCompleted = 1

        var puffcounter: Int16 = 0
        for idx in durations.indices {
            let phase = Phase(context: viewContext)
            phase.index = Int16(idx)
            phase.duration = durations[idx]
            phase.puffsTaken = puffsTaken[idx]
            phase.maxPuffs = maxPuffs[idx]

            for _ in 0..<phase.puffsTaken {
                puffcounter += 1
                let puff = Puff(context: viewContext)
                puff.puffNumber = puffcounter
                puff.timestamp = Date().addingTimeInterval(Double(-puffcounter * 10))
                puff.duration = 1.5
                phase.addToPuff(puff)
            }
            session.addToPhases(phase)
        }

        // Seed mock ActivePhase
        let active = ActivePhase(context: viewContext)
        active.phaseIndex = 0
        active.phaseStartDate = Date()

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return controller
    }()

    let container: NSPersistentContainer

    /// Background writer context (use for writes; UI reads via viewContext)
    lazy var writerContext: NSManagedObjectContext = {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.automaticallyMergesChangesFromParent = true
        return ctx
    }()

    init(inMemory: Bool = false) {
        // Ensure the name matches your .xcdatamodeld filename
        container = NSPersistentContainer(name: "VetraApp")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        // Enable lightweight migration
        if let d = container.persistentStoreDescriptions.first {
            d.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            d.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }
        container.loadPersistentStores { _, error in
            if let error = error as NSError? { fatalError("Unresolved error \(error), \(error.userInfo)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Idempotently seeds Phases, SessionLifetime, and ActivePhase.
    /// - Parameters:
    ///   - phaseCount: how many phases to create if none exist
    ///   - defaultPhaseDuration: seconds per phase
    ///   - defaultMaxPuffs: max puffs per phase
    ///   - initialActivePhaseIndex: starting active phase index (will clamp to available range)
    ///   - userId: initial user id for SessionLifetime
    func seedInitialData(
        phaseCount: Int = 10,
        defaultPhaseDuration: TimeInterval = 120,
        defaultMaxPuffs: Int = 10,
        initialActivePhaseIndex: Int = 0,
        userId: String = "default-user"
    ) {
        let ctx = container.viewContext
        ctx.perform {
            // 1) Phases — create if none
            let phaseReq: NSFetchRequest<Phase> = Phase.fetchRequest()
            phaseReq.fetchLimit = 1
            let hasPhases = ((try? ctx.count(for: phaseReq)) ?? 0) > 0

            if !hasPhases {
                for i in 0..<phaseCount {
                    let p = Phase(context: ctx)
                    p.index    = Int16(i)
                    p.duration = defaultPhaseDuration
                    p.maxPuffs = Int16(defaultMaxPuffs)
                }
            }

            // 2) SessionLifetime — create once
            let sessionReq: NSFetchRequest<SessionLifetime> = SessionLifetime.fetchRequest()
            let session = (try? ctx.fetch(sessionReq).first) ?? {
                let s = SessionLifetime(context: ctx)
                s.userId = userId; s.startedAt = Date()
                s.totalPuffsTaken = 0; s.phasesCompleted = 0
                return s
            }()

            // attach phases to session if not already attached
            if (session.phases?.count ?? 0) == 0 {
                let allPhasesReq: NSFetchRequest<Phase> = Phase.fetchRequest()
                allPhasesReq.sortDescriptors = [NSSortDescriptor(keyPath: \Phase.index, ascending: true)]
                ((try? ctx.fetch(allPhasesReq)) ?? []).forEach { session.addToPhases($0) }
            }

            // 3) ActivePhase — keep existing index if present; otherwise use initialActivePhaseIndex (both clamped)
            let activeReq: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
            
            let existing: ActivePhase? = (try? ctx.fetch(activeReq))?.first
            let active = existing ?? ActivePhase(context: ctx)
            let isNew = (existing == nil)

            // clamp helper
            let totalPhases = (try? ctx.count(for: Phase.fetchRequest())) ?? phaseCount
            let clamp: (Int) -> Int16 = { i in
                Int16(min(max(0, i), max(0, totalPhases - 1)))
            }

            if active.phaseStartDate == nil {
                active.phaseStartDate = Date()
            }
            
            let desired = isNew ? initialActivePhaseIndex : Int(active.phaseIndex)
            let clamped = clamp(desired)
            if active.phaseIndex != clamped {
                active.phaseIndex = clamped
            }
            do {
                try ctx.save()
            } catch {
                let nsError = error as NSError
                assertionFailure("Seed save error: \(nsError), \(nsError.userInfo)")
            }
        }
    }
}
