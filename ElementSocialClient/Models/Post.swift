import Foundation

enum SearchCategory: String {
    case all
    case users
    case posts
    case music
}

struct SearchPost: Identifiable {
    let id: Int
    let author: PostAuthor
    let text: String?
    let createDate: String?
}

struct SearchResults {
    let users: [PostAuthor]
    let posts: [SearchPost]
    let songs: [MusicSong]

    static let empty = SearchResults(users: [], posts: [], songs: [])
}

struct AccountExportItem: Identifiable {
    let id = UUID()
    let name: String
    let size: Int?
}

struct GiftItem: Identifiable {
    let id: Int
    let giftID: Int?
    let name: String
    let description: String?
    let price: Double?
    let image: MediaData?
    let quantity: Int?
    let sender: PostAuthor?
    let message: String?
    let isHidden: Bool
    let date: String?
}

struct Post: Decodable, Identifiable {
    let id: Int
    var text: String?
    var createDate: String?
    var editedAt: String?
    let author: PostAuthor
    var poll: PostPoll? = nil
    var content: PostContent?
    var likes: Int? = nil
    var liked: Bool? = nil
    var dislikes: Int? = nil
    var dislikesCount: Int? = nil
    var disliked: Bool? = nil
    var comments: Int? = nil
    var myPost: Bool? = nil
    var deleted: Bool? = nil
    var archived: Bool? = nil
    var reactions: PostReactions? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case createDate = "create_date"
        case editedAt = "edited_at"
        case author
        case poll
        case content
        case likes
        case liked
        case dislikes
        case dislikesCount = "dislikes_count"
        case disliked
        case comments
        case myPost = "my_post"
        case deleted
        case archived
        case reactions
    }
}

struct PostReactions: Codable, Equatable {
    var results: [String: Int]
    var userReactions: [PostUserReaction]

    var activeReaction: String? {
        userReactions.first(where: { !$0.reaction.isEmpty })?.reaction
    }

    enum CodingKeys: String, CodingKey {
        case results
        case userReactions = "user_reactions"
    }
}

struct PostUserReaction: Codable, Equatable {
    let reaction: String
}

extension Post {
    var displayReactions: PostReactions {
        if let reactions {
            return reactions
        }

        var results: [String: Int] = [:]
        if let likes, likes > 0 {
            results["1F44D"] = likes
        }
        let dislikeCount = dislikes ?? dislikesCount ?? 0
        if dislikeCount > 0 {
            results["1F494"] = dislikeCount
        }

        var userReactions: [PostUserReaction] = []
        if liked == true {
            userReactions.append(PostUserReaction(reaction: "1F44D"))
        } else if disliked == true {
            userReactions.append(PostUserReaction(reaction: "1F494"))
        }

        return PostReactions(results: results, userReactions: userReactions)
    }

    mutating func toggleReaction(_ reaction: String) -> Bool {
        var next = displayReactions
        let normalized = reaction.uppercased()
        let current = next.activeReaction?.uppercased()
        let isRemoving = current == normalized

        if let current {
            let count = max(0, (next.results[current] ?? 0) - 1)
            if count > 0 {
                next.results[current] = count
            } else {
                next.results.removeValue(forKey: current)
            }
        }

        if isRemoving {
            next.userReactions = []
        } else {
            next.userReactions = [PostUserReaction(reaction: normalized)]
            next.results[normalized] = (next.results[normalized] ?? 0) + 1
        }

        reactions = next
        liked = next.activeReaction?.uppercased() == "1F44D"
        disliked = next.activeReaction?.uppercased() == "1F494"
        likes = next.results["1F44D"]
        dislikes = next.results["1F494"]
        dislikesCount = next.results["1F494"]
        return isRemoving
    }
}

struct PostPollDraft: Equatable {
    let question: String
    let options: [String]
    let isAnonymous: Bool
    let multipleChoice: Bool

    var normalizedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedOptions: [String] {
        options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isValid: Bool {
        normalizedOptions.count >= 2
    }
}

struct PostPoll: Decodable {
    let id: Int
    let question: String
    let isAnonymous: Bool
    let multipleChoice: Bool
    let expiresAt: String?
    let totalVotes: Int
    let userVote: [Int]
    let options: [PostPollOption]

    enum CodingKeys: String, CodingKey {
        case id
        case question
        case isAnonymous = "is_anonymous"
        case multipleChoice = "multiple_choice"
        case expiresAt = "expires_at"
        case totalVotes = "total_votes"
        case userVote = "user_vote"
        case options
    }
}

struct PostPollOption: Decodable, Identifiable {
    let id: Int
    let text: String
    let votesCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case votesCount = "votes_count"
    }
}

struct PostAuthor: Decodable {
    let id: Int?
    let type: Int?
    let name: String?
    let username: String?
    let avatar: PostAuthorAvatar?
    let icons: [PostAuthorIcon]?
    let isVerified: Bool?
    let goldStatus: Bool?

    init(
        id: Int?,
        type: Int?,
        name: String?,
        username: String?,
        avatar: PostAuthorAvatar? = nil,
        icons: [PostAuthorIcon]? = nil,
        isVerified: Bool? = nil,
        goldStatus: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.username = username
        self.avatar = avatar
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

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case name
        case username
        case avatar
        case icons
        case verified
        case verify
        case isVerified = "is_verified"
        case goldStatus = "gold_status"
        case gold
        case subscription
        case isGold = "is_gold"
        case premium
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        type = try container.decodeIfPresent(Int.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        avatar = try container.decodeIfPresent(PostAuthorAvatar.self, forKey: .avatar)
        icons = try container.decodeIfPresent([PostAuthorIcon].self, forKey: .icons)
        let verified = Self.decodeBool(from: container, keys: [.verified, .verify, .isVerified])
        let gold = Self.decodeBool(from: container, keys: [.goldStatus, .gold, .subscription, .isGold, .premium])
        let iconVerified = icons?.contains(where: { $0.isVerify }) ?? false
        let iconGold = icons?.contains(where: { $0.isGold }) ?? false
        isVerified = verified ?? (iconVerified ? true : nil)
        goldStatus = gold ?? (iconGold ? true : nil)
    }

    private static func decodeBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Bool? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return intValue != 0
            }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["1", "true", "yes"].contains(normalized) { return true }
                if ["0", "false", "no"].contains(normalized) { return false }
            }
        }
        return nil
    }
}

struct PostAuthorIcon: Decodable {
    let iconId: String?

    enum CodingKeys: String, CodingKey {
        case iconId = "icon_id"
    }

    var isGold: Bool {
        iconId?.uppercased() == "GOLD"
    }

    var isVerify: Bool {
        iconId?.uppercased() == "VERIFY"
    }
}

struct PostAuthorAvatar: Codable {
    let file: String?
    let path: String?
    let simple: String?
    let aura: String?
    let storageFileID: Int?

    enum CodingKeys: String, CodingKey {
        case file
        case path
        case simple
        case aura
        case fileId = "file_id"
    }

    init(file: String?, path: String?, simple: String?, aura: String?, storageFileID: Int? = nil) {
        self.file = file
        self.path = path
        self.simple = simple
        self.aura = aura
        self.storageFileID = storageFileID
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            file = try container.decodeIfPresent(String.self, forKey: .file)
            path = try container.decodeIfPresent(String.self, forKey: .path)
            simple = try container.decodeIfPresent(String.self, forKey: .simple)
            aura = try container.decodeIfPresent(String.self, forKey: .aura)
            storageFileID = try container.decodeIfPresent(Int.self, forKey: .fileId)
            return
        }

        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self),
           let parsed = PostAuthorAvatar.fromJSONString(raw) {
            self = parsed
            return
        }

        file = nil
        path = nil
        simple = nil
        aura = nil
        storageFileID = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(simple, forKey: .simple)
        try container.encodeIfPresent(aura, forKey: .aura)
        try container.encodeIfPresent(storageFileID, forKey: .fileId)
    }

    private static func fromJSONString(_ raw: String) -> PostAuthorAvatar? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func decode(_ text: String) -> PostAuthorAvatar? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let fileID: Int? = {
                if let fid = object["file_id"] as? Int { return fid }
                if let fidNum = object["file_id"] as? NSNumber { return fidNum.intValue }
                return nil
            }()
            return PostAuthorAvatar(
                file: object["file"] as? String,
                path: object["path"] as? String,
                simple: object["simple"] as? String,
                aura: object["aura"] as? String,
                storageFileID: fileID
            )
        }

        if let parsed = decode(trimmed) {
            return parsed
        }

        let unescaped = trimmed.replacingOccurrences(of: "\\\"", with: "\"")
        return decode(unescaped)
    }
}

struct PostContent: Decodable {
    var images: [PostImage]?
    var videos: [PostVideo]?
    var files: [PostFile]?
    var songs: [MusicSong]?

    enum CodingKeys: String, CodingKey {
        case images
        case videos
        case files
        case songs
        case tracks
    }

    /// Attachment edit set for `posts/edit` (web EditPostModal parity).
    struct EditChanges {
        let text: String
        let newFiles: [UploadFile]
        let removedFileIDs: [Int]

        var hasAttachmentChanges: Bool {
            !newFiles.isEmpty || !removedFileIDs.isEmpty
        }
    }

    init(images: [PostImage]? = nil, videos: [PostVideo]? = nil, files: [PostFile]? = nil, songs: [MusicSong]? = nil) {
        self.images = images
        self.videos = videos
        self.files = files
        self.songs = songs
    }

    init(from decoder: Decoder) throws {
        // 1. Try decoding array of content blocks format: `[{"type":"images","items":[...]}, ...]`
        if var arrayContainer = try? decoder.unkeyedContainer() {
            var decodedImages: [PostImage] = []
            var decodedVideos: [PostVideo] = []
            var decodedFiles: [PostFile] = []
            var decodedSongs: [MusicSong] = []

            while !arrayContainer.isAtEnd {
                if let block = try? arrayContainer.decode(PostContentBlock.self) {
                    switch block.type.lowercased() {
                    case "images":
                        if let items = block.images {
                            decodedImages.append(contentsOf: items)
                        }
                    case "videos":
                        if let items = block.videos {
                            decodedVideos.append(contentsOf: items)
                        }
                    case "files":
                        if let items = block.files {
                            decodedFiles.append(contentsOf: items)
                        }
                    case "tracks", "songs":
                        if let items = block.songs {
                            decodedSongs.append(contentsOf: items)
                        }
                    default:
                        break
                    }
                }
            }

            self.images = decodedImages.isEmpty ? nil : decodedImages
            self.videos = decodedVideos.isEmpty ? nil : decodedVideos
            self.files = decodedFiles.isEmpty ? nil : decodedFiles
            self.songs = decodedSongs.isEmpty ? nil : decodedSongs
            return
        }

        // 2. Fallback: Try decoding keyed map format: `{"images":[...],"videos":[...]}`
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.images = try? container.decodeIfPresent([PostImage].self, forKey: .images)
            self.videos = try? container.decodeIfPresent([PostVideo].self, forKey: .videos)
            self.files = try? container.decodeIfPresent([PostFile].self, forKey: .files)
            self.songs = (try? container.decodeIfPresent([MusicSong].self, forKey: .songs))
                ?? (try? container.decodeIfPresent([MusicSong].self, forKey: .tracks))
            return
        }

        self.images = nil
        self.videos = nil
        self.files = nil
        self.songs = nil
    }
}

private struct PostContentBlock: Decodable {
    let type: String
    let images: [PostImage]?
    let videos: [PostVideo]?
    let files: [PostFile]?
    let songs: [MusicSong]?

    enum CodingKeys: String, CodingKey {
        case type
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""

        switch type.lowercased() {
        case "images":
            images = try? container.decodeIfPresent([PostImage].self, forKey: .items)
            videos = nil
            files = nil
            songs = nil
        case "videos":
            videos = try? container.decodeIfPresent([PostVideo].self, forKey: .items)
            images = nil
            files = nil
            songs = nil
        case "files":
            files = try? container.decodeIfPresent([PostFile].self, forKey: .items)
            images = nil
            videos = nil
            songs = nil
        case "tracks", "songs":
            songs = try? container.decodeIfPresent([MusicSong].self, forKey: .items)
            images = nil
            videos = nil
            files = nil
        default:
            images = nil
            videos = nil
            files = nil
            songs = nil
        }
    }
}

struct PostFile: Decodable, Identifiable {
    let id = UUID()
    let name: String?
    let size: Int?
    let file: String?
    let path: String?
    /// Server-side id used by `posts/edit` `removed_file_ids`.
    let serverFileID: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case file
        case path
        case fileID = "file_id"
    }

    init(name: String?, size: Int?, file: String?, path: String?, serverFileID: Int? = nil) {
        self.name = name
        self.size = size
        self.file = file
        self.path = path
        self.serverFileID = serverFileID
    }

    private struct NestedFileObject: Decodable {
        let id: Int?
        let path: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        size = (try? container.decodeIfPresent(Int.self, forKey: .size)) ?? nil
        path = try container.decodeIfPresent(String.self, forKey: .path)

        // `file` may be a plain path string or a nested object {id, path, …}.
        var fileString: String? = nil
        var nestedID: Int? = nil
        if let str = try? container.decodeIfPresent(String.self, forKey: .file) {
            fileString = str
        } else if let obj = try? container.decodeIfPresent(NestedFileObject.self, forKey: .file) {
            fileString = obj.path
            nestedID = obj.id
        }
        file = fileString

        let topID = (try? container.decodeIfPresent(Int.self, forKey: .fileID)) ?? nil
        serverFileID = topID ?? nestedID
    }
}

struct PostImage: Decodable, Identifiable {
    let id = UUID()
    let fileName: String?
    let fileSize: Int?
    let imgData: MediaData

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case fileSize = "file_size"
        case imgData = "img_data"
        case image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
        if let decoded = try? container.decode(MediaData.self, forKey: .imgData) {
            imgData = decoded
        } else if let decodedImage = try? container.decode(MediaData.self, forKey: .image) {
            imgData = decodedImage
        } else {
            // Fallback for legacy payloads where img_data is missing.
            let fallback = fileName ?? ""
            imgData = MediaData(file: fallback, path: "posts/images", preview: nil, simple: fallback, aura: nil)
        }
    }
}

extension PostImage {
    init(fileName: String?, fileSize: Int?, imgData: MediaData) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.imgData = imgData
    }
}

struct PostVideo: Decodable, Identifiable {
    let id = UUID()
    let file: String?
    let name: String?
    let fileName: String?
    let url: String?
    let src: String?
    let path: String?
    let simple: String?
    let preview: VideoPreview?
    let thumbnail: String?
    let fileId: Int?

    enum CodingKeys: String, CodingKey {
        case file
        case name
        case fileName = "file_name"
        case url
        case src
        case path
        case simple
        case preview
        case thumbnail
        case imgData = "img_data"
        case video
        case fileId = "file_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        src = try container.decodeIfPresent(String.self, forKey: .src)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        simple = try container.decodeIfPresent(String.self, forKey: .simple)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)

        let videoWrapper = try? container.decode(PostVideoWrapper.self, forKey: .video)
        let directFileId = try? container.decodeIfPresent(Int.self, forKey: .fileId)
        fileId = directFileId ?? videoWrapper?.fileId

        if let decoded = try? container.decode(VideoPreview.self, forKey: .preview), decoded.imgData != nil {
            preview = decoded
        } else if let media = try? container.decode(MediaData.self, forKey: .preview) {
            preview = VideoPreview(imgData: media)
        } else if let media = try? container.decode(MediaData.self, forKey: .imgData) {
            preview = VideoPreview(imgData: media)
        } else if let videoWrapper, let wrapPreview = videoWrapper.preview, wrapPreview.imgData != nil {
            preview = wrapPreview
        } else if let thumbnail, !thumbnail.isEmpty {
            let media = MediaData(file: thumbnail, path: "posts/videos", preview: nil, simple: thumbnail, aura: nil)
            preview = VideoPreview(imgData: media)
        } else {
            preview = nil
        }
    }
}

private struct PostVideoWrapper: Decodable {
    let preview: VideoPreview?
    let fileId: Int?

    enum CodingKeys: String, CodingKey {
        case preview
        case fileId = "file_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileId = try? container.decodeIfPresent(Int.self, forKey: .fileId)
        if let direct = try? container.decode(VideoPreview.self, forKey: .preview), direct.imgData != nil {
            preview = direct
        } else if let media = try? container.decode(MediaData.self, forKey: .preview) {
            preview = VideoPreview(imgData: media)
        } else {
            preview = nil
        }
    }
}


extension PostVideo {
    init(
        file: String?,
        name: String?,
        fileName: String?,
        url: String?,
        src: String?,
        path: String?,
        simple: String?,
        preview: VideoPreview?,
        thumbnail: String?,
        fileId: Int? = nil
    ) {
        self.file = file
        self.name = name
        self.fileName = fileName
        self.url = url
        self.src = src
        self.path = path
        self.simple = simple
        self.preview = preview
        self.thumbnail = thumbnail
        self.fileId = fileId
    }
}

struct VideoPreview: Decodable {
    let imgData: MediaData?

    enum CodingKeys: String, CodingKey {
        case imgData = "img_data"
    }

    init(imgData: MediaData?) {
        self.imgData = imgData
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let direct = try? container.decodeIfPresent(MediaData.self, forKey: .imgData) {
            imgData = direct
        } else if let media = try? MediaData(from: decoder) {
            imgData = media
        } else {
            imgData = nil
        }
    }
}

struct MediaData: Codable {
    let file: String?
    let path: String?
    let preview: String?
    let simple: String?
    let aura: String?
    /// Storage-backed image (e.g. playlist covers from `music/load_library`) — use storage download, not CDN `files/…`.
    let storageFileID: Int?

    enum CodingKeys: String, CodingKey {
        case file, path, preview, simple, aura
        case fileId = "file_id"
    }

    init(file: String?, path: String?, preview: String?, simple: String?, aura: String?, storageFileID: Int? = nil) {
        self.file = file
        self.path = path
        self.preview = preview
        self.simple = simple
        self.aura = aura
        self.storageFileID = storageFileID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        simple = try container.decodeIfPresent(String.self, forKey: .simple)
        aura = try container.decodeIfPresent(String.self, forKey: .aura)
        storageFileID = try container.decodeIfPresent(Int.self, forKey: .fileId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(simple, forKey: .simple)
        try container.encodeIfPresent(aura, forKey: .aura)
        try container.encodeIfPresent(storageFileID, forKey: .fileId)
    }

    private func normalized(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: "\\/", with: "/")
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func absoluteURL(from raw: String?) -> URL? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            return URL(string: value)
        }
        return nil
    }

    private func buildURL(path rawPath: String?, file rawFile: String?) -> URL? {
        if let absolute = absoluteURL(from: rawFile) {
            return absolute
        }

        guard let file = normalized(rawFile) else { return nil }

        let cleanedPath = normalized(rawPath)?
            .replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)

        let cleanedFile = file
            .replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)

        let relative: String
        if cleanedFile.contains("/") {
            relative = cleanedFile
        } else if let cleanedPath, !cleanedPath.isEmpty {
            relative = "\(cleanedPath)/\(cleanedFile)"
        } else {
            relative = cleanedFile
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "elemsocial.com"
        components.path = "/files/\(relative)"
        return components.url
    }

    var fullURL: URL? {
        buildURL(path: path, file: file)
    }

    var simpleURL: URL? {
        buildURL(path: path, file: simple)
    }

    /// Stable key for image cache / SwiftUI `.task(id:)`.
    var imageLoadKey: String {
        if let storageFileID {
            return "fid:\(storageFileID)"
        }
        return "\(path ?? "")|\(file ?? "")|\(simple ?? "")"
    }
}

extension MediaData: Equatable {
    static func == (lhs: MediaData, rhs: MediaData) -> Bool {
        lhs.file == rhs.file
            && lhs.path == rhs.path
            && lhs.preview == rhs.preview
            && lhs.simple == rhs.simple
            && lhs.aura == rhs.aura
            && lhs.storageFileID == rhs.storageFileID
    }
}
