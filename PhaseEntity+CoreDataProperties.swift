//
//  PhaseEntity+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-10.
//
//

import Foundation
import CoreData


extension PhaseEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<PhaseEntity> {
        return NSFetchRequest<PhaseEntity>(entityName: "PhaseEntity")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var index: Int16
    @NSManaged public var duration: Double
    @NSManaged public var maxPuffs: Int16

}

extension PhaseEntity : Identifiable {

}
