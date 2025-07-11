//
//  Phase+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-11.
//
//

import Foundation
import CoreData


extension Phase {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Phase> {
        return NSFetchRequest<Phase>(entityName: "Phase")
    }

    @NSManaged public var duration: Double
    @NSManaged public var index: Int16
    @NSManaged public var maxPuffs: Int16
    @NSManaged public var puffsTaken: Int16
    @NSManaged public var sessionLifetime: SessionLifetime?
    @NSManaged public var puff: NSOrderedSet?

}

// MARK: Generated accessors for puff
extension Phase {

    @objc(insertObject:inPuffAtIndex:)
    @NSManaged public func insertIntoPuff(_ value: Puff, at idx: Int)

    @objc(removeObjectFromPuffAtIndex:)
    @NSManaged public func removeFromPuff(at idx: Int)

    @objc(insertPuff:atIndexes:)
    @NSManaged public func insertIntoPuff(_ values: [Puff], at indexes: NSIndexSet)

    @objc(removePuffAtIndexes:)
    @NSManaged public func removeFromPuff(at indexes: NSIndexSet)

    @objc(replaceObjectInPuffAtIndex:withObject:)
    @NSManaged public func replacePuff(at idx: Int, with value: Puff)

    @objc(replacePuffAtIndexes:withPuff:)
    @NSManaged public func replacePuff(at indexes: NSIndexSet, with values: [Puff])

    @objc(addPuffObject:)
    @NSManaged public func addToPuff(_ value: Puff)

    @objc(removePuffObject:)
    @NSManaged public func removeFromPuff(_ value: Puff)

    @objc(addPuff:)
    @NSManaged public func addToPuff(_ values: NSOrderedSet)

    @objc(removePuff:)
    @NSManaged public func removeFromPuff(_ values: NSOrderedSet)

}

extension Phase : Identifiable {

}
