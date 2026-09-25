import Foundation

struct EBallHistoryResponse: Decodable {
    let status: String
    let transactions: [EBallTransaction]?
    let message: String?
}

struct EBallTransaction: Decodable, Identifiable {
    let id: String
    let sender: PostAuthor?
    let recipient: PostAuthor?
    let amount: Double
    let fee: Double
    let type: String?
    let message: String?
    let date: String?
    let isIncoming: Bool
    let gift: EBallGift?
    let giftRecipient: PostAuthor?

    enum CodingKeys: String, CodingKey {
        case id
        case sender
        case recipient
        case amount
        case fee
        case type
        case message
        case date
        case isIncoming = "is_incoming"
        case gift
        case giftRecipient = "gift_recipient"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = UUID().uuidString
        }

        sender = (try? container.decode(PostAuthor.self, forKey: .sender))
        recipient = (try? container.decode(PostAuthor.self, forKey: .recipient))
        amount = Self.decodeDouble(container, key: .amount)
        fee = Self.decodeDouble(container, key: .fee)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        isIncoming = (try? container.decode(Bool.self, forKey: .isIncoming)) ?? false
        gift = (try? container.decode(EBallGift.self, forKey: .gift))
        giftRecipient = (try? container.decode(PostAuthor.self, forKey: .giftRecipient))
    }

    private static func decodeDouble(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Double {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let intValue = try? container.decode(Int.self, forKey: key) { return Double(intValue) }
        if let raw = try? container.decode(String.self, forKey: key) {
            let normalized = raw.replacingOccurrences(of: ",", with: ".")
            return Double(normalized) ?? 0
        }
        return 0
    }
}

struct EBallGift: Decodable {
    let id: Int?
    let name: String?
    let image: EBallGiftImage?
}

struct EBallGiftImage: Decodable {
    let preview: String?
}
