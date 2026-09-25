import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer
import PhotosUI
import UniformTypeIdentifiers

struct MusicRootView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = MusicPlayerViewModel.shared
    @State private var isFullPlayerPresented = false
    @State private var quickActionAlert: QuickActionAlert?
    @State private var isCreatePlaylistSheetPresented = false
    @State private var isAddSongSheetPresented = false
    @State private var musicSearchQuery = ""
    @State private var isMusicSearchPresented = false
    @FocusState private var isMusicSearchFocused: Bool
    @State private var selectedArtistForNavigation: MusicArtist? = nil
    @State private var isArtistNavigationActive = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 22) {
                musicSearchBar
                // Tap-to-dismiss is scoped below the search bar: a tap covering
                // the search TextField would resign + refocus it, resetting
                // the cursor/selection to the end of the text.
                Group {
                quickActions
                artistsSection
                myMusicSection
                albumsSection
                songsGridSection(
                    title: AppLang.key("music_latest", code: selectedLanguageCode, fallback: "Latest"),
                    category: .latest,
                    songs: filteredSongs(for: .latest),
                    baseQueue: filteredSongs(for: .latest)
                )
                userPlaylistsDiscoverSection
                songsGridSection(
                    title: AppLang.key("music_random", code: selectedLanguageCode, fallback: "Random selection"),
                    category: .random,
                    songs: filteredSongs(for: .random),
                    baseQueue: filteredSongs(for: .random)
                )
                footerSection
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        dismissKeyboard()
                    }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 150)
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.key("nav_music", code: selectedLanguageCode, fallback: "Музыка"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isMusicSearchPresented) {
            MusicSearchScreen(initialQuery: musicSearchQuery)
        }
        .navigationDestination(isPresented: $isArtistNavigationActive) {
            if let artist = selectedArtistForNavigation {
                MusicArtistDetailScreen(artist: artist)
            }
        }
        .onChange(of: viewModel.selectedArtistForNavigation) { artist in
            if let artist = artist {
                self.selectedArtistForNavigation = artist
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.isArtistNavigationActive = true
                }
            } else {
                self.isArtistNavigationActive = false
            }
        }
        .onChange(of: isArtistNavigationActive) { active in
            if !active {
                viewModel.selectedArtistForNavigation = nil
            }
        }
        .task {
            await viewModel.loadInitialData()
        }
        .refreshable {
            await viewModel.loadInitialData(force: true)
        }
        .sheet(isPresented: $isFullPlayerPresented) {
            MusicFullPlayerView(viewModel: viewModel) { artist in
                self.isFullPlayerPresented = false
                viewModel.selectedArtistForNavigation = artist
            }
        }
        .sheet(isPresented: $isCreatePlaylistSheetPresented) {
            CreatePlaylistSheet { name, description, coverData in
                await createPlaylist(name: name, description: description, coverData: coverData)
            }
        }
        .sheet(isPresented: $isAddSongSheetPresented) {
            AddSongSheet { submission in
                await uploadSong(submission)
            }
        }
        .alert(item: $quickActionAlert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть")))
            )
        }
        .alert(
            AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.clearError() } }
            )
        ) {
            Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var musicSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)

            TextField(
                AppLang.tr("Поиск по музыке", "Search music", code: selectedLanguageCode),
                text: $musicSearchQuery
            )
            .focused($isMusicSearchFocused)
            .foregroundStyle(AppTheme.textPrimary)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .submitLabel(.search)
            .onSubmit {
                openMusicSearch()
            }

            if !musicSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    openMusicSearch()
                } label: {
                    Text(AppLang.tr("Найти", "Search", code: selectedLanguageCode))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(searchFieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(searchFieldStroke, lineWidth: 1)
        )
    }

    private var accountSummary: APIClient.AccountSummary {
        APIClient.shared.currentAccountSummary()
    }

    private var filteredLibrary: [MusicPlaylist] {
        viewModel.library
    }

    private func filteredSongs(for category: MusicCategory) -> [MusicSong] {
        viewModel.songs(for: category)
    }

    private var favoritesSongs: [MusicSong] {
        filteredSongs(for: .favorites)
    }

    private var quickActions: some View {
        HStack(spacing: 14) {
            MusicActionButton(
                title: AppLang.key("music_add_playlist", code: selectedLanguageCode, fallback: "Create playlist"),
                systemImage: "plus"
            ) {
                isCreatePlaylistSheetPresented = true
            }

            MusicActionButton(
                title: AppLang.key("music_add", code: selectedLanguageCode, fallback: "Add song"),
                systemImage: "square.and.arrow.up"
            ) {
                isAddSongSheetPresented = true
            }
        }
        .padding(.top, 4)
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(AppLang.tr("Исполнители", "Artists", code: selectedLanguageCode))

            if viewModel.artists.isEmpty && !viewModel.isLoading {
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(viewModel.artists) { artist in
                            NavigationLink {
                                MusicArtistDetailScreen(artist: artist)
                            } label: {
                                VStack(spacing: 8) {
                                    ArtistAvatarArtworkView(media: artist.avatar, size: 90, name: artist.name)
                                        .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
                                    
                                    Text(artist.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .lineLimit(1)
                                        .frame(width: 90)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private var displayAlbumsList: [MusicAlbum] {
        var list = viewModel.albums
        var seenKeys = Set(list.map { $0.id > 0 ? "id:\($0.id)" : "title:\($0.title.lowercased())" })
        let allSongs = (viewModel.songsByCategory[.latest] ?? []) + (viewModel.songsByCategory[.random] ?? []) + (viewModel.songsByCategory[.favorites] ?? [])
        for song in allSongs {
            guard let albumName = song.album?.trimmingCharacters(in: .whitespacesAndNewlines), !albumName.isEmpty else { continue }
            let key = "title:\(albumName.lowercased())"
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                list.append(MusicAlbum(
                    id: 0,
                    title: albumName,
                    artistName: song.artist,
                    cover: song.cover,
                    releaseDate: song.dateAdded
                ))
            }
        }
        return list
    }

    private var albumsSection: some View {
        let albumsList = displayAlbumsList
        return Group {
            if !albumsList.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle(AppLang.tr("Альбомы", "Albums", code: selectedLanguageCode))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(albumsList) { album in
                                NavigationLink {
                                    MusicAlbumDetailScreen(albumID: album.id, initialTitle: album.title)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        MusicCoverArtworkView(media: album.cover, size: 152)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title)
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundStyle(AppTheme.textPrimary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)

                                            if let artist = album.artistName, !artist.isEmpty {
                                                Text(artist)
                                                    .font(.system(size: 14, weight: .regular))
                                                    .foregroundStyle(AppTheme.textSecondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                        }
                                    }
                                    .frame(width: 152, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16)
                }
            }
        }
    }

    private var favoriteAlbumsList: [MusicAlbum] {
        var list = viewModel.favoriteAlbums
        var seenKeys = Set(list.map { $0.id > 0 ? "id:\($0.id)" : "title:\($0.title.lowercased())" })

        for album in viewModel.albums {
            let key = album.id > 0 ? "id:\(album.id)" : "title:\(album.title.lowercased())"
            if (viewModel.favoriteAlbumKeys.contains(key) || viewModel.isAlbumFavorite(albumID: album.id, title: album.title)) && !seenKeys.contains(key) {
                seenKeys.insert(key)
                list.append(album)
            }
        }
        return list
    }

    private var myMusicSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(AppLang.tr("Моя музыка", "My Music", code: selectedLanguageCode))

            let favAlbums = favoriteAlbumsList

            if favoritesSongs.isEmpty && filteredLibrary.isEmpty && favAlbums.isEmpty && !viewModel.isLoading {
                emptyState(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        favoritesCard

                        ForEach(filteredLibrary) { playlist in
                            NavigationLink {
                                MusicPlaylistScreen(
                                    playlist: playlist,
                                    fallbackSongs: nil,
                                    selectedSongID: viewModel.selectedSong?.id,
                                    onSelectSong: { song, queue in
                                        Task { await viewModel.selectSong(song, queue: queue) }
                                    }
                                )
                            } label: {
                                MusicPlaylistCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(favAlbums) { album in
                            NavigationLink {
                                MusicAlbumDetailScreen(albumID: album.id, initialTitle: album.title)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .bottomTrailing) {
                                        MusicCoverArtworkView(
                                            media: album.cover,
                                            size: 152
                                        )

                                        Image(systemName: "opticaldisc")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(6)
                                            .background(Color.black.opacity(0.55), in: Circle())
                                            .padding(8)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        Text(album.artistName ?? AppLang.tr("Альбом", "Album", code: selectedLanguageCode))
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundStyle(AppTheme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                .frame(width: 152, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private var favoritesCard: some View {
        NavigationLink {
            MusicPlaylistScreen(
                playlist: MusicPlaylist(
                    id: -1,
                    type: 1,
                    title: AppLang.key("music_favorites", code: selectedLanguageCode, fallback: "Favorites"),
                    authorName: accountSummary.name,
                    authorUsername: accountSummary.username,
                    addDate: nil,
                    cover: nil
                ),
                fallbackSongs: favoritesSongs,
                selectedSongID: viewModel.selectedSong?.id,
                onSelectSong: { song, queue in
                    Task { await viewModel.selectSong(song, queue: queue) }
                }
            )
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.79, green: 0.71, blue: 0.96))
                    .frame(width: 152, height: 152)
                    .overlay(
                        Image(systemName: "heart.fill")
                            .font(.system(size: 60, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [AppTheme.primary, AppTheme.primarySoft],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLang.key("music_favorites", code: selectedLanguageCode, fallback: "Favorites"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(accountSummary.name ?? accountSummary.username ?? "")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 152, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var userPlaylistsDiscoverSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(
                AppLang.tr("Плейлисты от пользователей", "User playlists", code: selectedLanguageCode)
            )

            if viewModel.isLoading && viewModel.discoverPlaylists.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 30)
            } else if viewModel.discoverPlaylists.isEmpty {
                emptyState(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(viewModel.discoverPlaylists.enumerated()), id: \.element.id) { index, playlist in
                            NavigationLink {
                                MusicPlaylistScreen(
                                    playlist: playlist,
                                    fallbackSongs: nil,
                                    selectedSongID: viewModel.selectedSong?.id,
                                    onSelectSong: { song, queue in
                                        Task { await viewModel.selectSong(song, queue: queue) }
                                    }
                                )
                            } label: {
                                MusicPlaylistCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                guard index >= max(0, viewModel.discoverPlaylists.count - 4),
                                      viewModel.canLoadMoreDiscoverPlaylists(),
                                      !viewModel.isLoadingMoreDiscoverPlaylists else { return }
                                Task { await viewModel.loadMoreDiscoverPlaylists() }
                            }
                        }

                        if viewModel.isLoadingMoreDiscoverPlaylists {
                            ProgressView()
                                .frame(width: 44, height: 168)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    @ViewBuilder
    private func songsGridSection(title: String, category: MusicCategory, songs: [MusicSong], baseQueue: [MusicSong]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title)

            if viewModel.isLoading && songs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 30)
            } else if songs.isEmpty {
                emptyState(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                            MusicSongGridCard(
                                song: song,
                                playlists: filteredLibrary,
                                downloadProgress: viewModel.downloadProgress(for: song.id)
                            ) {
                                Task { await viewModel.selectSong(song, queue: baseQueue) }
                            } onToggleLike: {
                                Task { await viewModel.toggleLike(song: song) }
                            } onAddToPlaylist: { playlist in
                                Task { await addSong(song, to: playlist) }
                            } onCreatePlaylist: {
                                isCreatePlaylistSheetPresented = true
                            }
                            .onAppear {
                                guard index >= max(0, songs.count - 6),
                                      viewModel.canLoadMoreSongs(for: category),
                                      !viewModel.isLoadingMoreSongs(for: category) else { return }
                                Task { await viewModel.loadMoreSongs(for: category) }
                            }
                        }

                        if viewModel.isLoadingMoreSongs(for: category) {
                            ProgressView()
                                .frame(width: 44, height: 168)
                        }
                    }
                    .padding(.leading, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private var footerSection: some View {
        Text("\(AppLang.key("music_copyright", code: selectedLanguageCode, fallback: "For copyright holders")) - elemsupport@proton.me")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 23, weight: .bold))
            .foregroundStyle(AppTheme.textPrimary)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }

    private func openMusicSearch() {
        let trimmed = musicSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        musicSearchQuery = trimmed
        isMusicSearchPresented = true
    }

    private var searchFieldBackground: Color {
        if colorScheme == .light {
            return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 18.0 / 255.0)
        }
        return AppTheme.surfaceElevated
    }

    private var searchFieldStroke: Color {
        if #available(iOS 26.0, *) {
            return .clear
        }
        return AppTheme.cardStroke
    }

    private func createPlaylist(name: String, description: String, coverData: Data?) async -> String? {
        do {
            try await APIClient.shared.createMusicPlaylist(name: name, description: description, coverData: coverData)
            await viewModel.refreshLibrary()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func uploadSong(_ submission: MusicUploadSubmission) async -> String? {
        do {
            try await APIClient.shared.uploadMusicTrack(
                fileData: submission.audioData,
                fileName: submission.audioFileName,
                coverData: submission.coverData,
                coverFileName: submission.coverFileName,
                title: submission.title,
                artist: submission.artist,
                album: submission.album,
                trackNumber: submission.trackNumber,
                genre: submission.genre,
                releaseDate: submission.releaseDate,
                composer: submission.composer
            )
            await viewModel.loadInitialData(force: true)
            quickActionAlert = QuickActionAlert(
                title: AppLang.tr("Готово", "Done", code: selectedLanguageCode),
                message: AppLang.tr("Трек отправлен в библиотеку.", "The track was uploaded to the library.", code: selectedLanguageCode)
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func addSong(_ song: MusicSong, to playlist: MusicPlaylist) async {
        do {
            try await APIClient.shared.addSongToMusicPlaylist(songID: song.id, playlistID: playlist.id)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func dismissKeyboard() {
        isMusicSearchFocused = false
    }
}

private struct QuickActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct MusicUploadSubmission {
    let audioData: Data
    let audioFileName: String
    let coverData: Data?
    let coverFileName: String?
    let title: String
    let artist: String
    let album: String?
    let trackNumber: Int?
    let genre: String?
    let releaseDate: String?
    let composer: String?
}

private struct CreatePlaylistSheet: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var coverPreview: UIImage?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    let onCreate: (String, String, Data?) async -> String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $selectedCoverItem, matching: .images) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 160)

                            if let coverPreview {
                                Image(uiImage: coverPreview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 36, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    Text(AppLang.key("music_form_cover", code: selectedLanguageCode, fallback: "Select cover"))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(AppLang.tr("Обложка", "Cover", code: selectedLanguageCode))
                } footer: {
                    Text(
                        AppLang.tr(
                            "По желанию. Как на сайте — картинка для карточки плейлиста.",
                            "Optional. Same as on the web — artwork for the playlist card.",
                            code: selectedLanguageCode
                        )
                    )
                }

                Section {
                    TextField(
                        AppLang.tr("Название плейлиста", "Playlist title", code: selectedLanguageCode),
                        text: $name
                    )

                    TextField(
                        AppLang.tr("Описание", "Description", code: selectedLanguageCode),
                        text: $description,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                } header: {
                    Text(AppLang.tr("Новый плейлист", "New playlist", code: selectedLanguageCode))
                } footer: {
                    Text(
                        AppLang.tr(
                            "Название обязательно, описание можно оставить пустым.",
                            "A title is required, description can be empty.",
                            code: selectedLanguageCode
                        )
                    )
                }
            }
            .navigationTitle(AppLang.key("music_add_playlist", code: selectedLanguageCode, fallback: "Create playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLang.tr("Создать", "Create", code: selectedLanguageCode)) {
                        Task {
                            isSubmitting = true
                            let error = await onCreate(
                                trimmedName,
                                description.trimmingCharacters(in: .whitespacesAndNewlines),
                                coverData
                            )
                            isSubmitting = false
                            if let error {
                                errorMessage = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(trimmedName.isEmpty || isSubmitting)
                }
            }
            .onChange(of: selectedCoverItem) { newItem in
                guard let newItem else { return }
                Task {
                    await loadCover(from: newItem)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert(
            AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadCover(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            await MainActor.run {
                coverData = data
                coverPreview = UIImage(data: data)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct EditPlaylistSheet: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss

    let existingCover: MediaData?

    let onSave: (String, String, Int, Data?) async -> String?

    @State private var name: String
    @State private var description: String
    @State private var privacy: Int
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var newCoverData: Data?
    @State private var newCoverPreview: UIImage?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        initialTitle: String,
        initialDescription: String,
        initialPrivacy: Int,
        existingCover: MediaData?,
        onSave: @escaping (String, String, Int, Data?) async -> String?
    ) {
        self.existingCover = existingCover
        self.onSave = onSave
        _name = State(initialValue: initialTitle)
        _description = State(initialValue: initialDescription)
        _privacy = State(initialValue: initialPrivacy)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $selectedCoverItem, matching: .images) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 160)

                            if let newCoverPreview {
                                Image(uiImage: newCoverPreview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            } else if let existingCover {
                                MusicCoverArtworkView(
                                    media: existingCover,
                                    size: 160,
                                    cornerRadius: 16,
                                    showsBorder: false,
                                    downloadProgress: nil
                                )
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 36, weight: .medium))
                                        .foregroundStyle(AppTheme.textSecondary)
                                    Text(AppLang.key("music_form_cover", code: selectedLanguageCode, fallback: "Select cover"))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(AppLang.tr("Обложка", "Cover", code: selectedLanguageCode))
                }

                Section {
                    TextField(
                        AppLang.tr("Название плейлиста", "Playlist title", code: selectedLanguageCode),
                        text: $name
                    )

                    TextField(
                        AppLang.tr("Описание", "Description", code: selectedLanguageCode),
                        text: $description,
                        axis: .vertical
                    )
                    .lineLimit(3...6)

                    Picker(AppLang.tr("Доступ", "Privacy", code: selectedLanguageCode), selection: $privacy) {
                        Text(AppLang.tr("Публичный", "Public", code: selectedLanguageCode)).tag(0)
                        Text(AppLang.tr("Приватный", "Private", code: selectedLanguageCode)).tag(1)
                        Text(AppLang.tr("Только по ссылке", "Link only", code: selectedLanguageCode)).tag(2)
                    }
                } header: {
                    Text(AppLang.tr("Плейлист", "Playlist", code: selectedLanguageCode))
                }
            }
            .navigationTitle(AppLang.tr("Изменить", "Edit", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLang.tr("Сохранить", "Save", code: selectedLanguageCode)) {
                        Task {
                            isSubmitting = true
                            let err = await onSave(
                                trimmedName,
                                description.trimmingCharacters(in: .whitespacesAndNewlines),
                                privacy,
                                newCoverData
                            )
                            isSubmitting = false
                            if let err {
                                errorMessage = err
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .disabled(trimmedName.isEmpty || isSubmitting)
                }
            }
            .onChange(of: selectedCoverItem) { newItem in
                guard let newItem else { return }
                Task {
                    await loadCover(from: newItem)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert(
            AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadCover(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            await MainActor.run {
                newCoverData = data
                newCoverPreview = UIImage(data: data)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AddSongSheet: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var trackNumber = ""
    @State private var genre = ""
    @State private var releaseDate = ""
    @State private var composer = ""

    @State private var audioData: Data?
    @State private var audioFileName = ""
    @State private var selectedAudioDisplayName = ""
    @State private var isFileImporterPresented = false
    @State private var isReadingMetadata = false

    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var manualCoverData: Data?
    @State private var manualCoverImage: UIImage?
    @State private var manualCoverFileName: String?
    @State private var embeddedCoverData: Data?
    @State private var embeddedCoverImage: UIImage?

    @State private var isSubmitting = false
    @State private var errorMessage: String?

    let onUpload: (MusicUploadSubmission) async -> String?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedArtist: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedTitle.isEmpty && !trimmedArtist.isEmpty && audioData != nil && !audioFileName.isEmpty && !isSubmitting
    }

    private var effectiveCoverData: Data? {
        manualCoverData ?? embeddedCoverData
    }

    private var effectiveCoverImage: UIImage? {
        manualCoverImage ?? embeddedCoverImage
    }

    private var effectiveCoverFileName: String? {
        manualCoverFileName ?? (embeddedCoverData == nil ? nil : "embedded_cover.jpg")
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    coverAndFileSection
                    formSectionTitle(AppLang.key("music_form_info", code: selectedLanguageCode, fallback: "Basic information"))
                    VStack(spacing: 12) {
                        formField(
                            AppLang.key("music_form_title", code: selectedLanguageCode, fallback: "Title (required)"),
                            text: $title
                        )
                        formField(
                            AppLang.key("music_form_artist", code: selectedLanguageCode, fallback: "Artist(s) (required)"),
                            text: $artist
                        )
                        formField(
                            AppLang.key("music_form_album", code: selectedLanguageCode, fallback: "Album"),
                            text: $album
                        )
                    }

                    Text(
                        AppLang.key(
                            "music_form_metadata_info",
                            code: selectedLanguageCode,
                            fallback: "If the file already has metadata, it will be loaded automatically. Metadata that you write in the form will be written over those already in the file."
                        )
                    )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)

                    formSectionTitle(AppLang.key("music_form_secondary_info", code: selectedLanguageCode, fallback: "Secondary information"))
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            formField(
                                AppLang.key("music_form_track_number", code: selectedLanguageCode, fallback: "Track number"),
                                text: $trackNumber
                            )
                            .keyboardType(.numberPad)

                            formField(
                                AppLang.key("music_form_composer", code: selectedLanguageCode, fallback: "Composer"),
                                text: $composer
                            )
                        }

                        formField(
                            AppLang.key("music_form_genre", code: selectedLanguageCode, fallback: "Genre"),
                            text: $genre
                        )

                        formField(
                            AppLang.key("music_form_release_year", code: selectedLanguageCode, fallback: "Release date"),
                            text: $releaseDate
                        )
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(AppLang.key("music_form_send", code: selectedLanguageCode, fallback: "Publish"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(!canSubmit)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(AppLang.key("music_add", code: selectedLanguageCode, fallback: "Add song"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await loadAudioFile(from: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: selectedCoverItem) { newValue in
            guard let newValue else { return }
            Task { await loadManualCover(from: newValue) }
        }
        .alert(
            AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var coverAndFileSection: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedCoverItem, matching: .images) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 204)

                    if let image = effectiveCoverImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 204)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "music.note")
                                .font(.system(size: 58, weight: .regular))
                                .foregroundStyle(AppTheme.textSecondary)

                            Text(AppLang.key("music_form_cover", code: selectedLanguageCode, fallback: "Select cover"))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                isFileImporterPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 16, weight: .semibold))

                    Text(AppLang.key("select_file", code: selectedLanguageCode, fallback: "Select file"))
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.primary)

            if isReadingMetadata {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(AppLang.tr("Читаю метаданные файла…", "Reading file metadata…", code: selectedLanguageCode))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            } else if !selectedAudioDisplayName.isEmpty {
                Text(selectedAudioDisplayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func formSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
    }

    private func formField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(AppTheme.textSecondary.opacity(0.85)))
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
    }

    private func loadManualCover(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            manualCoverData = data
            manualCoverImage = UIImage(data: data)
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            manualCoverFileName = "cover.\(ext)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadAudioFile(from url: URL) async {
        isReadingMetadata = true
        defer { isReadingMetadata = false }

        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            let metadata = extractMetadata(from: url)

            audioData = data
            audioFileName = url.lastPathComponent
            selectedAudioDisplayName = url.lastPathComponent

            title = metadata.title ?? ""
            artist = metadata.artist ?? ""
            album = metadata.album ?? ""
            trackNumber = metadata.trackNumber.map(String.init) ?? ""
            genre = metadata.genre ?? ""
            releaseDate = metadata.releaseDate ?? ""
            composer = metadata.composer ?? ""

            embeddedCoverData = metadata.artworkData
            embeddedCoverImage = metadata.artworkData.flatMap(UIImage.init(data:))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        guard let audioData else {
            errorMessage = AppLang.tr("Сначала выбери аудиофайл.", "Pick an audio file first.", code: selectedLanguageCode)
            return
        }

        isSubmitting = true
        let submission = MusicUploadSubmission(
            audioData: audioData,
            audioFileName: audioFileName,
            coverData: effectiveCoverData,
            coverFileName: effectiveCoverFileName,
            title: trimmedTitle,
            artist: trimmedArtist,
            album: cleanedValue(album),
            trackNumber: Int(trackNumber.trimmingCharacters(in: .whitespacesAndNewlines)),
            genre: cleanedValue(genre),
            releaseDate: cleanedValue(releaseDate),
            composer: cleanedValue(composer)
        )

        let error = await onUpload(submission)
        isSubmitting = false

        if let error {
            errorMessage = error
        } else {
            dismiss()
        }
    }

    private func cleanedValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractMetadata(from url: URL) -> ExtractedAudioMetadata {
        let asset = AVURLAsset(url: url)
        let metadataItems = asset.commonMetadata + asset.availableMetadataFormats.flatMap { asset.metadata(forFormat: $0) }

        let title = firstMetadataString(in: metadataItems, identifiers: ["title"])
        let artist = firstMetadataString(in: metadataItems, identifiers: ["artist"])
        let album = firstMetadataString(in: metadataItems, identifiers: ["album"])
        let genre = firstMetadataString(in: metadataItems, identifiers: ["genre"])
        let composer = firstMetadataString(in: metadataItems, identifiers: ["composer", "creator", "writer"])
        let trackNumber = firstMetadataInteger(in: metadataItems, identifiers: ["tracknumber", "track_number", "track"])
        let releaseDate = normalizeReleaseDate(firstMetadataString(in: metadataItems, identifiers: ["date", "year", "creationdate", "releasedate"]))
        let artworkData = firstArtworkData(in: metadataItems)

        return ExtractedAudioMetadata(
            title: title,
            artist: artist,
            album: album,
            trackNumber: trackNumber,
            genre: genre,
            releaseDate: releaseDate,
            composer: composer,
            artworkData: artworkData
        )
    }

    private func firstMetadataString(in items: [AVMetadataItem], identifiers: [String]) -> String? {
        for item in items {
            let rawIdentifier = item.identifier?.rawValue.lowercased() ?? ""
            let rawCommonKey = item.commonKey?.rawValue.lowercased() ?? ""
            let matches = identifiers.contains { probe in
                rawIdentifier.contains(probe) || rawCommonKey.contains(probe)
            }
            guard matches else { continue }

            if let stringValue = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !stringValue.isEmpty {
                return stringValue
            }
            if let numberValue = item.numberValue {
                return numberValue.stringValue
            }
            if let value = item.value as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    private func firstMetadataInteger(in items: [AVMetadataItem], identifiers: [String]) -> Int? {
        guard let raw = firstMetadataString(in: items, identifiers: identifiers) else {
            return nil
        }

        let digits = raw
            .split(separator: "/")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        return Int(digits)
    }

    private func firstArtworkData(in items: [AVMetadataItem]) -> Data? {
        for item in items {
            let rawIdentifier = item.identifier?.rawValue.lowercased() ?? ""
            let rawCommonKey = item.commonKey?.rawValue.lowercased() ?? ""
            guard rawIdentifier.contains("artwork") || rawCommonKey.contains("artwork") else { continue }

            if let data = item.dataValue, UIImage(data: data) != nil {
                return data
            }
        }

        return nil
    }

    private func normalizeReleaseDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let tIndex = trimmed.firstIndex(of: "T") {
            return String(trimmed[..<tIndex])
        }

        return trimmed
    }
}

private struct ExtractedAudioMetadata {
    let title: String?
    let artist: String?
    let album: String?
    let trackNumber: Int?
    let genre: String?
    let releaseDate: String?
    let composer: String?
    let artworkData: Data?
}

// MARK: - Edit Song Lyrics Sheet

struct EditSongLyricsSheet: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    let song: MusicSong

    @State private var lines: [EditableLyricsLine] = []
    @State private var isRawMode = false
    @State private var rawText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @StateObject private var viewModel = MusicPlayerViewModel.shared

    struct EditableLyricsLine: Identifiable {
        let id = UUID()
        var startTimeMs: Int
        var words: String

        var formattedTimestamp: String {
            let totalSeconds = startTimeMs / 1000
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            let hundredths = (startTimeMs % 1000) / 10
            return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(AppLang.key("music_loading", code: selectedLanguageCode, fallback: "Загрузка..."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isRawMode {
                    rawEditorView
                } else {
                    syncedEditorView
                }
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(AppLang.tr("Текст песни", "Lyrics", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                }

                ToolbarItem(placement: .principal) {
                    Picker("", selection: $isRawMode) {
                        Text(AppLang.tr("Синхронизация", "Sync", code: selectedLanguageCode)).tag(false)
                        Text(AppLang.tr("LRC / Текст", "LRC / Text", code: selectedLanguageCode)).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .onChange(of: isRawMode) { raw in
                        if raw {
                            rawText = linesToLrc(lines)
                        } else {
                            lines = lrcToLines(rawText)
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .tint(AppTheme.primary)
                            .frame(width: 32, height: 32)
                    } else {
                        Button {
                            Task { await save() }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(AppTheme.primary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            .task {
                await loadExistingLyrics()
            }
            .alert(
                AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var syncedEditorView: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    MusicCoverArtworkView(media: song.cover, size: 44, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if viewModel.isPlaying {
                        let currentMs = Int(viewModel.playbackProgress.currentTime * 1000)
                        let totalSec = currentMs / 1000
                        Text(String(format: "%02d:%02d", totalSec / 60, totalSec % 60))
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(AppTheme.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.primary.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.vertical, 4)
            }

            Section(header: Text(AppLang.tr("Синхронизированные строки", "Synced Lines", code: selectedLanguageCode))) {
                if lines.isEmpty {
                    Text(AppLang.tr("Нет строк. Нажмите «Добавить строку» или переключитесь в режим «LRC / Текст»", "No lines. Tap 'Add Line' or switch to 'LRC / Text' mode", code: selectedLanguageCode))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(line.formattedTimestamp)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AppTheme.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                                Spacer()

                                Button {
                                    let currentMs = Int(viewModel.playbackProgress.currentTime * 1000)
                                    lines[index].startTimeMs = max(0, currentMs)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "stopwatch")
                                        Text(AppLang.tr("Текущее", "Current", code: selectedLanguageCode))
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppTheme.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(AppTheme.primary.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    lines[index].startTimeMs = max(0, lines[index].startTimeMs - 500)
                                } label: {
                                    Text("-0.5s")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    lines[index].startTimeMs += 500
                                } label: {
                                    Text("+0.5s")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }

                            TextField(
                                AppLang.tr("Текст строки...", "Line text...", code: selectedLanguageCode),
                                text: Binding(
                                    get: { lines[index].words },
                                    set: { lines[index].words = $0 }
                                )
                            )
                            .font(.system(size: 15))
                            .foregroundStyle(AppTheme.textPrimary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        lines.remove(atOffsets: offsets)
                    }
                }

                Button {
                    let lastMs = lines.last?.startTimeMs ?? 0
                    let nextMs = viewModel.isPlaying ? Int(viewModel.playbackProgress.currentTime * 1000) : (lastMs + 3000)
                    lines.append(EditableLyricsLine(startTimeMs: nextMs, words: ""))
                } label: {
                    Label(
                        AppLang.tr("Добавить строку", "Add line", code: selectedLanguageCode),
                        systemImage: "plus.circle.fill"
                    )
                    .foregroundStyle(AppTheme.primary)
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var rawEditorView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLang.tr("Вставьте текст песни с таймкодами LRC [мм:сс.хх] или обычный текст", "Paste lyrics with LRC timestamps [mm:ss.xx] or plain text", code: selectedLanguageCode))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            TextEditor(text: $rawText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surfaceElevated)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    private func loadExistingLyrics() async {
        isLoading = true
        do {
            let fetched = try await APIClient.shared.loadSongLyrics(songID: song.id)
            lines = fetched.map { EditableLyricsLine(startTimeMs: $0.startTimeMs, words: $0.words) }
            if lines.isEmpty {
                rawText = ""
            } else {
                rawText = linesToLrc(lines)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        let finalLines: [LyricsLine]
        if isRawMode {
            finalLines = lrcToLines(rawText).map { LyricsLine(startTimeMs: $0.startTimeMs, words: $0.words) }
        } else {
            finalLines = lines.map { LyricsLine(startTimeMs: $0.startTimeMs, words: $0.words) }
        }

        do {
            try await viewModel.updateSongLyrics(songID: song.id, lines: finalLines)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func linesToLrc(_ items: [EditableLyricsLine]) -> String {
        items.map { "[\($0.formattedTimestamp)] \($0.words)" }.joined(separator: "\n")
    }

    private func lrcToLines(_ text: String) -> [EditableLyricsLine] {
        let rawLines = text.components(separatedBy: .newlines)
        var result: [EditableLyricsLine] = []
        var defaultTimeMs = 0

        let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:[.:](\\d{1,3}))?\\](.*)")

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let regex,
               let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: (trimmed as NSString).length)) {
                let ns = trimmed as NSString
                let minStr = ns.substring(with: match.range(at: 1))
                let secStr = ns.substring(with: match.range(at: 2))
                var ms = 0
                if match.range(at: 3).location != NSNotFound {
                    let subStr = ns.substring(with: match.range(at: 3))
                    if subStr.count == 1 { ms = (Int(subStr) ?? 0) * 100 }
                    else if subStr.count == 2 { ms = (Int(subStr) ?? 0) * 10 }
                    else { ms = Int(subStr) ?? 0 }
                }
                let minutes = Int(minStr) ?? 0
                let seconds = Int(secStr) ?? 0
                let totalMs = (minutes * 60 + seconds) * 1000 + ms

                let words: String
                if match.range(at: 4).location != NSNotFound {
                    words = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                } else {
                    words = ""
                }
                result.append(EditableLyricsLine(startTimeMs: totalMs, words: words))
                defaultTimeMs = totalMs + 3000
            } else {
                result.append(EditableLyricsLine(startTimeMs: defaultTimeMs, words: trimmed))
                defaultTimeMs += 3000
            }
        }

        return result.sorted { $0.startTimeMs < $1.startTimeMs }
    }
}

// MARK: - Edit Song Cover Sheet

struct EditSongCoverSheet: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    let song: MusicSong

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var selectedUIImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @StateObject private var viewModel = MusicPlayerViewModel.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let selectedUIImage {
                        Image(uiImage: selectedUIImage)
                            .resizable()
                            .aspectRatio(1, contentMode: .fill)
                            .frame(width: 220, height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    } else {
                        MusicCoverArtworkView(media: song.cover, size: 220, cornerRadius: 18)
                            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    }

                    VStack(spacing: 6) {
                        Text(song.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .multilineTextAlignment(.center)
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    PhotosPicker(
                        selection: $selectedItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text(selectedUIImage != nil
                                ? AppLang.tr("Выбрать другое фото", "Choose another photo", code: selectedLanguageCode)
                                : AppLang.tr("Выбрать обложку из галереи", "Choose cover from library", code: selectedLanguageCode))
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(AppTheme.primary, in: Capsule())
                    }
                    .onChange(of: selectedItem) { item in
                        guard let item else { return }
                        Task {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let img = UIImage(data: data) {
                                await MainActor.run {
                                    selectedImageData = data
                                    selectedUIImage = img
                                }
                            }
                        }
                    }
                }
                .padding(.top, 32)
                .padding(.horizontal, 20)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(AppLang.tr("Изменить обложку", "Edit Cover", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLang.key("cancel", code: selectedLanguageCode, fallback: "Отмена")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .tint(AppTheme.primary)
                    } else {
                        Button(AppLang.key("save", code: selectedLanguageCode, fallback: "Сохранить")) {
                            Task { await saveCover() }
                        }
                        .disabled(selectedImageData == nil || isSaving)
                        .fontWeight(.bold)
                    }
                }
            }
            .alert(
                AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func saveCover() async {
        guard let data = selectedImageData, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await viewModel.updateSongCover(songID: song.id, coverData: data)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct MusicActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(AppTheme.primary)
    }
}

private struct MusicPlaylistCard: View {
    let playlist: MusicPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let cover = playlist.cover {
                    MusicCoverArtworkView(
                        media: cover,
                        size: 152,
                        cornerRadius: 18,
                        showsBorder: true,
                        downloadProgress: nil
                    )
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.primary.opacity(0.88), AppTheme.primarySoft.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 152, height: 152)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: 48, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.96))
                        )
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let author = playlist.authorName, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(width: 152, alignment: .leading)
    }
}

private enum MusicSearchFilterTab: String, CaseIterable, Identifiable {
    case all = "all"
    case songs = "songs"
    case artists = "artists"

    var id: String { rawValue }

    func title(code: String) -> String {
        switch self {
        case .all: return AppLang.key("all", code: code, fallback: "Все")
        case .songs: return AppLang.key("songs", code: code, fallback: "Песни")
        case .artists: return AppLang.tr("Исполнители", "Artists", code: code)
        }
    }
}

private struct MusicSearchScreen: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = MusicPlayerViewModel.shared
    @State private var query: String
    @State private var songResults: [MusicSong] = []
    @State private var artistResults: [MusicArtist] = []
    @State private var selectedTab: MusicSearchFilterTab = .all
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    init(initialQuery: String) {
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        List {
            searchFieldSection
            filterTabsSection
            contentSection
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .listStyle(.insetGrouped)
        .navigationTitle(AppLang.tr("Поиск музыки", "Music Search", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            performSearch()
        }
    }

    private var searchFieldSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)

                TextField(
                    AppLang.tr("Поиск по музыке и исполнителям", "Search music & artists", code: selectedLanguageCode),
                    text: $query
                )
                .foregroundStyle(AppTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onChange(of: query) { _ in
                    performSearch()
                }
                .onSubmit {
                    performSearch()
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(searchFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(searchFieldStroke, lineWidth: 1)
            )
        }
        .listRowBackground(Color.clear)
    }

    private var filterTabsSection: some View {
        Section {
            Picker("", selection: $selectedTab) {
                ForEach(MusicSearchFilterTab.allCases) { tab in
                    Text(tab.title(code: selectedLanguageCode)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    @ViewBuilder
    private var contentSection: some View {
        if isLoading && songResults.isEmpty && artistResults.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ProgressView(AppLang.key("music_loading", code: selectedLanguageCode, fallback: "Загрузка..."))
                    Spacer()
                }
                .padding(.vertical, 12)
            }
        } else if let errorMessage, songResults.isEmpty && artistResults.isEmpty {
            Section {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        } else if songResults.isEmpty && artistResults.isEmpty {
            Section {
                Text(emptyResultsText)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        } else {
            switch selectedTab {
            case .all:
                if !artistResults.isEmpty {
                    artistsHorizontalSection
                }
                if !songResults.isEmpty {
                    songsSection
                }
            case .artists:
                if artistResults.isEmpty {
                    Section {
                        Text(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    artistsListSection
                }
            case .songs:
                if songResults.isEmpty {
                    Section {
                        Text(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    songsSection
                }
            }
        }
    }

    private var artistsHorizontalSection: some View {
        Section(AppLang.tr("Исполнители", "Artists", code: selectedLanguageCode)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(artistResults) { artist in
                        NavigationLink {
                            MusicArtistDetailScreen(artist: artist)
                        } label: {
                            VStack(spacing: 8) {
                                ArtistAvatarArtworkView(media: artist.avatar, size: 76, name: artist.name)
                                    .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)

                                Text(artist.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)
                                    .frame(width: 76)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
        }
    }

    private var artistsListSection: some View {
        Section(AppLang.tr("Исполнители", "Artists", code: selectedLanguageCode)) {
            ForEach(artistResults) { artist in
                NavigationLink {
                    MusicArtistDetailScreen(artist: artist)
                } label: {
                    HStack(spacing: 14) {
                        ArtistAvatarArtworkView(media: artist.avatar, size: 52, name: artist.name)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artist.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(AppLang.tr("Исполнитель", "Artist", code: selectedLanguageCode))
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var songsSection: some View {
        Section(AppLang.key("songs", code: selectedLanguageCode, fallback: "Песни")) {
            ForEach(Array(songResults.enumerated()), id: \.element.id) { index, song in
                searchResultRow(song: song, index: index)
            }
        }
    }

    private var emptyResultsText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLang.tr("Введите запрос для поиска музыки или исполнителя", "Enter a query to search music or artists", code: selectedLanguageCode)
            : AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено")
    }

    private func searchResultRow(song: MusicSong, index: Int) -> some View {
        MusicPlaylistSongRow(
            song: song,
            index: index + 1,
            isSelected: viewModel.selectedSong?.id == song.id,
            isPreparingPlayback: viewModel.isPreparingPlayback && viewModel.selectedSong?.id == song.id,
            activeForeground: AppTheme.textPrimary,
            playlists: viewModel.library,
            currentPlaylist: nil,
            downloadProgress: viewModel.downloadProgress(for: song.id),
            onTap: {
                Task {
                    await viewModel.selectSong(song, queue: songResults)
                }
            },
            onToggleLike: {
                await viewModel.toggleLike(song: song)
                syncLikedState(for: song.id)
            },
            onAddToPlaylist: { playlist in
                try? await APIClient.shared.addSongToMusicPlaylist(songID: song.id, playlistID: playlist.id)
            },
            onRemoveFromCurrentPlaylist: nil
        )
    }

    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            songResults = []
            artistResults = []
            errorMessage = nil
            isLoading = false
            return
        }

        // Local artist matching for immediate response
        let localArtists = viewModel.artists.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
        if !localArtists.isEmpty {
            self.artistResults = localArtists
        }

        isLoading = true
        errorMessage = nil

        searchTask = Task {
            async let songsSearch = APIClient.shared.search(query: trimmed, category: .music)
            async let artistsSearch = APIClient.shared.searchArtists(query: trimmed)

            do {
                let (songsResp, apiArtists) = try await (songsSearch, artistsSearch)

                var mergedArtists = localArtists
                for artist in apiArtists where !mergedArtists.contains(where: { $0.id == artist.id || $0.name.lowercased() == artist.name.lowercased() }) {
                    mergedArtists.append(artist)
                }

                // Also check artists inside matching songs
                for song in songsResp.songs {
                    for a in song.artists where !mergedArtists.contains(where: { $0.id == a.id || $0.name.lowercased() == a.name.lowercased() }) {
                        if a.name.localizedCaseInsensitiveContains(trimmed) {
                            mergedArtists.append(a)
                        }
                    }
                }

                await MainActor.run {
                    self.songResults = songsResp.songs
                    self.artistResults = mergedArtists
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.songResults = []
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func syncLikedState(for songID: Int) {
        if let index = songResults.firstIndex(where: { $0.id == songID }) {
            songResults[index].liked.toggle()
        }
    }

    private var searchFieldBackground: Color {
        if colorScheme == .light {
            return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 18.0 / 255.0)
        }
        return AppTheme.surfaceElevated
    }

    private var searchFieldStroke: Color {
        if #available(iOS 26.0, *) {
            return .clear
        }
        return AppTheme.cardStroke
    }
}

private struct MusicPlaylistScreen: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    let playlist: MusicPlaylist
    let fallbackSongs: [MusicSong]?
    let selectedSongID: Int?
    let onSelectSong: (MusicSong, [MusicSong]) -> Void

    @State private var details: MusicPlaylistDetails?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var isEditPlaylistPresented = false
    @State private var isFullPlayerPresented = false
    @StateObject private var viewModel = MusicPlayerViewModel.shared

    private var currentSelectedSongID: Int? {
        viewModel.selectedSong?.id ?? selectedSongID
    }

    private var screenBackground: some View {
        let coverMedia = details?.cover ?? playlist.cover
        let auraColor = colorFromAura(coverMedia?.aura)
        return auraColor.ignoresSafeArea()
    }

    private var isIOS26OrNewer: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private var playlistActiveForeground: Color {
        contrastingColorFromAura((details?.cover ?? playlist.cover)?.aura)
    }

    private var playlistAuthorName: String? {
        details?.authorName ?? playlist.authorName
    }

    private var playlistAuthorUsername: String? {
        details?.authorUsername ?? playlist.authorUsername
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    if let details {
                        playlistSummaryCard(details: details)
                            .padding(.top, isIOS26OrNewer ? 18 : 64)
                        
                        HStack(spacing: 16) {
                            Button {
                                let shuffled = details.songs.shuffled()
                                if let first = shuffled.first {
                                    onSelectSong(first, shuffled)
                                }
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .frame(width: 56, height: 56)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            
                            Button {
                                if let first = details.songs.first {
                                    onSelectSong(first, details.songs)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(AppLang.key("music_play", code: selectedLanguageCode, fallback: "Воспроизвести"))
                                        .font(.system(size: 16, weight: .bold))
                                }
                                .foregroundStyle(Color.white)
                                .frame(height: 56)
                                .frame(maxWidth: .infinity)
                                .background(Color.black)
                                .clipShape(Capsule())
                            }

                            if shouldShowPlaylistLikeButton(details: details) {
                                Button {
                                    Task { await togglePlaylistFavorite() }
                                } label: {
                                    Image(systemName: (details.isLiked ?? false) ? "heart.fill" : "heart")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle((details.isLiked ?? false) ? Color.white : AppTheme.textPrimary)
                                        .frame(width: 56, height: 56)
                                        .background(Color.white.opacity(0.15))
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        
                        VStack(spacing: 14) {
                            if details.songs.isEmpty {
                                Text(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.top, 40)
                            } else {
                                ForEach(Array(details.songs.enumerated()), id: \.element.id) { index, song in
                                    VStack(spacing: 12) {
                                        MusicPlaylistSongRow(
                                            song: song,
                                            index: index + 1,
                                            isSelected: currentSelectedSongID == song.id,
                                            isPreparingPlayback: viewModel.isPreparingPlayback && currentSelectedSongID == song.id,
                                            activeForeground: playlistActiveForeground,
                                            playlists: viewModel.library,
                                            currentPlaylist: playlist.id == -1 ? nil : playlist,
                                            downloadProgress: viewModel.downloadProgress(for: song.id),
                                            onTap: { onSelectSong(song, details.songs) },
                                            onToggleLike: {
                                                await toggleLike(song)
                                            },
                                            onAddToPlaylist: { selectedPlaylist in
                                                await addSong(song, to: selectedPlaylist)
                                            },
                                            onRemoveFromCurrentPlaylist: playlist.id == -1 ? nil : {
                                                await removeSongFromCurrentPlaylist(song)
                                            }
                                        )
                                        .padding(.horizontal, 16)
                                        
                                        if index < details.songs.count - 1 {
                                            Divider()
                                                .background(Color.white.opacity(0.15))
                                                .padding(.leading, 56)
                                                .padding(.trailing, 16)
                                        }
                                    }
                                }
                                
                                Text(summaryText(for: details))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .padding(.top, 16)
                                    .padding(.bottom, 120)
                            }
                        }
                    } else if isLoading {
                        loadingState
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .padding(.top, 100)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            if !isIOS26OrNewer {
                playlistFloatingHeader
            }

            if let song = viewModel.selectedSong {
                VStack(spacing: 0) {
                    Spacer()
                    MusicMiniPlayerView(
                        song: song,
                        isPreparing: viewModel.isPreparingPlayback,
                        isPlaying: viewModel.isPlaying,
                        playbackProgress: viewModel.playbackProgress,
                        downloadProgress: viewModel.downloadProgress(for: song.id),
                        onSeek: viewModel.seek(to:),
                        onTogglePlay: viewModel.togglePlayPause,
                        onPrevious: { Task { await viewModel.previous() } },
                        onNext: { Task { await viewModel.next() } },
                        onOpen: { isFullPlayerPresented = true }
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(screenBackground)
        .background(InteractivePopGestureEnabler().frame(width: 0, height: 0))
        .navigationBarHidden(!isIOS26OrNewer)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(isIOS26OrNewer ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if isIOS26OrNewer {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.white)
                    }
                    .tint(.white)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if playlist.id != -1, let details, shouldShowPlaylistMenu(details: details) {
                        playlistActionsMenu(details: details)
                            .foregroundStyle(.white)
                            .tint(.white)
                    }
                }
            }
        }
        .sheet(isPresented: $isEditPlaylistPresented) {
            Group {
                if let details {
                    EditPlaylistSheet(
                        initialTitle: details.title,
                        initialDescription: details.description ?? "",
                        initialPrivacy: details.privacy,
                        existingCover: details.cover,
                        onSave: { title, desc, privacy, coverData in
                            do {
                                try await APIClient.shared.editMusicPlaylist(
                                    playlistID: playlist.id,
                                    name: title,
                                    description: desc,
                                    privacy: privacy,
                                    coverData: coverData
                                )
                                await load()
                                await viewModel.refreshLibrary()
                                return nil
                            } catch {
                                return error.localizedDescription
                            }
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $isFullPlayerPresented) {
            MusicFullPlayerView(viewModel: viewModel) { artist in
                isFullPlayerPresented = false
                viewModel.selectedArtistForNavigation = artist
            }
        }
        .task {
            await load()
        }
        .alert(
            AppLang.tr("Удалить плейлист?", "Delete playlist?", code: selectedLanguageCode),
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button(AppLang.tr("Удалить", "Delete", code: selectedLanguageCode), role: .destructive) {
                Task { await deletePlaylist() }
            }
            Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {}
        } message: {
            Text(
                AppLang.tr(
                    "После удаления плейлист нельзя восстановить.",
                    "This playlist cannot be restored after deletion.",
                    code: selectedLanguageCode
                )
            )
        }
    }

    private var playlistFloatingHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }

            Spacer()

            if playlist.id != -1, let details, shouldShowPlaylistMenu(details: details) {
                playlistActionsMenu(details: details)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var loadingState: some View {
        ProgressView(AppLang.key("music_loading", code: selectedLanguageCode, fallback: "Загрузка..."))
            .padding(.top, isIOS26OrNewer ? 96 : 100)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .top)
    }

    private func shouldShowPlaylistLikeButton(details: MusicPlaylistDetails) -> Bool {
        playlist.id != -1 && details.isMyPlaylist != true
    }

    private func shouldShowPlaylistMenu(details: MusicPlaylistDetails) -> Bool {
        details.isMyPlaylist == true
    }

    private func playlistActionsMenu(details: MusicPlaylistDetails) -> some View {
        Menu {
            if details.isMyPlaylist == true {
                Button {
                    isEditPlaylistPresented = true
                } label: {
                    Label(AppLang.key("edit", code: selectedLanguageCode, fallback: "Редактировать"), systemImage: "square.and.pencil")
                }

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label(AppLang.key("delete", code: selectedLanguageCode, fallback: "Удалить"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    private func playlistSummaryCard(details: MusicPlaylistDetails) -> some View {
        let coverMedia = details.cover ?? playlist.cover
        let artworkSize: CGFloat = 208
        let artworkCornerRadius: CGFloat = 26
        let artworkIconSize: CGFloat = 82
        return VStack(alignment: .center, spacing: 12) {
            Group {
                if playlist.id == -1 {
                    RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                        .fill(Color(red: 0.79, green: 0.71, blue: 0.96))
                        .frame(width: artworkSize, height: artworkSize)
                        .overlay(
                            Image(systemName: "heart.fill")
                                .font(.system(size: artworkIconSize, weight: .semibold))
                                .foregroundStyle(AppTheme.primary)
                        )
                } else if let coverMedia {
                    MusicCoverArtworkView(
                        media: coverMedia,
                        size: artworkSize,
                        cornerRadius: artworkCornerRadius,
                        showsBorder: true,
                        downloadProgress: nil
                    )
                    .shadow(color: Color.black.opacity(0.36), radius: 12, x: 0, y: 6)
                } else {
                    RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.primary.opacity(0.88), AppTheme.primarySoft.opacity(0.72)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: artworkSize, height: artworkSize)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: artworkIconSize, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }
            }
            
            VStack(alignment: .center, spacing: 6) {
                Text(details.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .multilineTextAlignment(.center)
                
                if let author = playlistAuthorName, !author.isEmpty {
                    if let username = playlistAuthorUsername, !username.isEmpty {
                        NavigationLink {
                            ProfileRouteScreen(username: username)
                        } label: {
                            Text(author)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(author)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                Text(summaryText(for: details))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.88))
                    .multilineTextAlignment(.center)
                
                if let description = details.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func summaryText(for details: MusicPlaylistDetails) -> String {
        let songsCount = details.songs.count
        let totalDuration = details.songs.reduce(0) { $0 + ($1.duration ?? 0) }
        return "\(songsCount) \(AppLang.key("songs", code: selectedLanguageCode, fallback: "песни")) • \(formatDuration(totalDuration))"
    }

    private func load() async {
        errorMessage = nil

        if playlist.id == -1 {
            details = MusicPlaylistDetails(
                id: -1,
                title: AppLang.key("music_favorites", code: selectedLanguageCode, fallback: "Favorites"),
                description: AppLang.key("music_favorites_desc", code: selectedLanguageCode, fallback: "Любимые треки"),
                createDate: nil,
                privacy: 0,
                cover: nil,
                authorName: playlist.authorName,
                authorUsername: playlist.authorUsername,
                songs: fallbackSongs ?? []
            )
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            details = try await APIClient.shared.loadMusicPlaylist(playlistID: playlist.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleLike(_ song: MusicSong) async {
        await viewModel.toggleLike(song: song)
        guard var details else { return }
        if let index = details.songs.firstIndex(where: { $0.id == song.id }) {
            details.songs[index].liked.toggle()
            self.details = details
        }
    }

    private func addSong(_ song: MusicSong, to playlist: MusicPlaylist) async {
        do {
            try await APIClient.shared.addSongToMusicPlaylist(songID: song.id, playlistID: playlist.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeSongFromCurrentPlaylist(_ song: MusicSong) async {
        guard playlist.id != -1 else { return }
        do {
            try await APIClient.shared.removeSongFromMusicPlaylist(songID: song.id, playlistID: playlist.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func togglePlaylistFavorite() async {
        guard let currentDetails = details else { return }
        let currentlyLiked = currentDetails.isLiked ?? false
        do {
            if currentlyLiked {
                try await APIClient.shared.removePlaylistFromFavorites(playlistID: playlist.id)
            } else {
                try await APIClient.shared.addPlaylistToFavorites(playlistID: playlist.id)
            }
            details?.isLiked = !currentlyLiked
            await viewModel.refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePlaylist() async {
        guard playlist.id != -1 else { return }
        do {
            try await APIClient.shared.deleteMusicPlaylist(playlistID: playlist.id)
            await viewModel.refreshLibrary()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MusicPlaylistSongRow: View {
    let song: MusicSong
    let index: Int
    let isSelected: Bool
    let isPreparingPlayback: Bool
    let activeForeground: Color
    let playlists: [MusicPlaylist]
    let currentPlaylist: MusicPlaylist?
    let downloadProgress: Double?
    let onTap: () -> Void
    let onToggleLike: () async -> Void
    let onAddToPlaylist: (MusicPlaylist) async -> Void
    let onRemoveFromCurrentPlaylist: (() async -> Void)?

    private var downloadPercentText: String? {
        guard isPreparingPlayback, let downloadProgress, downloadProgress > 0, downloadProgress < 1 else {
            return nil
        }
        return "\(Int(downloadProgress * 100))%"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Text("\(index)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 28, alignment: .leading)

                    MusicCoverArtworkView(media: song.cover, size: 52, downloadProgress: downloadProgress)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? activeForeground : AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 4) {
                        if let downloadPercentText {
                            Text(downloadPercentText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.primary)
                        } else if let duration = song.duration {
                            Text(formatDuration(duration))
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }

                        if isPreparingPlayback {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AppTheme.primary)
                        } else {
                            Image(systemName: isSelected ? "speaker.wave.2.fill" : "play.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? activeForeground : AppTheme.textSecondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            MusicSongMenuButton(
                song: song,
                playlists: playlists,
                currentPlaylist: currentPlaylist,
                onToggleLike: {
                    Task { await onToggleLike() }
                },
                onAddToPlaylist: { playlist in
                    Task { await onAddToPlaylist(playlist) }
                },
                onRemoveFromCurrentPlaylist: onRemoveFromCurrentPlaylist.map { removal in
                    { Task { await removal() } }
                },
                onCreatePlaylist: nil
            )
        }
    }
}

private struct MusicSongGridCard: View {
    let song: MusicSong
    let playlists: [MusicPlaylist]
    let downloadProgress: Double?
    let action: () -> Void
    let onToggleLike: () -> Void
    let onAddToPlaylist: (MusicPlaylist) -> Void
    let onCreatePlaylist: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) {
                MusicCoverArtworkView(media: song.cover, size: 152, downloadProgress: downloadProgress)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(song.artist)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 4)

                MusicSongMenuButton(
                    song: song,
                    playlists: playlists,
                    currentPlaylist: nil,
                    onToggleLike: onToggleLike,
                    onAddToPlaylist: onAddToPlaylist,
                    onRemoveFromCurrentPlaylist: nil,
                    onCreatePlaylist: onCreatePlaylist
                )
                .padding(.top, 2)
            }
        }
        .frame(width: 152, alignment: .leading)
    }
}

private struct MusicSongMenuButton: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    let song: MusicSong
    let playlists: [MusicPlaylist]
    let currentPlaylist: MusicPlaylist?
    let onToggleLike: () -> Void
    let onAddToPlaylist: (MusicPlaylist) -> Void
    let onRemoveFromCurrentPlaylist: (() -> Void)?
    let onCreatePlaylist: (() -> Void)?

    @State private var isEditLyricsPresented = false
    @State private var isEditCoverPresented = false
    @State private var isTrackInfoPresented = false
    @State private var isAlbumPresented = false

    var body: some View {
        Menu {
            Button(action: onToggleLike) {
                Label(
                    song.liked
                    ? AppLang.tr("Удалить из избранного", "Remove from favorites", code: selectedLanguageCode)
                    : AppLang.tr("Добавить в избранное", "Add to favorites", code: selectedLanguageCode),
                    systemImage: song.liked ? "heart.slash" : "heart"
                )
            }

            Menu {
                if playlists.isEmpty {
                    if let onCreatePlaylist {
                        Button(action: onCreatePlaylist) {
                            Label(
                                AppLang.key("music_add_playlist", code: selectedLanguageCode, fallback: "Create playlist"),
                                systemImage: "plus"
                            )
                        }
                    } else {
                        Button(
                            AppLang.tr("Нет доступных плейлистов", "No playlists available", code: selectedLanguageCode),
                            action: {}
                        )
                        .disabled(true)
                    }
                } else {
                    ForEach(playlists) { playlist in
                        Button {
                            onAddToPlaylist(playlist)
                        } label: {
                            Text(playlist.title)
                        }
                    }

                    if let onCreatePlaylist {
                        Divider()
                        Button(action: onCreatePlaylist) {
                            Label(
                                AppLang.key("music_add_playlist", code: selectedLanguageCode, fallback: "Create playlist"),
                                systemImage: "plus"
                            )
                        }
                    }
                }
            } label: {
                Label(
                    AppLang.key("add_to_playlist", code: selectedLanguageCode, fallback: "Добавить в плейлист"),
                    systemImage: "text.badge.plus"
                )
            }

            if let album = song.album, !album.isEmpty {
                Button {
                    isAlbumPresented = true
                } label: {
                    Label(
                        AppLang.tr("Перейти к альбому", "Go to album", code: selectedLanguageCode),
                        systemImage: "opticaldisc"
                    )
                }
            }

            Divider()

            Button {
                isEditLyricsPresented = true
            } label: {
                Label(
                    AppLang.tr("Редактировать текст", "Edit lyrics", code: selectedLanguageCode),
                    systemImage: "quote.bubble"
                )
            }

            Button {
                isEditCoverPresented = true
            } label: {
                Label(
                    AppLang.tr("Изменить обложку", "Change cover", code: selectedLanguageCode),
                    systemImage: "photo"
                )
            }

            Button {
                isTrackInfoPresented = true
            } label: {
                Label(
                    AppLang.tr("Информация о треке", "Track info", code: selectedLanguageCode),
                    systemImage: "info.circle"
                )
            }

            if currentPlaylist != nil, let onRemoveFromCurrentPlaylist {
                Divider()
                Button(role: .destructive, action: onRemoveFromCurrentPlaylist) {
                    Label(
                        AppLang.key("remove_from_playlist", code: selectedLanguageCode, fallback: "Удалить из плейлиста"),
                        systemImage: "text.badge.minus"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .sheet(isPresented: $isEditLyricsPresented) {
            EditSongLyricsSheet(song: song)
        }
        .sheet(isPresented: $isEditCoverPresented) {
            EditSongCoverSheet(song: song)
        }
        .sheet(isPresented: $isTrackInfoPresented) {
            MusicTrackInfoSheet(song: song, selectedLanguageCode: selectedLanguageCode)
        }
        .sheet(isPresented: $isAlbumPresented) {
            NavigationStack {
                MusicAlbumDetailScreen(albumID: 0, initialTitle: song.album)
            }
        }
    }
}

struct MusicMiniPlayerView: View {
    let song: MusicSong
    let isPreparing: Bool
    let isPlaying: Bool
    @ObservedObject var playbackProgress: MusicPlaybackProgressStore
    let downloadProgress: Double?
    let onSeek: (Double) -> Void
    let onTogglePlay: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onOpen: () -> Void

    private var effectiveDuration: Double {
        max(playbackProgress.duration, song.duration ?? 0, 0.1)
    }

    private var displayedCurrent: Double {
        min(max(playbackProgress.currentTime, 0), effectiveDuration)
    }

    var body: some View {
        VStack(spacing: 2) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    MusicCoverArtworkView(media: song.cover, size: 40, downloadProgress: downloadProgress)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        Button(action: onPrevious) {
                            Image(systemName: "backward.fill")
                                .font(.title3.weight(.semibold))
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(BubblePressButtonStyle())

                        Button(action: onTogglePlay) {
                            if isPreparing {
                                ProgressView()
                                    .frame(width: 42, height: 42)
                            } else {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3.weight(.bold))
                                    .frame(width: 42, height: 42)
                            }
                        }
                        .buttonStyle(BubblePressButtonStyle())

                        Button(action: onNext) {
                            Image(systemName: "forward.fill")
                                .font(.title3.weight(.semibold))
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(BubblePressButtonStyle())
                    }
                    .foregroundStyle(AppTheme.textPrimary)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Text(formatDuration(displayedCurrent))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(minWidth: 38, alignment: .leading)
                    .lineLimit(1)

                CompactMusicSlider(
                    value: displayedCurrent,
                    range: 0...effectiveDuration,
                    onSeek: onSeek
                )
                .frame(height: 24)

                Text("-\(formatDuration(max(effectiveDuration - displayedCurrent, 0)))")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(minWidth: 38, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}

private final class InteractiveTrackSlider: UISlider {
    private let customTrackHeight: CGFloat = 8

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let defaultRect = super.trackRect(forBounds: bounds)
        return CGRect(
            x: defaultRect.origin.x,
            y: bounds.midY - customTrackHeight / 2,
            width: defaultRect.width,
            height: customTrackHeight
        )
    }

    private func updateValue(for touch: UITouch) {
        let point = touch.location(in: self)
        let trackBounds = trackRect(forBounds: bounds)
        let percentage = min(max((point.x - trackBounds.minX) / max(trackBounds.width, 1), 0), 1)
        let delta = maximumValue - minimumValue
        value = minimumValue + Float(percentage) * delta
        sendActions(for: .valueChanged)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateValue(for: touch)
        sendActions(for: .touchDown)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        updateValue(for: touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch {
            updateValue(for: touch)
        }
        sendActions(for: .touchUpInside)
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        sendActions(for: .touchCancel)
        super.cancelTracking(with: event)
    }
}

private struct CompactMusicSlider: UIViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let onSeek: (Double) -> Void

    func makeUIView(context: Context) -> UISlider {
        let slider = InteractiveTrackSlider(frame: .zero)
        slider.isContinuous = true
        slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.92)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.34)
        slider.tintColor = UIColor.white.withAlphaComponent(0.92)
        slider.setThumbImage(UIImage(), for: .normal)
        slider.setThumbImage(UIImage(), for: .highlighted)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchBegan(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        uiView.minimumValue = Float(range.lowerBound)
        uiView.maximumValue = Float(range.upperBound)
        uiView.tintColor = UIColor.white.withAlphaComponent(0.92)
        uiView.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.92)
        uiView.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.34)
        uiView.setMinimumTrackImage(trackImage(color: UIColor.white.withAlphaComponent(0.92)), for: .normal)
        uiView.setMaximumTrackImage(trackImage(color: UIColor.white.withAlphaComponent(0.34)), for: .normal)
        uiView.setThumbImage(transparentThumbImage(), for: .normal)
        uiView.setThumbImage(transparentThumbImage(), for: .highlighted)
        if !context.coordinator.isTracking {
            uiView.value = Float(value)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek)
    }

    private func trackImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }

    private func transparentThumbImage() -> UIImage {
        let size = CGSize(width: 2, height: 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.clear.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        }
    }

    final class Coordinator: NSObject {
        let onSeek: (Double) -> Void
        var isTracking = false

        init(onSeek: @escaping (Double) -> Void) {
            self.onSeek = onSeek
        }

        @objc func valueChanged(_ sender: UISlider) {
            isTracking = true
        }

        @objc func touchBegan(_ sender: UISlider) {
            isTracking = true
        }

        @objc func touchEnded(_ sender: UISlider) {
            isTracking = false
            onSeek(Double(sender.value))
        }
    }

}

struct MusicFullPlayerView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @ObservedObject var viewModel: MusicPlayerViewModel
    @ObservedObject private var playbackProgress: MusicPlaybackProgressStore
    @Environment(\.dismiss) private var dismiss
    @State private var isInfoPresented = false
    @State private var isEditLyricsPresented = false
    @State private var isEditCoverPresented = false
    @State private var isAlbumPresented = false
    @State private var scrubbingTime: Double?
    @State private var isLyricsModeActive = false
    @State private var lyrics: [LyricsLine] = []
    @State private var isLoadingLyrics = false
    @State private var lyricsLoadedSongID: Int?

    var onArtistSelected: (MusicArtist) -> Void

    init(viewModel: MusicPlayerViewModel, onArtistSelected: @escaping (MusicArtist) -> Void) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _playbackProgress = ObservedObject(wrappedValue: viewModel.playbackProgress)
        self.onArtistSelected = onArtistSelected
    }

    private var isIOS26OrNewer: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private struct PlayerLayoutMetrics {
        let topBarHorizontalPadding: CGFloat
        let artworkSize: CGFloat
        let controlsWidth: CGFloat
        let titleFontSize: CGFloat
        let artistFontSize: CGFloat
        let primaryControlSpacing: CGFloat
        let primaryButtonSize: CGFloat
        let primaryButtonIconSize: CGFloat
        let secondaryControlSpacing: CGFloat
        let contentSpacing: CGFloat
        let bottomPadding: CGFloat
        let topSpacerMinLength: CGFloat
        let middleSpacerMinLength: CGFloat

        static func forScreen(_ size: CGSize) -> PlayerLayoutMetrics {
            let width = size.width
            let height = size.height
            let isLargePhone = width >= 428 || height >= 900
            let sideInset = width >= 428 ? 28.0 : 24.0
            let availableContentWidth = max(width - (sideInset * 2), 200)

            let controlsWidth = min(max(availableContentWidth, 260), isLargePhone ? 400 : 372)
            let artworkSize = min(max(availableContentWidth, 220), isLargePhone ? 390 : 350)

            return PlayerLayoutMetrics(
                topBarHorizontalPadding: width >= 428 ? 24 : 20,
                artworkSize: artworkSize,
                controlsWidth: controlsWidth,
                titleFontSize: isLargePhone ? 25 : 22,
                artistFontSize: isLargePhone ? 16 : 15,
                primaryControlSpacing: isLargePhone ? 42 : 34,
                primaryButtonSize: isLargePhone ? 62 : 56,
                primaryButtonIconSize: isLargePhone ? 38 : 36,
                secondaryControlSpacing: isLargePhone ? 34 : 28,
                contentSpacing: isLargePhone ? 18 : 15,
                bottomPadding: isLargePhone ? 82 : 68,
                topSpacerMinLength: isLargePhone ? 28 : 18,
                middleSpacerMinLength: isLargePhone ? 30 : 22
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = PlayerLayoutMetrics.forScreen(geometry.size)
            let w = geometry.size.width
            let h = geometry.size.height

            Group {
                if let song = viewModel.selectedSong {
                    ZStack(alignment: .top) {
                        fullPlayerBackground(song: song)
                            .ignoresSafeArea()

                        VStack(spacing: 0) {
                            topBar()
                                .padding(.top, 14)
                                .padding(.horizontal, metrics.topBarHorizontalPadding)

                            Spacer(minLength: metrics.topSpacerMinLength)

                            ZStack {
                                MusicCoverArtworkView(
                                    media: song.cover,
                                    size: metrics.artworkSize,
                                    cornerRadius: 16,
                                    showsBorder: false,
                                    downloadProgress: viewModel.downloadProgress(for: song.id)
                                )
                                .scaleEffect(isLyricsModeActive ? 0.90 : (viewModel.isPlaying ? 1.0 : 0.88))
                                .opacity(isLyricsModeActive ? 0.0 : 1.0)
                                .blur(radius: isLyricsModeActive ? 14 : 0)
                                .shadow(color: .black.opacity(0.24), radius: 22, y: 14)
                                .allowsHitTesting(!isLyricsModeActive)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                        isLyricsModeActive = true
                                    }
                                    Task { await loadLyrics(songID: song.id) }
                                }

                                MusicLyricsView(
                                    lines: lyrics,
                                    isLoading: isLoadingLyrics,
                                    currentTimeMs: Int(displayedCurrentTime * 1000),
                                    size: metrics.artworkSize,
                                    onSeek: { ms in
                                        viewModel.seek(to: Double(ms) / 1000.0)
                                    },
                                    onAddLyricsTap: {
                                        isEditLyricsPresented = true
                                    }
                                )
                                .scaleEffect(isLyricsModeActive ? 1.0 : 1.08)
                                .opacity(isLyricsModeActive ? 1.0 : 0.0)
                                .blur(radius: isLyricsModeActive ? 0 : 14)
                                .allowsHitTesting(isLyricsModeActive)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isLyricsModeActive)

                            Spacer(minLength: metrics.middleSpacerMinLength)

                            VStack(spacing: 0) {
                                headerBlock(song, metrics: metrics)
                                    .padding(.bottom, metrics.contentSpacing)
                                progressBlock()
                                    .padding(.vertical, metrics.contentSpacing / 2)
                                primaryControls(metrics: metrics)
                                    .padding(.bottom, metrics.contentSpacing)
                                volumeBlock()
                                    .padding(.bottom, metrics.contentSpacing)
                                secondaryControls(metrics: metrics)
                            }
                            .frame(maxWidth: metrics.controlsWidth)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, metrics.bottomPadding)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: w, height: h, alignment: .top)
                    .clipped()
                } else {
                    ZStack {
                        AppTheme.backgroundGradient.ignoresSafeArea()
                        Text(AppLang.key("music_loading", code: selectedLanguageCode, fallback: "Загрузка..."))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .frame(width: w, height: h, alignment: .center)
                }
            }
            .frame(width: w, height: h, alignment: .top)
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $isEditLyricsPresented) {
            if let song = viewModel.selectedSong {
                EditSongLyricsSheet(song: song)
            }
        }
        .sheet(isPresented: $isEditCoverPresented) {
            if let song = viewModel.selectedSong {
                EditSongCoverSheet(song: song)
            }
        }
        .sheet(isPresented: $isAlbumPresented) {
            if let album = viewModel.selectedSong?.album {
                NavigationStack {
                    MusicAlbumDetailScreen(albumID: 0, initialTitle: album)
                }
            }
        }
        .sheet(isPresented: $isInfoPresented) {
            if let song = viewModel.selectedSong {
                MusicTrackInfoSheet(song: song, selectedLanguageCode: selectedLanguageCode)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: viewModel.selectedSong?.id) { newID in
            if newID != lyricsLoadedSongID {
                lyrics = []
                lyricsLoadedSongID = nil
            }
            if isLyricsModeActive, let newID {
                Task { await loadLyrics(songID: newID) }
            }
        }
    }

    private func loadLyrics(songID: Int) async {
        guard !isLoadingLyrics, lyricsLoadedSongID != songID else { return }
        isLoadingLyrics = true
        defer { isLoadingLyrics = false }
        do {
            let lines = try await APIClient.shared.loadSongLyrics(songID: songID)
            await MainActor.run {
                lyrics = lines
                lyricsLoadedSongID = songID
            }
        } catch {
            await MainActor.run { lyrics = [] }
        }
    }


    private func topBar() -> some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.white.opacity(0.68))
                .frame(width: 56, height: 6)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 44)
        .frame(height: 72)
        .offset(y: isIOS26OrNewer ? -12 : 0)
    }

    private func headerBlock(_ song: MusicSong, metrics: PlayerLayoutMetrics) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.system(size: metrics.titleFontSize, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                artistNameView(song: song, metrics: metrics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.toggleLikeCurrentSong() }
                } label: {
                    Image(systemName: song.liked ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(song.liked ? Color(red: 1.0, green: 0.42, blue: 0.58) : .white)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(BubblePressButtonStyle())

                Menu {
                    if let album = song.album, !album.isEmpty {
                        Button {
                            isAlbumPresented = true
                        } label: {
                            Label(
                                AppLang.tr("Перейти к альбому", "Go to album", code: selectedLanguageCode),
                                systemImage: "opticaldisc"
                            )
                        }
                    }

                    Button {
                        isEditLyricsPresented = true
                    } label: {
                        Label(
                            AppLang.tr("Редактировать текст", "Edit lyrics", code: selectedLanguageCode),
                            systemImage: "quote.bubble"
                        )
                    }

                    Button {
                        isEditCoverPresented = true
                    } label: {
                        Label(
                            AppLang.tr("Изменить обложку", "Change cover", code: selectedLanguageCode),
                            systemImage: "photo"
                        )
                    }

                    Divider()

                    Button {
                        isInfoPresented = true
                    } label: {
                        Label(
                            AppLang.tr("Информация о треке", "Track info", code: selectedLanguageCode),
                            systemImage: "info.circle"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .menuStyle(.borderlessButton)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func artistNameView(song: MusicSong, metrics: PlayerLayoutMetrics) -> some View {
        let tappableArtists = song.artists.filter { $0.slug != nil }
        if tappableArtists.isEmpty {
            // No artist page available – plain text
            Text(song.artist)
                .font(.system(size: metrics.artistFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        } else if tappableArtists.count == 1, let singleArtist = tappableArtists.first {
            // Single artist – whole line is tappable
            Button {
                onArtistSelected(singleArtist)
            } label: {
                Text(song.artist)
                    .font(.system(size: metrics.artistFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
        } else {
            // Multiple artists – each name is individually tappable
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(tappableArtists.enumerated()), id: \.element.id) { index, artist in
                        Button {
                            onArtistSelected(artist)
                        } label: {
                            Text(artist.name + (index < tappableArtists.count - 1 ? "," : ""))
                                .font(.system(size: metrics.artistFontSize, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                    }
                }
                // fallback: single tappable line joining all names
                Button {
                    if let firstArtist = tappableArtists.first {
                        onArtistSelected(firstArtist)
                    }
                } label: {
                    Text(song.artist)
                        .font(.system(size: metrics.artistFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func progressBlock() -> some View {
        VStack(spacing: 6) {
            AppleMusicSlider(
                value: min(max(displayedCurrentTime, 0), max(playbackProgress.duration, 0.1)),
                range: 0...max(playbackProgress.duration, 0.1),
                minimumTrackColor: UIColor.white.withAlphaComponent(0.92),
                maximumTrackColor: UIColor.white.withAlphaComponent(0.34),
                onPreviewChange: { scrubbingTime = $0 },
                onValueCommit: { value in
                    scrubbingTime = nil
                    viewModel.seek(to: value)
                }
            )
            .frame(height: 36)

            HStack {
                Text(formatDuration(displayedCurrentTime))
                Spacer()
                Text("-\(formatDuration(max(playbackProgress.duration - displayedCurrentTime, 0)))")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.62))
        }
    }

    private func primaryControls(metrics: PlayerLayoutMetrics) -> some View {
        HStack(spacing: metrics.primaryControlSpacing) {
            Button {
                Task { await viewModel.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: metrics.primaryButtonSize, height: metrics.primaryButtonSize)
            }
            .buttonStyle(BubblePressButtonStyle())

            Button {
                viewModel.togglePlayPause()
            } label: {
                Group {
                    if viewModel.isPreparingPlayback {
                        ProgressView()
                            .tint(.white)
                            .frame(width: metrics.primaryButtonSize, height: metrics.primaryButtonSize)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: metrics.primaryButtonIconSize, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: metrics.primaryButtonSize, height: metrics.primaryButtonSize)
                            .offset(x: viewModel.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(BubblePressButtonStyle())

            Button {
                Task { await viewModel.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: metrics.primaryButtonSize, height: metrics.primaryButtonSize)
            }
            .buttonStyle(BubblePressButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func volumeBlock() -> some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            SystemVolumeSlider()
                .frame(height: 20)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var displayedCurrentTime: Double {
        scrubbingTime ?? playbackProgress.currentTime
    }

    private func secondaryControls(metrics: PlayerLayoutMetrics) -> some View {
        HStack(spacing: metrics.secondaryControlSpacing) {
            Button {
                viewModel.isRandomEnabled.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(viewModel.isRandomEnabled ? AppTheme.primary : .white.opacity(0.68))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(FastMusicUtilityButtonStyle())

            Button {
                isLyricsModeActive.toggle()
                if isLyricsModeActive, let songID = viewModel.selectedSong?.id {
                    Task { await loadLyrics(songID: songID) }
                }
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isLyricsModeActive ? AppTheme.primary : .white.opacity(0.68))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(FastMusicUtilityButtonStyle())

            Button {
                isInfoPresented = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(FastMusicUtilityButtonStyle())

            Button {
                viewModel.cycleRepeatMode()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "repeat")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(viewModel.repeatMode == .off ? .white.opacity(0.68) : AppTheme.primary)
                        .frame(width: 30, height: 30)

                    if viewModel.repeatMode == .one {
                        Text("1")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AppTheme.primary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.96), in: Capsule())
                            .offset(x: 7, y: -4)
                    }
                }
            }
            .buttonStyle(FastMusicUtilityButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func fullPlayerBackground(song: MusicSong) -> some View {
        let accent = colorFromAura(song.cover?.aura)

        ZStack {
            LinearGradient(
                colors: [
                    accent.opacity(0.98),
                    accent.opacity(0.94),
                    accent.mix(with: .black, amount: 0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if song.cover != nil {
                MusicCoverArtworkView(media: song.cover, size: 520)
                    .blur(radius: 48)
                    .scaleEffect(1.45)
                    .opacity(0.22)
                    .offset(y: -60)
            }

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.04),
                            Color.clear,
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lyrics View

private struct MusicLyricsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    let lines: [LyricsLine]
    let isLoading: Bool
    let currentTimeMs: Int
    let size: CGFloat
    let onSeek: (Int) -> Void
    var onAddLyricsTap: (() -> Void)? = nil

    private var activeIndex: Int? {
        guard !lines.isEmpty else { return nil }
        var idx = 0
        for (i, line) in lines.enumerated() {
            if line.startTimeMs <= currentTimeMs { idx = i } else { break }
        }
        return idx
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .frame(width: size, height: size)

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if lines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.4))

                    Text(AppLang.tr("Текст песни пока не добавлен", "Lyrics not available yet", code: selectedLanguageCode))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)

                    if let onAddLyricsTap {
                        Button(action: onAddLyricsTap) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                Text(AppLang.tr("Добавить текст", "Add Lyrics", code: selectedLanguageCode))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.16), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            Color.clear.frame(height: size * 0.25)

                            ForEach(Array(lines.enumerated()), id: \.element.startTimeMs) { index, line in
                                let isActive = activeIndex == index
                                Text(line.words.isEmpty ? "•••" : line.words)
                                    .font(.system(size: isActive ? 22 : 17, weight: isActive ? .bold : .semibold, design: .default))
                                    .foregroundStyle(isActive ? .white : .white.opacity(0.40))
                                    .multilineTextAlignment(.leading)
                                    .scaleEffect(isActive ? 1.02 : 1.0, anchor: .leading)
                                    .shadow(color: isActive ? Color.white.opacity(0.20) : Color.clear, radius: 8, x: 0, y: 0)
                                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isActive)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        onSeek(line.startTimeMs)
                                    }
                            }

                            Color.clear.frame(height: size * 0.35)
                        }
                        .padding(.horizontal, 24)
                    }
                    .frame(width: size, height: size)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 0.88),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onChange(of: activeIndex) { newIndex in
                        if let newIndex {
                            withAnimation(.easeInOut(duration: 0.42)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct MusicTrackInfoSheet: View {
    let song: MusicSong
    let selectedLanguageCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var isEditLyricsPresented = false
    @State private var isEditCoverPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    infoHeader
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                Section {
                    if let album = song.album, !album.isEmpty {
                        NavigationLink {
                            MusicAlbumDetailScreen(albumID: 0, initialTitle: album)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(AppLang.key("music_info_album", code: selectedLanguageCode, fallback: "Альбом"))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer(minLength: 12)
                                Text(album)
                                    .foregroundStyle(AppTheme.primary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.body)
                        }
                    }
                    if let genre = song.genre, !genre.isEmpty {
                        metadataRow(title: AppLang.key("music_info_genre", code: selectedLanguageCode, fallback: "Жанр"), value: genre)
                    }
                    if let composer = song.composer, !composer.isEmpty {
                        metadataRow(title: selectedLanguageCode == "en" ? "Composer" : "Композитор", value: composer)
                    }
                    if let year = song.releaseYear {
                        metadataRow(title: selectedLanguageCode == "en" ? "Year" : "Год", value: "\(year)")
                    }
                    if let track = song.trackNumber {
                        metadataRow(title: selectedLanguageCode == "en" ? "Track" : "Номер трека", value: "\(track)")
                    }
                    if let bitrate = song.bitrate {
                        metadataRow(title: AppLang.key("music_info_bitrate", code: selectedLanguageCode, fallback: "Скорость потока"), value: "\(bitrate / 1000) кбит/с")
                    }
                    if let audioFormat = song.audioFormat, !audioFormat.isEmpty {
                        metadataRow(title: AppLang.key("music_info_audio_format", code: selectedLanguageCode, fallback: "Аудио формат"), value: audioFormat)
                    }
                    if let duration = song.duration, duration > 0 {
                        metadataRow(title: selectedLanguageCode == "en" ? "Duration" : "Длительность", value: formatDuration(duration))
                    }
                }

                Section {
                    Button {
                        isEditLyricsPresented = true
                    } label: {
                        Label(
                            AppLang.tr("Редактировать текст песни", "Edit lyrics", code: selectedLanguageCode),
                            systemImage: "quote.bubble"
                        )
                        .foregroundStyle(AppTheme.primary)
                    }

                    Button {
                        isEditCoverPresented = true
                    } label: {
                        Label(
                            AppLang.tr("Изменить обложку", "Change cover", code: selectedLanguageCode),
                            systemImage: "photo"
                        )
                        .foregroundStyle(AppTheme.primary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(selectedLanguageCode == "en" ? "Track Info" : "Информация о треке")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedLanguageCode == "en" ? "Done" : "Готово") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isEditLyricsPresented) {
                EditSongLyricsSheet(song: song)
            }
            .sheet(isPresented: $isEditCoverPresented) {
                EditSongCoverSheet(song: song)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
        }
    }

    private var infoHeader: some View {
        HStack(spacing: 14) {
            MusicCoverArtworkView(media: song.cover, size: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(song.artist)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    private func metadataRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .font(.body)
    }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> SystemVolumeSliderView {
        SystemVolumeSliderView()
    }

    func updateUIView(_ uiView: SystemVolumeSliderView, context: Context) {
        uiView.syncFromSystemVolume()
    }
}

private final class SystemVolumeSliderView: UIView {
    private let volumeView = MPVolumeView(frame: .zero)
    private let slider = InteractiveTrackSlider(frame: .zero)
    private var volumeObservation: NSKeyValueObservation?
    private var isSyncingFromSystem = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        slider.frame = bounds
        volumeView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func syncFromSystemVolume() {
        guard !slider.isTracking else { return }
        isSyncingFromSystem = true
        slider.setValue(AVAudioSession.sharedInstance().outputVolume, animated: false)
        isSyncingFromSystem = false
    }

    private func configure() {
        volumeView.showsRouteButton = false
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false

        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.isContinuous = true
        slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.92)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.34)
        slider.setMinimumTrackImage(trackImage(color: UIColor.white.withAlphaComponent(0.92)), for: .normal)
        slider.setMaximumTrackImage(trackImage(color: UIColor.white.withAlphaComponent(0.34)), for: .normal)
        slider.setThumbImage(transparentThumbImage(), for: .normal)
        slider.setThumbImage(transparentThumbImage(), for: .highlighted)
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)

        addSubview(volumeView)
        addSubview(slider)

        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.syncFromSystemVolume()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.syncFromSystemVolume()
        }
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        guard !isSyncingFromSystem else { return }
        guard let systemSlider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        systemSlider.setValue(sender.value, animated: false)
        systemSlider.sendActions(for: .valueChanged)
    }

    private func trackImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }

    private func transparentThumbImage() -> UIImage {
        let size = CGSize(width: 2, height: 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.clear.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        }
    }
}

private struct AppleMusicSlider: UIViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let minimumTrackColor: UIColor
    let maximumTrackColor: UIColor
    let onPreviewChange: (Double) -> Void
    let onValueCommit: (Double) -> Void

    func makeUIView(context: Context) -> UISlider {
        let slider = InteractiveTrackSlider(frame: .zero)
        slider.isContinuous = true
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchBegan(_:)), for: [.touchDown])
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        configure(slider)
        return slider
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        configure(uiView)
        uiView.minimumValue = Float(range.lowerBound)
        uiView.maximumValue = Float(range.upperBound)
        if !context.coordinator.isTracking {
            uiView.value = Float(value)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPreviewChange: onPreviewChange, onValueCommit: onValueCommit)
    }

    private func configure(_ slider: UISlider) {
        slider.minimumTrackTintColor = minimumTrackColor
        slider.maximumTrackTintColor = maximumTrackColor
        slider.tintColor = minimumTrackColor
        slider.setMinimumTrackImage(trackImage(color: minimumTrackColor), for: .normal)
        slider.setMaximumTrackImage(trackImage(color: maximumTrackColor), for: .normal)
        slider.setThumbImage(transparentThumbImage(), for: .normal)
        slider.setThumbImage(transparentThumbImage(), for: .highlighted)
    }

    private func trackImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }

    private func transparentThumbImage() -> UIImage {
        let size = CGSize(width: 2, height: 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.clear.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        }
    }

    final class Coordinator: NSObject {
        let onPreviewChange: (Double) -> Void
        let onValueCommit: (Double) -> Void
        var isTracking = false

        init(
            onPreviewChange: @escaping (Double) -> Void,
            onValueCommit: @escaping (Double) -> Void
        ) {
            self.onPreviewChange = onPreviewChange
            self.onValueCommit = onValueCommit
        }

        @objc func valueChanged(_ sender: UISlider) {
            onPreviewChange(Double(sender.value))
        }

        @objc func touchBegan(_ sender: UISlider) {
            isTracking = true
            onPreviewChange(Double(sender.value))
        }

        @objc func touchEnded(_ sender: UISlider) {
            isTracking = false
            onValueCommit(Double(sender.value))
        }
    }
}

struct BubblePressButtonStyle: PrimitiveButtonStyle {
    var pressedScale: CGFloat = 0.72
    var pressResponse: Double = 0.16
    var releaseResponse: Double = 0.24
    var bounceResetDelay: Double = 0.12

    func makeBody(configuration: Configuration) -> some View {
        BubblePressButton(
            configuration: configuration,
            pressedScale: pressedScale,
            pressResponse: pressResponse,
            releaseResponse: releaseResponse,
            bounceResetDelay: bounceResetDelay
        )
    }

    struct BubblePressButton: View {
        let configuration: PrimitiveButtonStyle.Configuration
        let pressedScale: CGFloat
        let pressResponse: Double
        let releaseResponse: Double
        let bounceResetDelay: Double

        @GestureState private var isTouching = false
        @State private var tapBounce = false

        var body: some View {
            configuration.label
                .scaleEffect((isTouching || tapBounce) ? pressedScale : 1)
                .animation(.spring(response: pressResponse, dampingFraction: 0.46), value: isTouching)
                .animation(.spring(response: releaseResponse, dampingFraction: 0.40), value: tapBounce)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isTouching) { _, state, _ in
                            state = true
                        }
                        .onEnded { _ in
                            tapBounce = true
                            configuration.trigger()

                            DispatchQueue.main.asyncAfter(deadline: .now() + bounceResetDelay) {
                                tapBounce = false
                            }
                        }
                )
        }
    }
}

private struct FastMusicUtilityButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BubblePressButtonStyle(
            pressedScale: 0.78,
            pressResponse: 0.10,
            releaseResponse: 0.14,
            bounceResetDelay: 0.07
        )
        .makeBody(configuration: configuration)
    }
}

private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableInteractivePop()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enableInteractivePop()
        }

        func enableInteractivePop() {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

private func contrastingColorFromAura(_ aura: String?) -> Color {
    guard let components = rgbComponentsFromAura(aura) else {
        return AppTheme.textPrimary
    }

    let luminance = 0.2126 * components.red + 0.7152 * components.green + 0.0722 * components.blue
    return luminance > 0.56 ? Color.black : Color.white
}

private func colorFromAura(_ aura: String?) -> Color {
    if let components = rgbComponentsFromAura(aura) {
        return Color(
            red: components.red,
            green: components.green,
            blue: components.blue
        )
    }

    return AppTheme.primary
}

private func rgbComponentsFromAura(_ aura: String?) -> (red: Double, green: Double, blue: Double)? {
    guard let aura = aura?.trimmingCharacters(in: .whitespacesAndNewlines), !aura.isEmpty else {
        return nil
    }
    
    if aura.lowercased().hasPrefix("rgb") {
        let scanner = Scanner(string: aura)
        _ = scanner.scanString("rgb(")
        _ = scanner.scanString("rgb")
        let defaultValue = 140.0
        var rValue = defaultValue
        var gValue = defaultValue
        var bValue = defaultValue
        if let parsedR = scanner.scanDouble() {
            rValue = parsedR
            _ = scanner.scanString(",")
            gValue = scanner.scanDouble() ?? defaultValue
            _ = scanner.scanString(",")
            bValue = scanner.scanDouble() ?? defaultValue
        }
        return (
            min(max(rValue, 0), 255) / 255.0,
            min(max(gValue, 0), 255) / 255.0,
            min(max(bValue, 0), 255) / 255.0
        )
    }
    
    var hexSanitized = aura.trimmingCharacters(in: .whitespacesAndNewlines)
    if hexSanitized.hasPrefix("#") {
        hexSanitized.removeFirst()
    }
    
    var rgb: UInt64 = 0
    let scanner = Scanner(string: hexSanitized)
    if scanner.scanHexInt64(&rgb) {
        let r, g, b: Double
        if hexSanitized.count == 6 {
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8) & 0xFF) / 255.0
            b = Double(rgb & 0xFF) / 255.0
            return (r, g, b)
        } else if hexSanitized.count == 3 {
            r = Double((rgb >> 8) & 0xF) * 17.0 / 255.0
            g = Double((rgb >> 4) & 0xF) * 17.0 / 255.0
            b = Double(rgb & 0xF) * 17.0 / 255.0
            return (r, g, b)
        }
    }
    
    return nil
}

private extension Color {
    func mix(with color: Color, amount: CGFloat) -> Color {
        let left = UIColor(self)
        let right = UIColor(color)

        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0

        left.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        right.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        let blend = min(max(amount, 0), 1)
        return Color(
            red: lr + (rr - lr) * blend,
            green: lg + (rg - lg) * blend,
            blue: lb + (rb - lb) * blend,
            opacity: la + (ra - la) * blend
        )
    }
}

struct MusicCoverArtworkView: View {
    let media: MediaData?
    let size: CGFloat
    var cornerRadius: CGFloat? = nil
    var showsBorder: Bool = true
    var downloadProgress: Double? = nil
    @State private var uiImage: UIImage?
    @State private var lastLoadID: String?

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? max(12, size * 0.12)
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .overlay {
            if showsBorder {
                RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            }
        }
        .overlay(alignment: .bottom) {
            if let downloadProgress, downloadProgress > 0, downloadProgress < 1 {
                VStack(spacing: 6) {
                    Spacer()
                    ProgressView(value: downloadProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, max(8, size * 0.08))
                        .padding(.bottom, max(8, size * 0.08))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
                )
            }
        }
        .task(id: loadID) {
            await loadImageIfNeeded()
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [AppTheme.primary.opacity(0.9), AppTheme.primarySoft.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            )
    }

    private var loadID: String {
        media?.imageLoadKey ?? ""
    }

    @MainActor
    private func loadImageIfNeeded() async {
        guard !loadID.isEmpty else {
            uiImage = nil
            lastLoadID = nil
            return
        }

        if lastLoadID == loadID, uiImage != nil {
            return
        }

        lastLoadID = loadID
        uiImage = nil

        if let media,
           let cached = APIClient.shared.cachedMediaImageData(for: media, lossless: true),
           let image = UIImage(data: cached) {
            uiImage = image
            return
        }

        if let media,
           let data = await APIClient.shared.downloadMediaImage(media, lossless: true),
           let image = UIImage(data: data) {
            uiImage = image
            return
        }

        if let url = media?.fullURL ?? media?.simpleURL {
            if let cached = APIClient.shared.cachedURLImageData(url: url), let image = UIImage(data: cached) {
                uiImage = image
                return
            }
            if let data = await APIClient.shared.downloadImageURL(url), let image = UIImage(data: data) {
                uiImage = image
            }
        }
    }
}

private func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

struct ArtistAvatarArtworkView: View {
    let media: MediaData?
    let size: CGFloat
    let name: String
    @State private var uiImage: UIImage?
    @State private var lastLoadID: String?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        }
        .task(id: loadID) {
            await loadImageIfNeeded()
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [AppTheme.primary.opacity(0.85), AppTheme.primarySoft.opacity(0.75)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
            )
    }

    private var loadID: String {
        media?.imageLoadKey ?? ""
    }

    @MainActor
    private func loadImageIfNeeded() async {
        guard !loadID.isEmpty else {
            uiImage = nil
            lastLoadID = nil
            return
        }

        if lastLoadID == loadID, uiImage != nil {
            return
        }

        lastLoadID = loadID
        uiImage = nil

        if let media,
           let cached = APIClient.shared.cachedMediaImageData(for: media, lossless: true),
           let image = UIImage(data: cached) {
            uiImage = image
            return
        }

        if let media,
           let data = await APIClient.shared.downloadMediaImage(media, lossless: true),
           let image = UIImage(data: data) {
            uiImage = image
            return
        }

        if let url = media?.fullURL ?? media?.simpleURL {
            if let cached = APIClient.shared.cachedURLImageData(url: url), let image = UIImage(data: cached) {
                uiImage = image
                return
            }
            if let data = await APIClient.shared.downloadImageURL(url), let image = UIImage(data: data) {
                uiImage = image
            }
        }
    }
}

struct MusicArtistDetailScreen: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    let artist: MusicArtist

    @State private var artistDetails: MusicArtist?
    @State private var songs: [MusicSong] = []
    @State private var albums: [MusicAlbum] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @StateObject private var viewModel = MusicPlayerViewModel.shared

    private var currentSelectedSongID: Int? {
        viewModel.selectedSong?.id
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .center, spacing: 16) {
                    ArtistAvatarArtworkView(media: artistDetails?.avatar ?? artist.avatar, size: 180, name: artist.name)
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                    
                    Text(artist.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if !albums.isEmpty {
                Section(AppLang.tr("Альбомы", "Albums", code: selectedLanguageCode)) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(albums) { album in
                                NavigationLink {
                                    MusicAlbumDetailScreen(albumID: album.id, initialTitle: album.title)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        MusicCoverArtworkView(media: album.cover, size: 120, cornerRadius: 12)
                                            .shadow(color: .black.opacity(0.18), radius: 6, y: 4)

                                        Text(album.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                            .lineLimit(1)
                                            .frame(width: 120, alignment: .leading)

                                        if let date = album.releaseDate, !date.isEmpty {
                                            Text(formatAlbumReleaseDate(date, languageCode: selectedLanguageCode, shortYearOnly: true) ?? date)
                                                .font(.caption2)
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .lineLimit(1)
                                                .frame(width: 120, alignment: .leading)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
                }
            }

            Section(AppLang.tr("Песни", "Songs", code: selectedLanguageCode)) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView(AppLang.key("music_loading", code: selectedLanguageCode, fallback: "Загрузка..."))
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                } else if songs.isEmpty {
                    Text(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        MusicPlaylistSongRow(
                            song: song,
                            index: index + 1,
                            isSelected: currentSelectedSongID == song.id,
                            isPreparingPlayback: viewModel.isPreparingPlayback && currentSelectedSongID == song.id,
                            activeForeground: AppTheme.textPrimary,
                            playlists: viewModel.library,
                            currentPlaylist: nil,
                            downloadProgress: viewModel.downloadProgress(for: song.id),
                            onTap: {
                                Task { await viewModel.selectSong(song, queue: songs) }
                            },
                            onToggleLike: {
                                await viewModel.toggleLike(song: song)
                            },
                            onAddToPlaylist: { selectedPlaylist in
                                await addSong(song, to: selectedPlaylist)
                            },
                            onRemoveFromCurrentPlaylist: nil
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.tr("Исполнитель", "Artist", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadArtistDetails()
        }
        .alert(
            AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadArtistDetails() async {
        guard let slug = artist.slug else { return }
        isLoading = true
        errorMessage = nil
        do {
            let res = try await viewModel.loadArtistSongs(slug: slug)
            self.artistDetails = res.artist
            self.songs = res.songs
            self.albums = res.albums

            for alb in res.albums {
                if !viewModel.albums.contains(where: { ($0.id > 0 && $0.id == alb.id) || $0.title.lowercased() == alb.title.lowercased() }) {
                    viewModel.albums.append(alb)
                }
            }

            if self.albums.isEmpty {
                var seenAlbums: Set<String> = []
                for s in res.songs {
                    guard let albumName = s.album?.trimmingCharacters(in: .whitespacesAndNewlines), !albumName.isEmpty else { continue }
                    let key = albumName.lowercased()
                    if !seenAlbums.contains(key) {
                        seenAlbums.insert(key)
                        self.albums.append(MusicAlbum(
                            id: 0,
                            title: albumName,
                            artistName: artist.name,
                            cover: s.cover,
                            releaseDate: s.dateAdded
                        ))
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func addSong(_ song: MusicSong, to playlist: MusicPlaylist) async {
        do {
            try await APIClient.shared.addSongToMusicPlaylist(songID: song.id, playlistID: playlist.id)
            await viewModel.refreshLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Album Detail Screen

struct MusicAlbumDetailScreen: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    let albumID: Int
    let initialTitle: String?

    @State private var album: MusicAlbum?
    @State private var tracks: [MusicSong] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @StateObject private var viewModel = MusicPlayerViewModel.shared

    private var displayTitle: String {
        album?.title ?? initialTitle ?? AppLang.tr("Альбом", "Album", code: selectedLanguageCode)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .center, spacing: 14) {
                    MusicCoverArtworkView(
                        media: album?.cover ?? tracks.first?.cover,
                        size: 180,
                        cornerRadius: 14
                    )
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)

                    VStack(spacing: 4) {
                        Text(displayTitle)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .multilineTextAlignment(.center)

                        if let artistName = album?.artistName ?? tracks.first?.artist, !artistName.isEmpty {
                            Text(artistName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.primary)
                        }

                        if let releaseType = album?.releaseType, !releaseType.isEmpty {
                            Text(releaseType)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .textCase(.uppercase)
                        }

                        if let rawDate = album?.releaseDate ?? tracks.first?.dateAdded,
                           let formatted = formatAlbumReleaseDate(rawDate, languageCode: selectedLanguageCode) {
                            Text(formatted)
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }

                    if !tracks.isEmpty {
                        HStack(spacing: 10) {
                            Button {
                                guard let first = tracks.first else { return }
                                Task { await viewModel.selectSong(first, queue: tracks) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                    Text(AppLang.tr("Слушать", "Play", code: selectedLanguageCode))
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)

                            Button {
                                guard !tracks.isEmpty else { return }
                                let shuffled = tracks.shuffled()
                                if let first = shuffled.first {
                                    Task { await viewModel.selectSong(first, queue: shuffled) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "shuffle")
                                    Text(AppLang.tr("Перемешать", "Shuffle", code: selectedLanguageCode))
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                Task {
                                    let base = self.album ?? MusicAlbum(
                                        id: albumID,
                                        title: displayTitle,
                                        artistName: tracks.first?.artist,
                                        cover: tracks.first?.cover,
                                        tracksCount: tracks.count,
                                        releaseDate: tracks.first?.dateAdded
                                    )
                                    let completeAlbum = MusicAlbum(
                                        id: base.id,
                                        title: base.title,
                                        artistName: base.artistName ?? tracks.first?.artist,
                                        description: base.description,
                                        cover: base.cover ?? tracks.first?.cover,
                                        tracksCount: base.tracksCount ?? tracks.count,
                                        releaseDate: base.releaseDate ?? tracks.first?.dateAdded,
                                        releaseType: base.releaseType
                                    )
                                    await viewModel.toggleAlbumFavorite(album: completeAlbum)
                                }
                            } label: {
                                let isFav = viewModel.isAlbumFavorite(albumID: albumID, title: displayTitle)
                                Image(systemName: isFav ? "heart.fill" : "heart")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(isFav ? Color(red: 1.0, green: 0.42, blue: 0.58) : AppTheme.textPrimary)
                                    .frame(width: 42, height: 42)
                                    .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let desc = album?.description, !desc.isEmpty {
                Section {
                    Text(desc)
                        .font(.body)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            Section(AppLang.tr("Треки", "Tracks", code: selectedLanguageCode)) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView(AppLang.key("music_loading", code: selectedLanguageCode, fallback: "Загрузка..."))
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                } else if tracks.isEmpty {
                    Text(AppLang.key("music_no_results", code: selectedLanguageCode, fallback: "Ничего не найдено"))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, song in
                        MusicPlaylistSongRow(
                            song: song,
                            index: song.trackNumber ?? (index + 1),
                            isSelected: viewModel.selectedSong?.id == song.id,
                            isPreparingPlayback: viewModel.isPreparingPlayback && viewModel.selectedSong?.id == song.id,
                            activeForeground: AppTheme.textPrimary,
                            playlists: viewModel.library,
                            currentPlaylist: nil,
                            downloadProgress: viewModel.downloadProgress(for: song.id),
                            onTap: {
                                Task { await viewModel.selectSong(song, queue: tracks) }
                            },
                            onToggleLike: {
                                await viewModel.toggleLike(song: song)
                            },
                            onAddToPlaylist: { selectedPlaylist in
                                try? await APIClient.shared.addSongToMusicPlaylist(songID: song.id, playlistID: selectedPlaylist.id)
                                await viewModel.refreshLibrary()
                            },
                            onRemoveFromCurrentPlaylist: nil
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task {
                        let base = self.album ?? MusicAlbum(
                            id: albumID,
                            title: displayTitle,
                            artistName: tracks.first?.artist,
                            cover: tracks.first?.cover,
                            tracksCount: tracks.count,
                            releaseDate: tracks.first?.dateAdded
                        )
                        let completeAlbum = MusicAlbum(
                            id: base.id,
                            title: base.title,
                            artistName: base.artistName ?? tracks.first?.artist,
                            description: base.description,
                            cover: base.cover ?? tracks.first?.cover,
                            tracksCount: base.tracksCount ?? tracks.count,
                            releaseDate: base.releaseDate ?? tracks.first?.dateAdded,
                            releaseType: base.releaseType
                        )
                        await viewModel.toggleAlbumFavorite(album: completeAlbum)
                    }
                } label: {
                    let isFav = viewModel.isAlbumFavorite(albumID: albumID, title: displayTitle)
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isFav ? Color(red: 1.0, green: 0.42, blue: 0.58) : AppTheme.textPrimary)
                }
            }
        }
        .task { await load() }
        .alert(
            AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(AppLang.key("close", code: selectedLanguageCode, fallback: "Закрыть"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        if albumID > 0 {
            do {
                let result = try await APIClient.shared.loadAlbum(albumID: albumID)
                album = result.album
                tracks = result.tracks
            } catch {
                errorMessage = error.localizedDescription
            }
        } else if let targetTitle = initialTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !targetTitle.isEmpty {
            let allSongs = (viewModel.songsByCategory[.latest] ?? []) + (viewModel.songsByCategory[.random] ?? []) + (viewModel.songsByCategory[.favorites] ?? []) + viewModel.currentQueue
            let matched = allSongs.filter {
                $0.album?.localizedCaseInsensitiveContains(targetTitle) == true
            }
            if !matched.isEmpty {
                var seen: Set<Int> = []
                self.tracks = matched.filter { seen.insert($0.id).inserted }
                self.album = MusicAlbum(
                    id: 0,
                    title: targetTitle,
                    artistName: tracks.first?.artist,
                    cover: tracks.first?.cover,
                    tracksCount: tracks.count
                )
            } else {
                do {
                    let searchRes = try await APIClient.shared.search(query: targetTitle, category: .music)
                    var seen: Set<Int> = []
                    self.tracks = searchRes.songs.filter { seen.insert($0.id).inserted }
                    self.album = MusicAlbum(
                        id: 0,
                        title: targetTitle,
                        artistName: tracks.first?.artist,
                        cover: tracks.first?.cover,
                        tracksCount: tracks.count
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }

        if let currentAlbum = self.album {
            if !viewModel.albums.contains(where: { ($0.id > 0 && $0.id == currentAlbum.id) || $0.title.lowercased() == currentAlbum.title.lowercased() }) {
                viewModel.albums.append(currentAlbum)
            }
        }

        isLoading = false
    }
}

