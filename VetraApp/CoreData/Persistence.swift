import SwiftUI
import Combine
import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

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
}
