import Foundation
import SwiftData

@Model
final class CRMContact {
    @Attribute(.unique) var id: UUID
    var name: String
    var company: String
    var email: String
    var phone: String
    var statusRawValue: String
    var dealValue: Decimal
    var dealStageRawValue: String
    var lastContactedAt: Date?
    var notes: String
    var createdAt: Date
    var todos: [TodoItem] = []

    var status: ContactStatus {
        get { ContactStatus(rawValue: statusRawValue) ?? .lead }
        set { statusRawValue = newValue.rawValue }
    }

    var dealStage: DealStage {
        get { DealStage(rawValue: dealStageRawValue) ?? .prospect }
        set { dealStageRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        company: String,
        email: String,
        phone: String = "",
        status: ContactStatus = .lead,
        dealValue: Decimal = 0,
        dealStage: DealStage = .prospect,
        lastContactedAt: Date? = nil,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.company = company
        self.email = email
        self.phone = phone
        self.statusRawValue = status.rawValue
        self.dealValue = dealValue
        self.dealStageRawValue = dealStage.rawValue
        self.lastContactedAt = lastContactedAt
        self.notes = notes
        self.createdAt = createdAt
    }
}
