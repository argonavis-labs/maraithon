import Foundation

struct CRMContactSnapshot: Equatable {
    let status: ContactStatus
    let dealStage: DealStage
    let lastContactedAt: Date?

    init(contact: CRMContact) {
        status = contact.status
        dealStage = contact.dealStage
        lastContactedAt = contact.lastContactedAt
    }

    func restore(to contact: CRMContact) {
        contact.status = status
        contact.dealStage = dealStage
        contact.lastContactedAt = lastContactedAt
    }
}

enum CRMQuickAction: Equatable {
    case markActive
    case logContact(Date)
    case archive

    var failurePrefix: String {
        switch self {
        case .markActive:
            "Could not mark this person active."
        case .logContact:
            "Could not save the contact history."
        case .archive:
            "Could not archive this person."
        }
    }

    func apply(to contact: CRMContact) {
        switch self {
        case .markActive:
            contact.status = .active
            if contact.dealStage == .lost {
                contact.dealStage = .qualified
            }

        case .logContact(let date):
            contact.status = .active
            contact.lastContactedAt = date
            if contact.dealStage == .lost {
                contact.dealStage = .qualified
            }

        case .archive:
            contact.status = .closed
            contact.dealStage = .lost
        }
    }
}
