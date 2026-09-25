import Foundation

// MARK: - Referral program (web ReferralProgram.tsx)

struct ReferralDashboard {
    var refCode: String?
    var inviteLink: String?
    var totalInvited: Int = 0
    var rewarded: Int = 0
    var pending: Int = 0
    var totalEarned: Double = 0
    var invitedByUsername: String?
}

struct ReferralHistoryEntry: Identifiable {
    let id: Int
    let invitedName: String?
    let invitedUsername: String?
    let invitedAvatar: MediaData?
    let status: String
    let date: String
    let rewardAmount: Double?
}

// MARK: - My reports (web MyReports.tsx)

struct MyReportItem: Identifiable {
    let id: Int
    let category: String
    let status: String
    let message: String?
    let targetText: String?
    let targetUsername: String?
    let resolution: String?
    let moderatorName: String?
    let createdAt: String

    var statusColorRGB: (Double, Double, Double) {
        switch status {
        case "under_review": return (0.13, 0.59, 0.95)
        case "resolved": return (0.30, 0.69, 0.31)
        case "rejected": return (0.96, 0.26, 0.21)
        default: return (1.0, 0.60, 0.0) // pending
        }
    }

    var statusLabel: String {
        switch status {
        case "under_review": return "На рассмотрении"
        case "resolved": return "Решена"
        case "rejected": return "Отклонена"
        default: return "Ожидает рассмотрения"
        }
    }

    var categoryLabel: String {
        // Web `report_reasons.*` key set.
        switch category {
        case "spam": return "Спам"
        case "illegal_content": return "Незаконный контент"
        case "animal_cruelty": return "Жестокость к животным"
        case "child_porn": return "Контент с несовершеннолетними"
        case "weapon_sales": return "Продажа оружия"
        case "drug_sales": return "Продажа наркотиков"
        case "hate": return "Разжигание ненависти"
        case "nonsense": return "Флуд/бред"
        case "copyright": return "Нарушение авторских прав"
        case "personal_data_without_consent": return "Чужие персональные данные"
        case "other": return "Другое"
        default: return category
        }
    }
}

// MARK: - My appeals (web MyAppealsListModal)

struct MyAppealItem: Identifiable {
    let id: Int
    let restrictionType: String
    let reason: String
    let status: String
    let createdAt: String
    let reviewedAt: String?
    let response: String?

    var restrictionLabel: String {
        switch restrictionType {
        case "posts": return "Публикация постов"
        case "comments": return "Комментирование"
        case "chat": return "Чаты"
        case "music": return "Музыка"
        default: return restrictionType
        }
    }

    var statusLabel: String {
        switch status {
        case "under_review": return "На рассмотрении"
        case "approved": return "Одобрена"
        case "rejected": return "Отклонена"
        default: return "Ожидает рассмотрения"
        }
    }
}

// MARK: - Third-party apps (web Pages/Apps)

struct ThirdPartyApp: Identifiable {
    let id: Int
    let name: String
    let description: String?
    let url: String?
    let apiKey: String?
    let iconBase64: String?
}
