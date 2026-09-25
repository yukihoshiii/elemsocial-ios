import Foundation

struct MessengerChatTarget: Hashable, Codable {
    let type: Int
    let id: Int

    var cacheKey: String { "t\(type)i\(id)" }
}

/// One chat row in the left list (`Chats.tsx` `ChatData`).
struct MessengerChatSummary: Identifiable {
    var id: String { target.cacheKey }
    let target: MessengerChatTarget
    let name: String
    let avatar: MediaData?
    var lastMessage: String
    var lastMessageDate: String
    var unreadCount: Int
}

struct MessengerGroupMember: Identifiable {
    let id: Int
    let name: String
    let avatar: MediaData?
}

/// Full data returned by `messenger/load_chat` (`selectedChat` in the web store).
struct MessengerActiveChat: Identifiable, Hashable, Equatable {
    var id: String { target.cacheKey }
    let target: MessengerChatTarget
    let name: String
    let username: String?
    let avatar: MediaData?
    let cover: MediaData?
    let description: String?
    let icons: [String]
    let type: Int
    var unreadCount: Int
    var isOnline: Bool
    var statusRaw: String?
    var membersCount: Int?
    var joinLink: String?
    var isOwner: Bool

    init(
        target: MessengerChatTarget,
        name: String,
        username: String? = nil,
        avatar: MediaData? = nil,
        cover: MediaData? = nil,
        description: String? = nil,
        icons: [String] = [],
        type: Int,
        unreadCount: Int = 0,
        isOnline: Bool = false,
        statusRaw: String? = nil,
        membersCount: Int? = nil,
        joinLink: String? = nil,
        isOwner: Bool = false
    ) {
        self.target = target
        self.name = name
        self.username = username
        self.avatar = avatar
        self.cover = cover
        self.description = description
        self.icons = icons
        self.type = type
        self.unreadCount = unreadCount
        self.isOnline = isOnline
        self.statusRaw = statusRaw
        self.membersCount = membersCount
        self.joinLink = joinLink
        self.isOwner = isOwner
    }

    static func == (lhs: MessengerActiveChat, rhs: MessengerActiveChat) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct MessengerMessageAuthor {
    let id: Int
    let name: String
    let avatar: MediaData?
}

/// Reaction entry — the new server format carries user objects.
struct MessengerReactionUser {
    let uid: Int
    let name: String
    let avatar: MediaData?
    let date: String?

    static func fallback(uid: Int) -> MessengerReactionUser {
        MessengerReactionUser(uid: uid, name: "...", avatar: nil, date: nil)
    }
}

struct MessengerReplyTo: Codable, Hashable {
    let mid: Int?
    let author: String?
    let text: String?
    let type: String?
}

/// Payload of `type: 'call'` service messages.
struct MessengerCallInfo: Hashable {
    let isMissed: Bool
    let isVideo: Bool
    let isGroup: Bool
    let duration: Double
}

/// Decrypted message payload (`decrypted` JSON on the web).
struct MessengerMessageContent: Hashable {
    let text: String
    let type: String
    let replyTo: MessengerReplyTo?
    let fileName: String?
    let fileSize: Int64?
    let mimeType: String?
    let previewBase64: String?
    let fileBase64: String?
    let fileMap: [Int]?
    let encryptedKey: String?
    let encryptedIV: String?
    let waveform: [Double]?
    let duration: Double?
    let isVideoCircle: Bool
    let thumbnailBase64: String?
    let isEdited: Bool
    let isError: Bool
    let call: MessengerCallInfo?

    init(
        text: String,
        type: String,
        replyTo: MessengerReplyTo? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        mimeType: String? = nil,
        previewBase64: String? = nil,
        fileBase64: String? = nil,
        fileMap: [Int]? = nil,
        encryptedKey: String? = nil,
        encryptedIV: String? = nil,
        waveform: [Double]? = nil,
        duration: Double? = nil,
        isVideoCircle: Bool = false,
        thumbnailBase64: String? = nil,
        isEdited: Bool = false,
        isError: Bool = false,
        call: MessengerCallInfo? = nil
    ) {
        self.text = text
        self.type = type
        self.replyTo = replyTo
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.previewBase64 = previewBase64
        self.fileBase64 = fileBase64
        self.fileMap = fileMap
        self.encryptedKey = encryptedKey
        self.encryptedIV = encryptedIV
        self.waveform = waveform
        self.duration = duration
        self.isVideoCircle = isVideoCircle
        self.thumbnailBase64 = thumbnailBase64
        self.isEdited = isEdited
        self.isError = isError
        self.call = call
    }

    /// Human readable preview used for replies and chat list rows.
    var replyPreviewText: String {
        switch type {
        case "voice": return text.isEmpty ? "Голосовое сообщение" : text
        case "video": return text.isEmpty ? "Видео сообщение" : text
        case "image": return text.isEmpty ? "Фото" : text
        case "file": return fileName ?? (text.isEmpty ? "Файл" : text)
        default: return text
        }
    }
}

struct MessengerMessage: Identifiable {
    let mid: Int?
    let tempMid: Int?
    /// Stable fallback identity for messages without mid/temp_mid yet.
    let localID = UUID().uuidString

    var id: String {
        if let mid { return "m-\(mid)" }
        if let tempMid { return "t-\(tempMid)" }
        return localID
    }
    let uid: Int
    let author: MessengerMessageAuthor?
    var content: MessengerMessageContent?
    let date: String
    let isOutgoing: Bool
    var status: String?
    var isRead: Bool
    var uploadProgress: Double?
    /// Progress of fetching the attachment from the server (0...100, -1 = error).
    var downloadProgress: Double?
    var reactions: [String: [MessengerReactionUser]]
    var localImageData: Data?
    /// Local file URL for voice/video attachments (already decrypted).
    var localFileURL: URL?
    var isListened: Bool

    init(
        mid: Int?,
        tempMid: Int?,
        uid: Int,
        author: MessengerMessageAuthor?,
        content: MessengerMessageContent?,
        date: String,
        isOutgoing: Bool,
        status: String? = nil,
        isRead: Bool = false,
        uploadProgress: Double? = nil,
        downloadProgress: Double? = nil,
        reactions: [String: [MessengerReactionUser]] = [:],
        localImageData: Data? = nil,
        localFileURL: URL? = nil,
        isListened: Bool = false
    ) {
        self.mid = mid
        self.tempMid = tempMid
        self.uid = uid
        self.author = author
        self.content = content
        self.date = date
        self.isOutgoing = isOutgoing
        self.status = status
        self.isRead = isRead
        self.uploadProgress = uploadProgress
        self.downloadProgress = downloadProgress
        self.reactions = reactions
        self.localImageData = localImageData
        self.localFileURL = localFileURL
        self.isListened = isListened
    }
}

/// All server → client messenger pushes (`useMessengerEvent(...)` counterparts).
enum MessengerPushKind {
    case newMessage(MessengerMessage, target: MessengerChatTarget)
    case messageEdited(mid: Int, target: MessengerChatTarget, content: MessengerMessageContent?, lastMessage: String?, lastMessageDate: String?)
    case messageDeleted(mid: Int, target: MessengerChatTarget, lastMessage: String?, lastMessageDate: String?)
    case messageReaction(mid: Int, target: MessengerChatTarget, emoji: String, uid: Int, name: String?, avatar: MediaData?, isRemove: Bool)
    case messagesRead(target: MessengerChatTarget)
    case typing(target: MessengerChatTarget, uid: Int, authorName: String?)
    case recordingVoice(target: MessengerChatTarget, uid: Int, authorName: String?, stop: Bool)
    case recordingVideoCircle(target: MessengerChatTarget, uid: Int, authorName: String?, stop: Bool)
    case sendMessageStatus(tempMid: Int, status: String, mid: Int?, errorText: String?)
    case uploadComplete(tempMid: Int, mid: Int, target: MessengerChatTarget)
    case reloadChats
}
