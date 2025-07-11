//
//  Puff+CoreDataProperties.swift
//  VetraApp
//
//  Created by dpalanis on 2025-07-11.
//
//

import Foundation
import CoreData


extension Puff {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Puff> {
        return NSFetchRequest<Puff>(entityName: "Puff")
    }

    @NSManaged public var duration: Double
    @NSManaged public var timestamp: Date?
    @NSManaged public var puffNumber: Int16
    @NSManaged public var phase: Phase?

}

extension Puff : Identifiable {

}
