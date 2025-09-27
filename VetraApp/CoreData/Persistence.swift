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
        phaseCount: Int = 21,
        defaultPhaseDuration: TimeInterval = 360,
        defaultMaxPuffs: Int = 3000,
        initialActivePhaseIndex: Int = 0,
        userId: String = "test-user"
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
//                let phaseRepo = PhaseRepositoryCoreData(context: self.writerContext) <- phase repo + context gets torn down before it can save
                let phaseRepo = PhaseRepositoryCoreData(context: ctx)
                phaseRepo.updatePhase(.init(phaseIndex:0, phaseStartDate: Date()), synchronously: true) // without sync: true - changes comes through but UI doesn't update
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
            
            do {
                try ctx.save()
            } catch {
                let nsError = error as NSError
                assertionFailure("Seed save error: \(nsError), \(nsError.userInfo)")
            }
        }
    }
}

//Failed to open URL App-Prefs:root=Bluetooth: Error Domain=FBSOpenApplicationServiceErrorDomain Code=4 "(null)" UserInfo={NSUnderlyingError=0x129024750 {Error Domain=FBSOpenApplicationErrorDomain Code=3 "Request is not trusted." UserInfo={BSErrorCodeDescription=Security, NSLocalizedFailureReason=Request is not trusted.}}, NSLocalizedFailure=The request to open "com.apple.Preferences" failed., FBSErrorContext=147937300, BSErrorCodeDescription=InvalidRequest}
