import XCTest
import CoreData
@testable import VetraApp

enum TestCoreDataStack {
    static func makeContainer() -> NSPersistentContainer {
        // Load the model from the app bundle
        let model = NSManagedObjectModel.mergedModel(from: [Bundle(for: Puff.self)])!
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
