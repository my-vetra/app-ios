//
//  cleanbreakApp.swift
//  cleanbreak
//
//  Created by user270007 on 2/9/25.
//

import SwiftUI

@main
struct VetraApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
