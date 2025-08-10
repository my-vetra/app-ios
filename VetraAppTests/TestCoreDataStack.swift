import XCTest
import CoreData
@testable import VetraApp

enum TestCoreDataStack {
    static func makeContainer() -> NSPersistentContainer {
        // Use any class defined in the app target to get its bundle
        let appBundle = Bundle(for: BluetoothManager.self) // or Puff.self, Phase.self, etc.
        guard let modelURL = appBundle.url(forResource: "VetraApp", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Could not load VetraApp.momd from app bundle")
        }
        let container = NSPersistentContainer(name: "VetraApp", managedObjectModel: model)
        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError)
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container
    }

    static func makeContext() -> NSManagedObjectContext {
        makeContainer().viewContext
    }
}
