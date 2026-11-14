//
//  Item.swift
//  DailyHealth
//
//  Created by Олег Шуляков on 14.11.2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
