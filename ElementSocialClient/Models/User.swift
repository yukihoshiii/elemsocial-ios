import Foundation

struct ProfileLink: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let url: String
}

struct User: Codable {
    let id: Int?
    let name: String?
    let username: String?
    let email: String?
    let description: String?
    let avatar: String?
    let cover: String?
    let eBalls: String?
    let messengerNotifications: Int?
    let notifications: Int?
    let goldStatus: Bool?
    let goldHistory: [GoldHistoryItem]?
    let channels: [ChannelSummary]?
    let createDate: String?
    let lastOnline: String?
    let permissions: UserPermissions?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case username
        case email
        case description
        case avatar
        case cover
        case eBalls = "e_balls"
        case messengerNotifications = "messenger_notifications"
        case notifications
        case goldStatus = "gold_status"
        case goldHistory = "gold_history"
        case channels
        case createDate = "create_date"
        case lastOnline = "last_online"
        case permissions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        avatar = UserFlexibleDecoding.stringOrJSON(from: container, forKey: .avatar)
        cover = UserFlexibleDecoding.stringOrJSON(from: container, forKey: .cover)
        eBalls = UserFlexibleDecoding.string(from: container, forKey: .eBalls)
        messengerNotifications = try container.decodeIfPresent(Int.self, forKey: .messengerNotifications)
        notifications = try container.decodeIfPresent(Int.self, forKey: .notifications)
        goldStatus = try container.decodeIfPresent(Bool.self, forKey: .goldStatus)
        goldHistory = try container.decodeIfPresent([GoldHistoryItem].self, forKey: .goldHistory)
        channels = try container.decodeIfPresent([ChannelSummary].self, forKey: .channels)
        createDate = UserFlexibleDecoding.string(from: container, forKey: .createDate)
        lastOnline = UserFlexibleDecoding.string(from: container, forKey: .lastOnline)
        permissions = try container.decodeIfPresent(UserPermissions.self, forKey: .permissions)
    }
}

struct ChannelSummary: Codable {
    let id: Int?
    let name: String?
    let username: String?
    let avatar: String?
    let cover: String?
    let description: String?
    let subscribers: Int?
    let posts: Int?
    let createDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case username
        case avatar
        case cover
        case description
        case subscribers
        case posts
        case createDate = "create_date"
    }

    init(
        id: Int?,
        name: String?,
        username: String?,
        avatar: String?,
        cover: String?,
        description: String?,
        subscribers: Int?,
        posts: Int?,
        createDate: String?
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.avatar = avatar
        self.cover = cover
        self.description = description
        self.subscribers = subscribers
        self.posts = posts
        self.createDate = createDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        avatar = UserFlexibleDecoding.stringOrJSON(from: container, forKey: .avatar)
        cover = UserFlexibleDecoding.stringOrJSON(from: container, forKey: .cover)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        subscribers = try container.decodeIfPresent(Int.self, forKey: .subscribers)
        posts = try container.decodeIfPresent(Int.self, forKey: .posts)
        createDate = UserFlexibleDecoding.string(from: container, forKey: .createDate)
    }
}

private enum UserFlexibleDecoding {
    static func stringOrJSON<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }
        guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else {
            return nil
        }
        guard let fragment = try? container.decode(AnyJSONFragment.self, forKey: key) else {
            return nil
        }
        return fragment.jsonString
    }

    static func string<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let intValue = try? container.decode(Int.self, forKey: key) {
            return String(intValue)
        }
        if let doubleValue = try? container.decode(Double.self, forKey: key) {
            return String(doubleValue)
        }
        return nil
    }
}

private struct AnyJSONFragment: Decodable {
    let jsonString: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            jsonString = trimmed
            return
        }
        if let int = try? container.decode(Int.self) {
            jsonString = String(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            jsonString = String(double)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            jsonString = bool ? "true" : "false"
            return
        }
        let value = try container.decode(AnyJSONValue.self)
        let data = try JSONSerialization.data(withJSONObject: value.object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to stringify JSON fragment")
        }
        jsonString = string
    }
}

private struct AnyJSONValue: Decodable {
    let object: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            object = value
            return
        }
        if let value = try? container.decode(Int.self) {
            object = value
            return
        }
        if let value = try? container.decode(Double.self) {
            object = value
            return
        }
        if let value = try? container.decode(String.self) {
            object = value
            return
        }
        if let value = try? container.decode([String: AnyJSONValue].self) {
            object = value.mapValues { $0.object }
            return
        }
        if let value = try? container.decode([AnyJSONValue].self) {
            object = value.map(\.object)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
}

struct GoldHistoryItem: Codable, Identifiable {
    let status: Int
    let date: String

    var id: String { "\(date)-\(status)" }
}

struct UserPermissions: Codable {
    let admin: Bool
    let comments: Bool
    let musicUpload: Bool
    let newChats: Bool
    let posts: Bool

    enum CodingKeys: String, CodingKey {
        case admin = "Admin"
        case comments = "Comments"
        case musicUpload = "MusicUpload"
        case newChats = "NewChats"
        case posts = "Posts"
    }
}

struct SocialNotification: Identifiable {
    let id: Int
    let author: PostAuthor?
    let action: String
    let content: SocialNotificationContent
    let viewed: Bool
    let date: String?
}

struct SocialNotificationContent {
    let postID: Int?
    let commentID: Int?
    let profileUsername: String?
    let commentText: String?
    let postText: String?
    let messageText: String?
    let authorName: String?
    let title: String?
    let subtype: String?
}

// MARK: - Blocked Users & Profile Media

struct BlockedUserItem: Identifiable, Equatable {
    let id: Int
    let target: PostAuthor
    let createdAt: String

    static func == (lhs: BlockedUserItem, rhs: BlockedUserItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.target.id == rhs.target.id &&
        lhs.target.username == rhs.target.username &&
        lhs.createdAt == rhs.createdAt
    }
}

struct ProfileMediaItem: Identifiable, Equatable {
    let id: String
    let postID: Int
    let image: MediaData

    init(id: String = UUID().uuidString, postID: Int, image: MediaData) {
        self.id = id
        self.postID = postID
        self.image = image
    }

    static func == (lhs: ProfileMediaItem, rhs: ProfileMediaItem) -> Bool {
        lhs.id == rhs.id && lhs.postID == rhs.postID && lhs.image == rhs.image
    }
}


