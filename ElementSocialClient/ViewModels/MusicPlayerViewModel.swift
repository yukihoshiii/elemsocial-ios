import Foundation
import AVFoundation
import MediaPlayer
import UIKit

enum MusicRepeatMode: Int {
    case off
    case all
    case one
}

/// High-frequency playback position updates are isolated so views that only need
/// "now playing" / queue state (e.g. every post row) are not re-rendered every tick.
@MainActor
final class MusicPlaybackProgressStore: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class MusicPlayerViewModel: ObservableObject {
    static let shared = MusicPlayerViewModel()

    let playbackProgress = MusicPlaybackProgressStore()

    @Published var library: [MusicPlaylist] = []
    /// Community playlists from `load_songs` / `playlists` (same as web «Плейлисты» row).
    @Published var discoverPlaylists: [MusicPlaylist] = []
    @Published var songsByCategory: [MusicCategory: [MusicSong]] = [:]
    @Published var artists: [MusicArtist] = []
    @Published var albums: [MusicAlbum] = []
    @Published var favoriteAlbumKeys: Set<String> = []
    @Published var favoriteAlbums: [MusicAlbum] = []
    @Published var selectedSong: MusicSong?
    @Published var selectedArtistForNavigation: MusicArtist? = nil
    @Published var currentQueue: [MusicSong] = []
    @Published var isLoading = false
    @Published var isPreparingPlayback = false
    @Published var isPlaying = false
    @Published var repeatMode: MusicRepeatMode = .off
    @Published var isRandomEnabled = false
    @Published var errorMessage: String?
    @Published private(set) var downloadProgressBySongID: [Int: Double] = [:]
    @Published private(set) var isLoadingMoreByCategory: [MusicCategory: Bool] = [:]
    @Published private(set) var isLoadingMoreDiscoverPlaylists: Bool = false

    private let apiClient: APIClient
    private let cacheStore: MusicScreenCacheStore
    private let songsPageSize: Int = 30
    private var nextDiscoverStartIndex: Int = 0
    private var hasMoreDiscoverPlaylists: Bool = true
    private var seenDiscoverPlaylistIDs: Set<Int> = []
    private var player: AVPlayer?
    private var currentIndex: Int = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var appDidEnterBackgroundObserver: NSObjectProtocol?
    private var appWillEnterForegroundObserver: NSObjectProtocol?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var audioSessionConfigured = false
    private var remoteCommandsConfigured = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isInitialLoadInFlight = false
    private var lastInitialLoadAt: Date?
    private var lastInitialLoadStartedAt: Date?
    private var activePlaybackRequestID = UUID()
    private var activeRequestedSongID: Int?
    private var lastPublishedPlaybackSecond: Int?
    private var lastNowPlayingElapsedSecond: Int?
    private var nextStartIndexByCategory: [MusicCategory: Int] = [:]
    private var hasMoreByCategory: [MusicCategory: Bool] = [:]
    private var seenSongIDsByCategory: [MusicCategory: Set<Int>] = [:]

    init(apiClient: APIClient = .shared, cacheStore: MusicScreenCacheStore = .shared) {
        self.apiClient = apiClient
        self.cacheStore = cacheStore
        if let stored = UserDefaults.standard.stringArray(forKey: "favorite_albums") {
            self.favoriteAlbumKeys = Set(stored)
        }
        if let data = UserDefaults.standard.data(forKey: "saved_favorite_albums"),
           let list = try? JSONDecoder().decode([MusicAlbum].self, from: data) {
            self.favoriteAlbums = list
        }
    }

    func loadInitialData(force: Bool = false) async {
        if isInitialLoadInFlight {
            return
        }

        if !force,
           let lastInitialLoadStartedAt,
           Date().timeIntervalSince(lastInitialLoadStartedAt) < 20 {
            return
        }

        let hasLoadedContent = !library.isEmpty || !discoverPlaylists.isEmpty || songsByCategory.values.contains(where: { !$0.isEmpty })
        if !force,
           hasLoadedContent,
           let lastInitialLoadAt,
           Date().timeIntervalSince(lastInitialLoadAt) < 15 {
            return
        }

        isInitialLoadInFlight = true
        lastInitialLoadStartedAt = Date()
        await hydrateFromCacheIfNeeded()
        isLoading = library.isEmpty && discoverPlaylists.isEmpty && songsByCategory.values.allSatisfy(\.isEmpty)
        errorMessage = nil
        defer {
            isLoading = false
            isInitialLoadInFlight = false
        }

        async let libraryTask = apiClient.loadMusicLibrary()
        async let favoritesTask = apiClient.loadSongs(category: .favorites)
        async let latestTask = apiClient.loadSongs(category: .latest)
        async let randomTask = apiClient.loadSongs(category: .random)
        async let discoverTask = apiClient.loadDiscoverPlaylists()
        async let artistsTask = apiClient.loadArtists()

        do {
            library = try await libraryTask
            let favoritesSongs = try await favoritesTask
            let latestSongs = try await latestTask
            let randomSongs = try await randomTask
            let discover = (try? await discoverTask) ?? []
            let artistsList = (try? await artistsTask) ?? []
            songsByCategory[.favorites] = favoritesSongs
            songsByCategory[.latest] = latestSongs
            songsByCategory[.random] = randomSongs
            discoverPlaylists = discover
            artists = artistsList
            resetPaginationState(for: .favorites, songs: favoritesSongs)
            resetPaginationState(for: .latest, songs: latestSongs)
            resetPaginationState(for: .random, songs: randomSongs)
            resetDiscoverPagination(playlists: discover)
            cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
            lastInitialLoadAt = Date()
            scheduleArtworkPrefetch()

            Task { [weak self] in
                await self?.loadFeaturedAlbums(for: artistsList)
            }
        } catch is CancellationError {
            // Pull-to-refresh or view teardown can cancel in-flight tasks; this is expected
            // and should not surface as an error toast/alert to the user.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func songs(for category: MusicCategory) -> [MusicSong] {
        songsByCategory[category] ?? []
    }

    func refreshCategory(_ category: MusicCategory) async {
        do {
            let refreshedSongs = try await apiClient.loadSongs(category: category)
            songsByCategory[category] = refreshedSongs
            resetPaginationState(for: category, songs: refreshedSongs)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func canLoadMoreSongs(for category: MusicCategory) -> Bool {
        hasMoreByCategory[category] ?? true
    }

    func isLoadingMoreSongs(for category: MusicCategory) -> Bool {
        isLoadingMoreByCategory[category] ?? false
    }

    func loadMoreSongs(for category: MusicCategory) async {
        guard category == .latest || category == .random else { return }
        guard !(isLoadingMoreByCategory[category] ?? false) else { return }
        guard hasMoreByCategory[category] ?? true else { return }

        isLoadingMoreByCategory[category] = true
        defer { isLoadingMoreByCategory[category] = false }

        let startIndex = nextStartIndexByCategory[category] ?? (songsByCategory[category]?.count ?? 0)
        print("[Music][LOAD_MORE] category=\(category.rawValue) startIndex=\(startIndex)")

        do {
            let fetchedSongs = try await apiClient.loadSongs(category: category, startIndex: startIndex)
            nextStartIndexByCategory[category] = startIndex + fetchedSongs.count
            print("[Music][LOAD_MORE] category=\(category.rawValue) fetched=\(fetchedSongs.count)")

            if fetchedSongs.isEmpty {
                // Server explicitly returned nothing -> stop for both.
                hasMoreByCategory[category] = false
                return
            }

            switch category {
            case .random:
                // For random selection we want the list to grow endlessly (duplicates are acceptable).
                songsByCategory[category, default: []].append(contentsOf: fetchedSongs)
                seenSongIDsByCategory[category, default: []].formUnion(fetchedSongs.map(\.id))
                cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
                // Keep hasMore=true unless the server returns empty.
                hasMoreByCategory[category] = true

            case .latest:
                var seenIDs = seenSongIDsByCategory[category] ?? Set((songsByCategory[category] ?? []).map(\.id))
                let uniqueSongs = fetchedSongs.filter { seenIDs.insert($0.id).inserted }
                print("[Music][LOAD_MORE] category=\(category.rawValue) uniqueAppend=\(uniqueSongs.count)")
                if !uniqueSongs.isEmpty {
                    songsByCategory[category, default: []].append(contentsOf: uniqueSongs)
                    seenSongIDsByCategory[category] = seenIDs
                    cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
                } else {
                    // If the server returns only already-seen tracks, still append them
                    // so the user sees infinite loading (duplicates are acceptable).
                    songsByCategory[category, default: []].append(contentsOf: fetchedSongs)
                    cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
                }
                // For "latest" we also keep loading until the server explicitly
                // returns an empty page. Page size here is not a reliable signal.
                hasMoreByCategory[category] = !fetchedSongs.isEmpty

            default:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func canLoadMoreDiscoverPlaylists() -> Bool {
        hasMoreDiscoverPlaylists
    }

    func loadMoreDiscoverPlaylists() async {
        guard !isLoadingMoreDiscoverPlaylists else { return }
        guard hasMoreDiscoverPlaylists else { return }

        isLoadingMoreDiscoverPlaylists = true
        defer { isLoadingMoreDiscoverPlaylists = false }

        let startIndex = nextDiscoverStartIndex
        print("[Music][LOAD_MORE] discover_playlists startIndex=\(startIndex)")

        do {
            let fetched = try await apiClient.loadDiscoverPlaylists(startIndex: startIndex)
            nextDiscoverStartIndex = startIndex + fetched.count
            print("[Music][LOAD_MORE] discover_playlists fetched=\(fetched.count)")

            if fetched.isEmpty {
                hasMoreDiscoverPlaylists = false
                return
            }

            var seen = seenDiscoverPlaylistIDs
            let unique = fetched.filter { seen.insert($0.id).inserted }
            if !unique.isEmpty {
                discoverPlaylists.append(contentsOf: unique)
                seenDiscoverPlaylistIDs = seen
            } else {
                discoverPlaylists.append(contentsOf: fetched)
            }
            hasMoreDiscoverPlaylists = !fetched.isEmpty
            cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetDiscoverPagination(playlists: [MusicPlaylist]) {
        nextDiscoverStartIndex = playlists.count
        hasMoreDiscoverPlaylists = !playlists.isEmpty
        seenDiscoverPlaylistIDs = Set(playlists.map(\.id))
        isLoadingMoreDiscoverPlaylists = false
    }

    func loadPlaylist(id: Int) async throws -> MusicPlaylistDetails {
        try await apiClient.loadMusicPlaylist(playlistID: id)
    }

    func selectSong(_ song: MusicSong, queue: [MusicSong]) async {
        currentQueue = queue
        currentIndex = queue.firstIndex(where: { $0.id == song.id }) ?? 0

        if isPreparingPlayback, activeRequestedSongID == song.id {
            return
        }

        if selectedSong?.id == song.id, !isPreparingPlayback {
            if !isPlaying {
                player?.play()
                isPlaying = true
                updateNowPlayingPlaybackState()
            }
            return
        }

        let requestID = UUID()
        activePlaybackRequestID = requestID
        activeRequestedSongID = song.id
        await play(song, requestID: requestID)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time)
        playbackProgress.currentTime = max(0, seconds)
        updateNowPlayingPlaybackState()
    }

    func toggleLikeCurrentSong() async {
        guard let selectedSong else { return }
        let newValue = !selectedSong.liked
        updateLikeState(songID: selectedSong.id, liked: newValue, songTemplate: selectedSong)

        do {
            if newValue {
                try await apiClient.addMusicFav(songID: selectedSong.id)
            } else {
                try await apiClient.removeMusicFav(songID: selectedSong.id)
            }
        } catch {
            updateLikeState(songID: selectedSong.id, liked: !newValue, songTemplate: selectedSong)
            errorMessage = error.localizedDescription
        }
    }

    func toggleLike(song: MusicSong) async {
        let newValue = !song.liked
        updateLikeState(songID: song.id, liked: newValue, songTemplate: song)

        do {
            if newValue {
                try await apiClient.addMusicFav(songID: song.id)
            } else {
                try await apiClient.removeMusicFav(songID: song.id)
            }
        } catch {
            updateLikeState(songID: song.id, liked: !newValue, songTemplate: song)
            errorMessage = error.localizedDescription
        }
    }

    func refreshLibrary() async {
        do {
            library = try await apiClient.loadMusicLibrary()
            cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadFeaturedAlbums(for artistsList: [MusicArtist]) async {
        var collectedAlbums: [MusicAlbum] = []
        var seenKeys: Set<String> = []

        let topArtists = artistsList.filter { $0.slug != nil && !$0.slug!.isEmpty }.prefix(14)
        await withTaskGroup(of: [MusicAlbum].self) { group in
            for artist in topArtists {
                guard let slug = artist.slug else { continue }
                group.addTask {
                    if let res = try? await self.apiClient.loadArtistDetails(slug: slug) {
                        return res.albums
                    }
                    return []
                }
            }
            for await artistAlbums in group {
                for album in artistAlbums {
                    let key = album.id > 0 ? "id:\(album.id)" : "title:\(album.title.lowercased())"
                    if !seenKeys.contains(key) {
                        seenKeys.insert(key)
                        collectedAlbums.append(album)
                    }
                }
            }
        }

        if !collectedAlbums.isEmpty {
            self.albums = collectedAlbums

            var favChanged = false
            for album in collectedAlbums {
                let key = albumKey(albumID: album.id, title: album.title)
                if favoriteAlbumKeys.contains(key) {
                    if !favoriteAlbums.contains(where: { ($0.id > 0 && $0.id == album.id) || $0.title.lowercased() == album.title.lowercased() }) {
                        favoriteAlbums.append(album)
                        favChanged = true
                    }
                }
            }
            for i in favoriteAlbums.indices {
                if let matched = collectedAlbums.first(where: { ($0.id > 0 && $0.id == favoriteAlbums[i].id) || $0.title.lowercased() == favoriteAlbums[i].title.lowercased() }) {
                    if favoriteAlbums[i].cover == nil || favoriteAlbums[i].artistName == nil || favoriteAlbums[i].id == 0 {
                        favoriteAlbums[i] = matched
                        favChanged = true
                    }
                }
            }
            if favChanged, let data = try? JSONEncoder().encode(favoriteAlbums) {
                UserDefaults.standard.set(data, forKey: "saved_favorite_albums")
            }
        }
    }

    func isAlbumFavorite(albumID: Int, title: String) -> Bool {
        let key = albumKey(albumID: albumID, title: title)
        if favoriteAlbumKeys.contains(key) { return true }
        return favoriteAlbums.contains(where: {
            if albumID > 0 && $0.id > 0 { return $0.id == albumID }
            return $0.title.lowercased() == title.lowercased()
        })
    }

    func toggleAlbumFavorite(album: MusicAlbum) async {
        let key = albumKey(albumID: album.id, title: album.title)
        let isFav = isAlbumFavorite(albumID: album.id, title: album.title)
        if isFav {
            favoriteAlbumKeys.remove(key)
            favoriteAlbums.removeAll(where: {
                if album.id > 0 && $0.id > 0 { return $0.id == album.id }
                return $0.title.lowercased() == album.title.lowercased()
            })
        } else {
            favoriteAlbumKeys.insert(key)
            if !favoriteAlbums.contains(where: {
                if album.id > 0 && $0.id > 0 { return $0.id == album.id }
                return $0.title.lowercased() == album.title.lowercased()
            }) {
                favoriteAlbums.append(album)
            }
        }
        UserDefaults.standard.set(Array(favoriteAlbumKeys), forKey: "favorite_albums")
        if let data = try? JSONEncoder().encode(favoriteAlbums) {
            UserDefaults.standard.set(data, forKey: "saved_favorite_albums")
        }

        if album.id > 0 {
            if isFav {
                try? await apiClient.removeAlbumFromFavorites(albumID: album.id)
            } else {
                try? await apiClient.addAlbumToFavorites(albumID: album.id)
            }
        }
    }

    func toggleAlbumFavorite(albumID: Int, title: String) async {
        let found = albums.first(where: { (albumID > 0 && $0.id == albumID) || $0.title.lowercased() == title.lowercased() })
            ?? favoriteAlbums.first(where: { (albumID > 0 && $0.id == albumID) || $0.title.lowercased() == title.lowercased() })
            ?? MusicAlbum(id: albumID, title: title)
        await toggleAlbumFavorite(album: found)
    }

    private func albumKey(albumID: Int, title: String) -> String {
        if albumID > 0 {
            return "id:\(albumID)"
        }
        return "title:\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func loadArtistSongs(slug: String) async throws -> (artist: MusicArtist, songs: [MusicSong], albums: [MusicAlbum]) {
        return try await apiClient.loadArtistDetails(slug: slug)
    }

    func updateSongLyrics(songID: Int, lines: [LyricsLine]) async throws {
        try await apiClient.saveSongLyrics(songID: songID, lines: lines)
    }

    func updateSongCover(songID: Int, coverData: Data) async throws {
        let newMedia = try await apiClient.editSongCover(songID: songID, coverData: coverData)
        if let newMedia {
            applySongUpdate(songID: songID) { song in
                song.with(cover: newMedia)
            }
        }
    }

    func updateSongMetadata(
        songID: Int,
        title: String,
        artist: String,
        album: String?,
        lyrics: [LyricsLine]?,
        coverData: Data?
    ) async throws {
        try await apiClient.editSongMetadata(
            songID: songID,
            title: title,
            artist: artist,
            album: album,
            lyrics: lyrics,
            coverData: coverData
        )
        if let coverData {
            _ = try? await apiClient.editSongCover(songID: songID, coverData: coverData)
        }
        applySongUpdate(songID: songID) { song in
            song.with(title: title, artist: artist, album: album)
        }
    }

    private func applySongUpdate(songID: Int, transform: (MusicSong) -> MusicSong) {
        if let current = selectedSong, current.id == songID {
            selectedSong = transform(current)
        }
        for (index, song) in currentQueue.enumerated() where song.id == songID {
            currentQueue[index] = transform(song)
        }
        for (category, songs) in songsByCategory {
            var updated = songs
            var modified = false
            for (i, s) in songs.enumerated() where s.id == songID {
                updated[i] = transform(s)
                modified = true
            }
            if modified {
                songsByCategory[category] = updated
            }
        }
        cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
    }

    func next() async {
        guard !currentQueue.isEmpty else { return }
        if isRandomEnabled {
            currentIndex = Int.random(in: 0..<currentQueue.count)
        } else {
            let nextIndex = currentIndex + 1
            if nextIndex >= currentQueue.count {
                switch repeatMode {
                case .all:
                    currentIndex = 0
                case .one, .off:
                    player?.pause()
                    isPlaying = false
                    playbackProgress.currentTime = playbackProgress.duration
                    updateNowPlayingPlaybackState()
                    return
                }
            } else {
                currentIndex = nextIndex
            }
        }
        let requestID = UUID()
        activePlaybackRequestID = requestID
        activeRequestedSongID = currentQueue[currentIndex].id
        await play(currentQueue[currentIndex], requestID: requestID)
    }

    func previous() async {
        guard !currentQueue.isEmpty else { return }
        if isRandomEnabled {
            currentIndex = Int.random(in: 0..<currentQueue.count)
        } else {
            currentIndex = currentIndex == 0 ? currentQueue.count - 1 : currentIndex - 1
        }
        let requestID = UUID()
        activePlaybackRequestID = requestID
        activeRequestedSongID = currentQueue[currentIndex].id
        await play(currentQueue[currentIndex], requestID: requestID)
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func downloadProgress(for songID: Int) -> Double? {
        downloadProgressBySongID[songID]
    }

    private func setDownloadProgress(_ progress: Double, for songID: Int) {
        downloadProgressBySongID[songID] = min(max(progress, 0), 1)
    }

    private func clearDownloadProgress(for songID: Int) {
        downloadProgressBySongID.removeValue(forKey: songID)
    }

    private func isActivePlaybackRequest(_ requestID: UUID) -> Bool {
        activePlaybackRequestID == requestID
    }

    var shouldKeepSocketAliveInBackground: Bool {
        isPreparingPlayback || isPlaying
    }

    private func play(_ song: MusicSong, requestID: UUID) async {
        var progressSongID = song.id

        do {
            guard isActivePlaybackRequest(requestID) else {
                throw CancellationError()
            }

            print("[Music][PLAY REQUEST] song_id=\(song.id) title=\(song.title)")
            isPreparingPlayback = true
            errorMessage = nil
            beginBackgroundPreparationTaskIfNeeded()
            configureAudioSessionIfNeeded()
            configureRemoteCommandsIfNeeded()
            installInterruptionObserverIfNeeded()
            installDiagnosticsObserversIfNeeded()

            let fullSong: MusicSong
            do {
                let loaded = try await apiClient.loadSong(songID: song.id)
                fullSong = loaded.mergedForPlayback(with: song)
            } catch {
                fullSong = song
            }

            progressSongID = fullSong.id

            guard isActivePlaybackRequest(requestID) else {
                throw CancellationError()
            }

            selectedSong = fullSong
            playbackProgress.duration = fullSong.duration ?? 0
            playbackProgress.currentTime = 0
            setDownloadProgress(0, for: fullSong.id)

            guard let fileID = fullSong.originalFileID else {
                throw APIError.serverError("У трека отсутствует file_id")
            }

            let fileURL = try await apiClient.downloadMusicFile(
                fileID: fileID,
                audioFormat: fullSong.audioFormat,
                onProgress: { [weak self] progress in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.setDownloadProgress(progress, for: fullSong.id)
                    }
                }
            )
            clearDownloadProgress(for: fullSong.id)

            guard isActivePlaybackRequest(requestID) else {
                throw CancellationError()
            }

            print("[Music][PLAYER READY] song_id=\(fullSong.id) file=\(fileURL.lastPathComponent)")
            let item = AVPlayerItem(url: fileURL)
            let player = AVPlayer(playerItem: item)
            if #available(iOS 14.0, *) {
                player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            }

            teardownPlayer()
            self.player = player
            selectedSong = fullSong
            installTimeObserver(on: player)
            installEndObserver(for: item)
            installPlayerStateObserver(on: player)
            player.play()
            print("[Music][PLAYBACK STARTED] song_id=\(fullSong.id)")
            isPlaying = true
            isPreparingPlayback = false
            activeRequestedSongID = nil
            updateNowPlayingMetadata(for: fullSong)
            updateNowPlayingPlaybackState()
            endBackgroundPreparationTaskIfNeeded()
        } catch is CancellationError {
            clearDownloadProgress(for: progressSongID)
            if isActivePlaybackRequest(requestID) {
                isPreparingPlayback = false
                activeRequestedSongID = nil
                endBackgroundPreparationTaskIfNeeded()
            }
        } catch {
            clearDownloadProgress(for: progressSongID)
            if isActivePlaybackRequest(requestID) {
                isPreparingPlayback = false
                isPlaying = false
                activeRequestedSongID = nil
                errorMessage = error.localizedDescription
                endBackgroundPreparationTaskIfNeeded()
            }
        }
    }

    private func updateLikeState(songID: Int, liked: Bool, songTemplate: MusicSong? = nil) {
        if selectedSong?.id == songID {
            selectedSong?.liked = liked
        }
        for category in MusicCategory.allCases {
            guard var songs = songsByCategory[category] else { continue }
            if let index = songs.firstIndex(where: { $0.id == songID }) {
                songs[index].liked = liked
                songsByCategory[category] = songs
                continue
            }
            if category == .favorites, liked, let songTemplate {
                var favoriteSong = songTemplate
                favoriteSong.liked = true
                songs.insert(favoriteSong, at: 0)
                songsByCategory[category] = deduplicatedSongs(songs)
            }
        }
        if !liked, var favoriteSongs = songsByCategory[.favorites] {
            favoriteSongs.removeAll { $0.id == songID }
            songsByCategory[.favorites] = favoriteSongs
        }
        if let index = currentQueue.firstIndex(where: { $0.id == songID }) {
            currentQueue[index].liked = liked
        }
        cacheStore.save(library: library, songsByCategory: songsByCategory, discoverPlaylists: discoverPlaylists)
    }

    private func deduplicatedSongs(_ songs: [MusicSong]) -> [MusicSong] {
        var seen = Set<Int>()
        return songs.filter { song in
            seen.insert(song.id).inserted
        }
    }

    private func resetPaginationState(for category: MusicCategory, songs: [MusicSong]) {
        nextStartIndexByCategory[category] = songs.count
        if category == .random {
            hasMoreByCategory[category] = true
        } else {
            // Optimistic: keep loading until the server returns an empty page.
            hasMoreByCategory[category] = !songs.isEmpty
        }
        seenSongIDsByCategory[category] = Set(songs.map(\.id))
        isLoadingMoreByCategory[category] = false
    }

    private func hydrateFromCacheIfNeeded() async {
        guard library.isEmpty && discoverPlaylists.isEmpty && songsByCategory.values.allSatisfy(\.isEmpty),
              let cached = await cacheStore.loadAsync() else {
            return
        }

        library = cached.asLibrary
        songsByCategory = cached.asSongsByCategory
        discoverPlaylists = cached.asDiscoverPlaylists
        for category in MusicCategory.allCases {
            resetPaginationState(for: category, songs: songsByCategory[category] ?? [])
        }
        resetDiscoverPagination(playlists: discoverPlaylists)
    }

    private func scheduleArtworkPrefetch() {
        let candidateSongs = [
            songsByCategory[.favorites] ?? [],
            songsByCategory[.latest] ?? [],
            songsByCategory[.random] ?? []
        ]
        .flatMap { $0.prefix(5) }

        guard !candidateSongs.isEmpty else { return }
        let apiClient = apiClient

        Task.detached(priority: .utility) {
            var seenArtworkIDs = Set<String>()

            for song in candidateSongs {
                guard let media = song.cover else { continue }
                let artworkID = media.imageLoadKey
                guard !artworkID.isEmpty, seenArtworkIDs.insert(artworkID).inserted else { continue }
                _ = await apiClient.downloadMediaImage(media, lossless: false)
            }
        }
    }

    private func configureAudioSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        do {
            if #available(iOS 13.0, *) {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            } else {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            print("[Music] Audio session configured for playback category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
            audioSessionConfigured = true
        } catch {
            audioSessionConfigured = false
            print("[Music] Audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.isPlaying {
                self.togglePlayPause()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying {
                self.togglePlayPause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.next() }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.previous() }
            return .success
        }
    }

    private func installInterruptionObserverIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard
                    let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: typeValue)
                else { return }

                switch type {
                case .began:
                    self.isPlaying = false
                    self.updateNowPlayingPlaybackState()
                case .ended:
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        print("[Music] Failed to reactivate audio session: \(error.localizedDescription)")
                    }

                    let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        self.player?.play()
                        self.isPlaying = true
                    }
                    self.updateNowPlayingPlaybackState()
                @unknown default:
                    break
                }
            }
        }
    }

    private func installDiagnosticsObserversIfNeeded() {
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { notification in
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
                print("[Music][ROUTE CHANGE] reason=\(reason.map { String($0.rawValue) } ?? "unknown")")
            }
        }

        if mediaServicesResetObserver == nil {
            mediaServicesResetObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("[Music][AUDIO RESET] media services were reset")
                    self.audioSessionConfigured = false
                    self.configureAudioSessionIfNeeded()
                    if self.isPlaying {
                        self.player?.play()
                    }
                }
            }
        }

        if appDidEnterBackgroundObserver == nil {
            appDidEnterBackgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("[Music][APP] didEnterBackground isPlaying=\(self.isPlaying) rate=\(self.player?.rate ?? 0)")
                }
            }
        }

        if appWillEnterForegroundObserver == nil {
            appWillEnterForegroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("[Music][APP] willEnterForeground isPlaying=\(self.isPlaying) rate=\(self.player?.rate ?? 0)")
                }
            }
        }
    }

    private func installPlayerStateObserver(on player: AVPlayer) {
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else { return }
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            print("[Music][PLAYER STATE] timeControlStatus=\(player.timeControlStatus.rawValue) rate=\(player.rate) reason=\(reason)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newIsPlaying = player.timeControlStatus == .playing
                if self.isPlaying != newIsPlaying {
                    self.isPlaying = newIsPlaying
                    self.updateNowPlayingPlaybackState()
                }
            }
        }
    }

    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let resolvedTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            let roundedSecond = Int(resolvedTime.rounded(.down))
            let itemDuration = player.currentItem?.duration.seconds
            let newIsPlaying = player.rate > 0

            Task { @MainActor [weak self] in
                guard let self else { return }

                if self.lastPublishedPlaybackSecond != roundedSecond
                    || abs(self.playbackProgress.currentTime - resolvedTime) >= 0.45 {
                    self.playbackProgress.currentTime = resolvedTime
                    self.lastPublishedPlaybackSecond = roundedSecond
                }

                if let itemDuration,
                   itemDuration.isFinite,
                   abs(self.playbackProgress.duration - itemDuration) >= 0.5 {
                    self.playbackProgress.duration = itemDuration
                }

                if self.isPlaying != newIsPlaying {
                    self.isPlaying = newIsPlaying
                }

                if self.lastNowPlayingElapsedSecond != roundedSecond {
                    self.lastNowPlayingElapsedSecond = roundedSecond
                    self.updateNowPlayingPlaybackState()
                }
            }
        }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.player?.play()
                    self.isPlaying = true
                } else {
                    await self.next()
                }
            }
        }
    }

    private func teardownPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil

        timeControlStatusObservation = nil

        player?.pause()
        player = nil
        endBackgroundPreparationTaskIfNeeded()
    }

    private func beginBackgroundPreparationTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MusicPlaybackPreparation") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundPreparationTaskIfNeeded()
            }
        }
    }

    private func endBackgroundPreparationTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func updateNowPlayingMetadata(for song: MusicSong) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        if let album = song.album, !album.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }
        if let duration = song.duration, duration.isFinite {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlayingPlaybackState() {
        guard selectedSong != nil else { return }
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackProgress.currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = playbackProgress.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }
}
