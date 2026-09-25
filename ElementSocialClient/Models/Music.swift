import Foundation

enum MusicCategory: String, CaseIterable, Identifiable {
    case favorites
    case latest
    case random

    var id: String { rawValue }
}

struct MusicFileDescriptor: Equatable {
    let file: String?
    let path: String?

    var fullURL: URL? {
        guard let rawFile = file?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFile.isEmpty else {
            return nil
        }

        let normalizedFile = rawFile
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let relative: String
        if normalizedFile.contains("/") {
            relative = normalizedFile
        } else if let normalizedPath, !normalizedPath.isEmpty {
            relative = "\(normalizedPath)/\(normalizedFile)"
        } else {
            relative = normalizedFile
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "elemsocial.com"
        components.path = "/files/\(relative)"
        return components.url
    }
}

struct MusicArtist: Identifiable, Decodable, Equatable, Hashable {
    static func == (lhs: MusicArtist, rhs: MusicArtist) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    let id: Int
    let name: String
    let slug: String?
    let avatar: MediaData?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case avatar
    }

    init(id: Int, name: String, slug: String?, avatar: MediaData?) {
        self.id = id
        self.name = name
        self.slug = slug
        self.avatar = avatar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let directId = try? container.decode(Int.self, forKey: .id) {
            self.id = directId
        } else if let stringId = try? container.decode(String.self, forKey: .id), let intVal = Int(stringId) {
            self.id = intVal
        } else {
            self.id = 0
        }
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        self.slug = try container.decodeIfPresent(String.self, forKey: .slug)
        self.avatar = try container.decodeIfPresent(MediaData.self, forKey: .avatar)
    }
}

struct MusicSong: Identifiable, Decodable {
    let id: Int
    let originalFileID: Int?
    let title: String
    let artist: String
    let artists: [MusicArtist]
    let album: String?
    let cover: MediaData?
    let fileDescriptor: MusicFileDescriptor?
    let type: Int
    let duration: Double?
    let dateAdded: String?
    var liked: Bool
    let genre: String?
    let trackNumber: Int?
    let releaseYear: Int?
    let composer: String?
    let bitrate: Int?
    let audioFormat: String?

    init(
        id: Int,
        originalFileID: Int?,
        title: String,
        artist: String,
        artists: [MusicArtist],
        album: String?,
        cover: MediaData?,
        fileDescriptor: MusicFileDescriptor?,
        type: Int,
        duration: Double?,
        dateAdded: String?,
        liked: Bool,
        genre: String?,
        trackNumber: Int?,
        releaseYear: Int?,
        composer: String?,
        bitrate: Int?,
        audioFormat: String?
    ) {
        self.id = id
        self.originalFileID = originalFileID
        self.title = title
        self.artist = artist
        self.artists = artists
        self.album = album
        self.cover = cover
        self.fileDescriptor = fileDescriptor
        self.type = type
        self.duration = Self.normalizedDuration(duration)
        self.dateAdded = dateAdded
        self.liked = liked
        self.genre = genre
        self.trackNumber = trackNumber
        self.releaseYear = releaseYear
        self.composer = composer
        self.bitrate = bitrate
        self.audioFormat = audioFormat
    }

    enum CodingKeys: String, CodingKey {
        case id
        case originalFileID = "original_file_id"
        case legacyOriginalFileID = "original_file"
        case title
        case artist
        case artists
        case album
        case cover
        case fileDescriptor = "file"
        case type
        case duration
        case dateAdded = "date_added"
        case liked
        case genre
        case trackNumber = "track_number"
        case releaseYear = "release_year"
        case composer
        case bitrate
        case audioFormat = "audio_format"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLossyInt(forKey: .id) ?? 0
        if let fileID = try container.decodeLossyIntIfPresent(forKey: .originalFileID) {
            originalFileID = fileID
        } else {
            originalFileID = try container.decodeLossyIntIfPresent(forKey: .legacyOriginalFileID)
        }
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown"
        
        let parsedArtists = (try? container.decodeIfPresent([MusicArtist].self, forKey: .artists)) ?? []
        self.artists = parsedArtists
        
        let rawArtist = try container.decodeIfPresent(String.self, forKey: .artist)
        let isRawArtistUsable = rawArtist.map { !$0.isEmpty && $0.lowercased() != "unknown" } ?? false
        if isRawArtistUsable {
            self.artist = rawArtist!
        } else if !parsedArtists.isEmpty {
            self.artist = parsedArtists.map { $0.name }.joined(separator: ", ")
        } else {
            self.artist = "Unknown"
        }
        
        album = try container.decodeIfPresent(String.self, forKey: .album)
        cover = try container.decodeIfPresent(MediaData.self, forKey: .cover)
        fileDescriptor = try container.decodeIfPresent(MusicFileDescriptor.self, forKey: .fileDescriptor)
        type = (try? container.decodeLossyIntIfPresent(forKey: .type)) ?? 0
        duration = Self.normalizedDuration(try? container.decodeLossyDoubleIfPresent(forKey: .duration))
        dateAdded = try? container.decodeIfPresent(String.self, forKey: .dateAdded)
        liked = (try? container.decodeIfPresent(Bool.self, forKey: .liked)) ?? false
        genre = try? container.decodeIfPresent(String.self, forKey: .genre)
        trackNumber = try? container.decodeLossyIntIfPresent(forKey: .trackNumber)
        releaseYear = try? container.decodeLossyIntIfPresent(forKey: .releaseYear)
        composer = try? container.decodeIfPresent(String.self, forKey: .composer)
        bitrate = try? container.decodeLossyIntIfPresent(forKey: .bitrate)
        audioFormat = try? container.decodeIfPresent(String.self, forKey: .audioFormat)
    }

    /// Server sends track length in milliseconds (web: `formatTime(timeMs)` divides by 1000).
    private static func normalizedDuration(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        if raw >= 1000 {
            return raw / 1000.0
        }
        return raw
    }

    /// `load_song` may omit `original_file_id`; keep list/queue values needed for playback.
    func mergedForPlayback(with fallback: MusicSong) -> MusicSong {
        MusicSong(
            id: id,
            originalFileID: originalFileID ?? fallback.originalFileID,
            title: title,
            artist: artist,
            artists: artists.isEmpty ? fallback.artists : artists,
            album: album ?? fallback.album,
            cover: cover ?? fallback.cover,
            fileDescriptor: fileDescriptor ?? fallback.fileDescriptor,
            type: type,
            duration: duration ?? fallback.duration,
            dateAdded: dateAdded ?? fallback.dateAdded,
            liked: liked,
            genre: genre ?? fallback.genre,
            trackNumber: trackNumber ?? fallback.trackNumber,
            releaseYear: releaseYear ?? fallback.releaseYear,
            composer: composer ?? fallback.composer,
            bitrate: bitrate ?? fallback.bitrate,
            audioFormat: audioFormat ?? fallback.audioFormat
        )
    }

    func with(
        title: String? = nil,
        artist: String? = nil,
        artists: [MusicArtist]? = nil,
        album: String? = nil,
        cover: MediaData? = nil,
        genre: String? = nil,
        releaseYear: Int? = nil,
        composer: String? = nil
    ) -> MusicSong {
        MusicSong(
            id: id,
            originalFileID: originalFileID,
            title: title ?? self.title,
            artist: artist ?? self.artist,
            artists: artists ?? self.artists,
            album: album ?? self.album,
            cover: cover ?? self.cover,
            fileDescriptor: fileDescriptor,
            type: type,
            duration: duration,
            dateAdded: dateAdded,
            liked: liked,
            genre: genre ?? self.genre,
            trackNumber: trackNumber,
            releaseYear: releaseYear ?? self.releaseYear,
            composer: composer ?? self.composer,
            bitrate: bitrate,
            audioFormat: audioFormat
        )
    }
}

extension MusicFileDescriptor: Decodable {}

private extension KeyedDecodingContainer {
    func decodeLossyInt(forKey key: Key) throws -> Int? {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key) else { return nil }
        return try decodeLossyInt(forKey: key)
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

struct MusicPlaylist: Identifiable, Equatable {
    let id: Int
    let type: Int
    let title: String
    let authorName: String?
    let authorUsername: String?
    let addDate: String?
    let cover: MediaData?
}

struct MusicPlaylistDetails {
    let id: Int
    let title: String
    let description: String?
    let createDate: String?
    let privacy: Int
    let cover: MediaData?
    let authorName: String?
    let authorUsername: String?
    var songs: [MusicSong]
    var isLiked: Bool? = nil
    var isMyPlaylist: Bool? = nil
}

// MARK: - Lyrics & Albums Models

struct LyricsLine: Identifiable, Codable, Equatable {
    var id: Int { startTimeMs }
    let startTimeMs: Int
    let words: String

    enum CodingKeys: String, CodingKey {
        case startTimeMs = "start_time_ms"
        case words
    }
}

struct MusicSongLyrics: Codable, Equatable {
    let languageCode: String?
    let type: String?
    let lines: [LyricsLine]

    enum CodingKeys: String, CodingKey {
        case languageCode = "language_code"
        case type
        case lines
    }
}

struct MusicAlbum: Identifiable, Codable, Equatable, Hashable {
    let id: Int
    let title: String
    let artistName: String?
    let description: String?
    let cover: MediaData?
    let tracksCount: Int?
    let releaseDate: String?
    let releaseType: String?

    init(
        id: Int,
        title: String,
        artistName: String? = nil,
        description: String? = nil,
        cover: MediaData? = nil,
        tracksCount: Int? = nil,
        releaseDate: String? = nil,
        releaseType: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.description = description
        self.cover = cover
        self.tracksCount = tracksCount
        self.releaseDate = releaseDate
        self.releaseType = releaseType
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artistName = "artist"
        case description
        case cover
        case tracksCount = "tracks_count"
        case releaseDate = "release_date"
        case releaseType = "release_type"
    }

    private struct ReleaseDateObj: Decodable {
        let iso: String?
        let date: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeLossyInt(forKey: .id)) ?? 0
        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.artistName = try? container.decodeIfPresent(String.self, forKey: .artistName)
        self.description = try? container.decodeIfPresent(String.self, forKey: .description)
        self.cover = try? container.decodeIfPresent(MediaData.self, forKey: .cover)
        self.tracksCount = try? container.decodeLossyIntIfPresent(forKey: .tracksCount)
        if let directStr = try? container.decodeIfPresent(String.self, forKey: .releaseDate) {
            self.releaseDate = directStr
        } else if let dateObj = try? container.decodeIfPresent(ReleaseDateObj.self, forKey: .releaseDate) {
            self.releaseDate = dateObj.iso ?? dateObj.date
        } else {
            self.releaseDate = nil
        }
        self.releaseType = try? container.decodeIfPresent(String.self, forKey: .releaseType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(artistName, forKey: .artistName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(cover, forKey: .cover)
        try container.encodeIfPresent(tracksCount, forKey: .tracksCount)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(releaseType, forKey: .releaseType)
    }

    static func == (lhs: MusicAlbum, rhs: MusicAlbum) -> Bool {
        if lhs.id > 0 && rhs.id > 0 {
            return lhs.id == rhs.id
        }
        return lhs.title.lowercased() == rhs.title.lowercased()
    }

    func hash(into hasher: inout Hasher) {
        if id > 0 {
            hasher.combine(id)
        } else {
            hasher.combine(title.lowercased())
        }
    }
}

struct MusicSongDetails {
    let song: MusicSong
    let lyrics: [LyricsLine]
    let albumName: String?
    let composer: String?
    let genre: String?
    let releaseYear: Int?
    let bitrate: Int?
    let duration: Double?
}

func formatAlbumReleaseDate(_ raw: String?, languageCode: String = "ru", shortYearOnly: Bool = false) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }

    if raw.count == 4, let year = Int(raw) {
        return languageCode == "ru" ? "\(year) г." : "\(year)"
    }

    let isoFormatterFractional = ISO8601DateFormatter()
    isoFormatterFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let isoFormatterStandard = ISO8601DateFormatter()
    isoFormatterStandard.formatOptions = [.withInternetDateTime]

    let date: Date? = isoFormatterFractional.date(from: raw)
        ?? isoFormatterStandard.date(from: raw)
        ?? {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            return df.date(from: raw)
        }()

    if let date {
        let displayFormatter = DateFormatter()
        displayFormatter.locale = Locale(identifier: languageCode)
        if shortYearOnly {
            displayFormatter.dateFormat = languageCode == "ru" ? "yyyy г." : "yyyy"
        } else {
            if languageCode == "ru" {
                displayFormatter.dateFormat = "d MMMM yyyy г."
            } else {
                displayFormatter.dateStyle = .medium
                displayFormatter.timeStyle = .none
            }
        }
        return displayFormatter.string(from: date)
    }

    if let match = raw.range(of: #"\b(19\d\d|20\d\d)\b"#, options: .regularExpression) {
        let year = String(raw[match])
        return languageCode == "ru" ? "\(year) г." : year
    }

    return raw
}

