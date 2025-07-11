//
//  ActivePhase+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-11.
//
//

import Foundation
import CoreData


extension ActivePhase {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ActivePhase> {
        return NSFetchRequest<ActivePhase>(entityName: "ActivePhase")
    }

    @NSManaged public var phaseIndex: Int16
    @NSManaged public var phaseStartDate: Date?

}

extension ActivePhase : Identifiable {

}
