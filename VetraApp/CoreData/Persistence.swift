import SwiftUI
import Combine
import CoreData

struct PersistenceController {
    #if DEBUG
    static let shared = PersistenceController(inMemory: true)
    #else
    static let shared = PersistenceController()
    #endif


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
            for i in 0..<phase.puffsTaken {
                puffcounter+=1
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

    init(inMemory: Bool = false) {
        // Ensure the name matches your .xcdatamodeld filename
        container = NSPersistentContainer(name: "VetraApp")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
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
        initialActivePhaseIndex: Int = 1,
        userId: String = "default-user"
    ) {
        let ctx = container.viewContext
        ctx.perform {
            // 1) Phases — create if none
            let phaseReq: NSFetchRequest<Phase> = Phase.fetchRequest()
            phaseReq.fetchLimit = 1
            let hasPhases = ((try? ctx.count(for: phaseReq)) ?? 0) > 0
            
            let p = Phase(context: ctx)
            p.index = Int16(1)
            p.duration = defaultPhaseDuration
            p.maxPuffs = Int16(defaultMaxPuffs)

            if !hasPhases {
                for i in 2..<phaseCount {
                    let p = Phase(context: ctx)
                    p.index = Int16(i)
                    p.duration = defaultPhaseDuration
                    p.maxPuffs = Int16(defaultMaxPuffs)
                }
            }

            // 2) SessionLifetime — create if missing; ensure it references all phases
            let sessionReq: NSFetchRequest<SessionLifetime> = SessionLifetime.fetchRequest()
            sessionReq.fetchLimit = 1
            let session = (try? ctx.fetch(sessionReq).first) ?? {
                let s = SessionLifetime(context: ctx)
                s.userId = userId
                s.startedAt = Date()
                s.totalPuffsTaken = 0
                s.phasesCompleted = 0
                return s
            }()

            // attach phases to session if not already attached
            if (session.phases?.count ?? 0) == 0 {
                let allPhasesReq: NSFetchRequest<Phase> = Phase.fetchRequest()
                allPhasesReq.sortDescriptors = [NSSortDescriptor(keyPath: \Phase.index, ascending: true)]
                let allPhases = (try? ctx.fetch(allPhasesReq)) ?? []
                allPhases.forEach { session.addToPhases($0) }
            }

            // 3) ActivePhase — create/set to desired index if missing
            let activeReq: NSFetchRequest<ActivePhase> = ActivePhase.fetchRequest()
            activeReq.fetchLimit = 1
            let active = (try? ctx.fetch(activeReq).first) ?? {
                let a = ActivePhase(context: ctx)
                a.phaseIndex = 1
                a.phaseStartDate = Date()
                return a
            }()

            // clamp initial index into available range
            let maxIndex = max(0, (try? ctx.count(for: phaseReq)) ?? phaseCount) - 1
            let clamped = Int16(min(max(0, initialActivePhaseIndex), maxIndex))
            if active.phaseStartDate == nil { // only set on first seed
                active.phaseIndex = clamped
                active.phaseStartDate = Date()
            }

            if ctx.hasChanges {
                try? ctx.save()
            }
        }
    }
}
