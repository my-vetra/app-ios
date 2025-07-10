//
//  PuffEntryEntity+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-10.
//
//

import Foundation
import CoreData


extension PuffEntryEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<PuffEntryEntity> {
        return NSFetchRequest<PuffEntryEntity>(entityName: "PuffEntryEntity")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var timestamp: Date?
    @NSManaged public var duration: Double
    @NSManaged public var phaseIndex: Int16

}

extension PuffEntryEntity : Identifiable {

}
