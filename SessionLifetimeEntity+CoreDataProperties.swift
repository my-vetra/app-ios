//
//  SessionLifetimeEntity+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-10.
//
//

import Foundation
import CoreData


extension SessionLifetimeEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<SessionLifetimeEntity> {
        return NSFetchRequest<SessionLifetimeEntity>(entityName: "SessionLifetimeEntity")
    }

    @NSManaged public var sessionId: UUID?
    @NSManaged public var userId: String?
    @NSManaged public var startedAt: Date?
    @NSManaged public var totalPuffsTaken: Int32
    @NSManaged public var phasesCompleted: Int16

}

extension SessionLifetimeEntity : Identifiable {

}
