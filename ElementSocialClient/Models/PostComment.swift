import Foundation

struct PostComment: Decodable, Identifiable {
    let serverID: Int?
    let text: String
    let createDate: String?
    let author: PostCommentAuthor
    let content: PostCommentContent?
    let replyToID: Int?
    let replyPreview: PostCommentReplyPreview?

    private let fallbackID: String

    var id: String {
        if let serverID {
            return "srv-\(serverID)"
        }
        return "tmp-\(fallbackID)"
    }

    init(
        serverID: Int?,
        text: String,
        createDate: String?,
        author: PostCommentAuthor,
        content: PostCommentContent? = nil,
        replyToID: Int? = nil,
        replyPreview: PostCommentReplyPreview? = nil
    ) {
        self.serverID = serverID
        self.text = text
        self.createDate = createDate
        self.author = author
        self.content = content
        self.replyToID = replyToID
        self.replyPreview = replyPreview
        self.fallbackID = UUID().uuidString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        let serverID = container.decodeInt(for: ["id", "cid", "comment_id"])
        let text = container.decodeString(for: ["text", "comment", "message"]) ?? ""
        let createDate = container.decodeString(for: ["create_date", "date"])
        let content = container.decodeDecodable(PostCommentContent.self, for: ["content"])
        let replyToIDRaw = container.decodeInt(for: ["reply_to", "reply_id", "parent_id", "target_comment_id", "reply_comment_id"])
        let replyPreviewRaw =
            container.decodeDecodable(PostCommentReplyPreview.self, for: ["reply", "reply_comment", "reply_to_comment", "target_comment", "parent_comment"])
        let replyPreview = replyPreviewRaw ?? content?.reply
        let replyToID = replyToIDRaw ?? replyPreview?.id

        let author: PostCommentAuthor
        if let nestedAuthor = container.decodeDecodable(PostCommentAuthor.self, for: ["author", "user", "from"]) {
            author = nestedAuthor
        } else {
            let fallbackName = container.decodeString(for: ["name", "author_name", "from_name"])
            let fallbackUsername = container.decodeString(for: ["username", "author_username", "from_username"])
            author = PostCommentAuthor(id: nil, name: fallbackName, username: fallbackUsername, avatarAura: nil)
        }

        self.serverID = serverID
        self.text = text
        self.createDate = createDate
        self.author = author
        self.content = content
        self.replyToID = replyToID
        self.replyPreview = replyPreview
        self.fallbackID = UUID().uuidString
    }
}

struct PostCommentContent: Decodable {
    let images: [PostCommentImage]?
    let videos: [PostVideo]?
    let files: [PostCommentFile]?
    let reply: PostCommentReplyPreview?
}

struct PostCommentImage: Decodable, Identifiable {
    let id = UUID()
    let fileName: String?
    let fileSize: Int?
    let imgData: MediaData?

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case fileSize = "file_size"
        case imgData = "img_data"
    }
}

struct PostCommentFile: Decodable, Identifiable {
    let id = UUID()
    let name: String?
    let size: Int?
    let file: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case file
    }
}

struct PostCommentAuthor: Decodable {
    let id: Int?
    let name: String?
    let username: String?
    let avatar: PostCommentAvatar?
    let avatarAura: String?
    let icons: [PostAuthorIcon]?
    let isVerified: Bool?
    let goldStatus: Bool?

    init(
        id: Int?,
        name: String?,
        username: String?,
        avatar: PostCommentAvatar? = nil,
        avatarAura: String?,
        icons: [PostAuthorIcon]? = nil,
        isVerified: Bool? = nil,
        goldStatus: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.avatar = avatar
        self.avatarAura = avatarAura
        self.icons = icons
        self.isVerified = isVerified
        self.goldStatus = goldStatus
    }

    var avatarMedia: MediaData? {
        guard let avatar else { return nil }
        return MediaData(
            file: avatar.file,
            path: avatar.path,
            preview: nil,
            simple: avatar.simple,
            aura: avatar.aura,
            storageFileID: avatar.storageFileID
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = container.decodeInt(for: ["id", "user_id"])
        name = container.decodeString(for: ["name", "display_name"])
        username = container.decodeString(for: ["username", "login"])
        avatar = container.decodeDecodable(PostCommentAvatar.self, for: ["avatar"])
        avatarAura = avatar?.aura
        icons = container.decodeDecodable([PostAuthorIcon].self, for: ["icons"])

        let verified = Self.decodeBool(from: container, keys: ["verified", "verify", "is_verified"])
        let gold = Self.decodeBool(from: container, keys: ["gold_status", "gold", "subscription", "is_gold", "premium"])
        let iconVerified = icons?.contains(where: { $0.isVerify }) ?? false
        let iconGold = icons?.contains(where: { $0.isGold }) ?? false
        isVerified = verified ?? (iconVerified ? true : nil)
        goldStatus = gold ?? (iconGold ? true : nil)
    }

    private static func decodeBool(
        from container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> Bool? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = try? container.decodeIfPresent(Bool.self, forKey: codingKey) {
                return value
            }
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: codingKey) {
                return intValue != 0
            }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: codingKey) {
                let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["1", "true", "yes"].contains(normalized) { return true }
                if ["0", "false", "no"].contains(normalized) { return false }
            }
        }
        return nil
    }
}

struct PostCommentAvatar: Decodable {
    let file: String?
    let path: String?
    let simple: String?
    let aura: String?
    let storageFileID: Int?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            file = container.decodeString(for: ["file", "name", "id"])
            path = container.decodeString(for: ["path"])
            simple = container.decodeString(for: ["simple"])
            aura = container.decodeString(for: ["aura"])
            storageFileID = container.decodeInt(for: ["file_id", "fileId", "storage_file_id"])
            return
        }

        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            file = raw
            path = nil
            simple = raw
            aura = nil
            storageFileID = nil
            return
        }

        file = nil
        path = nil
        simple = nil
        aura = nil
        storageFileID = nil
    }
}

struct PostCommentReplyPreview: Decodable {
    let id: Int?
    let text: String?
    let author: PostCommentAuthor?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = container.decodeInt(for: ["id", "comment_id", "cid"])
        text = container.decodeString(for: ["text", "comment", "message"])
        author = container.decodeDecodable(PostCommentAuthor.self, for: ["author", "user", "from"])
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == DynamicCodingKey {
    func decodeString(for keys: [String]) -> String? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = (try? decodeIfPresent(String.self, forKey: codingKey)) ?? nil {
                return value
            }
        }
        return nil
    }

    func decodeInt(for keys: [String]) -> Int? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }

            if let value = (try? decodeIfPresent(Int.self, forKey: codingKey)) ?? nil {
                return value
            }
            if let value = (try? decodeIfPresent(String.self, forKey: codingKey)) ?? nil,
               let parsed = Int(value) {
                return parsed
            }
        }
        return nil
    }

    func decodeDecodable<T: Decodable>(_ type: T.Type, for keys: [String]) -> T? {
        for key in keys {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            if let value = (try? decodeIfPresent(T.self, forKey: codingKey)) ?? nil {
                return value
            }
        }
        return nil
    }
}
