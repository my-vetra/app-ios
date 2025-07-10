//
//  ActivePhasesEntity+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-10.
//
//

import Foundation
import CoreData


extension ActivePhasesEntity {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ActivePhasesEntity> {
        return NSFetchRequest<ActivePhasesEntity>(entityName: "ActivePhasesEntity")
    }

    @NSManaged public var phaseIndex: Int16
    @NSManaged public var phaseStartDate: Date?
    @NSManaged public var puffsTaken: Int16

}

extension ActivePhasesEntity : Identifiable {

}
