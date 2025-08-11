// VetraApp.swift
import SwiftUI


@main
struct VetraApp: App {
    let persistence = PersistenceController.shared
    
    init() {
        persistence.seedInitialData()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(writerContextProvider: {persistence.writerContext})
                .environment(\.managedObjectContext, persistence.container.viewContext)
        }
    }
}
