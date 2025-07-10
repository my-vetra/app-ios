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
        let durations: [Double] = [60, 120, 90]
        let maxPuffs: [Int16] = [5, 4, 6]
        for idx in durations.indices {
            let phase = PhaseEntity(context: viewContext)
            phase.id = UUID()
            phase.index = Int16(idx)
            phase.duration = durations[idx]
            phase.maxPuffs = maxPuffs[idx]
        }

        // Seed mock SessionLifetime
        let session = SessionLifetimeEntity(context: viewContext)
        session.sessionId = UUID()
        session.userId = "preview-user"
        session.startedAt = Date()
        session.totalPuffsTaken = 10
        session.phasesCompleted = 1

        // Seed mock ActivePhase
        let active = ActivePhasesEntity(context: viewContext)
        active.phaseIndex = 1
        active.phaseStartDate = Date().addingTimeInterval(-30)
        active.puffsTaken = 2

        // Seed mock PuffEntries
        for i in 0..<3 {
            let puff = PuffEntryEntity(context: viewContext)
            puff.id = UUID()
            puff.timestamp = Date().addingTimeInterval(Double(-i * 10))
            puff.duration = 1.5
            puff.phaseIndex = Int16(i % durations.count)
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
