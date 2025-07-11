//
//  SessionLifetime+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-11.
//
//

import Foundation
import CoreData


extension SessionLifetime {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<SessionLifetime> {
        return NSFetchRequest<SessionLifetime>(entityName: "SessionLifetime")
    }

    @NSManaged public var phasesCompleted: Int16
    @NSManaged public var startedAt: Date?
    @NSManaged public var totalPuffsTaken: Int32
    @NSManaged public var userId: String?
    @NSManaged public var phases: NSOrderedSet?

}

// MARK: Generated accessors for phases
extension SessionLifetime {

    @objc(insertObject:inPhasesAtIndex:)
    @NSManaged public func insertIntoPhases(_ value: Phase, at idx: Int)

    @objc(removeObjectFromPhasesAtIndex:)
    @NSManaged public func removeFromPhases(at idx: Int)

    @objc(insertPhases:atIndexes:)
    @NSManaged public func insertIntoPhases(_ values: [Phase], at indexes: NSIndexSet)

    @objc(removePhasesAtIndexes:)
    @NSManaged public func removeFromPhases(at indexes: NSIndexSet)

    @objc(replaceObjectInPhasesAtIndex:withObject:)
    @NSManaged public func replacePhases(at idx: Int, with value: Phase)

    @objc(replacePhasesAtIndexes:withPhases:)
    @NSManaged public func replacePhases(at indexes: NSIndexSet, with values: [Phase])

    @objc(addPhasesObject:)
    @NSManaged public func addToPhases(_ value: Phase)

    @objc(removePhasesObject:)
    @NSManaged public func removeFromPhases(_ value: Phase)

    @objc(addPhases:)
    @NSManaged public func addToPhases(_ values: NSOrderedSet)

    @objc(removePhases:)
    @NSManaged public func removeFromPhases(_ values: NSOrderedSet)

}

extension SessionLifetime : Identifiable {

}
