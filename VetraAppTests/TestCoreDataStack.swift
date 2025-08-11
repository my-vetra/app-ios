import XCTest
import CoreData
@testable import VetraApp

final class TestCoreDataStack {
    let container: NSPersistentContainer
    lazy var viewContext: NSManagedObjectContext = {
        let viewContext = container.viewContext
        viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.undoManager = nil
        return viewContext
    }()
    lazy var writerContext: NSManagedObjectContext = {
        let writerContext = container.newBackgroundContext()
        writerContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        writerContext.automaticallyMergesChangesFromParent = true
        writerContext.undoManager = nil
        return writerContext
    }()

    init(testName: String = UUID().uuidString) {
        // Load model from the app bundle
        let appBundle = Bundle(for: BluetoothManager.self)
        guard let modelURL = appBundle.url(forResource: "VetraApp", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Could not load VetraApp.momd from app bundle")
        }

        container = NSPersistentContainer(name: "VetraApp", managedObjectModel: model)

        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        desc.configuration = nil
        desc.shouldAddStoreAsynchronously = false   // ← avoid async race in tests
        container.persistentStoreDescriptions = [desc]

        var loadError: Error?
        container.loadPersistentStores { _, err in loadError = err }
        XCTAssertNil(loadError)
    }
    
    func makeContext() -> NSManagedObjectContext {
        return viewContext
    }
    
    func makeBackgroundContext() -> NSManagedObjectContext {
        return writerContext
    }
}

import XCTest

extension XCTestCase {
    /// Wait one turn of the main queue so Combine .receive(on: .main) can deliver.
    func drainMain(timeout: TimeInterval = 1.0) {
        drain(DispatchQueue.main)
    }
    
    func drain(_ q: DispatchQueue, timeout: TimeInterval = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(description: "drain \(q)")
        q.async { exp.fulfill() }
        wait(for: [exp], timeout: timeout)
    }
}
