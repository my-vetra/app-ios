// VetraApp.swift
import SwiftUI

@main
struct VetraApp: App {
    let persistenceController = PersistenceController.shared

    init() {
        persistenceController.seedInitialData()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
