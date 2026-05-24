import Foundation
import SwiftData

@Model
final class PullRecord {
    var cardAPIID: String
    var setID: String
    var rarity: String
    var pulledAt: Date
    var packSessionID: UUID
    var isNew: Bool
    var slotIndex: Int

    init(
        cardAPIID: String,
        setID: String,
        rarity: String,
        pulledAt: Date = .now,
        packSessionID: UUID,
        isNew: Bool,
        slotIndex: Int
    ) {
        self.cardAPIID = cardAPIID
        self.setID = setID
        self.rarity = rarity
        self.pulledAt = pulledAt
        self.packSessionID = packSessionID
        self.isNew = isNew
        self.slotIndex = slotIndex
    }
}
