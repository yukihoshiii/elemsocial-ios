import Foundation

final class ProfileCacheStore {
    static let shared = ProfileCacheStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let baseURL: URL

    private init() {
        baseURL = CachePaths.appSupportDirectory.appendingPathComponent("profiles", isDirectory: true)
        CachePaths.ensureDirectory(baseURL)
    }

    func load(username: String) -> APIClient.ProfileData? {
        let url = fileURL(for: username)
        guard let data = try? Data(contentsOf: url),
              let cached = try? decoder.decode(ProfileCacheEntry.self, from: data) else {
            return nil
        }
        return cached.asProfileData
    }

    func loadAsync(username: String) async -> APIClient.ProfileData? {
        await Task.detached { [weak self] in
            self?.load(username: username)
        }.value
    }

    func save(profile: APIClient.ProfileData) {
        let entry = ProfileCacheEntry(profile: profile)
        guard let data = try? encoder.encode(entry) else { return }
        let url = fileURL(for: profile.username)
        CachePaths.writeData(data, to: url)
    }

    private func fileURL(for username: String) -> URL {
        let safe = CachePaths.safeFilename(username)
        return baseURL.appendingPathComponent("\(safe).json")
    }
}

final class NotificationsCacheStore {
    static let shared = NotificationsCacheStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let baseURL: URL

    private init() {
        baseURL = CachePaths.appSupportDirectory.appendingPathComponent("notifications", isDirectory: true)
        CachePaths.ensureDirectory(baseURL)
    }

    func load(username: String, variant: String = "all_date_desc") -> [SocialNotification] {
        let url = fileURL(for: username, variant: variant)
        guard let data = try? Data(contentsOf: url),
              let cached = try? decoder.decode([CachedNotification].self, from: data) else {
            return []
        }
        return cached.map { $0.asSocialNotification }
    }

    func loadAsync(username: String, variant: String = "all_date_desc") async -> [SocialNotification] {
        await Task.detached { [weak self] in
            self?.load(username: username, variant: variant) ?? []
        }.value
    }

    func save(notifications: [SocialNotification], username: String, variant: String = "all_date_desc") {
        let trimmed = notifications.prefix(250).map { CachedNotification(notification: $0) }
        guard let data = try? encoder.encode(Array(trimmed)) else { return }
        let url = fileURL(for: username, variant: variant)
        CachePaths.writeData(data, to: url)
    }

    private func fileURL(for username: String, variant: String) -> URL {
        let safeUser = CachePaths.safeFilename(username)
        let safeVariant = CachePaths.safeFilename(variant)
        return baseURL.appendingPathComponent("\(safeUser)__\(safeVariant).json")
    }
}

final class ProfileScreenCacheStore {
    static let shared = ProfileScreenCacheStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let baseURL: URL

    private init() {
        baseURL = CachePaths.appSupportDirectory.appendingPathComponent("profile_screens", isDirectory: true)
        CachePaths.ensureDirectory(baseURL)
    }

    func load(username: String) -> ProfileScreenCacheEntry? {
        let url = fileURL(for: username)
        guard let data = try? Data(contentsOf: url),
              let cached = try? decoder.decode(ProfileScreenCacheEntry.self, from: data) else {
            return nil
        }
        return cached
    }

    func loadAsync(username: String) async -> ProfileScreenCacheEntry? {
        await Task.detached { [weak self] in
            self?.load(username: username)
        }.value
    }

    func save(profile: APIClient.ProfileData, posts: [Post], wall: [Post]) {
        let entry = ProfileScreenCacheEntry(profile: profile, posts: posts, wall: wall)
        guard let data = try? encoder.encode(entry) else { return }
        let url = fileURL(for: profile.username)
        CachePaths.writeData(data, to: url)
    }

    private func fileURL(for username: String) -> URL {
        let safe = CachePaths.safeFilename(username)
        return baseURL.appendingPathComponent("\(safe).json")
    }
}

final class MusicScreenCacheStore {
    static let shared = MusicScreenCacheStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL

    private init() {
        let baseURL = CachePaths.appSupportDirectory.appendingPathComponent("music", isDirectory: true)
        CachePaths.ensureDirectory(baseURL)
        fileURL = baseURL.appendingPathComponent("screen.json")
    }

    func load() -> MusicScreenCacheEntry? {
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? decoder.decode(MusicScreenCacheEntry.self, from: data) else {
            return nil
        }
        return cached
    }

    func loadAsync() async -> MusicScreenCacheEntry? {
        await Task.detached { [weak self] in
            self?.load()
        }.value
    }

    func save(library: [MusicPlaylist], songsByCategory: [MusicCategory: [MusicSong]], discoverPlaylists: [MusicPlaylist] = []) {
        let entry = MusicScreenCacheEntry(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
        guard let data = try? encoder.encode(entry) else { return }
        CachePaths.writeData(data, to: fileURL)
    }
}

struct ProfileCacheEntry: Codable {
    let id: Int
    let type: Int
    let name: String
    let username: String
    let description: String?
    let avatar: CachedMedia?
    let cover: CachedMedia?
    let listeningSong: CachedMusicSong?
    let isOnline: Bool?
    let postsCount: Int
    let subscribersCount: Int
    let subscribedCount: Int
    let giftsCount: Int?
    let archivePostsCount: Int?
    let trashBinPostsCount: Int?
    let isSubscribed: Bool
    let isBlocked: Bool?
    let isMyProfile: Bool
    let createDate: String?
    let lastOnline: String?
    let isVerified: Bool?
    let goldStatus: Bool?
    let isMuted: Bool?
    let cachedAt: Date

    init(profile: APIClient.ProfileData) {
        id = profile.id
        type = profile.type
        name = profile.name
        username = profile.username
        description = profile.description
        avatar = profile.avatar.map(CachedMedia.init)
        cover = profile.cover.map(CachedMedia.init)
        listeningSong = profile.listeningSong.map(CachedMusicSong.init)
        isOnline = profile.isOnline
        postsCount = profile.postsCount
        subscribersCount = profile.subscribersCount
        subscribedCount = profile.subscribedCount
        giftsCount = profile.giftsCount
        archivePostsCount = profile.archivePostsCount
        trashBinPostsCount = profile.trashBinPostsCount
        isSubscribed = profile.isSubscribed
        isBlocked = profile.isBlocked
        isMyProfile = profile.isMyProfile
        createDate = profile.createDate
        lastOnline = profile.lastOnline
        isVerified = profile.isVerified
        goldStatus = profile.goldStatus
        isMuted = profile.isMuted
        cachedAt = Date()
    }

    var asProfileData: APIClient.ProfileData {
        APIClient.ProfileData(
            id: id,
            type: type,
            name: name,
            username: username,
            description: description,
            avatar: avatar?.asMediaData,
            cover: cover?.asMediaData,
            listeningSong: listeningSong?.asMusicSong,
            isOnline: isOnline ?? false,
            postsCount: postsCount,
            subscribersCount: subscribersCount,
            subscribedCount: subscribedCount,
            giftsCount: giftsCount ?? 0,
            archivePostsCount: archivePostsCount ?? 0,
            trashBinPostsCount: trashBinPostsCount ?? 0,
            isSubscribed: isSubscribed,
            isBlocked: isBlocked ?? false,
            isMyProfile: isMyProfile,
            createDate: createDate,
            lastOnline: lastOnline,
            isVerified: isVerified,
            goldStatus: goldStatus,
            isMuted: isMuted ?? false
        )
    }
}

struct ProfileScreenCacheEntry: Codable {
    let profile: ProfileCacheEntry
    let posts: [CachedPost]
    let wall: [CachedPost]
    let cachedAt: Date

    init(profile: APIClient.ProfileData, posts: [Post], wall: [Post]) {
        self.profile = ProfileCacheEntry(profile: profile)
        self.posts = posts.map(CachedPost.init)
        self.wall = wall.map(CachedPost.init)
        cachedAt = Date()
    }
}

struct MusicScreenCacheEntry: Codable {
    let library: [CachedMusicPlaylist]
    let favorites: [CachedMusicSong]
    let latest: [CachedMusicSong]
    let random: [CachedMusicSong]
    let discoverPlaylists: [CachedMusicPlaylist]
    let cachedAt: Date

    enum CodingKeys: String, CodingKey {
        case library, favorites, latest, random, discoverPlaylists, cachedAt
    }

    init(library: [MusicPlaylist], songsByCategory: [MusicCategory: [MusicSong]], discoverPlaylists: [MusicPlaylist] = []) {
        self.library = library.map(CachedMusicPlaylist.init)
        self.favorites = (songsByCategory[.favorites] ?? []).map(CachedMusicSong.init)
        self.latest = (songsByCategory[.latest] ?? []).map(CachedMusicSong.init)
        self.random = (songsByCategory[.random] ?? []).map(CachedMusicSong.init)
        self.discoverPlaylists = discoverPlaylists.map(CachedMusicPlaylist.init)
        self.cachedAt = Date()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        library = try container.decode([CachedMusicPlaylist].self, forKey: .library)
        favorites = try container.decode([CachedMusicSong].self, forKey: .favorites)
        latest = try container.decode([CachedMusicSong].self, forKey: .latest)
        random = try container.decode([CachedMusicSong].self, forKey: .random)
        discoverPlaylists = try container.decodeIfPresent([CachedMusicPlaylist].self, forKey: .discoverPlaylists) ?? []
        cachedAt = try container.decode(Date.self, forKey: .cachedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(library, forKey: .library)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(latest, forKey: .latest)
        try container.encode(random, forKey: .random)
        try container.encode(discoverPlaylists, forKey: .discoverPlaylists)
        try container.encode(cachedAt, forKey: .cachedAt)
    }

    var asLibrary: [MusicPlaylist] {
        library.map(\.asMusicPlaylist)
    }

    var asDiscoverPlaylists: [MusicPlaylist] {
        discoverPlaylists.map(\.asMusicPlaylist)
    }

    var asSongsByCategory: [MusicCategory: [MusicSong]] {
        [
            .favorites: favorites.map(\.asMusicSong),
            .latest: latest.map(\.asMusicSong),
            .random: random.map(\.asMusicSong)
        ]
    }
}

struct CachedMedia: Codable {
    let file: String?
    let path: String?
    let preview: String?
    let simple: String?
    let aura: String?
    let storageFileID: Int?

    init(_ media: MediaData) {
        file = media.file
        path = media.path
        preview = media.preview
        simple = media.simple
        aura = media.aura
        storageFileID = media.storageFileID
    }

    var asMediaData: MediaData {
        MediaData(file: file, path: path, preview: preview, simple: simple, aura: aura, storageFileID: storageFileID)
    }
}

struct CachedMusicPlaylist: Codable {
    let id: Int
    let type: Int
    let title: String
    let authorName: String?
    let authorUsername: String?
    let addDate: String?
    let cover: CachedMedia?

    init(_ playlist: MusicPlaylist) {
        id = playlist.id
        type = playlist.type
        title = playlist.title
        authorName = playlist.authorName
        authorUsername = playlist.authorUsername
        addDate = playlist.addDate
        cover = playlist.cover.map(CachedMedia.init)
    }

    var asMusicPlaylist: MusicPlaylist {
        MusicPlaylist(
            id: id,
            type: type,
            title: title,
            authorName: authorName,
            authorUsername: authorUsername,
            addDate: addDate,
            cover: cover?.asMediaData
        )
    }
}

struct CachedMusicFileDescriptor: Codable {
    let file: String?
    let path: String?

    init(_ descriptor: MusicFileDescriptor?) {
        file = descriptor?.file
        path = descriptor?.path
    }

    var asMusicFileDescriptor: MusicFileDescriptor? {
        guard file != nil || path != nil else { return nil }
        return MusicFileDescriptor(file: file, path: path)
    }
}

struct CachedMusicArtist: Codable {
    let id: Int
    let name: String
    let slug: String?
    let avatar: CachedMedia?

    init(_ artist: MusicArtist) {
        id = artist.id
        name = artist.name
        slug = artist.slug
        avatar = artist.avatar.map(CachedMedia.init)
    }

    var asMusicArtist: MusicArtist {
        MusicArtist(id: id, name: name, slug: slug, avatar: avatar?.asMediaData)
    }
}

struct CachedMusicSong: Codable {
    let id: Int
    let originalFileID: Int?
    let title: String
    let artist: String
    let artists: [CachedMusicArtist]
    let album: String?
    let cover: CachedMedia?
    let fileDescriptor: CachedMusicFileDescriptor
    let type: Int
    let duration: Double?
    let dateAdded: String?
    let liked: Bool
    let genre: String?
    let trackNumber: Int?
    let releaseYear: Int?
    let composer: String?
    let bitrate: Int?
    let audioFormat: String?

    init(_ song: MusicSong) {
        id = song.id
        originalFileID = song.originalFileID
        title = song.title
        artist = song.artist
        artists = song.artists.map(CachedMusicArtist.init)
        album = song.album
        cover = song.cover.map(CachedMedia.init)
        fileDescriptor = CachedMusicFileDescriptor(song.fileDescriptor)
        type = song.type
        duration = song.duration
        dateAdded = song.dateAdded
        liked = song.liked
        genre = song.genre
        trackNumber = song.trackNumber
        releaseYear = song.releaseYear
        composer = song.composer
        bitrate = song.bitrate
        audioFormat = song.audioFormat
    }

    var asMusicSong: MusicSong {
        MusicSong(
            id: id,
            originalFileID: originalFileID,
            title: title,
            artist: artist,
            artists: artists.map(\.asMusicArtist),
            album: album,
            cover: cover?.asMediaData,
            fileDescriptor: fileDescriptor.asMusicFileDescriptor,
            type: type,
            duration: duration,
            dateAdded: dateAdded,
            liked: liked,
            genre: genre,
            trackNumber: trackNumber,
            releaseYear: releaseYear,
            composer: composer,
            bitrate: bitrate,
            audioFormat: audioFormat
        )
    }
}

struct CachedPostContent: Codable {
    let images: [CachedPostImage]?
    let videos: [CachedPostVideo]?
    let files: [CachedPostFile]?
    let songs: [CachedMusicSong]?

    init(content: PostContent?) {
        images = content?.images?.map(CachedPostImage.init)
        videos = content?.videos?.map(CachedPostVideo.init)
        files = content?.files?.map(CachedPostFile.init)
        songs = content?.songs?.map(CachedMusicSong.init)
    }

    var asPostContent: PostContent? {
        if images == nil, videos == nil, files == nil, songs == nil { return nil }
        return PostContent(
            images: images?.map { $0.asPostImage },
            videos: videos?.map { $0.asPostVideo },
            files: files?.map { $0.asPostFile },
            songs: songs?.map(\.asMusicSong)
        )
    }
}

struct CachedPostImage: Codable {
    let fileName: String?
    let fileSize: Int?
    let imgData: CachedMedia

    init(image: PostImage) {
        fileName = image.fileName
        fileSize = image.fileSize
        imgData = CachedMedia(image.imgData)
    }

    var asPostImage: PostImage {
        PostImage(fileName: fileName, fileSize: fileSize, imgData: imgData.asMediaData)
    }
}

struct CachedPostVideo: Codable {
    let file: String?
    let name: String?
    let fileName: String?
    let url: String?
    let src: String?
    let path: String?
    let simple: String?
    let preview: CachedVideoPreview?
    let thumbnail: String?
    let fileId: Int?

    init(video: PostVideo) {
        file = video.file
        name = video.name
        fileName = video.fileName
        url = video.url
        src = video.src
        path = video.path
        simple = video.simple
        preview = video.preview.map(CachedVideoPreview.init)
        thumbnail = video.thumbnail
        fileId = video.fileId
    }

    var asPostVideo: PostVideo {
        PostVideo(
            file: file,
            name: name,
            fileName: fileName,
            url: url,
            src: src,
            path: path,
            simple: simple,
            preview: preview?.asPreview,
            thumbnail: thumbnail,
            fileId: fileId
        )
    }
}

struct CachedVideoPreview: Codable {
    let imgData: CachedMedia?

    init(preview: VideoPreview) {
        imgData = preview.imgData.map(CachedMedia.init)
    }

    var asPreview: VideoPreview {
        VideoPreview(imgData: imgData?.asMediaData)
    }
}

struct CachedPostFile: Codable {
    let name: String?
    let size: Int?
    let file: String?
    let path: String?

    init(file: PostFile) {
        name = file.name
        size = file.size
        self.file = file.file
        self.path = file.path
    }

    var asPostFile: PostFile {
        PostFile(name: name, size: size, file: file, path: path)
    }
}

struct CachedPost: Codable {
    let id: Int
    let text: String?
    let createDate: String?
    let author: CachedAuthor
    let content: CachedPostContent?
    let likes: Int?
    let liked: Bool?
    let dislikes: Int?
    let dislikesCount: Int?
    let disliked: Bool?
    let comments: Int?
    let myPost: Bool?
    let reactions: PostReactions?

    init(post: Post) {
        id = post.id
        text = post.text
        createDate = post.createDate
        author = CachedAuthor(author: post.author)
        content = CachedPostContent(content: post.content)
        likes = post.likes
        liked = post.liked
        dislikes = post.dislikes
        dislikesCount = post.dislikesCount
        disliked = post.disliked
        comments = post.comments
        myPost = post.myPost
        reactions = post.reactions
    }

    var asPost: Post {
        Post(
            id: id,
            text: text,
            createDate: createDate,
            author: author.asPostAuthor ?? PostAuthor(id: nil, type: nil, name: nil, username: nil),
            content: content?.asPostContent,
            likes: likes,
            liked: liked,
            dislikes: dislikes,
            dislikesCount: dislikesCount,
            disliked: disliked,
            comments: comments,
            myPost: myPost,
            reactions: reactions
        )
    }
}

struct CachedAuthor: Codable {
    let id: Int?
    let type: Int?
    let name: String?
    let username: String?
    let avatar: PostAuthorAvatar?
    let isVerified: Bool?
    let goldStatus: Bool?

    init(author: PostAuthor?) {
        id = author?.id
        type = author?.type
        name = author?.name
        username = author?.username
        avatar = author?.avatar
        isVerified = author?.isVerified
        goldStatus = author?.goldStatus
    }

    var asPostAuthor: PostAuthor? {
        guard id != nil || name != nil || username != nil || avatar != nil else { return nil }
        return PostAuthor(
            id: id,
            type: type,
            name: name,
            username: username,
            avatar: avatar,
            isVerified: isVerified,
            goldStatus: goldStatus
        )
    }
}

struct CachedNotificationContent: Codable {
    let postID: Int?
    let commentID: Int?
    let profileUsername: String?
    let commentText: String?
    let postText: String?
    let messageText: String?
    let authorName: String?
    let title: String?
    let subtype: String?

    init(content: SocialNotificationContent) {
        postID = content.postID
        commentID = content.commentID
        profileUsername = content.profileUsername
        commentText = content.commentText
        postText = content.postText
        messageText = content.messageText
        authorName = content.authorName
        title = content.title
        subtype = content.subtype
    }

    var asContent: SocialNotificationContent {
        SocialNotificationContent(
            postID: postID,
            commentID: commentID,
            profileUsername: profileUsername,
            commentText: commentText,
            postText: postText,
            messageText: messageText,
            authorName: authorName,
            title: title,
            subtype: subtype
        )
    }
}

struct CachedNotification: Codable {
    let id: Int
    let author: CachedAuthor?
    let action: String
    let content: CachedNotificationContent
    let viewed: Bool
    let date: String?

    init(notification: SocialNotification) {
        id = notification.id
        author = CachedAuthor(author: notification.author)
        action = notification.action
        content = CachedNotificationContent(content: notification.content)
        viewed = notification.viewed
        date = notification.date
    }

    var asSocialNotification: SocialNotification {
        SocialNotification(
            id: id,
            author: author?.asPostAuthor,
            action: action,
            content: content.asContent,
            viewed: viewed,
            date: date
        )
    }
}

enum CachePaths {
    static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ElementSocialCache", isDirectory: true)
        ensureDirectory(dir)
        return dir
    }()

    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ElementSocialCache", isDirectory: true)
        ensureDirectory(dir)
        return dir
    }()

    static func ensureDirectory(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    static func safeFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }

    static func writeData(_ data: Data, to url: URL) {
        ensureDirectory(url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort cache write.
        }
    }
}
