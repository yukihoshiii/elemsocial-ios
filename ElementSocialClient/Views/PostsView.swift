import SwiftUI
import UIKit
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

private func parseUnixTimestampDate(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
    let seconds = value > 9_999_999_999 ? value / 1000 : value
    return Date(timeIntervalSince1970: seconds)
}

private enum ProfileMenuDestination: String, Identifiable {
    case accountSelection
    case myProfile
    case myChannels
    case music
    case notifications
    case eBalance
    case subscribe
    case hall
    case settings
    case logout

    var id: String { rawValue }
}

private enum FeedCategory: String, CaseIterable {
    case last
    case rec
    case subscribe
}

private enum MainTab: String {
    case feed
    case messenger
    case create
    case settings
    case profile
}

final class ProfileComposeContext: ObservableObject {
    @Published var activeScreenID: UUID?
    @Published var activeUsername: String?
    @Published var isWallTabActive = false
    @Published var wallComposeRequestID: UUID?

    func setActive(screenID: UUID, username: String?) {
        activeScreenID = screenID
        activeUsername = username
    }

    func clearActive(screenID: UUID) {
        guard activeScreenID == screenID else { return }
        activeScreenID = nil
        activeUsername = nil
        isWallTabActive = false
    }

    func setWallTabActive(_ isActive: Bool, screenID: UUID) {
        guard activeScreenID == screenID else { return }
        isWallTabActive = isActive
    }

    func requestWallCompose() {
        wallComposeRequestID = UUID()
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all
    case users
    case posts
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Всё"
        case .users: return "Пользователи"
        case .posts: return "Посты"
        case .music: return "Музыка"
        }
    }

    var category: SearchCategory {
        switch self {
        case .all: return .all
        case .users: return .users
        case .posts: return .posts
        case .music: return .music
        }
    }
}

private struct SearchResultsView: View {
    @State private var query: String
    @State private var scope: SearchScope = .all
    @State private var results: SearchResults = .empty
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var detailedPosts: [Int: Post] = [:]
    @State private var loadingPostIDs: Set<Int> = []
    @StateObject private var musicPlayerViewModel = MusicPlayerViewModel.shared

    let onOpenProfile: (String?) -> Void
    let onImageTap: ([PostImage], Int) -> Void
    let onVideoTap: (PostVideo) -> Void
    let onOpenComments: (Post) -> Void
    let onDownloadImages: (Post) -> Void
    let onDownloadPostFile: (PostFile) -> Void
    let onShowMessage: (String) -> Void

    init(
        initialQuery: String,
        onOpenProfile: @escaping (String?) -> Void,
        onImageTap: @escaping ([PostImage], Int) -> Void,
        onVideoTap: @escaping (PostVideo) -> Void,
        onOpenComments: @escaping (Post) -> Void,
        onDownloadImages: @escaping (Post) -> Void,
        onDownloadPostFile: @escaping (PostFile) -> Void,
        onShowMessage: @escaping (String) -> Void
    ) {
        _query = State(initialValue: initialQuery)
        self.onOpenProfile = onOpenProfile
        self.onImageTap = onImageTap
        self.onVideoTap = onVideoTap
        self.onOpenComments = onOpenComments
        self.onDownloadImages = onDownloadImages
        self.onDownloadPostFile = onDownloadPostFile
        self.onShowMessage = onShowMessage
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Где искать", selection: $scope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            content
        }
        .padding(.top, 12)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scope) { _ in
            performSearch()
        }
        .onAppear {
            performSearch()
        }
    }

    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return AnyView(
                Text("Введите запрос для поиска")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        if isLoading {
            return AnyView(
                VStack {
                    ProgressView("Ищем...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        if let errorMessage {
            return AnyView(
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        if results.users.isEmpty && results.posts.isEmpty && results.songs.isEmpty {
            return AnyView(
                Text("Ничего не найдено")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        return AnyView(resultsList)
    }

    private var resultsList: some View {
        List {
            if (scope == .all || scope == .users), !results.users.isEmpty {
                Text("Пользователи")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(results.users.indices, id: \.self) { index in
                    userRow(results.users[index])
                }
            }

            if (scope == .all || scope == .posts), !results.posts.isEmpty {
                Text("Посты")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(results.posts) { post in
                    searchPostRow(post)
                }
            }

            if (scope == .all || scope == .music), !results.songs.isEmpty {
                Text("Музыка")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(results.songs) { song in
                    searchSongRow(song)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func userRow(_ author: PostAuthor) -> some View {
        Button {
            onOpenProfile(author.username)
        } label: {
            HStack(spacing: 12) {
                PostAuthorAvatarView(media: author.avatarMedia, fallbackText: author.name ?? author.username ?? "U", size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(author.name ?? author.username ?? "Unknown")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if let username = author.username {
                        Text("@\(username)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .padding(12)
        .postCardStyle(cornerRadius: 16)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func searchPostRow(_ post: SearchPost) -> some View {
        Group {
            if let detailed = detailedPosts[post.id] {
                let canDeleteChannelPost = canManageChannelPost(detailed.author)
                PostRowView(
                    post: detailed,
                    isTrashContext: false,
                    canManageChannelPost: canDeleteChannelPost,
                    onImageTap: { images, index in
                        onImageTap(images, index)
                    },
                    onVideoTap: { video in
                        onVideoTap(video)
                    },
                    onAuthorTap: {
                        onOpenProfile(detailed.author.username)
                    },
                    onUsernameTap: { username in
                        onOpenProfile(username)
                    },
                    onReactionTap: { reaction in
                        toggleReaction(postID: detailed.id, reaction: reaction)
                    },
                    onCommentsTap: {
                        onOpenComments(detailed)
                    },
                    onEditTap: { changes in
                        try await editPost(postID: detailed.id, changes: changes)
                    },
                    onDeleteTap: {
                        deletePost(postID: detailed.id)
                    },
                    onRestoreTap: { },
                    onArchiveTap: { },
                    onDownloadImagesTap: {
                        onDownloadImages(detailed)
                    },
                    onDownloadPostFileTap: { file in
                        onDownloadPostFile(file)
                    }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if let username = post.author.username {
                            Button {
                                onOpenProfile(username)
                            } label: {
                                PostAuthorAvatarView(
                                    media: post.author.avatarMedia,
                                    fallbackText: post.author.name ?? post.author.username ?? "U",
                                    size: 28
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                onOpenProfile(username)
                            } label: {
                                let isVerified = post.author.isVerified ?? false
                                let hasGold = post.author.goldStatus ?? false
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(post.author.name ?? post.author.username ?? "Unknown")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        if isVerified || hasGold {
                                            UserStatusBadges(isVerified: isVerified, hasGold: hasGold, size: 14)
                                        }
                                    }
                                    Text("@\(username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            PostAuthorAvatarView(
                                media: post.author.avatarMedia,
                                fallbackText: post.author.name ?? post.author.username ?? "U",
                                size: 28
                            )

                            let isVerified = post.author.isVerified ?? false
                            let hasGold = post.author.goldStatus ?? false
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(post.author.name ?? post.author.username ?? "Unknown")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.textPrimary)
                                    if isVerified || hasGold {
                                        UserStatusBadges(isVerified: isVerified, hasGold: hasGold, size: 14)
                                    }
                                }
                            }
                        }
                        Spacer()
                    }

                    let trimmedText = post.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if trimmedText.isEmpty {
                        Text("Загружаем пост...")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        LinkifiedPostText(text: trimmedText, onUsernameTap: { username in
                            onOpenProfile(username)
                        })
                            .font(.body)
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(3)
                    }
                }
                .padding(14)
                .postCardStyle(cornerRadius: 16)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .onAppear {
            loadDetailedPostIfNeeded(postID: post.id)
        }
    }

    private func canManageChannelPost(_ author: PostAuthor) -> Bool {
        guard author.type == 1, let authorID = author.id else { return false }
        let owned = APIClient.shared.currentUserChannelsSnapshot()
        return owned.contains(where: { $0.id == authorID })
    }

    private func loadDetailedPostIfNeeded(postID: Int) {
        guard detailedPosts[postID] == nil, !loadingPostIDs.contains(postID) else { return }
        loadingPostIDs.insert(postID)
        Task {
            do {
                let post = try await APIClient.shared.loadPost(postID: postID)
                await MainActor.run {
                    detailedPosts[postID] = post
                    _ = loadingPostIDs.remove(postID)
                }
            } catch {
                await MainActor.run {
                    _ = loadingPostIDs.remove(postID)
                }
            }
        }
    }

    private func toggleReaction(postID: Int, reaction: String) {
        guard var post = detailedPosts[postID] else { return }
        let original = post
        let isRemoving = post.toggleReaction(reaction)
        if !isRemoving {
            triggerLikeHaptic()
        }
        detailedPosts[postID] = post

        Task {
            do {
                try await APIClient.shared.setPostReaction(postID: postID, reaction: reaction, isRemoving: isRemoving)
            } catch {
                await MainActor.run {
                    detailedPosts[postID] = original
                    onShowMessage(error.localizedDescription)
                }
            }
        }
    }

    private func deletePost(postID: Int) {
        Task {
            do {
                try await APIClient.shared.deletePost(postID: postID)
                await MainActor.run {
                    detailedPosts.removeValue(forKey: postID)
                    results = SearchResults(
                        users: results.users,
                        posts: results.posts.filter { $0.id != postID },
                        songs: results.songs
                    )
                }
            } catch {
                await MainActor.run {
                    onShowMessage(error.localizedDescription)
                }
            }
        }
    }

    private func editPost(postID: Int, changes: PostContent.EditChanges) async throws {
        let trimmed = changes.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || changes.hasAttachmentChanges else {
            throw APIError.serverError("Введите текст поста")
        }

        let previousDetailed = detailedPosts[postID]
        let previousSearchPosts = results.posts
        let editedAt = ISO8601DateFormatter().string(from: Date())

        if var post = detailedPosts[postID] {
            post.text = trimmed
            post.editedAt = editedAt
            detailedPosts[postID] = post
        }

        results = SearchResults(
            users: results.users,
            posts: results.posts.map { item in
                guard item.id == postID else { return item }
                return SearchPost(id: item.id, author: item.author, text: trimmed, createDate: item.createDate)
            },
            songs: results.songs
        )

        do {
            let blocks = try await APIClient.shared.editPost(
                postID: postID,
                text: trimmed,
                newFiles: changes.newFiles,
                removedFileIDs: changes.removedFileIDs
            )
            if var post = detailedPosts[postID] {
                // Web mergeContentBlock: replace blocks with server result.
                var content = post.content ?? PostContent()
                if blocks.images != nil || changes.hasAttachmentChanges {
                    content.images = blocks.images
                }
                if blocks.files != nil || changes.hasAttachmentChanges {
                    content.files = blocks.files
                }
                post.content = content
                detailedPosts[postID] = post
            }
        } catch {
            detailedPosts[postID] = previousDetailed
            results = SearchResults(
                users: results.users,
                posts: previousSearchPosts,
                songs: results.songs
            )
            throw error
        }
    }

    private func searchSongRow(_ song: MusicSong) -> some View {
        Button {
            Task {
                await musicPlayerViewModel.selectSong(song, queue: results.songs)
            }
        } label: {
            HStack(spacing: 12) {
                MusicCoverArtworkView(
                    media: song.cover,
                    size: 56,
                    cornerRadius: 14
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                    if let album = song.album, !album.isEmpty {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(12)
            .postCardStyle(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = .empty
            errorMessage = nil
            isLoading = false
            return
        }

        searchTask?.cancel()
        isLoading = true
        errorMessage = nil
        detailedPosts = [:]
        loadingPostIDs = []

        searchTask = Task {
            do {
                let response = try await APIClient.shared.search(query: trimmed, category: scope.category)
                await MainActor.run {
                    results = response
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    results = .empty
                    isLoading = false
                }
            }
        }
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct FileExportPayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct FileExportSheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct EmojiKeyboardHelper: UIViewControllerRepresentable {
    final class Coordinator: NSObject, UITextFieldDelegate {
        private let onText: (String) -> Void
        private let onDelete: () -> Void
        private let onEnd: () -> Void
        var textField: UITextField?

        init(onText: @escaping (String) -> Void, onDelete: @escaping () -> Void, onEnd: @escaping () -> Void) {
            self.onText = onText
            self.onDelete = onDelete
            self.onEnd = onEnd
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty, range.length > 0 {
                onDelete()
                return false
            }
            guard !string.isEmpty else { return true }
            onText(string)
            textField.text = ""
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onEnd()
        }
    }

    final class EmojiTextField: UITextField {
        var forcedInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
        }

        override var textInputMode: UITextInputMode? {
            forcedInputMode ?? super.textInputMode
        }
    }

    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onDelete: onDelete, onEnd: { isActive = false })
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let textField = EmojiTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.textContentType = .none
        textField.isHidden = true
        controller.view.addSubview(textField)
        context.coordinator.textField = textField
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let textField = context.coordinator.textField else { return }
        if isActive, !textField.isFirstResponder {
            textField.becomeFirstResponder()
        } else if !isActive, textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onResult: (Result<UploadFile, Error>) -> Void

        init(onResult: @escaping (Result<UploadFile, Error>) -> Void) {
            self.onResult = onResult
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { picker.dismiss(animated: true) }

            guard let mediaType = info[.mediaType] as? String else { return }

            if mediaType == UTType.image.identifier {
                guard let image = info[.originalImage] as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.9) else {
                    return
                }
                let name = "camera_\(Int(Date().timeIntervalSince1970)).jpg"
                onResult(.success(UploadFile(name: name, data: data)))
                return
            }

            if mediaType == UTType.movie.identifier {
                guard let url = info[.mediaURL] as? URL else { return }
                do {
                    let data = try Data(contentsOf: url)
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let name = "video_\(Int(Date().timeIntervalSince1970)).\(ext)"
                    onResult(.success(UploadFile(name: name, data: data)))
                } catch {
                    onResult(.failure(error))
                }
            }
        }
    }

    let onResult: (Result<UploadFile, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.allowsEditing = false
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

struct PostsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @AppStorage("adv_show_online") private var showOnlineUsers: Bool = true
    @AppStorage("adv_notifications_toast") private var notificationsToast: Bool = true
    @AppStorage("adv_notifications_sound") private var notificationsSound: Bool = true
    @AppStorage("adv_create_post_ui") private var createPostUIStyleRaw: String = CreatePostUIStyle.both.rawValue
    @AppStorage("feed_posts_type") private var feedPostsTypeRaw: String = "last"
    @StateObject var viewModel: PostsViewModel
    let onLogout: () -> Void
    @State private var selectedVideo: PostVideo?
    @State private var selectedImagePayload: SelectedImagePayload?
    @State private var sharePayload: SharePayload?
    @State private var showingCreatePost = false
    @State private var selectedCommentsPost: Post?
    @State private var feedScrollTargetPostID: Int?
    @State private var menuDestination: ProfileMenuDestination?
    @State private var profileRouteUsername: String?
    @State private var profileRouteViewModel: ProfileViewModel?
    @State private var isProfileLoading = false
    @State private var infoMessage: String?
    @State private var debugLogLines: [String] = []
    @State private var lastAutoRefreshAt: Date?
    @State private var accountSwitchToken = UUID()
    @State private var currentAuthorSnapshot: PostAuthor?
    @State private var topBarAuthorSnapshot: PostAuthor?
    @State private var quickPostText: String = ""
    @State private var createPostDraftText: String = ""
    @State private var createPostDraftFiles: [UploadFile] = []
    @State private var createPostDraftSongs: [MusicSong] = []
    @State private var createPostDraftPoll: PostPollDraft?
    @State private var isQuickPosting = false
    @State private var showEmojiKeyboard = false
    @State private var quickSelectedPhotoItems: [PhotosPickerItem] = []
    @State private var quickSelectedSongs: [MusicSong] = []
    @State private var quickDraftFiles: [UploadFile] = []
    @State private var quickPollDraft: PostPollDraft?
    @State private var isQuickPhotosPickerPresented = false
    @State private var isQuickFileImporting = false
    @State private var isQuickCameraPresented = false
    @State private var isQuickMusicPickerPresented = false
    @State private var isQuickPollEditorPresented = false
    @FocusState private var isQuickPostFocused: Bool
    @State private var currentEBalls: String = "0.000"
    @State private var onlineUsers: [PostAuthor] = []
    @State private var isLoadingOnlineUsers = false
    @State private var isFeedSwitching = false
    @State private var selectedTab: MainTab = .feed
    @State private var lastNonCreateTab: MainTab = .feed
    @StateObject private var profileComposeContext = ProfileComposeContext()
    @StateObject private var rootProfileViewModel = ProfileViewModel()
    @StateObject private var accountSwitcher = AccountSwitcherViewModel()
    @StateObject private var musicPlayerViewModel = MusicPlayerViewModel.shared
    @State private var isMusicFullPlayerPresented = false
    @State private var isTopMiniPlayerExpanded = false
    @State private var searchQuery: String = ""
    @State private var isSearchResultsPresented = false
    @FocusState private var isSearchFocused: Bool
    @State private var inlineSearchResults: SearchResults? = nil
    @State private var isInlineSearchLoading = false
    @State private var inlineSearchTask: Task<Void, Never>? = nil
    @State private var isSearchDropdownVisible = false
    @State private var lastLoggedTopBarSearchWidth: CGFloat = 0
    @State private var lastLoggedTopBarTrailingWidth: CGFloat = 0
    @State private var exportPayload: FileExportPayload?
    @State private var inAppBanner: InAppBannerData?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var unreadNotificationsCount: Int = APIClient.shared.currentUserNotificationsSnapshot()
    @State private var unreadMessengerCount: Int = APIClient.shared.currentUserMessengerNotificationsSnapshot()
    @State private var isMessengerChatActive = false
    @State private var currentChannels: [ChannelSummary] = []
    @State private var selectedChannel: ChannelSummary?
    @State private var isCreateChannelPresented = false
    private let bottomBarContentInset: CGFloat = 96
    private let topBarBubbleHeight: CGFloat = 34
    private let onlineUsersRefreshInterval: UInt64 = 8_000_000_000
    /// Feed rows use `listRowInsets` leading 8; iOS 26 liquid bar search sits a few pt further left.
    private let ios26FeedSearchLeadingAlignPad: CGFloat = -6
    private var isIOS17OrNewer: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }
    private var isIOS26OrNewer: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    private var topBarAvatarSize: CGFloat {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 18 ? 30 : 34
    }
    private var activeBottomInset: CGFloat {
        if isIOS26OrNewer { return 0 }
        if selectedTab == .messenger && isMessengerChatActive { return 0 }
        return selectedTab == .profile ? 0 : bottomBarContentInset
    }
    private var rootBottomInset: CGFloat { isIOS26OrNewer ? 0 : 18 }
    private var notificationsBadgeText: String? {
        let count = unreadNotificationsCount
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    private var messengerBadgeText: String? {
        let count = unreadMessengerCount
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }
    private var createPostUIStyle: CreatePostUIStyle {
        CreatePostUIStyle(rawValue: createPostUIStyleRaw) ?? .both
    }
    private var shouldShowCreatePostCard: Bool {
        createPostUIStyle == .card || createPostUIStyle == .both
    }
    private var shouldShowCreatePostButton: Bool {
        createPostUIStyle == .button || createPostUIStyle == .both
    }
    private var canSendQuickPost: Bool {
        !isQuickPosting && (
            !quickPostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !quickSelectedSongs.isEmpty
            || !quickDraftFiles.isEmpty
            || quickPollDraft != nil
        )
    }
    private var quickActionBackground: Color {
        AppTheme.surfaceElevated
    }
    private var quickActionForeground: Color {
        AppTheme.controlIcon
    }

    /// Top / bottom floating chrome on iOS < 26, light appearance (#ffffffb3 + #d1d1d178 stroke).
    private var legacyLightFloatingChromeFill: Color {
        Color(red: 1, green: 1, blue: 1, opacity: 179 / 255)
    }

    private var legacyLightFloatingChromeBorder: Color {
        Color(red: 209 / 255, green: 209 / 255, blue: 209 / 255, opacity: 120 / 255)
    }

    private var legacyPreIOS26ToolbarBubbleStroke: Color {
        colorScheme == .light
            ? legacyLightFloatingChromeBorder
            : Color.white.opacity(0.12)
    }

    @ViewBuilder
    private var legacyPreIOS26ToolbarBubbleBackground: some View {
        if colorScheme == .light {
            Capsule().fill(legacyLightFloatingChromeFill)
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }

    var body: some View {
        mainView
    }

    private var mainView: some View {
        applyMainViewModifiers(
            rootBase
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: rootBottomInset)
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: $isSearchResultsPresented) { searchResultsDestination }
                .toolbar { feedToolbar }
        )
    }

    private var rootBase: some View {
        ZStack(alignment: .top) {
            AppTheme.backgroundGradient
                .ignoresSafeArea()

            if isIOS26OrNewer {
                ios26TabRoot
            } else {
                legacyRoot
            }
        }
        // NOTE: no app-wide tap-to-dismiss here on purpose.
        // A simultaneous tap covering text inputs resigns and immediately
        // re-acquires focus on every tap, which resets the cursor/selection
        // to the end of the text. Dismiss gestures are scoped to regions
        // without text inputs (feed posts area, chat messages area).
        .onChange(of: searchQuery) { newValue in
            let q = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            inlineSearchTask?.cancel()
            if q.isEmpty {
                inlineSearchResults = nil
                isInlineSearchLoading = false
                isSearchDropdownVisible = false
                return
            }
            // searchQuery is bound only to the search TextField,
            // so any change means the user is actively typing in search → show dropdown
            isSearchDropdownVisible = true
            isInlineSearchLoading = true
            inlineSearchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let results = try await APIClient.shared.search(query: q, category: .all)
                    await MainActor.run {
                        inlineSearchResults = results
                        isInlineSearchLoading = false
                    }
                } catch {
                    await MainActor.run { isInlineSearchLoading = false }
                }
            }
        }
        .onChange(of: isSearchFocused) { focused in
            if !focused {
                isSearchDropdownVisible = false
            } else if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isSearchDropdownVisible = true
            }
        }
    }

    @ViewBuilder
    private var inlineSearchDropdown: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if isInlineSearchLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .tint(AppTheme.textSecondary)
                                .padding(.vertical, 20)
                            Spacer()
                        }
                    } else if let results = inlineSearchResults {
                        let hasAny = !results.users.isEmpty || !results.posts.isEmpty || !results.songs.isEmpty
                        if hasAny {
                            // Users & Channels
                            if !results.users.isEmpty {
                                ForEach(results.users.prefix(5), id: \.id) { user in
                                    Button {
                                        if let username = user.username {
                                            searchQuery = ""
                                            isSearchFocused = false
                                            inlineSearchResults = nil
                                            openProfileWithLoading(username)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            PostAuthorAvatarView(
                                                media: user.avatarMedia,
                                                fallbackText: user.name ?? user.username ?? "?",
                                                size: 38
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(user.name ?? user.username ?? "")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(AppTheme.textPrimary)
                                                    .lineLimit(1)
                                                if let uname = user.username {
                                                    Text("@\(uname)")
                                                        .font(.caption)
                                                        .foregroundStyle(AppTheme.textSecondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            if (user.type ?? 0) == 1 {
                                                Image(systemName: "megaphone.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(AppTheme.textSecondary)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 66)
                                }
                            }
                            // Posts
                            if !results.posts.isEmpty {
                                ForEach(results.posts.prefix(3), id: \.id) { post in
                                    Button {
                                        searchQuery = ""
                                        isSearchFocused = false
                                        inlineSearchResults = nil
                                        openSearchResults()
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "doc.text")
                                                .font(.system(size: 16))
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .frame(width: 38, height: 38)
                                                .background(AppTheme.surfaceElevated, in: Circle())
                                            VStack(alignment: .leading, spacing: 2) {
                                                if let authorName = post.author.name ?? post.author.username {
                                                    Text(authorName)
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(AppTheme.textSecondary)
                                                        .lineLimit(1)
                                                }
                                                if let text = post.text, !text.isEmpty {
                                                    Text(text)
                                                        .font(.subheadline)
                                                        .foregroundStyle(AppTheme.textPrimary)
                                                        .lineLimit(2)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 66)
                                }
                            }
                            // Songs
                            if !results.songs.isEmpty {
                                ForEach(results.songs.prefix(3), id: \.id) { song in
                                    Button {
                                        Task { await musicPlayerViewModel.selectSong(song, queue: results.songs) }
                                        searchQuery = ""
                                        isSearchFocused = false
                                        inlineSearchResults = nil
                                    } label: {
                                        HStack(spacing: 12) {
                                            MusicCoverArtworkView(
                                                media: song.cover,
                                                size: 38,
                                                cornerRadius: 8,
                                                showsBorder: false
                                            )
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(song.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(AppTheme.textPrimary)
                                                    .lineLimit(1)
                                                if !song.artist.isEmpty {
                                                    Text(song.artist)
                                                        .font(.caption)
                                                        .foregroundStyle(AppTheme.textSecondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "play.fill")
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 66)
                                }
                            }
                            // Show all
                            Button {
                                isSearchFocused = false
                                openSearchResults()
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(selectedLanguageCode == "en" ? "Show all results" : "Показать все результаты")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.primary)
                                    Spacer()
                                }
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(selectedLanguageCode == "en" ? "Nothing found" : "Ничего не найдено")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxHeight: 290)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: inlineSearchResults != nil)
        .zIndex(100)
    }

    private var searchResultsDestination: some View {
        SearchResultsView(
            initialQuery: searchQuery,
            onOpenProfile: { username in
                isSearchResultsPresented = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    openProfileWithLoading(username)
                }
            },
            onImageTap: { images, index in
                selectedImagePayload = makeImagePayload(images: images, startIndex: index)
            },
            onVideoTap: { video in
                selectedVideo = video
            },
            onOpenComments: { post in
                selectedCommentsPost = post
            },
            onDownloadImages: { post in
                Task {
                    do {
                        let items = post.content?.images?.map {
                            ImageSaveItem(media: $0.imgData, estimatedBytes: $0.fileSize)
                        } ?? []
                        let count = try await PhotoLibrarySaver.saveImages(from: items)
                        infoMessage = "Сохранено фото: \(count)"
                    } catch {
                        infoMessage = error.localizedDescription
                    }
                }
            },
            onDownloadPostFile: { file in
                Task {
                    await downloadPostFile(file)
                }
            },
            onShowMessage: { message in
                infoMessage = message
            }
        )
    }

    @ToolbarContentBuilder
    private var feedToolbar: some ToolbarContent {
        if selectedTab == .feed {
            let hasTopSong = topMiniPlayerSong != nil
            let eballsLeadingPadding: CGFloat = 8
            let screenWidth = UIScreen.main.bounds.width
            let minLegacySearchWidth: CGFloat = hasTopSong ? 172 : 205
            /// iOS 26: measured trailing pill is ~122–134pt; fixed reserve 158 was a bit small → search ran wide.
            let topBarTrailingReserve: CGFloat = {
                if hasTopSong { return isIOS26OrNewer ? 222.0 : 195.0 }
                return isIOS26OrNewer ? 190.0 : 158.0
            }()
            let feedSearchFieldWidth = max(minLegacySearchWidth, screenWidth - topBarTrailingReserve)
            /// iOS 26 liquid toolbar: one height for search + trailing so the row reads as one line.
            let toolbarChromeHeight: CGFloat = isIOS26OrNewer ? 38 : topBarBubbleHeight
            let ios26SearchBubbleWidth: CGFloat = isIOS26OrNewer
                ? max(minLegacySearchWidth, feedSearchFieldWidth - ios26FeedSearchLeadingAlignPad)
                : feedSearchFieldWidth
            if isIOS26OrNewer {
                // `.principal` on iOS 26 often proposes only intrinsic width, so `maxWidth: .infinity`
                // does not expand — use explicit width from `feedSearchFieldWidth` (tighter reserve on 26).
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                        TextField(selectedLanguageCode == "en" ? "Search" : "Поиск", text: $searchQuery)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .submitLabel(.search)
                            .focused($isSearchFocused)
                            .onSubmit { openSearchResults() }
                            .textFieldStyle(.plain)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: ios26SearchBubbleWidth, height: toolbarChromeHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isSearchFocused = true
                        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            isSearchDropdownVisible = true
                        }
                    }
                    .background { legacyPreIOS26ToolbarBubbleBackground }
                    .overlay(
                        Capsule()
                            .stroke(legacyPreIOS26ToolbarBubbleStroke, lineWidth: 1)
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    let measured = geo.size.width
                                    if abs(lastLoggedTopBarSearchWidth - measured) > 0.5 {
                                        lastLoggedTopBarSearchWidth = measured
                                        print(
                                            "[UI][TopBarSearchWidth] ios26=\(isIOS26OrNewer) hasTopSong=\(hasTopSong) " +
                                            "screen=\(screenWidth) target=\(ios26SearchBubbleWidth) leadPad=\(ios26FeedSearchLeadingAlignPad) measured=\(measured)"
                                        )
                                    }
                                }
                                .onChange(of: geo.size.width) { newWidth in
                                    if abs(lastLoggedTopBarSearchWidth - newWidth) > 0.5 {
                                        lastLoggedTopBarSearchWidth = newWidth
                                        print(
                                            "[UI][TopBarSearchWidth] ios26=\(isIOS26OrNewer) hasTopSong=\(hasTopSong) " +
                                            "screen=\(screenWidth) target=\(ios26SearchBubbleWidth) leadPad=\(ios26FeedSearchLeadingAlignPad) measured=\(newWidth)"
                                        )
                                    }
                                }
                        }
                    )
                    .padding(.leading, ios26FeedSearchLeadingAlignPad)
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                        TextField(selectedLanguageCode == "en" ? "Search" : "Поиск", text: $searchQuery)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .submitLabel(.search)
                            .focused($isSearchFocused)
                            .onSubmit { openSearchResults() }
                            .textFieldStyle(.plain)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: feedSearchFieldWidth, height: toolbarChromeHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isSearchFocused = true
                        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            isSearchDropdownVisible = true
                        }
                    }
                    .background { legacyPreIOS26ToolbarBubbleBackground }
                    .overlay(
                        Capsule()
                            .stroke(legacyPreIOS26ToolbarBubbleStroke, lineWidth: 1)
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    let measured = geo.size.width
                                    if abs(lastLoggedTopBarSearchWidth - measured) > 0.5 {
                                        lastLoggedTopBarSearchWidth = measured
                                        print(
                                            "[UI][TopBarSearchWidth] ios26=\(isIOS26OrNewer) hasTopSong=\(hasTopSong) " +
                                            "screen=\(screenWidth) target=\(feedSearchFieldWidth) measured=\(measured)"
                                        )
                                    }
                                }
                                .onChange(of: geo.size.width) { newWidth in
                                    if abs(lastLoggedTopBarSearchWidth - newWidth) > 0.5 {
                                        lastLoggedTopBarSearchWidth = newWidth
                                        print(
                                            "[UI][TopBarSearchWidth] ios26=\(isIOS26OrNewer) hasTopSong=\(hasTopSong) " +
                                            "screen=\(screenWidth) target=\(feedSearchFieldWidth) measured=\(newWidth)"
                                        )
                                    }
                                }
                        }
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    if let topSong = topMiniPlayerSong {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                isTopMiniPlayerExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isTopMiniPlayerExpanded ? "music.note.house.fill" : "music.note")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .accessibilityLabel(topSong.title)
                        }
                        .buttonStyle(.plain)
                        
                        Capsule()
                            .fill(AppTheme.cardStroke.opacity(0.8))
                            .frame(width: 1, height: 14)
                    }

                    Menu {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label(selectedLanguageCode == "en" ? "Refresh" : "Обновить", systemImage: "arrow.clockwise")
                    }
                    Button {
                        navigateToMenuDestination(.myProfile)
                    } label: {
                        Label(selectedLanguageCode == "en" ? "My profile" : "Мой профиль", systemImage: "person.circle")
                    }
                    Button {
                        navigateToMenuDestination(.accountSelection)
                    } label: {
                        Label(selectedLanguageCode == "en" ? "Accounts" : "Аккаунты", systemImage: "person.2")
                    }
                    Menu {
                        Button {
                            navigateToMenuDestination(.myChannels)
                        } label: {
                            Label(
                                AppLang.tr("Открыть список", "Open list", code: selectedLanguageCode),
                                systemImage: "rectangle.stack"
                            )
                        }
                        if currentChannels.isEmpty {
                            Text(AppLang.key("no_channels_yet", code: selectedLanguageCode, fallback: "Вы ещё не создали ни один канал"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(currentChannels.indices, id: \.self) { index in
                                let channel = currentChannels[index]
                                Button {
                                    if let username = channel.username, !username.isEmpty {
                                        openProfileWithLoading(username)
                                    }
                                } label: {
                                    Label {
                                        Text(channel.name ?? channel.username ?? "Channel")
                                    } icon: {
                                        menuAvatarIcon(for: channelAvatarMedia(channel), fallbackSystemName: "megaphone")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button {
                            isCreateChannelPresented = true
                        } label: {
                            Label(
                                AppLang.tr("Создать канал", "Create channel", code: selectedLanguageCode),
                                systemImage: "plus"
                            )
                        }
                    } label: {
                        Label(AppLang.key("my_channels", code: selectedLanguageCode, fallback: "Мои каналы"), systemImage: "megaphone")
                    }
                    Button {
                        navigateToMenuDestination(.notifications)
                    } label: {
                        Label(selectedLanguageCode == "en" ? "Notifications" : "Уведомления", systemImage: "bell")
                    }
                    Button {
                        navigateToMenuDestination(.music)
                    } label: {
                        Label(AppLang.key("nav_music", code: selectedLanguageCode, fallback: "Музыка"), systemImage: "music.note")
                    }
                    Button {
                        navigateToMenuDestination(.eBalance)
                    } label: {
                        Label(AppLang.tr("Кошелёк", "Wallet", code: selectedLanguageCode), systemImage: "creditcard")
                    }
                    Button {
                        navigateToMenuDestination(.subscribe)
                    } label: {
                        Label {
                            Text(AppLang.tr("Подписка", "Subscription", code: selectedLanguageCode))
                        } icon: {
                            Image(systemName: "star.fill")
                        }
                    }
                    Button {
                        navigateToMenuDestination(.hall)
                    } label: {
                        Label(
                            AppLang.key("nav_hall", code: selectedLanguageCode, fallback: "Зал славы"),
                            systemImage: "trophy"
                        )
                    }
                    Button {
                        navigateToMenuDestination(.settings)
                    } label: {
                        Label(selectedLanguageCode == "en" ? "Settings" : "Настройки", systemImage: "gearshape")
                    }
                    Button(role: .destructive) {
                        navigateToMenuDestination(.logout)
                    } label: {
                        Label(selectedLanguageCode == "en" ? "Logout" : "Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                            .if(isIOS26OrNewer) { view in
                                view.foregroundStyle(.red)
                            }
                    }
                    .if(isIOS26OrNewer) { view in
                        view.tint(.red)
                    }
                    } label: {
                        HStack(spacing: 10) {
                        eballsBadge
                        PostAuthorAvatarView(
                            media: topBarUserAvatar,
                            fallbackText: topBarUserFallbackText,
                            size: topBarAvatarSize
                        )
                        .overlay(
                            Circle()
                                .stroke(AppTheme.cardStroke, lineWidth: 1)
                        )
                        }
                        .contentShape(Rectangle())
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, isIOS26OrNewer ? 12 : eballsLeadingPadding)
                .padding(.trailing, isIOS26OrNewer ? 4 : 2)
                .frame(height: toolbarChromeHeight)
                .if(!isIOS26OrNewer) { view in
                    view
                        .background { legacyPreIOS26ToolbarBubbleBackground }
                        .overlay(
                            Capsule()
                                .stroke(legacyPreIOS26ToolbarBubbleStroke, lineWidth: 1)
                        )
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                let measured = geo.size.width
                                if abs(lastLoggedTopBarTrailingWidth - measured) > 0.5 {
                                    lastLoggedTopBarTrailingWidth = measured
                                    print("[UI][TopBarTrailingWidth] hasTopSong=\(hasTopSong) measured=\(measured)")
                                }
                            }
                            .onChange(of: geo.size.width) { newWidth in
                                if abs(lastLoggedTopBarTrailingWidth - newWidth) > 0.5 {
                                    lastLoggedTopBarTrailingWidth = newWidth
                                    print("[UI][TopBarTrailingWidth] hasTopSong=\(hasTopSong) measured=\(newWidth)")
                                }
                            }
                    }
                )
            }
        }
    }
    private func applyMainViewModifiers<Content: View>(_ content: Content) -> some View {
        content
            // iOS 26: use native toolbar bubble (button) instead of .searchable
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if let song = topMiniPlayerSong, isTopMiniPlayerExpanded {
                        MusicMiniPlayerView(
                            song: song,
                            isPreparing: musicPlayerViewModel.isPreparingPlayback,
                            isPlaying: musicPlayerViewModel.isPlaying,
                            playbackProgress: musicPlayerViewModel.playbackProgress,
                            downloadProgress: musicPlayerViewModel.downloadProgress(for: song.id),
                            onSeek: musicPlayerViewModel.seek(to:),
                            onTogglePlay: musicPlayerViewModel.togglePlayPause,
                            onPrevious: { Task { await musicPlayerViewModel.previous() } },
                            onNext: { Task { await musicPlayerViewModel.next() } },
                            onOpen: { isMusicFullPlayerPresented = true }
                        )
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let banner = inAppBanner {
                        InAppBannerView(
                            title: banner.title,
                            message: banner.message,
                            onTap: banner.notification == nil ? nil : {
                                handleInAppBannerTap(banner)
                            }
                        )
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 8)
                .zIndex(1)
            }
            .overlay(alignment: .bottomTrailing) { EmptyView() }
            .overlay(alignment: .top) {
                let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if isSearchDropdownVisible && !trimmedQuery.isEmpty {
                    inlineSearchDropdown
                        .padding(.top, 6)
                }
            }
            .task {
                currentAuthorSnapshot = APIClient.shared.currentAuthorSnapshot()
                if topBarAuthorSnapshot == nil {
                    topBarAuthorSnapshot = currentAuthorSnapshot
                }
                updateEBallsSnapshot()
                unreadNotificationsCount = APIClient.shared.currentUserNotificationsSnapshot()
                unreadMessengerCount = APIClient.shared.currentUserMessengerNotificationsSnapshot()
                let desiredType = feedPostsTypeRaw
                if viewModel.postsType != desiredType {
                    await viewModel.setPostsType(desiredType)
                } else if case .idle = viewModel.state {
                    await viewModel.loadPosts(reset: true)
                }
                await refreshOnlineUsersIfNeeded()
            }
            .task {
                await onlineUsersAutoRefreshLoop()
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                guard shouldAutoRefreshOnForeground() else { return }
                Task { await refreshAll() }
            }
            .onChange(of: showOnlineUsers) { isEnabled in
                if isEnabled {
                    Task { await refreshOnlineUsersIfNeeded(force: true) }
                } else {
                    onlineUsers = []
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: APIClient.inAppNotification)) { notification in
                guard scenePhase == .active else { return }
                if (notification.userInfo?["kind"] as? String) == "notification" {
                    if menuDestination != .notifications {
                        unreadNotificationsCount = min(unreadNotificationsCount + 1, 999)
                    }
                }
                if (notification.userInfo?["kind"] as? String) == "message" {
                    if selectedTab != .messenger {
                        unreadMessengerCount = min(unreadMessengerCount + 1, 999)
                    }
                }
                if notificationsSound {
                    NotificationSoundPlayer.shared.playNotificationSound()
                }
                guard notificationsToast else { return }
                if let pushNotification = notification.userInfo?["notification"] as? SocialNotification {
                    showInAppBanner(notification: pushNotification)
                    return
                }
                let rawTitle = notification.userInfo?["title"] as? String ?? ""
                let message = notification.userInfo?["message"] as? String ?? ""
                let title = rawTitle.isEmpty
                    ? AppLang.tr("Уведомление", "Notification", code: selectedLanguageCode)
                    : rawTitle
                guard !message.isEmpty || !title.isEmpty else { return }
                showInAppBanner(title: title, message: message)
            }
            .onChange(of: selectedTab) { newValue in
                if newValue != .feed, isTopMiniPlayerExpanded {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        isTopMiniPlayerExpanded = false
                    }
                }
                if newValue == .messenger {
                    unreadMessengerCount = APIClient.shared.currentUserMessengerNotificationsSnapshot()
                }
                if newValue == .create {
                    let returnTab = lastNonCreateTab
                    selectedTab = returnTab
                    if profileComposeContext.activeScreenID != nil, profileComposeContext.isWallTabActive {
                        profileComposeContext.requestWallCompose()
                    } else {
                        createPostDraftText = ""
                        createPostDraftFiles = []
                        createPostDraftSongs = []
                        createPostDraftPoll = nil
                        showingCreatePost = true
                    }
                    return
                }

                lastNonCreateTab = newValue
                if newValue == .feed {
                    Task { await refreshAll() }
                }
            }
            .onChange(of: feedPostsTypeRaw) { newValue in
                Task {
                    isFeedSwitching = true
                    await viewModel.setPostsType(newValue)
                    isFeedSwitching = false
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { selectedVideo != nil },
                set: { if !$0 { selectedVideo = nil } }
            )) {
                if let selectedVideo {
                    VideoPlayerScreen(video: selectedVideo)
                }
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items)
            }
            .sheet(item: $exportPayload) { payload in
                FileExportSheet(url: payload.url) { success in
                    exportPayload = nil
                    if success {
                        infoMessage = "Файл сохранён"
                    } else {
                        infoMessage = "Сохранение отменено"
                    }
                }
            }
            .sheet(isPresented: $isMusicFullPlayerPresented) {
                MusicFullPlayerView(viewModel: musicPlayerViewModel) { artist in
                    self.isMusicFullPlayerPresented = false
                    self.selectedTab = .settings
                    musicPlayerViewModel.selectedArtistForNavigation = artist
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { selectedImagePayload != nil },
                set: { if !$0 { selectedImagePayload = nil } }
            )) {
                if let payload = selectedImagePayload {
                    FullscreenImageViewer(items: payload.items, startIndex: payload.startIndex)
                }
            }
            .sheet(isPresented: $showingCreatePost) {
                CreatePostSheet(
                    initialText: createPostDraftText,
                    initialFiles: createPostDraftFiles,
                    initialSongs: createPostDraftSongs,
                    initialPoll: createPostDraftPoll,
                    availableChannels: currentChannels,
                    selectedChannel: $selectedChannel,
                    onCreateChannel: { isCreateChannelPresented = true },
                    accounts: accountSwitcher.accounts,
                    currentAccountID: accountSwitcher.currentAccountID,
                    onSelectAccount: { id in
                        Task { await handleAccountSwitch(to: id) }
                    }
                ) { text, files, songs, poll, channel in
                    let postID = try await viewModel.createPost(text: text, files: files, songs: songs, poll: poll, fromChannel: channel)
                    await viewModel.refreshAfterCreating(postID: postID)
                    createPostDraftText = ""
                    quickPostText = ""
                    createPostDraftFiles = []
                    createPostDraftSongs = []
                    createPostDraftPoll = nil
                    quickSelectedSongs = []
                    quickDraftFiles = []
                    quickPollDraft = nil
                }
            }
            .sheet(isPresented: $isCreateChannelPresented) {
                CreateChannelSheet { created in
                    if created {
                        updateChannelsSnapshot()
                    }
                }
            }
            .onChange(of: showingCreatePost) { isPresented in
                if !isPresented {
                    createPostDraftFiles = []
                    createPostDraftSongs = []
                    createPostDraftPoll = nil
                }
            }
            .sheet(isPresented: $isQuickMusicPickerPresented) {
                PostMusicPickerSheet(selectedSongs: $quickSelectedSongs)
            }
            .sheet(isPresented: $isQuickPollEditorPresented) {
                PostPollEditorSheet(initialDraft: quickPollDraft) { draft in
                    quickPollDraft = draft
                }
            }
            .onChange(of: selectedChannel?.id) { _ in
                APIClient.shared.setSelectedChannel(selectedChannel)
            }
            .photosPicker(
                isPresented: $isQuickPhotosPickerPresented,
                selection: $quickSelectedPhotoItems,
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos])
            )
            .fullScreenCover(isPresented: $isQuickCameraPresented) {
                CameraPicker { result in
                    switch result {
                    case .success(let payload):
                        appendQuickDraftFiles([payload])
                    case .failure(let error):
                        infoMessage = error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $isQuickFileImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await importQuickFiles(urls) }
                case .failure(let error):
                    infoMessage = error.localizedDescription
                }
            }
            .onChange(of: quickSelectedPhotoItems.count) { _ in
                let items = quickSelectedPhotoItems
                Task { await importQuickPhotos(items) }
            }
            .onChange(of: musicPlayerViewModel.selectedSong?.id) { songID in
                guard songID == nil, isTopMiniPlayerExpanded else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isTopMiniPlayerExpanded = false
                }
            }
            .onAppear {
                let hasTopSong = topMiniPlayerSong != nil
                let principalTrailingPadding: CGFloat = hasTopSong ? 12 : 2
                let eballsLeadingPadding: CGFloat = 8
                print(
                    "[UI][TopBarSpacing] ios26=\(isIOS26OrNewer) hasTopSong=\(hasTopSong) " +
                    "searchTrailingPadding=\(principalTrailingPadding) eballsLeadingPadding=\(eballsLeadingPadding)"
                )
            }
            .sheet(isPresented: Binding(
                get: { selectedCommentsPost != nil },
                set: { if !$0 { selectedCommentsPost = nil } }
            )) {
                if let post = selectedCommentsPost {
                    CommentsSheet(post: post, onCommentSent: {
                        viewModel.incrementCommentsCount(postID: post.id)
                    }, onOpenProfile: { username in
                        openProfileWithLoading(username)
                    })
                }
            }
            .navigationDestination(isPresented: isMenuDestinationPresented) {
                menuDestinationView
            }
            .navigationDestination(isPresented: Binding(
                get: { profileRouteUsername != nil },
                set: { isPresented in
                    if !isPresented {
                        profileRouteUsername = nil
                        profileRouteViewModel = nil
                    }
                }
            )) {
                if let username = profileRouteUsername, let viewModel = profileRouteViewModel {
                ProfileScreen(
                    username: username,
                    viewModel: viewModel
                )
                    .environmentObject(profileComposeContext)
            }
        }
            .alert("Сообщение", isPresented: Binding(
                get: { infoMessage != nil || viewModel.actionError != nil },
                set: { newValue in
                    if !newValue {
                        infoMessage = nil
                        viewModel.clearActionError()
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    infoMessage = nil
                    viewModel.clearActionError()
                }
            } message: {
                Text(infoMessage ?? viewModel.actionError ?? "")
            }
            .overlay {
                if isProfileLoading {
                    loadingOverlay
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                handleOpenURL(url)
            })
            .onAppear {
                updateEBallsSnapshot()
                updateChannelsSnapshot()
            }
    }

    private var currentAuthor: PostAuthor {
        currentAuthorSnapshot ?? APIClient.shared.currentAuthorSnapshot()
    }

    private var currentUserAvatar: MediaData? {
        if let fromSession = currentAuthor.avatarMedia {
            return fromSession
        }
        guard let currentID = currentAuthor.id else { return nil }
        return viewModel.posts.first(where: { post in
            guard let authorID = post.author.id else { return false }
            return authorID == currentID
        })?.author.avatarMedia
    }

    private var currentUserFallbackText: String {
        currentAuthor.name ?? currentAuthor.username ?? "U"
    }

    private var topBarUserAvatar: MediaData? {
        guard let author = topBarAuthorSnapshot else { return currentUserAvatar }
        if let authorID = author.id {
            return author.avatarMedia
                ?? viewModel.posts.first(where: { $0.author.id == authorID })?.author.avatarMedia
                ?? currentUserAvatar
        }
        return author.avatarMedia ?? currentUserAvatar
    }

    private var topBarUserFallbackText: String {
        guard let author = topBarAuthorSnapshot else { return currentUserFallbackText }
        return author.name ?? author.username ?? "U"
    }

    private func openSearchResults() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchQuery = trimmed
        isSearchResultsPresented = true
    }

    private var feedContent: some View {
        switch viewModel.state {
        case .idle where viewModel.posts.isEmpty, .loading where viewModel.posts.isEmpty:
            if isFeedSwitching {
                return AnyView(feedList)
            }
            return AnyView(
                VStack {
                    ProgressView(selectedLanguageCode == "en" ? "Loading posts..." : "Загружаем посты...")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        case .error(let message) where viewModel.posts.isEmpty:
            return AnyView(
                VStack(spacing: 12) {
                    Text(selectedLanguageCode == "en" ? "Loading error" : "Ошибка загрузки")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.red)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button(selectedLanguageCode == "en" ? "Retry" : "Повторить") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        default:
            return AnyView(feedList)
        }
    }

    private var messengerContent: some View {
        MessengerRootView(isChatActive: $isMessengerChatActive)
            .onAppear {
                unreadMessengerCount = APIClient.shared.currentUserMessengerNotificationsSnapshot()
            }
    }

    private var settingsContent: some View {
        NavigationStack {
            MusicRootView()
        }
    }

    private var profileContent: some View {
        ProfileScreen(
            username: currentAuthor.username ?? APIClient.shared.currentUsernameSnapshot(),
            viewModel: rootProfileViewModel,
            isRootTabProfile: true
        )
            .environmentObject(profileComposeContext)
    }

    private var legacyRoot: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .feed, .create:
                    feedContent
                case .messenger:
                    messengerContent
                case .settings:
                    settingsContent
                case .profile:
                    profileContent
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: activeBottomInset)
            }

            VStack(spacing: 4) {
                if selectedTab == .settings, let song = musicPlayerViewModel.selectedSong {
                    MusicMiniPlayerView(
                        song: song,
                        isPreparing: musicPlayerViewModel.isPreparingPlayback,
                        isPlaying: musicPlayerViewModel.isPlaying,
                        playbackProgress: musicPlayerViewModel.playbackProgress,
                        downloadProgress: musicPlayerViewModel.downloadProgress(for: song.id),
                        onSeek: musicPlayerViewModel.seek(to:),
                        onTogglePlay: musicPlayerViewModel.togglePlayPause,
                        onPrevious: { Task { await musicPlayerViewModel.previous() } },
                        onNext: { Task { await musicPlayerViewModel.next() } },
                        onOpen: { isMusicFullPlayerPresented = true }
                    )
                    .padding(.horizontal, 14)
                }

                if !isMessengerChatActive || selectedTab != .messenger {
                    bottomNavBar
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, -38)
        }
    }

    private var ios26TabRoot: some View {
        ZStack(alignment: .bottom) {
            AppTheme.backgroundGradient
                .ignoresSafeArea()

            NavigationStack {
                TabView(selection: $selectedTab) {
                    feedContent
                        .tag(MainTab.feed)
                        .tabItem {
                            Label(
                                selectedLanguageCode == "en" ? "Home" : "Главная",
                                systemImage: "house.fill"
                            )
                        }

                    messengerContent
                        .tag(MainTab.messenger)
                        .tabItem {
                            Label(
                                AppLang.key("nav_messenger", code: selectedLanguageCode, fallback: "Мессенджер"),
                                systemImage: "message.fill"
                            )
                        }
                        .if(unreadMessengerCount > 0) { view in
                            view.badge(unreadMessengerCount)
                        }

                    if shouldShowCreatePostButton {
                        Color.clear
                            .tag(MainTab.create)
                            .tabItem {
                                Label(
                                    selectedLanguageCode == "en" ? "New post" : "Создать пост",
                                    systemImage: "plus"
                                )
                            }
                    }

                    settingsContent
                        .tag(MainTab.settings)
                        .tabItem {
                            Label(
                                AppLang.key("nav_music", code: selectedLanguageCode, fallback: "Музыка"),
                                systemImage: "music.note"
                            )
                        }

                    profileContent
                        .tag(MainTab.profile)
                        .tabItem {
                            Label(
                                selectedLanguageCode == "en" ? "Profile" : "Профиль",
                                systemImage: "person.crop.circle.fill"
                            )
                        }
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: ios26MiniPlayerReservedHeight)
                }
                .tint(AppTheme.primary)
                .navigationTitle(selectedTabTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarBackground(AppTheme.surface, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }

            if let song = ios26MiniPlayerSong {
                MusicMiniPlayerView(
                    song: song,
                    isPreparing: musicPlayerViewModel.isPreparingPlayback,
                    isPlaying: musicPlayerViewModel.isPlaying,
                    playbackProgress: musicPlayerViewModel.playbackProgress,
                    downloadProgress: musicPlayerViewModel.downloadProgress(for: song.id),
                    onSeek: musicPlayerViewModel.seek(to:),
                    onTogglePlay: musicPlayerViewModel.togglePlayPause,
                    onPrevious: { Task { await musicPlayerViewModel.previous() } },
                    onNext: { Task { await musicPlayerViewModel.next() } },
                    onOpen: { isMusicFullPlayerPresented = true }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var ios26MiniPlayerSong: MusicSong? {
        guard selectedTab == .settings else { return nil }
        return musicPlayerViewModel.selectedSong
    }

    private var topMiniPlayerSong: MusicSong? {
        guard selectedTab == .feed else { return nil }
        return musicPlayerViewModel.selectedSong
    }

    private var ios26MiniPlayerReservedHeight: CGFloat {
        ios26MiniPlayerSong == nil ? 0 : 78
    }

    private var selectedTabTitle: String {
        switch selectedTab {
        case .feed:
            return ""
        case .messenger:
            return AppLang.key("nav_messenger", code: selectedLanguageCode, fallback: "Мессенджер")
        case .create:
            return selectedLanguageCode == "en" ? "New post" : "Создать пост"
        case .settings:
            return AppLang.key("nav_music", code: selectedLanguageCode, fallback: "Музыка")
        case .profile:
            return isIOS26OrNewer ? "" : (selectedLanguageCode == "en" ? "Profile" : "Профиль")
        }
    }

    private var bottomNavBar: some View {
        let isLight = colorScheme == .light
        return AnyView(
            HStack(spacing: 10) {
                bottomNavItem(
                    title: selectedLanguageCode == "en" ? "Home" : "Главная",
                    systemImage: "house.fill",
                    isPrimary: false,
                    isSelected: selectedTab == .feed,
                    action: { goHome() }
                )
                bottomNavItem(
                    title: AppLang.key("nav_messenger", code: selectedLanguageCode, fallback: "Мессенджер"),
                    systemImage: "message.fill",
                    isPrimary: false,
                    isSelected: selectedTab == .messenger,
                    badgeText: messengerBadgeText,
                    action: { selectedTab = .messenger }
                )
                if shouldShowCreatePostButton {
                    bottomNavItem(
                        title: selectedLanguageCode == "en" ? "New post" : "Создать пост",
                        systemImage: "plus",
                        isPrimary: true,
                        isSelected: false,
                        action: {
                            if profileComposeContext.activeScreenID != nil, profileComposeContext.isWallTabActive {
                                profileComposeContext.requestWallCompose()
                            } else {
                                createPostDraftText = ""
                                createPostDraftFiles = []
                                createPostDraftSongs = []
                                createPostDraftPoll = nil
                                showingCreatePost = true
                            }
                        }
                    )
                }
                bottomNavItem(
                    title: AppLang.key("nav_music", code: selectedLanguageCode, fallback: "Музыка"),
                    systemImage: "music.note",
                    isPrimary: false,
                    isSelected: selectedTab == .settings,
                    action: { selectedTab = .settings }
                )
                bottomNavItem(
                    title: selectedLanguageCode == "en" ? "Profile" : "Профиль",
                    systemImage: "person.crop.circle.fill",
                    isPrimary: false,
                    isSelected: selectedTab == .profile,
                    action: { selectedTab = .profile }
                )
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(bottomBarBackground(cornerRadius: 22, isLight: isLight))
            .shadow(color: isLight ? Color.black.opacity(0.12) : Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
        )
    }

    /// Inactive tab icon + label on legacy bottom bar (requested #88868d).
    private var bottomNavInactiveTint: Color {
        Color(red: 136 / 255, green: 134 / 255, blue: 141 / 255)
    }

    @ViewBuilder
    private func bottomBarBackground(cornerRadius: CGFloat, isLight: Bool) -> some View {
        if isIOS26OrNewer {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isLight ? 0.5 : 0.16), lineWidth: 1)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func bottomNavItem(title: String, systemImage: String, isPrimary: Bool, isSelected: Bool, badgeText: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: isPrimary ? 0 : 4) {
                ZStack {
                    if isPrimary {
                        Circle()
                            .fill(AppTheme.primary)
                            .frame(width: 44, height: 44)
                    }
                    Image(systemName: systemImage)
                        .font(isPrimary ? .title3.weight(.bold) : .system(size: 18, weight: .semibold))
                        .foregroundStyle(isPrimary ? .white : (isSelected ? AppTheme.primary : bottomNavInactiveTint))
                    if let badgeText, !isPrimary {
                        Text(badgeText)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, badgeText.count >= 3 ? 6 : 5)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .offset(x: 14, y: -12)
                    }
                }
                if !isPrimary {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? AppTheme.primary : bottomNavInactiveTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @MainActor
    private func goHome() {
        selectedTab = .feed
        menuDestination = nil
        let target = viewModel.posts.first?.id
        feedScrollTargetPostID = nil
        feedScrollTargetPostID = target
    }

    private func canManageChannelPost(_ author: PostAuthor) -> Bool {
        guard author.type == 1, let authorID = author.id else { return false }
        let owned = APIClient.shared.currentUserChannelsSnapshot()
        return owned.contains(where: { $0.id == authorID })
    }

    private let feedItemSpacing: CGFloat = 4
    private let feedHorizontalPadding: CGFloat = 8

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: feedItemSpacing) {
                    AppUpdateBanner()

                    if shouldShowOnlineUsersCard {
                        onlineUsersCard
                    }

                    if shouldShowCreatePostCard {
                        createPostCard
                    }

                    // Tap-to-dismiss is intentionally scoped to the area BELOW
                    // the composer card: the quick-post TextField lives above,
                    // and a tap covering it would resign + refocus it, which
                    // resets the cursor/selection to the end of the text.
                    Group {
                    feedTabsRow
                        .padding(.bottom, 2)

                    if viewModel.isLoading && viewModel.posts.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }

                    ForEach(viewModel.posts) { post in
                        let canDeleteChannelPost = canManageChannelPost(post.author)
                        PostRowView(
                            post: post,
                            isTrashContext: false,
                            canManageChannelPost: canDeleteChannelPost,
                            onImageTap: { images, index in
                                selectedImagePayload = makeImagePayload(images: images, startIndex: index)
                            },
                            onVideoTap: { video in
                                selectedVideo = video
                            },
                            onAuthorTap: {
                                openAuthorProfile(post.author)
                            },
                            onUsernameTap: { username in
                                openProfileByUsername(username)
                            },
                            onReactionTap: { reaction in
                                Task { await viewModel.toggleReaction(postID: post.id, reaction: reaction) }
                            },
                            onCommentsTap: {
                                selectedCommentsPost = post
                            },
                            onEditTap: { changes in
                                try await viewModel.editPost(postID: post.id, changes: changes)
                            },
                            onDeleteTap: {
                                Task { await viewModel.deletePost(postID: post.id) }
                            },
                            onRestoreTap: { },
                            onArchiveTap: {
                                let shouldArchive = !(post.archived ?? false)
                                Task { await viewModel.toggleArchive(postID: post.id, shouldArchive: shouldArchive) }
                            },
                            onDownloadImagesTap: {
                                Task {
                                    do {
                                        let items = post.content?.images?.map {
                                            ImageSaveItem(media: $0.imgData, estimatedBytes: $0.fileSize)
                                        } ?? []
                                        let count = try await PhotoLibrarySaver.saveImages(from: items)
                                        infoMessage = "Сохранено фото: \(count)"
                                    } catch {
                                        infoMessage = error.localizedDescription
                                    }
                                }
                            },
                            onDownloadPostFileTap: { file in
                                Task {
                                    await downloadPostFile(file)
                                }
                            }
                        )
                        .id(post.id)
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded(currentPost: post) }
                        }
                    }

                    if viewModel.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    } else if !viewModel.hasMore {
                        HStack {
                            Spacer()
                            Text(selectedLanguageCode == "en" ? "No more posts" : "Посты закончились")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    }
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            dismissKeyboardsIfAllowed()
                        }
                    )
                }
                .padding(.horizontal, feedHorizontalPadding)
                .padding(.top, 3)
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.backgroundGradient)
            .if(isIOS26OrNewer) { view in
                view.scrollDismissesKeyboard(.never)
            }
            .refreshable {
                await refreshAll()
            }
            .onChange(of: feedScrollTargetPostID) { targetID in
                guard let targetID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
    }

    private var selectedFeedCategory: FeedCategory {
        FeedCategory(rawValue: feedPostsTypeRaw) ?? .last
    }

    private var shouldShowOnlineUsersCard: Bool {
        showOnlineUsers && !onlineUsers.isEmpty
    }

    private var onlineUsersCard: some View {
        let avatarSize: CGFloat = 40
        let avatarPadding: CGFloat = 3
        let spacing: CGFloat = 8

        return VStack(alignment: .leading, spacing: 12) {
            Text(selectedLanguageCode == "en" ? "Online now" : "сейчас в сети")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Group {
                if #available(iOS 17.0, *) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(Array(onlineUsers.enumerated()), id: \.offset) { _, user in
                                Button {
                                    openAuthorProfile(user)
                                } label: {
                                    PostAuthorAvatarView(
                                        media: user.avatarMedia,
                                        fallbackText: user.name ?? user.username ?? "U",
                                        size: avatarSize
                                    )
                                    .padding(avatarPadding)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 1)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(Array(onlineUsers.enumerated()), id: \.offset) { _, user in
                                Button {
                                    openAuthorProfile(user)
                                } label: {
                                    PostAuthorAvatarView(
                                        media: user.avatarMedia,
                                        fallbackText: user.name ?? user.username ?? "U",
                                        size: avatarSize
                                    )
                                    .padding(avatarPadding)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(height: avatarSize + avatarPadding * 2 + 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .postCardStyle(cornerRadius: 16)
    }

    private var createPostCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                AppLang.tr("Текст поста...", "Post text...", code: selectedLanguageCode),
                text: $quickPostText
            )
            .focused($isQuickPostFocused)
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(quickActionBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )

            if !quickSelectedSongs.isEmpty {
                attachedSongsPreview(
                    quickSelectedSongs,
                    removeAction: { song in
                        quickSelectedSongs.removeAll { $0.id == song.id }
                    }
                )
            }

            if let quickPollDraft {
                attachedPollPreview(quickPollDraft) {
                    self.quickPollDraft = nil
                }
            }

            if !quickDraftFiles.isEmpty {
                quickDraftFilesStrip
            }

            HStack(spacing: 8) {
                quickAttachmentsMenu(iconOnly: true)
                quickComposerIcon(systemImage: "music.note") {
                    isQuickMusicPickerPresented = true
                }
                quickComposerIcon(systemImage: "chart.bar.xaxis") {
                    isQuickPollEditorPresented = true
                }
                quickComposerIcon(systemImage: "face.smiling") {
                    showEmojiKeyboard = true
                    isQuickPostFocused = false
                }
                Spacer()
                Menu {
                    Text(AppLang.tr("Профили", "Profiles", code: selectedLanguageCode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(accountSwitcher.accounts) { account in
                        Button {
                            Task {
                                await handleAccountSwitch(to: account.id)
                                setSelectedChannel(nil)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayName)
                                    if let username = account.username, !username.isEmpty {
                                        Text("@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedChannel == nil, account.id == accountSwitcher.currentAccountID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppTheme.primary)
                                }
                            }
                        }
                    }
                    Divider()
                    Text(AppLang.tr("Каналы", "Channels", code: selectedLanguageCode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !currentChannels.isEmpty {
                        ForEach(currentChannels.indices, id: \.self) { index in
                            let channel = currentChannels[index]
                            Button {
                                setSelectedChannel(channel)
                            } label: {
                                Label {
                                    Text(menuTitle(channel.name ?? channel.username ?? "Channel", isSelected: selectedChannel?.id == channel.id))
                                } icon: {
                                    menuAvatarIcon(for: channelAvatarMedia(channel), fallbackSystemName: "megaphone")
                                }
                            }
                        }
                    } else {
                        Text(AppLang.key("no_channels_yet", code: selectedLanguageCode, fallback: "Вы ещё не создали ни один канал"))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Button {
                        isCreateChannelPresented = true
                    } label: {
                        Label(
                            AppLang.tr("Создать канал", "Create channel", code: selectedLanguageCode),
                            systemImage: "plus"
                        )
                    }
                } label: {
                    let media = selectedChannel.map(channelAvatarMedia) ?? currentAuthorSnapshot?.avatarMedia
                    let fallback = selectedChannel?.name ?? selectedChannel?.username ?? currentAuthorSnapshot?.name ?? currentAuthorSnapshot?.username ?? "U"
                    PostAuthorAvatarView(
                        media: media,
                        fallbackText: fallback,
                        size: 32
                    )
                    .overlay(
                        Circle().stroke(AppTheme.cardStroke, lineWidth: 1)
                    )
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isQuickPosting)
                Button(isQuickPosting ? AppLang.tr("Отправляем...", "Sending...", code: selectedLanguageCode) : AppLang.tr("Отправить", "Send", code: selectedLanguageCode)) {
                    Task { await submitQuickPost() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(canSendQuickPost ? .white : quickActionForeground)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    canSendQuickPost
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [AppTheme.primary, AppTheme.primarySoft],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(quickActionBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .disabled(!canSendQuickPost)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .postCardStyle(cornerRadius: 16)
        .background(
            EmojiKeyboardHelper(isActive: $showEmojiKeyboard, onText: { inserted in
                quickPostText.append(inserted)
            }, onDelete: {
                if !quickPostText.isEmpty {
                    quickPostText.removeLast()
                }
            })
            .frame(width: 0, height: 0)
        )
    }

    private func dismissKeyboards() {
        appendDebugLog("dismissKeyboards()")
        showEmojiKeyboard = false
        isQuickPostFocused = false
        isSearchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder
    private func attachedSongsPreview(_ songs: [MusicSong], removeAction: @escaping (MusicSong) -> Void) -> some View {
        VStack(spacing: 8) {
            ForEach(songs) { song in
                HStack(spacing: 10) {
                    MusicCoverArtworkView(media: song.cover, size: 44, cornerRadius: 12)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(song.artist)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer(minLength: 12)

                    Button {
                        removeAction(song)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func attachedPollPreview(_ poll: PostPollDraft, removeAction: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 40, height: 40)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Опрос · \(poll.normalizedOptions.count) вариантов")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                if !poll.normalizedQuestion.isEmpty {
                    Text("«\(poll.normalizedQuestion)»")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(poll.multipleChoice ? "Несколько вариантов ответа" : "Один вариант ответа")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                removeAction()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }

    private func dismissKeyboardsIfAllowed() {
        appendDebugLog("dismissKeyboardsIfAllowed(): dismissing")
        dismissKeyboards()
    }

    private func appendDebugLog(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLogLines.append("[\(time)] \(message)")
        if debugLogLines.count > 200 {
            debugLogLines.removeFirst(debugLogLines.count - 200)
        }
    }

    private func debugLogSnapshot() -> String {
        let tail = debugLogLines.suffix(20)
        if tail.isEmpty {
            return "Логов пока нет."
        }
        return tail.joined(separator: "\n")
    }

    private func showInAppBanner(title: String, message: String, notification: SocialNotification? = nil) {
        bannerDismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            inAppBanner = InAppBannerData(title: title, message: message, notification: notification)
        }
        bannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    inAppBanner = nil
                }
            }
        }
    }

    private func showInAppBanner(notification: SocialNotification) {
        let title = inAppBannerTitle(for: notification)
        let message = inAppBannerMessage(for: notification)
        showInAppBanner(title: title, message: message, notification: notification)
    }

    private func handleInAppBannerTap(_ banner: InAppBannerData) {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            inAppBanner = nil
        }
        guard let notification = banner.notification else { return }
        Task { await openInAppNotification(notification) }
    }

    private func openInAppNotification(_ notification: SocialNotification) async {
        if let postID = notification.content.postID {
            let action = normalizedNotificationAction(notification)
            let shouldOpenComments = action == "PostComment" || action == "ReplyComment" || notification.content.commentID != nil
            await openFromNotification(postID: postID, openComments: shouldOpenComments)
            return
        }

        if let username = notification.content.profileUsername ?? notification.author?.username,
           !username.isEmpty {
            await openProfileFromNotification(username)
        }
    }

    private func inAppBannerTitle(for notification: SocialNotification) -> String {
        if let name = notification.author?.name, !name.isEmpty {
            return name
        }
        if let name = notification.content.authorName, !name.isEmpty {
            return name
        }
        return AppLang.tr("Уведомление", "Notification", code: selectedLanguageCode)
    }

    private func inAppBannerMessage(for notification: SocialNotification) -> String {
        let action = normalizedNotificationAction(notification)
        let comment = notification.content.commentText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let postText = notification.content.postText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = notification.content.messageText?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "PostLike":
            return AppLang.tr("поставил(а) лайк вашему посту", "liked your post", code: selectedLanguageCode)
        case "PostDislike":
            return AppLang.tr("поставил(а) дизлайк вашему посту", "disliked your post", code: selectedLanguageCode)
        case "PostComment":
            if let comment, !comment.isEmpty {
                return AppLang.tr(
                    "оставил(а) комментарий: \"\(comment)\"",
                    "commented: \"\(comment)\"",
                    code: selectedLanguageCode
                )
            }
            return AppLang.tr("оставил(а) комментарий", "left a comment", code: selectedLanguageCode)
        case "ReplyComment":
            if let comment, !comment.isEmpty {
                return AppLang.tr(
                    "ответил(а): \"\(comment)\"",
                    "replied: \"\(comment)\"",
                    code: selectedLanguageCode
                )
            }
            return AppLang.tr("ответил(а) на комментарий", "replied to your comment", code: selectedLanguageCode)
        case "ProfileSubscribe":
            return AppLang.tr("подписался(ась) на ваш профиль", "subscribed to your profile", code: selectedLanguageCode)
        case "ProfileUnsubscribe":
            return AppLang.tr("отписался(ась) от вашего профиля", "unsubscribed from your profile", code: selectedLanguageCode)
        case "NewPost":
            if let postText, !postText.isEmpty {
                return AppLang.tr(
                    "Новый пост: \(shortPreview(postText))",
                    "New post: \(shortPreview(postText))",
                    code: selectedLanguageCode
                )
            }
            if let message, !message.isEmpty {
                return shortPreview(message)
            }
            return AppLang.tr("Новый пост", "New post", code: selectedLanguageCode)
        case "NewWallPost":
            if let postText, !postText.isEmpty {
                return AppLang.tr(
                    "Новый пост на стене: \(shortPreview(postText))",
                    "New wall post: \(shortPreview(postText))",
                    code: selectedLanguageCode
                )
            }
            if let message, !message.isEmpty {
                return shortPreview(message)
            }
            return AppLang.tr("Новый пост на стене", "New wall post", code: selectedLanguageCode)
        case "Message":
            return message ?? AppLang.tr("Новое сообщение", "New message", code: selectedLanguageCode)
        default:
            if let message, !message.isEmpty {
                return message
            }
            if let title = notification.content.title, !title.isEmpty {
                return title
            }
            return AppLang.tr("Новое уведомление", "New notification", code: selectedLanguageCode)
        }
    }

    private func normalizedNotificationAction(_ notification: SocialNotification) -> String {
        if notification.action == "notification",
           let subtype = notification.content.subtype,
           !subtype.isEmpty {
            return subtype
        }
        return notification.action
    }

    private func shortPreview(_ text: String, wordLimit: Int = 8) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !cleaned.isEmpty else { return text }
        if cleaned.count <= wordLimit {
            return cleaned.joined(separator: " ")
        }
        return cleaned.prefix(wordLimit).joined(separator: " ") + "..."
    }

    @ViewBuilder
    private var quickDraftFilesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(quickDraftFiles.enumerated()), id: \.offset) { index, file in
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 8) {
                            if let image = UIImage(data: file.data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(AppTheme.surfaceElevated)
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "doc.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(AppTheme.primary)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                    .font(.system(size: 9))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        .padding(6)
                        .padding(.trailing, 14)
                        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            quickDraftFiles.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(AppTheme.textSecondary)
                                .background(Circle().fill(AppTheme.surface))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func quickComposerIcon(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            quickComposerIconView(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(isQuickPosting)
    }

    private func quickComposerIconView(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(quickActionForeground)
            .frame(width: 34, height: 34)
            .background(quickActionBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    @ViewBuilder
    private func quickAttachmentsMenu(iconOnly: Bool) -> some View {
        Menu {
            Button(AppLang.tr("Медиатека", "Media Library", code: selectedLanguageCode)) {
                isQuickPhotosPickerPresented = true
            }
            Button(AppLang.tr("Снять фото или видео", "Take Photo or Video", code: selectedLanguageCode)) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    isQuickCameraPresented = true
                } else {
                    infoMessage = AppLang.tr("Камера недоступна на этом устройстве.", "Camera is not available on this device.", code: selectedLanguageCode)
                }
            }
            Button(AppLang.tr("Выбрать файлы", "Choose Files", code: selectedLanguageCode)) {
                isQuickFileImporting = true
            }
        } label: {
            if iconOnly {
                quickComposerIconView(systemImage: "doc")
            } else {
                Text(AppLang.tr("Вложения", "Attachments", code: selectedLanguageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(quickActionForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(quickActionBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled(isQuickPosting)
    }

    private func openFullComposer() {
        showEmojiKeyboard = false
        createPostDraftText = quickPostText
        createPostDraftFiles = []
        createPostDraftSongs = quickSelectedSongs
        createPostDraftPoll = quickPollDraft
        showingCreatePost = true
    }

    @MainActor
    private func handleAccountSwitch(to accountID: String) async {
        let previousSnapshot = currentAuthorSnapshot
        if let account = accountSwitcher.accounts.first(where: { $0.id == accountID }) {
            currentAuthorSnapshot = authorFromAccount(account)
        }
        let switched = await accountSwitcher.switchAccount(id: accountID)
        if switched {
            accountSwitchToken = UUID()
            currentAuthorSnapshot = APIClient.shared.currentAuthorSnapshot()
            await viewModel.refresh()
            await reloadRootProfileAfterSwitch()
            updateChannelsSnapshot()
            setSelectedChannel(nil)
        } else {
            infoMessage = accountSwitcher.errorMessage
                ?? AppLang.tr("Не удалось переключить аккаунт", "Failed to switch account", code: selectedLanguageCode)
            currentAuthorSnapshot = previousSnapshot ?? APIClient.shared.currentAuthorSnapshot()
        }
    }

    /// The profile tab caches its ViewModel — reload it for the new identity.
    @MainActor
    private func reloadRootProfileAfterSwitch() async {
        if let username = APIClient.shared.currentUsernameSnapshot() {
            await rootProfileViewModel.load(username: username, force: true)
        } else if case .error = rootProfileViewModel.state {
            // No username available; leave as is.
        }
    }

    private func mediaDataFromAccount(_ avatar: PostAuthorAvatar?) -> MediaData? {
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

    private func menuTitle(_ base: String, isSelected: Bool) -> String {
        isSelected ? "\(base) ✓" : base
    }

    private func menuAvatarIcon(for media: MediaData?, fallbackSystemName: String, size: CGFloat = 20) -> Image {
        if let image = menuAvatarImage(for: media, size: size) {
            return Image(uiImage: image).renderingMode(.original)
        }
        return Image(systemName: fallbackSystemName)
    }

    private func menuAvatarImage(for media: MediaData?, size: CGFloat) -> UIImage? {
        guard let media else { return nil }
        if let data = APIClient.shared.cachedMediaImageData(for: media, lossless: true)
            ?? APIClient.shared.cachedMediaImageData(for: media, lossless: false),
           let image = UIImage(data: data) {
            return circularImage(from: image, diameter: size)
        }
        return nil
    }

    private func circularImage(from image: UIImage, diameter: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: rect).addClip()
            let scale = max(diameter / image.size.width, diameter / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            let x = (diameter - width) / 2
            let y = (diameter - height) / 2
            image.draw(in: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    private func channelAvatarMedia(_ channel: ChannelSummary) -> MediaData? {
        guard let avatar = parseChannelAvatar(raw: channel.avatar) else { return nil }
        return MediaData(
            file: avatar.file,
            path: avatar.path ?? "avatars",
            preview: nil,
            simple: avatar.simple,
            aura: avatar.aura,
            storageFileID: avatar.storageFileID
        )
    }

    private func parseChannelAvatar(raw: String?) -> PostAuthorAvatar? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PostAuthorAvatar.self, from: data) {
            return decoded
        }
        let unescaped = raw.replacingOccurrences(of: "\\\"", with: "\"")
        if let data = unescaped.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PostAuthorAvatar.self, from: data) {
            return decoded
        }
        return nil
    }

    private func authorFromAccount(_ account: AccountStore.StoredAccount) -> PostAuthor {
        PostAuthor(
            id: account.userID,
            type: 0,
            name: account.name,
            username: account.username,
            avatar: account.avatar
        )
    }

    /// Max attachments on the quick card, mirroring the full composer picker.
    private let quickDraftFilesLimit = 10

    private func submitQuickPost() async {
        let trimmed = quickPostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !quickSelectedSongs.isEmpty || !quickDraftFiles.isEmpty), !isQuickPosting else { return }
        isQuickPosting = true
        showEmojiKeyboard = false
        do {
            let postID = try await viewModel.createPost(
                text: trimmed,
                files: quickDraftFiles,
                songs: quickSelectedSongs,
                poll: quickPollDraft,
                fromChannel: selectedChannel
            )
            await viewModel.refreshAfterCreating(postID: postID)
            quickPostText = ""
            quickSelectedSongs = []
            quickDraftFiles = []
            quickPollDraft = nil
        } catch {
            infoMessage = error.localizedDescription
        }
        isQuickPosting = false
    }

    private func importQuickPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var attachments: [UploadFile] = []
        for (index, item) in items.enumerated() {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let name = "photo_\(Int(Date().timeIntervalSince1970))_\(index).\(ext)"
                    attachments.append(UploadFile(name: name, data: data))
                }
            } catch {
                infoMessage = error.localizedDescription
            }
        }
        quickSelectedPhotoItems = []
        appendQuickDraftFiles(attachments)
    }

    private func importQuickFiles(_ urls: [URL]) async {
        var attachments: [UploadFile] = []
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent.isEmpty ? "file.bin" : url.lastPathComponent
                attachments.append(UploadFile(name: name, data: data))
            } catch {
                infoMessage = error.localizedDescription
            }
        }
        appendQuickDraftFiles(attachments)
    }

    /// Attachments picked from the quick card stay on the quick card —
    /// they are sent with "Отправить" instead of opening the full composer.
    private func appendQuickDraftFiles(_ attachments: [UploadFile]) {
        guard !attachments.isEmpty else { return }
        let room = max(0, quickDraftFilesLimit - quickDraftFiles.count)
        if room <= 0 {
            infoMessage = selectedLanguageCode == "en"
                ? "Attachment limit reached (\(quickDraftFilesLimit))"
                : "Достигнут лимит вложений (\(quickDraftFilesLimit))"
            return
        }
        quickDraftFiles.append(contentsOf: attachments.prefix(room))
        if attachments.count > room {
            infoMessage = selectedLanguageCode == "en"
                ? "Only the first \(room) files were attached"
                : "Прикреплены только первые \(room) файлов"
        }
    }

    private var feedTabsRow: some View {
        let selection = Binding<FeedCategory>(
            get: { selectedFeedCategory },
            set: { feedPostsTypeRaw = $0.rawValue }
        )
        return Picker("Раздел", selection: selection) {
            ForEach(FeedCategory.allCases, id: \.rawValue) { category in
                Text(feedTabTitle(category)).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 4)
    }

    private func feedTabTitle(_ category: FeedCategory) -> String {
        switch category {
        case .last:
            return selectedLanguageCode == "en" ? "Last" : "Последние"
        case .rec:
            return selectedLanguageCode == "en" ? "Recommended" : "Рекомендации"
        case .subscribe:
            return selectedLanguageCode == "en" ? "Subscribed" : "Подписки"
        }
    }

    private func navigateToMenuDestination(_ destination: ProfileMenuDestination) {
        switch destination {
        case .notifications:
            menuDestination = .notifications
        case .myProfile:
            selectedTab = .profile
            menuDestination = nil
        default:
            menuDestination = destination
        }
    }

    private func openAuthorProfile(_ author: PostAuthor) {
        openProfileWithLoading(author.username)
    }

    private func openProfileByUsername(_ username: String) {
        openProfileWithLoading(username)
    }

    @MainActor
    private func openProfileWithLoading(_ username: String?) {
        guard let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            infoMessage = "Не удалось открыть профиль"
            return
        }
        let profileViewModel = ProfileViewModel()
        profileViewModel.hydrateFromCache(username: trimmed)
        profileRouteViewModel = profileViewModel
        profileRouteUsername = trimmed
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            ProgressView(selectedLanguageCode == "en" ? "Loading..." : "Загружаем...")
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                )
        }
        .transition(.opacity)
    }

    @MainActor
    private func refreshAll() async {
        await viewModel.refresh()
        updateEBallsSnapshot()
        updateChannelsSnapshot()
        await refreshOnlineUsersIfNeeded(force: true)
    }

    private var eballsBadge: some View {
        HStack(spacing: 4) {
            Text("E")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(AppTheme.primary)
                        .shadow(color: AppTheme.primary.opacity(0.35), radius: 4, x: 0, y: 2)
                )
            Text(currentEBalls)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    private func updateEBallsSnapshot() {
        let raw = APIClient.shared.currentUserEBallsSnapshot()
        let normalized = raw?.replacingOccurrences(of: ",", with: ".") ?? ""
        let value = Double(normalized) ?? 0
        currentEBalls = String(format: "%.3f", value)
    }

    private func updateChannelsSnapshot() {
        currentChannels = APIClient.shared.currentUserChannelsSnapshot()
        if selectedChannel == nil {
            selectedChannel = APIClient.shared.currentSelectedChannelSnapshot()
        }
        if let selectedChannel,
           !currentChannels.contains(where: { $0.id == selectedChannel.id }) {
            setSelectedChannel(nil)
        }
    }

    private func setSelectedChannel(_ channel: ChannelSummary?) {
        selectedChannel = channel
        APIClient.shared.setSelectedChannel(channel)
    }

    @MainActor
    private func refreshOnlineUsersIfNeeded(force: Bool = false) async {
        guard showOnlineUsers else { return }
        guard !isLoadingOnlineUsers || force else { return }
        isLoadingOnlineUsers = true
        defer { isLoadingOnlineUsers = false }

        do {
            onlineUsers = try await APIClient.shared.loadOnlineUsers()
        } catch {
            // Keep the previous list on error to avoid flicker.
        }
    }

    private func onlineUsersAutoRefreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: onlineUsersRefreshInterval)
            } catch {
                break
            }

            if Task.isCancelled {
                break
            }

            guard scenePhase == .active else { continue }
            guard selectedTab == .feed else { continue }
            guard showOnlineUsers else { continue }

            await refreshOnlineUsersIfNeeded(force: true)
        }
    }

    private func downloadPostFile(_ file: PostFile) async {
        let candidates = attachmentPathCandidates(rawFile: file.file, preferredPaths: ["posts/files", "files"])
        for (path, filename) in candidates {
            if let url = await APIClient.shared.downloadFile(path: path, file: filename) {
                let displayName = exportFilename(for: file, fallback: filename)
                if let exportURL = prepareExportURL(from: url, filename: displayName) {
                    await MainActor.run {
                        exportPayload = FileExportPayload(url: exportURL)
                    }
                } else {
                    await MainActor.run {
                        infoMessage = "Не удалось подготовить файл"
                    }
                }
                return
            }
        }
        infoMessage = "Не удалось скачать файл"
    }

    private func exportFilename(for file: PostFile, fallback: String) -> String {
        let preferred = file.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (preferred?.isEmpty == false) ? preferred! : fallback
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        return (normalized as NSString).lastPathComponent
    }

    private func prepareExportURL(from url: URL, filename: String) -> URL? {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("ElementExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let targetURL = exportDir.appendingPathComponent(filename)
        if url == targetURL { return targetURL }
        try? FileManager.default.removeItem(at: targetURL)
        do {
            try FileManager.default.copyItem(at: url, to: targetURL)
            return targetURL
        } catch {
            return nil
        }
    }

    private func attachmentPathCandidates(rawFile: String?, preferredPaths: [String]) -> [(String, String)] {
        guard let rawFile else { return [] }
        let cleaned = rawFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        guard !cleaned.lowercased().hasPrefix("http://"), !cleaned.lowercased().hasPrefix("https://") else { return [] }

        let normalized = cleaned.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\", with: "/")
        var result: [(String, String)] = []

        for path in preferredPaths {
            result.append((path, normalized))
        }

        let ns = normalized as NSString
        if ns.pathComponents.count > 1 {
            let path = ns.deletingLastPathComponent
            let file = ns.lastPathComponent
            if !path.isEmpty, !file.isEmpty {
                result.append((path, file))
            }
        }

        var unique: [(String, String)] = []
        var seen = Set<String>()
        for (path, file) in result {
            let key = "\(path)|\(file)"
            if seen.insert(key).inserted {
                unique.append((path, file))
            }
        }
        return unique
    }

    private var menuAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.1)
    }

    private func shouldAutoRefreshOnForeground() -> Bool {
        let now = Date()
        defer { lastAutoRefreshAt = now }
        guard let lastAutoRefreshAt else { return true }
        return now.timeIntervalSince(lastAutoRefreshAt) >= 2.0
    }

    private var isMenuDestinationPresented: Binding<Bool> {
        Binding(
            get: { menuDestination != nil },
            set: { isPresented in
                if !isPresented {
                    menuDestination = nil
                }
            }
        )
    }

    @ViewBuilder
    private var menuDestinationView: some View {
        switch menuDestination {
        case .accountSelection:
            AccountSelectionView(
                currentAuthor: currentAuthor,
                onSwitchCompleted: {
                    accountSwitchToken = UUID()
                    currentAuthorSnapshot = APIClient.shared.currentAuthorSnapshot()
                    Task { await viewModel.refresh() }
                    Task { await reloadRootProfileAfterSwitch() }
                }
            )
        case .myProfile:
            ProfileScreen(
                username: currentAuthor.username ?? APIClient.shared.currentUsernameSnapshot(),
                viewModel: rootProfileViewModel
            )
                .environmentObject(profileComposeContext)
        case .myChannels:
            MyChannelsView(
                channels: currentChannels,
                onSelect: { channel in
                    if let username = channel.username, !username.isEmpty {
                        openProfileWithLoading(username)
                    }
                },
                onCreate: {
                    isCreateChannelPresented = true
                }
            )
        case .notifications:
            NotificationsView(
                onOpenPostInFeed: { postID in
                    Task { await openFromNotification(postID: postID, openComments: false) }
                },
                onOpenCommentsInFeed: { postID in
                    Task { await openFromNotification(postID: postID, openComments: true) }
                },
                onOpenProfile: { username in
                    Task { await openProfileFromNotification(username) }
                }
            )
            .onAppear {
                unreadNotificationsCount = 0
            }
        case .music:
            NavigationStack {
                MusicRootView()
            }
        case .settings:
            SettingsRootView()
        case .eBalance:
            EBalanceView()
        case .subscribe:
            SubscriptionScreen()
        case .hall:
            EBallHallView(onOpenProfile: { username in
                menuDestination = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    openProfileWithLoading(username)
                }
            })
        case .logout:
            LogoutView(onLogout: onLogout)
        case .none:
            EmptyView()
        }
    }

    @MainActor
    private func openFromNotification(postID: Int, openComments: Bool) async {
        selectedTab = .feed
        menuDestination = nil

        // Wait for navigation transition back to feed to complete.
        try? await Task.sleep(nanoseconds: 180_000_000)

        guard let post = await viewModel.ensurePostAvailable(postID: postID) else {
            infoMessage = selectedLanguageCode == "en"
                ? "Post is unavailable (it may have been deleted)"
                : "Пост недоступен (возможно, он удалён)"
            return
        }

        feedScrollTargetPostID = nil
        feedScrollTargetPostID = postID
        if openComments {
            try? await Task.sleep(nanoseconds: 220_000_000)
            selectedCommentsPost = post
        }
    }

    @MainActor
    private func openProfileFromNotification(_ username: String) async {
        openProfileByUsername(username)
    }

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        guard let postID = postIDFromElementURL(url) else {
            return .systemAction(url)
        }

        Task { @MainActor in
            await openFromNotification(postID: postID, openComments: false)
        }
        return .handled
    }

    private func postIDFromElementURL(_ url: URL) -> Int? {
        guard let host = url.host?.lowercased(), host.hasSuffix("elemsocial.com") else {
            return nil
        }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].lowercased() == "post" else {
            return nil
        }
        return Int(parts[1])
    }
}

private struct AccountSelectionView: View {
    @StateObject private var viewModel = AccountSwitcherViewModel()
    @Environment(\.dismiss) private var dismiss
    let currentAuthor: PostAuthor
    let onSwitchCompleted: () -> Void

    var body: some View {
        List {
            Section("Аккаунты") {
                if viewModel.accounts.isEmpty {
                    Text("Сохраненных аккаунтов нет")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.accounts) { account in
                        Button {
                            guard !viewModel.isSwitching else { return }
                            Task {
                                let switched = await viewModel.switchAccount(id: account.id)
                                if switched {
                                    onSwitchCompleted()
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                PostAuthorAvatarView(media: mediaData(from: account.avatar), fallbackText: account.displayName)
                                    .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayName)
                                        .font(.headline)
                                    if let username = account.username, !username.isEmpty {
                                        Text("@\(username)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if account.id == viewModel.currentAccountID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppTheme.primary)
                                }
                            }
                            .opacity(viewModel.isSwitching ? 0.55 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSwitching)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.removeAccount(id: account.id)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }

                NavigationLink {
                    LoginView(viewModel: LoginViewModel()) {
                        viewModel.reload()
                        onSwitchCompleted()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .background(AppTheme.surfaceElevated, in: Circle())
                        Text("Добавить аккаунт")
                            .font(.headline)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Аккаунты")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isSwitching {
                ZStack {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                    ProgressView("Переключаемся...")
                        .padding(16)
                        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private func mediaData(from avatar: PostAuthorAvatar?) -> MediaData? {
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
}

@MainActor
private final class AccountSwitcherViewModel: ObservableObject {
    @Published private(set) var accounts: [AccountStore.StoredAccount] = []
    @Published private(set) var currentAccountID: String?
    @Published var isSwitching = false
    @Published var errorMessage: String?

    private let apiClient: APIClient
    private let accountStore: AccountStore
    private let tokenStore: AuthTokenStore

    init(apiClient: APIClient = .shared, accountStore: AccountStore = AccountStore(), tokenStore: AuthTokenStore = AuthTokenStore()) {
        self.apiClient = apiClient
        self.accountStore = accountStore
        self.tokenStore = tokenStore
        reload()
    }

    func reload() {
        accounts = accountStore.accounts().sorted { $0.lastUsedAt > $1.lastUsedAt }
        currentAccountID = accountStore.currentAccountID()
    }

    func switchAccount(id: String) async -> Bool {
        guard !isSwitching else { return false }
        guard id != currentAccountID else { return true }
        guard let target = accounts.first(where: { $0.id == id }) else { return false }
        isSwitching = true
        defer { isSwitching = false }

        apiClient.resumeSocket()

        // Site parity: re-authorize on the live socket (no disconnect races).
        let restored = await apiClient.switchAccountSession(sKey: target.sKey)
        if restored {
            tokenStore.save(sessionKey: target.sKey)
            accountStore.setCurrentAccount(id: target.id)
            let summary = apiClient.currentAccountSummary()
            accountStore.updateCurrent(summary: summary)
            reload()
            return true
        } else {
            errorMessage = "Не удалось переключить аккаунт"
            return false
        }
    }

    func removeAccount(id: String) {
        accountStore.removeAccount(id: id)
        reload()
    }
}

struct ProfileScreen: View {
    enum Tab: Hashable {
        case posts
        case media
        case wall
        case gifts
        case archive
        case trashBin
        case info
    }

    struct ProfileTabItem: Identifiable {
        let tab: Tab
        let title: String

        var id: Tab { tab }
    }

    enum FollowListKind: String, Identifiable {
        case subscribers
        case subscriptions

        var id: String { rawValue }

        func title(for language: String) -> String {
            switch self {
            case .subscribers: return AppLang.tr("Подписчики", "Subscribers", code: language)
            case .subscriptions: return AppLang.tr("Подписки", "Subscriptions", code: language)
            }
        }
    }


    let username: String?
    var isRootTabProfile: Bool = false
    var isMessengerProfile: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @EnvironmentObject private var profileComposeContext: ProfileComposeContext
    @StateObject private var viewModel: ProfileViewModel
    @State private var selectedTab: Tab = .posts
    @State private var selectedVideo: PostVideo?
    @State private var selectedImagePayload: SelectedImagePayload?
    @State private var selectedCommentsPost: Post?
    @State private var selectedGift: GiftItem?
    @State private var showingSendGiftSheet = false
    @State private var reportContext: ReportContext?
    @State private var infoMessage: String?
    @State private var exportPayload: FileExportPayload?
    @State private var showingCreateWallPost = false
    @State private var showingEditChannelSheet = false
    @State private var selectedChannel: ChannelSummary? = APIClient.shared.currentSelectedChannelSnapshot()
    @State private var profileRouteUsername: String?
    @State private var profileRouteViewModel: ProfileViewModel?
    @State private var isProfileLoading = false
    @State private var activeFollowList: FollowListKind?
    @State private var scrollResetToken = UUID()
    @State private var screenID = UUID()
    @State private var didUserScroll = false
    @State private var profileScrollSafeAreaTop: CGFloat = Self.defaultProfileScrollSafeAreaTop()
    @State private var previousNavBarAppearance: NavBarAppearanceSnapshot?
    @ObservedObject private var musicPlayerViewModel = MusicPlayerViewModel.shared
    @State private var mediaItems: [ProfileMediaItem] = []
    @State private var isMediaLoading = false
    @State private var mediaError: String?
    @State private var mediaPostToOpen: Int?
    private let bottomBarAlignmentOffset: CGFloat = 18

    private func canOpenProfile(for author: PostAuthor) -> Bool {
        if let profile = viewModel.profile {
            if let authorID = author.id, authorID == profile.id {
                return false
            }
            if let authorUsername = author.username?.lowercased(),
               authorUsername == profile.username.lowercased() {
                return false
            }
        }
        if let authorID = author.id, let currentID = APIClient.shared.currentUserIDSnapshot(), authorID == currentID {
            return false
        }
        if let authorUsername = author.username?.lowercased(),
           let currentUsername = APIClient.shared.currentAuthorSnapshot().username?.lowercased(),
           authorUsername == currentUsername {
            return false
        }
        return true
    }

    private func canOpenProfile(username: String?) -> Bool {
        guard let target = username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !target.isEmpty else {
            return false
        }
        if let profile = viewModel.profile,
           target == profile.username.lowercased() {
            return false
        }
        if let currentUsername = APIClient.shared.currentAuthorSnapshot().username?.lowercased(),
           target == currentUsername {
            return false
        }
        return true
    }
    private let profileBottomInset: CGFloat = 96
    // (intentionally no matched-geometry namespace for profile tabs)
    private let navigationBarHeight: CGFloat = 44
    private let topBarBubbleHeight: CGFloat = 34
    private var isIOS26OrNewer: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    init(username: String?, viewModel: ProfileViewModel, isRootTabProfile: Bool = false, isMessengerProfile: Bool = false) {
        self.username = username
        self.isRootTabProfile = isRootTabProfile
        self.isMessengerProfile = isMessengerProfile
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        profileSheets
    }

    private var profileSheets: some View {
        profileLifecycle
            .fullScreenCover(isPresented: Binding(
                get: { selectedImagePayload != nil },
                set: { if !$0 { selectedImagePayload = nil } }
            )) {
                if let payload = selectedImagePayload {
                    FullscreenImageViewer(items: payload.items, startIndex: payload.startIndex)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { selectedVideo != nil },
                set: { if !$0 { selectedVideo = nil } }
            )) {
                if let selectedVideo {
                    VideoPlayerScreen(video: selectedVideo)
                }
            }
            .sheet(isPresented: Binding(
                get: { selectedCommentsPost != nil },
                set: { if !$0 { selectedCommentsPost = nil } }
            )) {
                if let post = selectedCommentsPost {
                    CommentsSheet(post: post, onCommentSent: {
                        viewModel.incrementCommentsCount(postID: post.id)
                    }, onOpenProfile: { username in
                        openProfileWithLoading(username)
                    })
                }
            }
            .sheet(isPresented: $showingCreateWallPost) {
                CreatePostSheet(
                    initialText: "",
                    initialFiles: [],
                    initialSongs: [],
                    initialPoll: nil,
                    availableChannels: APIClient.shared.currentUserChannelsSnapshot(),
                    selectedChannel: $selectedChannel,
                    accounts: [],
                    currentAccountID: nil,
                    onSelectAccount: { _ in }
                ) { text, files, songs, poll, channel in
                    selectedChannel = channel
                    APIClient.shared.setSelectedChannel(channel)
                    let postID = try await viewModel.createWallPost(text: text, files: files, songs: songs, poll: poll, fromChannel: channel)
                    await viewModel.refreshWallAfterCreating(postID: postID)
                }
            }
            .sheet(item: $selectedGift) { gift in
                NavigationStack {
                    GiftDetailView(
                        gift: gift,
                        profile: viewModel.profile,
                        onOpenProfile: { username in
                            selectedGift = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                openProfileWithLoading(username)
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: $showingSendGiftSheet) {
                if let targetUsername = viewModel.profile?.username ?? username {
                    GiftSendSheet(username: targetUsername)
                } else {
                    Text("Не удалось определить пользователя")
                }
            }
            .sheet(item: $reportContext) { context in
                ReportSheet(context: context)
            }
            .sheet(item: $activeFollowList) { list in
                followListSheet(kind: list)
            }
            .onChange(of: selectedChannel?.id) { _ in
                APIClient.shared.setSelectedChannel(selectedChannel)
            }
            .sheet(item: $exportPayload) { payload in
                FileExportSheet(url: payload.url) { success in
                    infoMessage = success ? "Файл сохранён" : "Сохранение отменено"
                }
            }
            .sheet(isPresented: $showingEditChannelSheet) {
                if let profile = viewModel.profile {
                    EditChannelSheet(
                        channelID: profile.id,
                        initialName: profile.name,
                        initialUsername: profile.username,
                        initialDescription: profile.description ?? "",
                        initialAvatar: profile.avatar,
                        initialCover: profile.cover,
                        onUpdated: {
                            Task {
                                await viewModel.load(username: username, force: true)
                            }
                        }
                    )
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { profileRouteUsername != nil },
                set: { isPresented in
                    if !isPresented {
                        profileRouteUsername = nil
                        profileRouteViewModel = nil
                    }
                }
            )) {
                if let username = profileRouteUsername, let viewModel = profileRouteViewModel {
                    ProfileScreen(
                        username: username,
                        viewModel: viewModel
                    )
                        .environmentObject(profileComposeContext)
                }
            }
            .alert("Сообщение", isPresented: Binding(
                get: { infoMessage != nil || viewModel.actionError != nil },
                set: { newValue in
                    if !newValue {
                        infoMessage = nil
                        viewModel.clearActionError()
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    infoMessage = nil
                    viewModel.clearActionError()
                }
            } message: {
                Text(infoMessage ?? viewModel.actionError ?? "")
            }
            .overlay {
                if isProfileLoading {
                    loadingOverlay
                }
            }
    }

    private var profileLifecycle: some View {
        profileBase
            .onAppear {
                if !isIOS26OrNewer {
                    applyLegacyProfileNavBarAppearance()
                }
                let normalized = username?.trimmingCharacters(in: .whitespacesAndNewlines)
                let shouldReset = viewModel.loadedUsername != normalized
                if shouldReset {
                    scrollResetToken = UUID()
                    didUserScroll = false
                    viewModel.resetUserScroll()
                }
                profileComposeContext.setActive(screenID: screenID, username: viewModel.profile?.username ?? username)
                profileComposeContext.setWallTabActive(selectedTab == .wall, screenID: screenID)
                Task { await viewModel.load(username: username, force: true) }
            }
            .onDisappear {
                if !isIOS26OrNewer {
                    restoreLegacyNavBarAppearance()
                }
                profileComposeContext.clearActive(screenID: screenID)
            }
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active else { return }
                Task { await viewModel.load(username: username, force: false) }
            }
            .onChange(of: selectedTab) { newValue in
                profileComposeContext.setWallTabActive(newValue == .wall, screenID: screenID)
                didUserScroll = false
                viewModel.resetUserScroll()
                Task { await viewModel.loadInitialContentIfNeeded(tab: newValue) }
                if newValue == .media { loadMediaIfNeeded() }
            }
            .onChange(of: viewModel.profile?.username) { newValue in
                profileComposeContext.setActive(screenID: screenID, username: newValue ?? username)
            }
            .onChange(of: viewModel.profile?.isMyProfile) { isMyProfile in
                if isMyProfile != true, (selectedTab == .trashBin || selectedTab == .archive) {
                    selectedTab = .posts
                }
            }
            .onChange(of: profileComposeContext.wallComposeRequestID) { _ in
                guard profileComposeContext.activeScreenID == screenID, selectedTab == .wall else { return }
                showingCreateWallPost = true
            }
            .onChange(of: mediaPostToOpen) { postID in
                guard let postID else { return }
                mediaPostToOpen = nil
                // find post in existing lists or load it
                if let found = viewModel.posts.first(where: { $0.id == postID }) ?? viewModel.wallPosts.first(where: { $0.id == postID }) {
                    selectedCommentsPost = commentSnapshot(for: found)
                } else {
                    Task {
                        if let loaded = try? await APIClient.shared.loadPost(postID: postID) {
                            await MainActor.run { selectedCommentsPost = loaded }
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var profileBase: some View {
        let base = ZStack(alignment: .bottomTrailing) {
            profileScrollView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .padding(.bottom, -bottomBarAlignmentOffset)
            if shouldShowWallComposeButton {
                Button {
                    showingCreateWallPost = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(
                            LinearGradient(
                                colors: [AppTheme.primary, AppTheme.primarySoft],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppTheme.cardStroke, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 6)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .accessibilityLabel("Новый пост")
            }
        }
        .navigationTitle(isIOS26OrNewer ? "" : AppLang.tr("Профиль", "Profile", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)

        if #available(iOS 26.0, *) {
            base
                .toolbarBackground(Color.clear, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            base
                .toolbarBackground(
                    colorScheme == .dark
                    ? Color.black.opacity(0.88)
                    : Color.white.opacity(0.94),
                    for: .navigationBar
                )
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var shouldShowWallComposeButton: Bool {
        guard selectedTab == .wall, let profile = viewModel.profile else { return false }
        return !profile.isMyProfile
    }

    private var isCurrentUserProfileContext: Bool {
        if viewModel.profile?.isMyProfile == true {
            return true
        }
        guard let currentUsername = APIClient.shared.currentAuthorSnapshot().username?.lowercased() else {
            return username == nil
        }
        let targetUsername = (viewModel.profile?.username ?? username)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let targetUsername {
            return targetUsername == currentUsername
        }
        return true
    }

    private var profileScrollView: some View {
        VerticalLockScrollView(
            resetID: scrollResetToken,
            showsIndicators: false,
            onRefresh: {
                didUserScroll = false
                viewModel.resetUserScroll()
                await viewModel.load(username: username, force: true)
                await viewModel.reloadContent(tab: selectedTab)
            },
            onScroll: { offset in
                guard offset.y > 8 else { return }
                if !didUserScroll {
                    didUserScroll = true
                    viewModel.recordUserScroll()
                }
            },
            onSafeAreaTopChange: { topInset in
                profileScrollSafeAreaTop = topInset
            },
            onReachBottom: {
                guard didUserScroll else { return }
                switch selectedTab {
                case .posts:
                    guard let lastPost = viewModel.posts.last else { return }
                    Task { await viewModel.loadMorePostsIfNeeded(currentPost: lastPost) }
                case .media:
                    break
                case .wall:
                    guard let lastPost = viewModel.wallPosts.last else { return }
                    Task { await viewModel.loadMoreWallIfNeeded(currentPost: lastPost) }
                case .gifts:
                    break
                case .archive:
                    guard let lastPost = viewModel.archivePosts.last else { return }
                    Task { await viewModel.loadMoreArchiveIfNeeded(currentPost: lastPost) }
                case .trashBin:
                    guard let lastPost = viewModel.trashBinPosts.last else { return }
                    Task { await viewModel.loadMoreTrashIfNeeded(currentPost: lastPost) }
                case .info:
                    break
                }
            }
        ) {
            VStack(spacing: 12) {
                profileHeader
                    .padding(.horizontal, 6)
                if shouldShowListeningNowCard {
                    profileListeningNowCard
                        .padding(.horizontal, 6)
                }
                profileDescriptionSection
                    .padding(.horizontal, 6)
                profileLinksSection
                    .padding(.horizontal, 6)
                tabRow
                    .padding(.horizontal, 6)
                tabContent
                    .padding(.horizontal, 6)
                    .padding(.bottom, profileBottomInset)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, profileTopInset())
        }
    }

    private func profileTopInset() -> CGFloat {
        let topSpacing: CGFloat
        if #available(iOS 26.0, *) {
            topSpacing = 10
        } else {
            topSpacing = 8
        }
        
        if isCurrentUserProfileContext && isRootTabProfile {
            if #available(iOS 26.0, *) {
                // Stable offset of -10.0 points to match the perfect bleed layout from the first open
                let inset: CGFloat = -10.0
#if DEBUG
                print("[PROFILE][TOP] ios26 total=\(inset) (stable)")
#endif
                return inset
            } else {
                let safeAreaTop = profileScrollSafeAreaTop > 0 ? profileScrollSafeAreaTop : Self.defaultProfileScrollSafeAreaTop()
                let profileAdjustment: CGFloat = -84
                let inset: CGFloat
                if safeAreaTop > (navigationBarHeight * 2) {
                    inset = safeAreaTop + topSpacing + profileAdjustment
                } else {
                    inset = safeAreaTop + navigationBarHeight + topSpacing + profileAdjustment
                }
#if DEBUG
                print("[PROFILE][TOP] safeTop=\(safeAreaTop) nav=\(navigationBarHeight) total=\(inset)")
#endif
                return inset
            }
        } else {
            let rawSafeAreaTop = profileScrollSafeAreaTop > 0 ? profileScrollSafeAreaTop : Self.defaultProfileScrollSafeAreaTop()
            let safeAreaTop = max(0, rawSafeAreaTop - (isMessengerProfile ? navigationBarHeight : 0))
            let inset = safeAreaTop + topSpacing
#if DEBUG
            print("[PROFILE][TOP] safeTop=\(safeAreaTop) raw=\(rawSafeAreaTop) nav=\(navigationBarHeight) total=\(inset) (other)")
#endif
            return inset
        }
    }

    private static func statusBarSafeAreaTop() -> CGFloat {
        let windowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 47
        return windowInset
    }

    private static func defaultProfileScrollSafeAreaTop() -> CGFloat {
        let windowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 24
        return windowInset + 44
    }

    private struct NavBarAppearanceSnapshot {
        let standard: UINavigationBarAppearance?
        let scrollEdge: UINavigationBarAppearance?
        let compact: UINavigationBarAppearance?
        let compactScrollEdge: UINavigationBarAppearance?
    }

    private func applyLegacyProfileNavBarAppearance() {
        guard previousNavBarAppearance == nil else { return }
        let navBar = UINavigationBar.appearance()
        previousNavBarAppearance = NavBarAppearanceSnapshot(
            standard: navBar.standardAppearance,
            scrollEdge: navBar.scrollEdgeAppearance,
            compact: navBar.compactAppearance,
            compactScrollEdge: navBar.compactScrollEdgeAppearance
        )

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = colorScheme == .dark
            ? UIColor.black.withAlphaComponent(0.88)
            : UIColor.white.withAlphaComponent(0.94)
        appearance.shadowColor = .clear

        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
        navBar.compactScrollEdgeAppearance = appearance
    }

    private func restoreLegacyNavBarAppearance() {
        guard let snapshot = previousNavBarAppearance else { return }
        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = snapshot.standard ?? UINavigationBarAppearance()
        navBar.scrollEdgeAppearance = snapshot.scrollEdge
        navBar.compactAppearance = snapshot.compact
        navBar.compactScrollEdgeAppearance = snapshot.compactScrollEdge
        previousNavBarAppearance = nil
    }

    private func openAuthorProfile(_ author: PostAuthor) {
        openProfileWithLoading(author.username)
    }

    private func openProfileByUsername(_ username: String) {
        openProfileWithLoading(username)
    }

    private func openProfileWithLoading(_ username: String?) {
        guard let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            infoMessage = "Не удалось открыть профиль"
            return
        }
        isProfileLoading = true
        let profileViewModel = ProfileViewModel()
        Task {
            await profileViewModel.load(username: trimmed, force: false)
            if case .error(let message) = profileViewModel.state, profileViewModel.profile == nil {
                infoMessage = message
                isProfileLoading = false
                return
            }
            profileRouteViewModel = profileViewModel
            profileRouteUsername = trimmed
            isProfileLoading = false
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            ProgressView(selectedLanguageCode == "en" ? "Loading..." : "Загружаем...")
                .padding(.vertical, 14)
                .padding(.horizontal, 18)
                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                )
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var profileHeader: some View {
        let coverHeight: CGFloat = 190
        let avatarSize: CGFloat = 112
        let avatarOverlap: CGFloat = avatarSize / 2
        let isVerified = viewModel.profile?.isVerified ?? false
        let hasGold = viewModel.profile?.goldStatus ?? false

        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ProfileCoverView(media: viewModel.profile?.cover)
                    .frame(maxWidth: .infinity)
                    .frame(height: coverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 1)
                    )

                PostAuthorAvatarView(
                    media: viewModel.profile?.avatar,
                    fallbackText: viewModel.profile?.name ?? viewModel.profile?.username ?? "U",
                    size: avatarSize
                )
                .clipShape(Circle())
                .contentShape(Circle())
                .overlay(
                    Circle().stroke(AppTheme.cardStroke, lineWidth: 2)
                )
                .overlay(alignment: .bottomTrailing) {
                    if profileShowsOnlineDot {
                        Circle()
                            .fill(Color(red: 0.31, green: 0.88, blue: 0.25))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(AppTheme.postCard, lineWidth: 3))
                            .offset(x: -14, y: -2)
                    }
                }
                .offset(y: avatarOverlap)
            }
            .padding(.bottom, avatarOverlap)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(viewModel.profile?.name ?? "Профиль")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.tail)
                    if isVerified || hasGold {
                        UserStatusBadges(isVerified: isVerified, hasGold: hasGold, size: 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Text("@\(viewModel.profile?.username ?? username ?? "unknown")")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .center)

                if let statusText = profileStatusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.top, 8)

            if shouldShowSubscribeButton {
                profileActionRow
                    .padding(.top, 14)
            }

            statsRow
                .padding(.top, shouldShowSubscribeButton ? 12 : 16)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .postCardStyle(cornerRadius: 16)
    }

#if DEBUG
    @discardableResult
    private static func debugLogProfileHeader(size: CGSize, insets: EdgeInsets, frame: CGRect, topInset: CGFloat) -> Bool {
        print("[PROFILE][HEADER] size=\(size) insets=\(insets) frame=\(frame) topInset=\(topInset)")
        return true
    }
#endif

    private var shouldShowSubscribeButton: Bool {
        if let profile = viewModel.profile {
            if profile.type == 1 && profile.isMyProfile {
                return true
            }
            return !profile.isMyProfile
        }
        return false
    }

    private var shouldShowProfileMenu: Bool {
        if let profile = viewModel.profile {
            return !profile.isMyProfile
        }
        return false
    }

    private var profileShowsOnlineDot: Bool {
        guard let profile = viewModel.profile else { return false }
        return profile.type != 1 && profile.isOnline
    }

    private var profileStatusText: String? {
        guard let profile = viewModel.profile, profile.type != 1 else { return nil }
        if profileShowsOnlineDot {
            return AppLang.tr("сейчас в сети", "online now", code: selectedLanguageCode)
        }
        guard let lastOnline = profile.lastOnline, !lastOnline.isEmpty else { return nil }
        return AppLang.tr("был(а) в сети", "last online", code: selectedLanguageCode) + " " + relativeDateString(lastOnline)
    }

    private var profileSubscribeButton: some View {
        let profile = viewModel.profile
        return Button {
            Task { await viewModel.toggleSubscription() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: (profile?.isSubscribed ?? false) ? "person.badge.minus" : "person.badge.plus")
                    .font(.system(size: 19, weight: .semibold))
                Text((profile?.isSubscribed ?? false)
                     ? (selectedLanguageCode == "en" ? "Unsubscribe" : "отписаться")
                     : (selectedLanguageCode == "en" ? "Subscribe" : "подписаться"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle((profile?.isSubscribed ?? false) ? AppTheme.textPrimary : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                Group {
                    if profile?.isSubscribed ?? false {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(postCardBackground)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.primary, AppTheme.primarySoft],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isUpdatingSubscription)
    }

    private var profileGiftButton: some View {
        Button {
            showingSendGiftSheet = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "gift")
                    .font(.system(size: 19, weight: .semibold))
                Text(selectedLanguageCode == "en" ? "Gift" : "подарок")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(postCardBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private var profileMuteButton: some View {
        let isMuted = viewModel.profile?.isMuted ?? false
        return Button {
            Task { await viewModel.toggleMute() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isMuted ? "bell.slash" : "bell")
                    .font(.system(size: 19, weight: .semibold))
                Text(isMuted
                     ? (selectedLanguageCode == "en" ? "Unmute" : "вкл. звук")
                     : (selectedLanguageCode == "en" ? "Mute" : "откл. звук"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(postCardBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isUpdatingMute)
    }

    private var profileMenuButton: some View {
        Menu {
            Button {
                showingSendGiftSheet = true
            } label: {
                Label("Отправить подарок", systemImage: "gift")
            }
            if let profile = viewModel.profile {
                Button {
                    let targetType: ReportTargetType = profile.type == 1 ? .channel : .user
                    reportContext = ReportContext(
                        targetType: targetType,
                        targetId: profile.id,
                        title: profile.name,
                        subtitle: "@\(profile.username)",
                        text: profile.description
                    )
                } label: {
                    Label("Пожаловаться", systemImage: "exclamationmark.bubble")
                }

                let isBlocked = profile.isBlocked
                Button(role: isBlocked ? nil : .destructive) {
                    Task { await viewModel.toggleBlock() }
                } label: {
                    Label(
                        AppLang.tr(
                            isBlocked ? "Разблокировать" : "Заблокировать",
                            isBlocked ? "Unblock" : "Block",
                            code: selectedLanguageCode
                        ),
                        systemImage: "hand.raised.fill"
                    )
                    .if(isIOS26OrNewer && !isBlocked) { view in
                        view
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.red)
                            .tint(.red)
                    }
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 19, height: 19)
                Text(selectedLanguageCode == "en" ? "More" : "ещё")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .offset(y: 2)
            }
            .foregroundStyle(AppTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(postCardBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private var editChannelButton: some View {
        Button {
            showingEditChannelSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                Text(selectedLanguageCode == "en" ? "Edit channel" : "Редактировать канал")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.primary)
            )
        }
        .buttonStyle(.plain)
    }

    private var profileActionRow: some View {
        HStack(spacing: 8) {
            if let profile = viewModel.profile, profile.type == 1 && profile.isMyProfile {
                editChannelButton
            } else {
                profileSubscribeButton
                profileMuteButton
                profileGiftButton
                profileMenuButton
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            statCard(
                value: viewModel.profile?.subscribedCount ?? 0,
                title: AppLang.tr("Подписок", "Subscriptions", code: selectedLanguageCode),
                action: { openFollowList(.subscriptions) }
            )
            statCard(
                value: viewModel.profile?.subscribersCount ?? 0,
                title: AppLang.tr("Подписчиков", "Subscribers", code: selectedLanguageCode),
                action: { openFollowList(.subscribers) }
            )
            statCard(
                value: viewModel.profile?.postsCount ?? 0,
                title: AppLang.tr("Постов", "Posts", code: selectedLanguageCode)
            )
        }
    }

    private var profileStatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            statsRow
                .animation(nil, value: viewModel.profile?.subscribedCount ?? 0)
                .animation(nil, value: viewModel.profile?.subscribersCount ?? 0)
                .animation(nil, value: viewModel.profile?.postsCount ?? 0)
            profileDescriptionCard
        }
        .padding(12)
        .postCardStyle(cornerRadius: 14)
    }

    private var shouldShowListeningNowCard: Bool {
        guard let profile = viewModel.profile else { return false }
        return profile.type != 1 && profile.listeningSong != nil
    }

    @ViewBuilder
    private var profileListeningNowCard: some View {
        if let song = viewModel.profile?.listeningSong {
            PostSongCard(
                song: song,
                footer: AppLang.tr("Сейчас слушает", "Listening now", code: selectedLanguageCode)
            )
        }
    }

    @ViewBuilder
    private var profileDescriptionCard: some View {
        let rawText = viewModel.profile?.description ?? ""
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedLanguageCode == "en" ? "description" : "описание")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)

                Text(trimmed)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .postCardStyle(cornerRadius: 14)
        }
    }

    @ViewBuilder
    private var profileDescriptionSection: some View {
        profileDescriptionCard
    }

    @ViewBuilder
    private var profileLinksSection: some View {
        let links = viewModel.profile?.links ?? []
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedLanguageCode == "en" ? "links" : "ссылки")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 2)

                FlowLayout(spacing: 8) {
                    ForEach(links) { link in
                        Button {
                            if let url = URL(string: link.url) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: profileLinkIcon(for: link.url))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.primary)
                                Text(link.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .postCardStyle(cornerRadius: 14)
        }
    }

    private func profileLinkIcon(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return "link"
        }
        if host.contains("t.me") || host.contains("telegram") { return "paperplane.fill" }
        if host.contains("youtube") || host.contains("youtu.be") { return "play.rectangle.fill" }
        if host.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if host.contains("vk.com") { return "bubble.left.and.bubble.right.fill" }
        if host.contains("tiktok") { return "music.note" }
        if host.contains("spotify") { return "music.note.list" }
        if host.contains("discord") { return "headphones" }
        if host.contains("pinterest") || host.contains("pin.it") { return "pin.fill" }
        if host.contains("elemsocial") { return "star.fill" }
        if host.contains("steam") { return "gamecontroller.fill" }
        return "link"
    }

    private func statCard(value: Int, title: String, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(AppTheme.textPrimary)
            Text(title.lowercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .if(action != nil) { view in
            Button(action: { action?() }) {
                view
            }
            .buttonStyle(.plain)
        }
    }

    private var softPanelBackground: Color {
        AppTheme.surface
    }

    private var profileTabItems: [ProfileTabItem] {
        var items: [ProfileTabItem] = [
            .init(tab: .posts, title: AppLang.tr("Посты", "Posts", code: selectedLanguageCode)),
            .init(tab: .media, title: AppLang.tr("Медиа", "Media", code: selectedLanguageCode)),
            .init(tab: .wall, title: AppLang.tr("Стена", "Wall", code: selectedLanguageCode))
        ]

        if (viewModel.profile?.giftsCount ?? 0) > 0 {
            items.append(
                .init(
                    tab: .gifts,
                    title: "\(AppLang.tr("Подарки", "Gifts", code: selectedLanguageCode)) (\(viewModel.profile?.giftsCount ?? 0))"
                )
            )
        }

        if viewModel.profile?.isMyProfile == true {
            let archiveCount = viewModel.profile?.archivePostsCount ?? 0
            if archiveCount > 0 {
                items.append(
                    .init(
                        tab: .archive,
                        title: "\(AppLang.tr("Архив", "Archive", code: selectedLanguageCode)) (\(archiveCount))"
                    )
                )
            }

            let trashCount = viewModel.profile?.trashBinPostsCount ?? 0
            if trashCount > 0 {
                items.append(
                    .init(
                        tab: .trashBin,
                        title: "\(AppLang.tr("Корзина", "Trash", code: selectedLanguageCode)) (\(trashCount))"
                    )
                )
            }
        }

        items.append(.init(tab: .info, title: AppLang.tr("Доп. инфо", "Info", code: selectedLanguageCode)))
        return items
    }

    private func relativeDateString(_ raw: String) -> String {
        guard let date = parseProfileStatusDate(raw) else { return raw }

        let now = Date()
        let seconds = Int(now.timeIntervalSince(date))
        let calendar = Calendar.current

        if seconds >= 0 && seconds <= 3600 {
            let minutes = max(1, seconds / 60)
            return selectedLanguageCode == "en" ? "\(minutes) min ago" : "\(minutes) минут назад"
        }

        if calendar.isDateInToday(date) {
            let time = Self.profileStatusTimeFormatter.string(from: date)
            return selectedLanguageCode == "en" ? "today at \(time)" : "сегодня в \(time)"
        }

        if calendar.isDateInYesterday(date) {
            let time = Self.profileStatusTimeFormatter.string(from: date)
            return selectedLanguageCode == "en" ? "yesterday at \(time)" : "вчера в \(time)"
        }

        return Self.profileStatusDateTimeFormatter.string(from: date)
    }

    private func parseProfileStatusDate(_ raw: String) -> Date? {
        if let date = parseUnixTimestampDate(raw) {
            return date
        }
        if let date = Self.profileStatusISOFormatter.date(from: raw) {
            return date
        }
        if let date = Self.profileStatusISOFormatterNoFraction.date(from: raw) {
            return date
        }
        return Self.profileStatusFallbackFormatter.date(from: raw)
    }

    private static let profileStatusFallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let profileStatusISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let profileStatusISOFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let profileStatusTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let profileStatusDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy 'в' HH:mm"
        return formatter
    }()

    private var tabRow: some View {
        Picker("", selection: Binding(
            get: { selectedTab },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.16)) {
                    selectedTab = newValue
                }
            }
        )) {
            ForEach(profileTabItems) { item in
                Text(item.title).tag(item.tab)
            }
        }
        .pickerStyle(.segmented)
    }

    private var postCardBackground: Color {
        AppTheme.surfaceElevated
    }

    private func openFollowList(_ kind: FollowListKind) {
        guard viewModel.profile != nil else { return }
        activeFollowList = kind
        Task { await viewModel.loadFollowList(kind: kind) }
    }

    private func followListSheet(kind: FollowListKind) -> some View {
        NavigationStack {
            Group {
                if viewModel.isFollowListLoading {
                    ProgressView(selectedLanguageCode == "en" ? "Loading..." : "Загружаем...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.followListError {
                    VStack(spacing: 8) {
                        Text(selectedLanguageCode == "en" ? "Loading error" : "Ошибка загрузки")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if viewModel.followListUsers.isEmpty {
                    Text(selectedLanguageCode == "en" ? "Empty" : "Пусто")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(viewModel.followListUsers.enumerated()), id: \.offset) { _, user in
                            Button {
                                activeFollowList = nil
                                openProfileWithLoading(user.username)
                            } label: {
                                HStack(spacing: 12) {
                                    PostAuthorAvatarView(
                                        media: user.avatarMedia,
                                        fallbackText: user.name ?? user.username ?? "U",
                                        size: 44
                                    )
                                    .overlay(
                                        Circle().stroke(AppTheme.cardStroke, lineWidth: 1)
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(user.name ?? "—")
                                            .font(.headline.weight(.semibold))
                                            .foregroundStyle(AppTheme.textPrimary)
                                        if let username = user.username {
                                            Text("@\(username)")
                                                .font(.footnote)
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(kind.title(for: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedLanguageCode == "en" ? "Close" : "Закрыть") {
                        activeFollowList = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.state {
        case .loading where viewModel.profile == nil:
            ProgressView("Загружаем профиль...")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        case .error(let message) where viewModel.profile == nil:
            VStack(spacing: 8) {
                Text("Ошибка загрузки")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        default:
            switch selectedTab {
            case .posts:
                ProfilePostsList(
                    posts: viewModel.posts,
                    emptyText: AppLang.tr("Постов пока нет", "No posts yet", code: selectedLanguageCode),
                    isTrashContext: false,
                    onImageTap: { images, index in
                        selectedImagePayload = makeImagePayload(images: images, startIndex: index)
                    },
                    onVideoTap: { video in
                        selectedVideo = video
                    },
                    onReactionTap: { postID, reaction in
                        Task { await viewModel.toggleReaction(postID: postID, reaction: reaction) }
                    },
                    onCommentsTap: { post in
                        selectedCommentsPost = commentSnapshot(for: post)
                    },
                    onEditTap: { postID, changes in
                        try await viewModel.editPost(postID: postID, changes: changes)
                    },
                    onDeleteTap: { postID in
                        Task { await viewModel.deletePost(postID: postID) }
                    },
                    onRestoreTap: { _ in },
                    onArchiveTap: { postID in
                        let shouldArchive = !(viewModel.posts.first(where: { $0.id == postID })?.archived ?? false)
                        Task { await viewModel.toggleArchive(postID: postID, shouldArchive: shouldArchive) }
                    },
                    onDownloadImagesTap: { post in
                        Task {
                            do {
                                let items = post.content?.images?.map {
                                    ImageSaveItem(media: $0.imgData, estimatedBytes: $0.fileSize)
                                } ?? []
                                let count = try await PhotoLibrarySaver.saveImages(from: items)
                                infoMessage = AppLang.tr(
                                    "Сохранено фото: \(count)",
                                    "Saved photos: \(count)",
                                    code: selectedLanguageCode
                                )
                            } catch {
                                infoMessage = error.localizedDescription
                            }
                        }
                    },
                    onDownloadPostFileTap: { file in
                        Task {
                            await downloadPostFile(file)
                        }
                    },
                    onAuthorTap: { author in
                        guard canOpenProfile(for: author) else { return }
                        openAuthorProfile(author)
                    },
                    onUsernameTap: { username in
                        guard canOpenProfile(username: username) else { return }
                        openProfileByUsername(username)
                    }
                )
            case .wall:
                ProfilePostsList(
                    posts: viewModel.wallPosts,
                    emptyText: AppLang.tr("Постов пока нет", "No posts yet", code: selectedLanguageCode),
                    isTrashContext: false,
                    onImageTap: { images, index in
                        selectedImagePayload = makeImagePayload(images: images, startIndex: index)
                    },
                    onVideoTap: { video in
                        selectedVideo = video
                    },
                    onReactionTap: { postID, reaction in
                        Task { await viewModel.toggleReaction(postID: postID, reaction: reaction) }
                    },
                    onCommentsTap: { post in
                        selectedCommentsPost = commentSnapshot(for: post)
                    },
                    onEditTap: { postID, changes in
                        try await viewModel.editPost(postID: postID, changes: changes)
                    },
                    onDeleteTap: { postID in
                        Task { await viewModel.deletePost(postID: postID) }
                    },
                    onRestoreTap: { _ in },
                    onArchiveTap: { postID in
                        let shouldArchive = !(viewModel.wallPosts.first(where: { $0.id == postID })?.archived ?? false)
                        Task { await viewModel.toggleArchive(postID: postID, shouldArchive: shouldArchive) }
                    },
                    onDownloadImagesTap: { post in
                        Task {
                            do {
                                let items = post.content?.images?.map {
                                    ImageSaveItem(media: $0.imgData, estimatedBytes: $0.fileSize)
                                } ?? []
                                let count = try await PhotoLibrarySaver.saveImages(from: items)
                                infoMessage = AppLang.tr(
                                    "Сохранено фото: \(count)",
                                    "Saved photos: \(count)",
                                    code: selectedLanguageCode
                                )
                            } catch {
                                infoMessage = error.localizedDescription
                            }
                        }
                    },
                    onDownloadPostFileTap: { file in
                        Task {
                            await downloadPostFile(file)
                        }
                    },
                    onAuthorTap: { author in
                        guard canOpenProfile(for: author) else { return }
                        openAuthorProfile(author)
                    },
                    onUsernameTap: { username in
                        guard canOpenProfile(username: username) else { return }
                        openProfileByUsername(username)
                    }
                )
            case .gifts:
                giftsView
            case .archive:
                ProfilePostsList(
                    posts: viewModel.archivePosts,
                    emptyText: AppLang.tr("Архив пуст", "Archive is empty", code: selectedLanguageCode),
                    isTrashContext: false,
                    onImageTap: { images, index in
                        selectedImagePayload = makeImagePayload(images: images, startIndex: index)
                    },
                    onVideoTap: { video in
                        selectedVideo = video
                    },
                    onReactionTap: { postID, reaction in
                        Task { await viewModel.toggleReaction(postID: postID, reaction: reaction) }
                    },
                    onCommentsTap: { post in
                        selectedCommentsPost = commentSnapshot(for: post)
                    },
                    onEditTap: { postID, changes in
                        try await viewModel.editPost(postID: postID, changes: changes)
                    },
                    onDeleteTap: { postID in
                        Task { await viewModel.deletePost(postID: postID) }
                    },
                    onRestoreTap: { _ in },
                    onArchiveTap: { postID in
                        Task { await viewModel.toggleArchive(postID: postID, shouldArchive: false) }
                    },
                    onDownloadImagesTap: { post in
                        Task {
                            do {
                                let items = post.content?.images?.map {
                                    ImageSaveItem(media: $0.imgData, estimatedBytes: $0.fileSize)
                                } ?? []
                                let count = try await PhotoLibrarySaver.saveImages(from: items)
                                infoMessage = AppLang.tr(
                                    "Сохранено фото: \(count)",
                                    "Saved photos: \(count)",
                                    code: selectedLanguageCode
                                )
                            } catch {
                                infoMessage = error.localizedDescription
                            }
                        }
                    },
                    onDownloadPostFileTap: { file in
                        Task {
                            await downloadPostFile(file)
                        }
                    },
                    onAuthorTap: { author in
                        guard canOpenProfile(for: author) else { return }
                        openAuthorProfile(author)
                    },
                    onUsernameTap: { username in
                        guard canOpenProfile(username: username) else { return }
                        openProfileByUsername(username)
                    }
                )
            case .trashBin:
                ProfilePostsList(
                    posts: viewModel.trashBinPosts,
                    emptyText: AppLang.tr("Корзина пуста", "Trash is empty", code: selectedLanguageCode),
                    isTrashContext: true,
                    onImageTap: { images, index in
                        selectedImagePayload = makeImagePayload(images: images, startIndex: index)
                    },
                    onVideoTap: { video in
                        selectedVideo = video
                    },
                    onReactionTap: { postID, reaction in
                        Task { await viewModel.toggleReaction(postID: postID, reaction: reaction) }
                    },
                    onCommentsTap: { post in
                        selectedCommentsPost = commentSnapshot(for: post)
                    },
                    onEditTap: { _, _ in },
                    onDeleteTap: { postID in
                        Task { await viewModel.deletePostForever(postID: postID) }
                    },
                    onRestoreTap: { postID in
                        Task { await viewModel.restorePost(postID: postID) }
                    },
                    onArchiveTap: { _ in },
                    onDownloadImagesTap: { post in
                        Task {
                            do {
                                let items = post.content?.images?.map {
                                    ImageSaveItem(media: $0.imgData, estimatedBytes: $0.fileSize)
                                } ?? []
                                let count = try await PhotoLibrarySaver.saveImages(from: items)
                                infoMessage = AppLang.tr(
                                    "Сохранено фото: \(count)",
                                    "Saved photos: \(count)",
                                    code: selectedLanguageCode
                                )
                            } catch {
                                infoMessage = error.localizedDescription
                            }
                        }
                    },
                    onDownloadPostFileTap: { file in
                        Task {
                            await downloadPostFile(file)
                        }
                    },
                    onAuthorTap: { author in
                        guard canOpenProfile(for: author) else { return }
                        openAuthorProfile(author)
                    },
                    onUsernameTap: { username in
                        guard canOpenProfile(username: username) else { return }
                        openProfileByUsername(username)
                    }
                )
            case .media:
                profileMediaGridView
            case .info:
                profileInfoView
            }
        }
    }

    @ViewBuilder
    private var profileMediaGridView: some View {
        if isMediaLoading {
            ProgressView(AppLang.tr("Загрузка...", "Loading...", code: selectedLanguageCode))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if let error = mediaError {
            VStack(spacing: 8) {
                Text(AppLang.tr("Ошибка загрузки", "Load error", code: selectedLanguageCode))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.red)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else if mediaItems.isEmpty {
            Text(AppLang.tr("Медиа нет", "No media yet", code: selectedLanguageCode))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
                    GeometryReader { geo in
                        MediaImageView(
                            media: item.image,
                            width: geo.size.width,
                            height: geo.size.width,
                            maxHeight: nil,
                            prefersLossless: false,
                            estimatedBytes: nil,
                            contentMode: .fill,
                            applyMinimumPlaceholderHeight: false
                        )
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let payloadItems = mediaItems.map { ImagePayloadItem(media: $0.image, estimatedBytes: nil) }
                        selectedImagePayload = SelectedImagePayload(items: payloadItems, startIndex: index)
                    }
                }
            }
        }
    }

    private func loadMediaIfNeeded() {
        guard let username = viewModel.profile?.username else { return }
        guard !isMediaLoading else { return }
        isMediaLoading = true
        mediaError = nil
        Task {
            do {
                let items = try await APIClient.shared.getProfileMedia(username: username)
                await MainActor.run {
                    mediaItems = items
                    isMediaLoading = false
                }
            } catch {
                await MainActor.run {
                    mediaError = error.localizedDescription
                    isMediaLoading = false
                }
            }
        }
    }

    private var giftsView: some View {
        Group {
            if viewModel.isGiftsLoading {
                ProgressView("Загружаем подарки...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if let error = viewModel.giftsError {
                VStack(spacing: 8) {
                    Text("Ошибка загрузки")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if viewModel.gifts.isEmpty {
                Text("Подарков пока нет")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(viewModel.gifts) { gift in
                        GiftCardView(gift: gift, profile: viewModel.profile)
                            .onTapGesture {
                                selectedGift = gift
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var profileInfoView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let descriptionText = profileDescriptionText {
                infoRow(title: AppLang.tr("Описание", "Description", code: selectedLanguageCode), value: descriptionText)
            }
            infoRow(
                title: AppLang.tr("Дата регистрации", "Registration date", code: selectedLanguageCode),
                value: formatRegistrationDate(viewModel.profile?.createDate)
            )
            infoRow(
                title: AppLang.tr("Был(а) в сети", "Last online", code: selectedLanguageCode),
                value: formatLastOnline(viewModel.profile?.lastOnline)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .postCardStyle(cornerRadius: 16)
    }

    private var profileDescriptionText: String? {
        let raw = viewModel.profile?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct GiftCardView: View {
        let gift: GiftItem
        let profile: APIClient.ProfileData?
        @State private var isHidden: Bool
        @State private var isUpdating = false

        init(gift: GiftItem, profile: APIClient.ProfileData?) {
            self.gift = gift
            self.profile = profile
            _isHidden = State(initialValue: gift.isHidden)
        }

        var body: some View {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 10) {
                    if let image = gift.image {
                        MediaImageView(
                            media: image,
                            width: nil,
                            height: nil,
                            maxHeight: 130,
                            prefersLossless: true,
                            estimatedBytes: nil,
                            contentMode: .fit
                        )
                        .frame(height: 120)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.surfaceElevated)
                            .frame(height: 120)
                    }

                    Text(gift.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)

                    if let sender = gift.sender {
                        HStack(spacing: 6) {
                            Text("от")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.textSecondary)
                            PostAuthorAvatarView(
                                media: sender.avatarMedia,
                                fallbackText: sender.name ?? sender.username ?? "U",
                                size: 20
                            )
                            Text(sender.name ?? sender.username ?? "—")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .postCardStyle(cornerRadius: 16)
                .opacity(isHidden ? 0.5 : 1)

                if profile?.isMyProfile == true {
                    Button {
                        toggleHidden()
                    } label: {
                        Image(systemName: isHidden ? "eye.slash" : "eye")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .padding(6)
                            .background(AppTheme.surface, in: Circle())
                            .overlay(
                                Circle().stroke(AppTheme.cardStroke, lineWidth: 1)
                            )
                    }
                    .padding(8)
                    .disabled(isUpdating)
                }
            }
        }

        private func toggleHidden() {
            guard let profile else { return }
            let nextHidden = !isHidden
            isHidden = nextHidden
            isUpdating = true
            Task {
                do {
                    try await APIClient.shared.setGiftHidden(nextHidden, giftID: gift.id, username: profile.username)
                } catch {
                    isHidden.toggle()
                }
                isUpdating = false
            }
        }
    }

    private struct GiftDetailView: View {
        let gift: GiftItem
        let profile: APIClient.ProfileData?
        let onOpenProfile: (String) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            ScrollView {
                VStack(spacing: 16) {
                    if let image = gift.image {
                        MediaImageView(
                            media: image,
                            width: nil,
                            height: nil,
                            maxHeight: 144,
                            prefersLossless: true,
                            estimatedBytes: nil,
                            contentMode: .fit
                        )
                        .frame(maxHeight: 144)
                    }

                    Text(gift.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)

                    if let description = gift.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 0) {
                        giftInfoRow(title: "От", value: senderView)
                        giftInfoRow(title: "Получатель", value: recipientView)
                        giftInfoRow(title: "Цена", value: priceView)
                        giftInfoRow(title: "Сообщение", value: Text(gift.message?.isEmpty == false ? gift.message! : "—"))
                        giftInfoRow(title: "Дата", value: Text(formatGiftDate(gift.date)))
                    }
                    .padding(12)
                    .postCardStyle(cornerRadius: 16)
                }
                .padding(16)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(gift.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }

        private var senderView: some View {
            Group {
                if let sender = gift.sender {
                    if let username = sender.username, !username.isEmpty {
                        Button {
                            onOpenProfile(username)
                        } label: {
                            HStack(spacing: 8) {
                                PostAuthorAvatarView(
                                    media: sender.avatarMedia,
                                    fallbackText: sender.name ?? sender.username ?? "U",
                                    size: 22
                                )
                                Text(sender.name ?? sender.username ?? "—")
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 8) {
                            PostAuthorAvatarView(
                                media: sender.avatarMedia,
                                fallbackText: sender.name ?? sender.username ?? "U",
                                size: 22
                            )
                            Text(sender.name ?? sender.username ?? "—")
                        }
                    }
                } else {
                    Text("—")
                }
            }
        }

        private var recipientView: some View {
            Group {
                if let profile {
                    HStack(spacing: 8) {
                        if let avatar = profile.avatar {
                            PostAuthorAvatarView(
                                media: avatar,
                                fallbackText: profile.name,
                                size: 22
                            )
                        }
                        Text(profile.name)
                    }
                } else {
                    Text("—")
                }
            }
        }

        private var priceView: some View {
            let value = gift.price ?? 0
            let formatted = String(format: "%.3f", value)
            return HStack(spacing: 6) {
                Text(formatted)
                Text("E")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(AppTheme.primary))
            }
        }

        @ViewBuilder
        private func giftInfoRow(title: String, value: some View) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 100, alignment: .leading)
                value
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }

        private func formatGiftDate(_ raw: String?) -> String {
            guard let raw else { return "—" }
            if let date = parseGiftDate(raw) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ru_RU")
                formatter.dateFormat = "HH:mm d.M.yyyy"
                return formatter.string(from: date)
            }
            return raw
        }

        private func parseGiftDate(_ raw: String) -> Date? {
            if let date = parseUnixTimestampDate(raw) {
                return date
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: raw) { return date }
            let isoShort = ISO8601DateFormatter()
            isoShort.formatOptions = [.withInternetDateTime]
            if let date = isoShort.date(from: raw) { return date }
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "ru_RU")
            fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return fallback.date(from: raw)
        }
    }

    private struct GiftSendSheet: View {
        let username: String
        @Environment(\.dismiss) private var dismiss
        @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
        @State private var gifts: [GiftItem] = []
        @State private var isLoading = false
        @State private var errorMessage: String?
        @State private var infoMessage: String?
        @State private var sendingGiftID: Int?
        @State private var eBalls: String = "0.000"
        private var isIOS26OrNewer: Bool {
            if #available(iOS 26.0, *) { return true }
            return false
        }

        var body: some View {
            NavigationStack {
                Group {
                    if isLoading {
                        ProgressView("Загружаем подарки...")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if gifts.isEmpty {
                        Text("Нет доступных подарков")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        List(gifts) { gift in
                            GiftSendRow(
                                gift: gift,
                                isSending: sendingGiftID == (gift.giftID ?? gift.id),
                                onSend: { sendGift(gift) }
                            )
                            .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                    }
                }
                .navigationTitle("Подарки")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 4) {
                            Text("E")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(
                                    Circle()
                                        .fill(AppTheme.primary)
                                        .shadow(color: AppTheme.primary.opacity(0.35), radius: 4, x: 0, y: 2)
                                )
                            Text(eBalls)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .layoutPriority(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Готово") { dismiss() }
                    }
                }
            }
            .task {
                refreshEBalls()
                await loadGifts()
            }
            .alert("Сообщение", isPresented: Binding(
                get: { infoMessage != nil || errorMessage != nil },
                set: { newValue in
                    if !newValue {
                        infoMessage = nil
                        errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {
                    infoMessage = nil
                    errorMessage = nil
                }
            } message: {
                Text(infoMessage ?? errorMessage ?? "")
            }
        }

        private func loadGifts() async {
            guard !isLoading else { return }
            isLoading = true
            errorMessage = nil
            do {
                gifts = try await APIClient.shared.loadGiftCatalog()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }

        private func refreshEBalls() {
            eBalls = APIClient.shared.currentUserEBallsSnapshot() ?? "0.000"
        }

        private func sendGift(_ gift: GiftItem) {
            let giftID = gift.giftID ?? gift.id
            guard giftID > 0 else {
                infoMessage = "Не удалось определить подарок"
                return
            }
            sendingGiftID = giftID
            Task {
                do {
                    try await APIClient.shared.sendGift(username: username, giftID: giftID)
                    refreshEBalls()
                    infoMessage = "Подарок отправлен"
                } catch {
                    errorMessage = error.localizedDescription
                }
                sendingGiftID = nil
            }
        }

        private struct GiftSendRow: View {
            let gift: GiftItem
            let isSending: Bool
            let onSend: () -> Void

            var body: some View {
                HStack(spacing: 12) {
                    if let image = gift.image {
                        MediaImageView(
                            media: image,
                            width: 52,
                            height: 52,
                            maxHeight: 52,
                            prefersLossless: true,
                            estimatedBytes: nil,
                            contentMode: .fit
                        )
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.surfaceElevated)
                            .frame(width: 52, height: 52)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(gift.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        if let price = gift.price {
                            Text(String(format: "%.3f", price))
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Text("Доступно для покупки: \(gift.quantity ?? 0)")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer()

                    Button {
                        onSend()
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "gift")
                                VStack(spacing: 0) {
                                    Text("Отправить")
                                    Text("подарок")
                                }
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: true, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSending)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func formatRegistrationDate(_ raw: String?) -> String {
        guard let raw else { return "—" }
        if let date = parseProfileDate(raw) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM yyyy 'года'"
            return formatter.string(from: date)
        }
        return raw
    }

    private func formatLastOnline(_ raw: String?) -> String {
        guard let raw else { return "—" }
        guard let date = parseProfileDate(raw) else {
            return raw
        }

        let now = Date()
        let seconds = Int(now.timeIntervalSince(date))
        let calendar = Calendar.current

        if seconds >= 0 && seconds <= 3600 {
            let minutes = max(1, seconds / 60)
            return "\(minutes) минут назад"
        }

        if calendar.isDateInToday(date) {
            return "сегодня в \(Self.profileTimeFormatter.string(from: date))"
        }

        if calendar.isDateInYesterday(date) {
            return "вчера в \(Self.profileTimeFormatter.string(from: date))"
        }

        return Self.profileDateTimeFormatter.string(from: date)
    }

    private func parseProfileDate(_ raw: String) -> Date? {
        if let date = parseUnixTimestampDate(raw) {
            return date
        }
        if let date = Self.profileISOFormatter.date(from: raw) {
            return date
        }
        if let date = Self.profileISOFormatterNoFraction.date(from: raw) {
            return date
        }
        return Self.profileDateFallbackFormatter.date(from: raw)
    }

    private static let profileDateFallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let profileISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let profileISOFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let profileTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let profileDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy 'в' HH:mm"
        return formatter
    }()

    private func commentSnapshot(for post: Post) -> Post {
        Post(
            id: post.id,
            text: post.text,
            createDate: post.createDate,
            author: post.author,
            content: nil,
            likes: post.likes,
            liked: post.liked,
            dislikes: post.dislikes,
            dislikesCount: post.dislikesCount,
            disliked: post.disliked,
            comments: post.comments,
            myPost: post.myPost
        )
    }

    private func downloadPostFile(_ file: PostFile) async {
        let candidates = attachmentPathCandidates(rawFile: file.file, preferredPaths: ["posts/files", "files"])
        for (path, filename) in candidates {
            if let url = await APIClient.shared.downloadFile(path: path, file: filename) {
                let displayName = exportFilename(for: file, fallback: filename)
                if let exportURL = prepareExportURL(from: url, filename: displayName) {
                    await MainActor.run {
                        exportPayload = FileExportPayload(url: exportURL)
                    }
                } else {
                    await MainActor.run {
                        infoMessage = "Не удалось подготовить файл"
                    }
                }
                return
            }
        }
        infoMessage = "Не удалось скачать файл"
    }

    private func exportFilename(for file: PostFile, fallback: String) -> String {
        let preferred = file.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (preferred?.isEmpty == false) ? preferred! : fallback
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        return (normalized as NSString).lastPathComponent
    }

    private func prepareExportURL(from url: URL, filename: String) -> URL? {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("ElementExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let targetURL = exportDir.appendingPathComponent(filename)
        if url == targetURL { return targetURL }
        try? FileManager.default.removeItem(at: targetURL)
        do {
            try FileManager.default.copyItem(at: url, to: targetURL)
            return targetURL
        } catch {
            return nil
        }
    }

    private func attachmentPathCandidates(rawFile: String?, preferredPaths: [String]) -> [(String, String)] {
        guard let rawFile else { return [] }
        let cleaned = rawFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        guard !cleaned.lowercased().hasPrefix("http://"), !cleaned.lowercased().hasPrefix("https://") else { return [] }

        let normalized = cleaned.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\", with: "/")
        var result: [(String, String)] = []

        for path in preferredPaths {
            result.append((path, normalized))
        }

        let ns = normalized as NSString
        if ns.pathComponents.count > 1 {
            let path = ns.deletingLastPathComponent
            let file = ns.lastPathComponent
            if !path.isEmpty, !file.isEmpty {
                result.append((path, file))
            }
        }

        var unique: [(String, String)] = []
        var seen = Set<String>()
        for (path, file) in result {
            let key = "\(path)|\(file)"
            if seen.insert(key).inserted {
                unique.append((path, file))
            }
        }
        return unique
    }
}

// (debug helpers removed)

struct ProfileRouteScreen: View {
    let username: String
    @StateObject private var viewModel = ProfileViewModel()
    @StateObject private var profileComposeContext = ProfileComposeContext()

    var body: some View {
        ProfileScreen(username: username, viewModel: viewModel)
            .environmentObject(profileComposeContext)
    }
}

@MainActor
final class ProfileViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var state: State = .idle
    @Published var profile: APIClient.ProfileData?
    @Published var posts: [Post] = []
    @Published var wallPosts: [Post] = []
    @Published var archivePosts: [Post] = []
    @Published var trashBinPosts: [Post] = []
    @Published var actionError: String?
    @Published var followListUsers: [PostAuthor] = []
    @Published var isFollowListLoading = false
    @Published var followListError: String?
    @Published var isUpdatingSubscription = false
    @Published var isUpdatingBlock = false
    @Published var isUpdatingMute = false
    @Published var isLoadingMorePosts = false
    @Published var isLoadingMoreWall = false
    @Published var isLoadingMoreArchive = false
    @Published var isLoadingMoreTrash = false
    @Published var hasMorePosts = true
    @Published var hasMoreWall = true
    @Published var hasMoreArchive = true
    @Published var hasMoreTrash = true
    @Published var gifts: [GiftItem] = []
    @Published var isGiftsLoading = false
    @Published var giftsError: String?

    private let api = APIClient.shared
    private let cacheStore = ProfileCacheStore.shared
    private let profileScreenCacheStore = ProfileScreenCacheStore.shared
    private let profileScreenCacheLimit = 5
    private var currentUsername: String?
    private let pageSize = 10
    private let loadMoreThreshold = 5
    private var postsStartIndex = 0
    private var wallStartIndex = 0
    private var archiveStartIndex = 0
    private var trashStartIndex = 0
    private var lastLoadMorePostID: Int?
    private var lastLoadMoreWallID: Int?
    private var lastLoadMoreArchiveID: Int?
    private var lastLoadMoreTrashID: Int?
    private var hasUserScrolled = false

    var loadedUsername: String? { currentUsername }

    func hydrateFromCache(username: String) {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if currentUsername != normalized {
            resetForUsername(normalized)
        }

        if let cachedScreen = profileScreenCacheStore.load(username: normalized) {
            if profile == nil {
                profile = cachedScreen.profile.asProfileData
            }
            if posts.isEmpty {
                posts = Array(cachedScreen.posts.map { $0.asPost }.prefix(profileScreenCacheLimit))
                postsStartIndex = 0
                hasMorePosts = false
            }
            if wallPosts.isEmpty {
                wallPosts = Array(cachedScreen.wall.map { $0.asPost }.prefix(profileScreenCacheLimit))
                wallStartIndex = 0
                hasMoreWall = false
            }
            if case .idle = state, profile != nil || !posts.isEmpty || !wallPosts.isEmpty {
                state = .loaded
            }
            Task {
                await primeTimelineMediaCache(posts: posts)
                await primeTimelineMediaCache(posts: wallPosts)
            }
        }

        if let cached = cacheStore.load(username: normalized) {
            profile = cached
            if case .idle = state {
                state = .loaded
            }
            Task {
                await primeProfileMediaCache(profile: cached)
            }
        }
    }

    func load(username: String?, force: Bool) async {
        guard let username = username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            state = .error("Не удалось определить username профиля")
            return
        }

        if currentUsername != username {
            resetForUsername(username)
        }

        if let cachedScreen = await profileScreenCacheStore.loadAsync(username: username) {
            if profile == nil {
                profile = cachedScreen.profile.asProfileData
            }
            if posts.isEmpty {
                posts = Array(cachedScreen.posts.map { $0.asPost }.prefix(profileScreenCacheLimit))
                postsStartIndex = 0
                hasMorePosts = false
            }
            if wallPosts.isEmpty {
                wallPosts = Array(cachedScreen.wall.map { $0.asPost }.prefix(profileScreenCacheLimit))
                wallStartIndex = 0
                hasMoreWall = false
            }
            await primeTimelineMediaCache(posts: posts)
            await primeTimelineMediaCache(posts: wallPosts)
        }

        if let cached = await cacheStore.loadAsync(username: username) {
            profile = cached
            if case .idle = state {
                state = .loaded
            }
            await primeProfileMediaCache(profile: cached)
        }

        let shouldRefreshPosts = force || posts.isEmpty
        let shouldRefreshWall = force || wallPosts.isEmpty

        if !force, currentUsername == username, state == .loaded, profile != nil, !shouldRefreshPosts, !shouldRefreshWall {
            return
        }

        if force || profile == nil {
            state = .loading
        }
        do {
            let profile = try await api.loadProfile(username: username)
            self.profile = profile
            cacheStore.save(profile: profile)
            updateProfileScreenCache(profile: profile)
            await primeProfileMediaCache(profile: profile)

            if shouldRefreshPosts {
                await loadPosts(profile: profile)
            }
            if shouldRefreshWall {
                await loadWall(profile: profile)
            }
            state = .loaded
        } catch {
            if profile != nil {
                actionError = error.localizedDescription
                state = .loaded
            } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    func loadInitialContentIfNeeded(tab: ProfileScreen.Tab) async {
        guard let profile else { return }
        switch tab {
        case .posts:
            await loadPosts(profile: profile)
        case .media:
            break  // handled directly in ProfileScreen.loadMediaIfNeeded()
        case .wall:
            await loadWall(profile: profile)
        case .gifts:
            await loadGifts(profile: profile)
        case .archive:
            await loadArchive(profile: profile)
        case .trashBin:
            await loadTrashBin(profile: profile)
        case .info:
            break
        }
    }

    func reloadContent(tab: ProfileScreen.Tab) async {
        guard let profile else { return }
        switch tab {
        case .posts:
            await loadPosts(profile: profile)
        case .media:
            break
        case .wall:
            await loadWall(profile: profile)
        case .gifts:
            await loadGifts(profile: profile)
        case .archive:
            await loadArchive(profile: profile)
        case .trashBin:
            await loadTrashBin(profile: profile)
        case .info:
            break
        }
    }

    private func loadPosts(profile: APIClient.ProfileData) async {
        postsStartIndex = 0
        hasMorePosts = true
        lastLoadMorePostID = nil
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "profile",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: 0
            )
            let initial = Array(loaded.prefix(pageSize))
            posts = initial
            postsStartIndex = initial.count
            hasMorePosts = loaded.count >= pageSize && !initial.isEmpty
            updateProfileScreenCache(profile: profile)
            await primeTimelineMediaCache(posts: Array(initial.prefix(profileScreenCacheLimit)))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func loadWall(profile: APIClient.ProfileData) async {
        wallStartIndex = 0
        hasMoreWall = true
        lastLoadMoreWallID = nil
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "wall",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: 0
            )
            let initial = Array(loaded.prefix(pageSize))
            wallPosts = initial
            wallStartIndex = initial.count
            hasMoreWall = loaded.count >= pageSize && !initial.isEmpty
            updateProfileScreenCache(profile: profile)
            await primeTimelineMediaCache(posts: Array(initial.prefix(profileScreenCacheLimit)))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func loadGifts(profile: APIClient.ProfileData) async {
        guard !isGiftsLoading else { return }
        isGiftsLoading = true
        giftsError = nil
        defer { isGiftsLoading = false }
        do {
            let loaded = try await api.loadGifts(username: profile.username)
            gifts = loaded
        } catch {
            giftsError = error.localizedDescription
        }
    }

    private func loadArchive(profile: APIClient.ProfileData) async {
        guard profile.isMyProfile else {
            archivePosts = []
            hasMoreArchive = false
            return
        }
        archiveStartIndex = 0
        hasMoreArchive = true
        lastLoadMoreArchiveID = nil
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "archive",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: 0
            )
            let initial = Array(loaded.prefix(pageSize))
            archivePosts = initial
            archiveStartIndex = initial.count
            hasMoreArchive = loaded.count >= pageSize && !initial.isEmpty
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func loadTrashBin(profile: APIClient.ProfileData) async {
        guard profile.isMyProfile else {
            trashBinPosts = []
            hasMoreTrash = false
            return
        }
        trashStartIndex = 0
        hasMoreTrash = true
        lastLoadMoreTrashID = nil
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "trash_bin",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: 0
            )
            let initial = Array(loaded.prefix(pageSize))
            trashBinPosts = initial
            trashStartIndex = initial.count
            hasMoreTrash = loaded.count >= pageSize && !initial.isEmpty
        } catch {
            actionError = error.localizedDescription
        }
    }

    func loadMorePostsIfNeeded(currentPost: Post) async {
        guard hasUserScrolled else { return }
        guard !isLoadingMorePosts, hasMorePosts, let profile else { return }
        guard let index = posts.firstIndex(where: { $0.id == currentPost.id }) else { return }
        let threshold = max(posts.count - loadMoreThreshold, 0)
        guard index >= threshold else { return }
        if lastLoadMorePostID == currentPost.id { return }
        lastLoadMorePostID = currentPost.id

        isLoadingMorePosts = true
        defer { isLoadingMorePosts = false }
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "profile",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: postsStartIndex
            )
            guard !loaded.isEmpty else {
                hasMorePosts = false
                return
            }
            let newPosts = Array(loaded.prefix(pageSize))
            let existing = Set(posts.map(\.id))
            posts.append(contentsOf: newPosts.filter { !existing.contains($0.id) })
            postsStartIndex += newPosts.count
            if newPosts.count < pageSize {
                hasMorePosts = false
            }
            updateProfileScreenCache(profile: profile)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func loadMoreWallIfNeeded(currentPost: Post) async {
        guard hasUserScrolled else { return }
        guard !isLoadingMoreWall, hasMoreWall, let profile else { return }
        guard let index = wallPosts.firstIndex(where: { $0.id == currentPost.id }) else { return }
        let threshold = max(wallPosts.count - loadMoreThreshold, 0)
        guard index >= threshold else { return }
        if lastLoadMoreWallID == currentPost.id { return }
        lastLoadMoreWallID = currentPost.id

        isLoadingMoreWall = true
        defer { isLoadingMoreWall = false }
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "wall",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: wallStartIndex
            )
            guard !loaded.isEmpty else {
                hasMoreWall = false
                return
            }
            let newPosts = Array(loaded.prefix(pageSize))
            let existing = Set(wallPosts.map(\.id))
            wallPosts.append(contentsOf: newPosts.filter { !existing.contains($0.id) })
            wallStartIndex += newPosts.count
            if newPosts.count < pageSize {
                hasMoreWall = false
            }
            updateProfileScreenCache(profile: profile)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func loadMoreArchiveIfNeeded(currentPost: Post) async {
        guard hasUserScrolled else { return }
        guard !isLoadingMoreArchive, hasMoreArchive, let profile else { return }
        guard let index = archivePosts.firstIndex(where: { $0.id == currentPost.id }) else { return }
        let threshold = max(archivePosts.count - loadMoreThreshold, 0)
        guard index >= threshold else { return }
        if lastLoadMoreArchiveID == currentPost.id { return }
        lastLoadMoreArchiveID = currentPost.id

        isLoadingMoreArchive = true
        defer { isLoadingMoreArchive = false }
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "archive",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: archiveStartIndex
            )
            guard !loaded.isEmpty else {
                hasMoreArchive = false
                return
            }
            let newPosts = Array(loaded.prefix(pageSize))
            let existing = Set(archivePosts.map(\.id))
            archivePosts.append(contentsOf: newPosts.filter { !existing.contains($0.id) })
            archiveStartIndex += newPosts.count
            if newPosts.count < pageSize {
                hasMoreArchive = false
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func loadMoreTrashIfNeeded(currentPost: Post) async {
        guard hasUserScrolled else { return }
        guard !isLoadingMoreTrash, hasMoreTrash, let profile else { return }
        guard let index = trashBinPosts.firstIndex(where: { $0.id == currentPost.id }) else { return }
        let threshold = max(trashBinPosts.count - loadMoreThreshold, 0)
        guard index >= threshold else { return }
        if lastLoadMoreTrashID == currentPost.id { return }
        lastLoadMoreTrashID = currentPost.id

        isLoadingMoreTrash = true
        defer { isLoadingMoreTrash = false }
        do {
            let loaded = try await api.loadProfilePosts(
                postsType: "trash_bin",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: trashStartIndex
            )
            guard !loaded.isEmpty else {
                hasMoreTrash = false
                return
            }
            let newPosts = Array(loaded.prefix(pageSize))
            let existing = Set(trashBinPosts.map(\.id))
            trashBinPosts.append(contentsOf: newPosts.filter { !existing.contains($0.id) })
            trashStartIndex += newPosts.count
            if newPosts.count < pageSize {
                hasMoreTrash = false
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func updateProfileScreenCache(profile: APIClient.ProfileData) {
        let cachedPosts = Array(posts.prefix(profileScreenCacheLimit))
        let cachedWall = Array(wallPosts.prefix(profileScreenCacheLimit))
        profileScreenCacheStore.save(profile: profile, posts: cachedPosts, wall: cachedWall)
    }

    private func primeProfileMediaCache(profile: APIClient.ProfileData) async {
        if let avatar = profile.avatar {
            let media = MediaData(
                file: avatar.file,
                path: avatar.path,
                preview: nil,
                simple: avatar.simple,
                aura: avatar.aura,
                storageFileID: avatar.storageFileID
            )
            _ = await api.downloadMediaImage(media, lossless: true)
        }
        if let cover = profile.cover {
            _ = await api.downloadMediaImage(cover, lossless: true)
        }
        if let listeningSongCover = profile.listeningSong?.cover {
            _ = await api.downloadMediaImage(listeningSongCover, lossless: false)
        }
    }

    private func primeTimelineMediaCache(posts: [Post]) async {
        for post in posts.prefix(profileScreenCacheLimit) {
            if let avatar = post.author.avatarMedia {
                _ = await api.downloadMediaImage(avatar, lossless: false)
            }

            if let image = post.content?.images?.first?.imgData {
                _ = await api.downloadMediaImage(image, lossless: false)
            }

            if let preview = post.content?.videos?.first?.preview?.imgData {
                _ = await api.downloadMediaImage(preview, lossless: false)
            }
        }
    }

    private func resetForUsername(_ username: String) {
        currentUsername = username
        posts = []
        wallPosts = []
        archivePosts = []
        trashBinPosts = []
        gifts = []
        giftsError = nil
        postsStartIndex = 0
        wallStartIndex = 0
        archiveStartIndex = 0
        trashStartIndex = 0
        hasMorePosts = true
        hasMoreWall = true
        hasMoreArchive = true
        hasMoreTrash = true
        lastLoadMorePostID = nil
        lastLoadMoreWallID = nil
        lastLoadMoreArchiveID = nil
        lastLoadMoreTrashID = nil
        hasUserScrolled = false
    }

    func toggleReaction(postID: Int, reaction: String) async {
        var originalPosts: Post?
        var originalWall: Post?
        var originalArchive: Post?
        var originalTrash: Post?
        var didAddReaction = false

        originalPosts = updatePost(in: &posts, postID: postID) { post in
            didAddReaction = !post.toggleReaction(reaction)
        }

        originalWall = updatePost(in: &wallPosts, postID: postID) { post in
            didAddReaction = !post.toggleReaction(reaction)
        }

        originalArchive = updatePost(in: &archivePosts, postID: postID) { post in
            didAddReaction = !post.toggleReaction(reaction)
        }

        originalTrash = updatePost(in: &trashBinPosts, postID: postID) { post in
            didAddReaction = !post.toggleReaction(reaction)
        }

        guard originalPosts != nil || originalWall != nil || originalArchive != nil || originalTrash != nil else { return }
        if didAddReaction {
            triggerLikeHaptic()
        }

        do {
            try await api.setPostReaction(postID: postID, reaction: reaction, isRemoving: !didAddReaction)
        } catch {
            if let originalPosts {
                _ = updatePost(in: &posts, postID: postID) { post in
                    post = originalPosts
                }
            }
            if let originalWall {
                _ = updatePost(in: &wallPosts, postID: postID) { post in
                    post = originalWall
                }
            }
            if let originalArchive {
                _ = updatePost(in: &archivePosts, postID: postID) { post in
                    post = originalArchive
                }
            }
            if let originalTrash {
                _ = updatePost(in: &trashBinPosts, postID: postID) { post in
                    post = originalTrash
                }
            }
            actionError = error.localizedDescription
        }
    }

    func toggleSubscription() async {
        guard let profile else { return }
        guard !isUpdatingSubscription else { return }
        isUpdatingSubscription = true
        defer { isUpdatingSubscription = false }

        do {
            try await api.toggleProfileSubscription(username: profile.username)

            let wasSubscribed = profile.isSubscribed
            let nextSubscribers = max(0, profile.subscribersCount + (wasSubscribed ? -1 : 1))
            let updated = APIClient.ProfileData(
                id: profile.id,
                type: profile.type,
                name: profile.name,
                username: profile.username,
                description: profile.description,
                avatar: profile.avatar,
                cover: profile.cover,
                listeningSong: profile.listeningSong,
                isOnline: profile.isOnline,
                postsCount: profile.postsCount,
                subscribersCount: nextSubscribers,
                subscribedCount: profile.subscribedCount,
                giftsCount: profile.giftsCount,
                archivePostsCount: profile.archivePostsCount,
                trashBinPostsCount: profile.trashBinPostsCount,
                isSubscribed: !wasSubscribed,
                isBlocked: profile.isBlocked,
                isMyProfile: profile.isMyProfile,
                createDate: profile.createDate,
                lastOnline: profile.lastOnline,
                isVerified: profile.isVerified,
                goldStatus: profile.goldStatus,
                isMuted: profile.isMuted
            )
            self.profile = updated
            cacheStore.save(profile: updated)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func toggleMute() async {
        guard let profile else { return }
        guard !isUpdatingMute else { return }
        isUpdatingMute = true
        defer { isUpdatingMute = false }

        do {
            let nextMuted = !profile.isMuted
            try await api.toggleProfileMuted(username: profile.username, mute: nextMuted)

            let updated = APIClient.ProfileData(
                id: profile.id,
                type: profile.type,
                name: profile.name,
                username: profile.username,
                description: profile.description,
                avatar: profile.avatar,
                cover: profile.cover,
                listeningSong: profile.listeningSong,
                isOnline: profile.isOnline,
                postsCount: profile.postsCount,
                subscribersCount: profile.subscribersCount,
                subscribedCount: profile.subscribedCount,
                giftsCount: profile.giftsCount,
                archivePostsCount: profile.archivePostsCount,
                trashBinPostsCount: profile.trashBinPostsCount,
                isSubscribed: profile.isSubscribed,
                isBlocked: profile.isBlocked,
                isMyProfile: profile.isMyProfile,
                createDate: profile.createDate,
                lastOnline: profile.lastOnline,
                isVerified: profile.isVerified,
                goldStatus: profile.goldStatus,
                isMuted: nextMuted
            )
            self.profile = updated
            cacheStore.save(profile: updated)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func toggleBlock() async {
        guard let profile else { return }
        guard !isUpdatingBlock else { return }
        isUpdatingBlock = true
        defer { isUpdatingBlock = false }

        let nextBlocked = !profile.isBlocked
        do {
            if nextBlocked {
                try await api.blockProfile(username: profile.username)
            } else {
                try await api.unblockProfile(username: profile.username)
            }

            let updated = APIClient.ProfileData(
                id: profile.id,
                type: profile.type,
                name: profile.name,
                username: profile.username,
                description: profile.description,
                avatar: profile.avatar,
                cover: profile.cover,
                listeningSong: profile.listeningSong,
                isOnline: profile.isOnline,
                postsCount: profile.postsCount,
                subscribersCount: profile.subscribersCount,
                subscribedCount: profile.subscribedCount,
                giftsCount: profile.giftsCount,
                archivePostsCount: profile.archivePostsCount,
                trashBinPostsCount: profile.trashBinPostsCount,
                isSubscribed: profile.isSubscribed,
                isBlocked: nextBlocked,
                isMyProfile: profile.isMyProfile,
                createDate: profile.createDate,
                lastOnline: profile.lastOnline,
                isVerified: profile.isVerified,
                goldStatus: profile.goldStatus,
                isMuted: profile.isMuted
            )
            self.profile = updated
            cacheStore.save(profile: updated)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func loadFollowList(kind: ProfileScreen.FollowListKind) async {
        guard let profile else { return }
        guard !isFollowListLoading else { return }
        isFollowListLoading = true
        followListError = nil
        followListUsers = []
        defer { isFollowListLoading = false }

        do {
            switch kind {
            case .subscribers:
                followListUsers = try await api.loadProfileSubscribers(username: profile.username)
            case .subscriptions:
                followListUsers = try await api.loadProfileSubscriptions(username: profile.username)
            }
        } catch {
            followListError = error.localizedDescription
        }
    }

    func deletePost(postID: Int) async {
        do {
            try await api.deletePost(postID: postID)
            posts.removeAll { $0.id == postID }
            wallPosts.removeAll { $0.id == postID }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func editPost(postID: Int, changes: PostContent.EditChanges) async throws {
        let trimmed = changes.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || changes.hasAttachmentChanges else {
            throw APIError.serverError("Введите текст поста")
        }

        let editedAt = ISO8601DateFormatter().string(from: Date())
        let originalPosts = updatePost(in: &posts, postID: postID) { post in
            post.text = trimmed
            post.editedAt = editedAt
        }
        let originalWall = updatePost(in: &wallPosts, postID: postID) { post in
            post.text = trimmed
            post.editedAt = editedAt
        }
        let originalArchive = updatePost(in: &archivePosts, postID: postID) { post in
            post.text = trimmed
            post.editedAt = editedAt
        }

        func mergeAttachments(_ post: inout Post, newImages: [PostImage]?, newFiles: [PostFile]?) {
            // Web mergeContentBlock: replace blocks with server result.
            var content = post.content ?? PostContent()
            if newImages != nil || changes.hasAttachmentChanges {
                content.images = newImages
            }
            if newFiles != nil || changes.hasAttachmentChanges {
                content.files = newFiles
            }
            post.content = content
        }

        do {
            let blocks = try await api.editPost(
                postID: postID,
                text: trimmed,
                newFiles: changes.newFiles,
                removedFileIDs: changes.removedFileIDs
            )
            _ = updatePost(in: &posts, postID: postID) { mergeAttachments(&$0, newImages: blocks.images, newFiles: blocks.files) }
            _ = updatePost(in: &wallPosts, postID: postID) { mergeAttachments(&$0, newImages: blocks.images, newFiles: blocks.files) }
            _ = updatePost(in: &archivePosts, postID: postID) { mergeAttachments(&$0, newImages: blocks.images, newFiles: blocks.files) }
        } catch {
            if let originalPosts {
                _ = updatePost(in: &posts, postID: postID) { post in
                    post = originalPosts
                }
            }
            if let originalWall {
                _ = updatePost(in: &wallPosts, postID: postID) { post in
                    post = originalWall
                }
            }
            if let originalArchive {
                _ = updatePost(in: &archivePosts, postID: postID) { post in
                    post = originalArchive
                }
            }
            actionError = error.localizedDescription
            throw error
        }
    }

    func toggleArchive(postID: Int, shouldArchive: Bool) async {
        let originalPosts = posts
        let originalWall = wallPosts
        let originalArchive = archivePosts
        let originalProfile = profile

        if shouldArchive {
            posts.removeAll { $0.id == postID }
            wallPosts.removeAll { $0.id == postID }
        } else {
            archivePosts.removeAll { $0.id == postID }
        }

        if let profile {
            let nextCount = max(profile.archivePostsCount + (shouldArchive ? 1 : -1), 0)
            self.profile = APIClient.ProfileData(
                id: profile.id,
                type: profile.type,
                name: profile.name,
                username: profile.username,
                description: profile.description,
                avatar: profile.avatar,
                cover: profile.cover,
                listeningSong: profile.listeningSong,
                isOnline: profile.isOnline,
                postsCount: profile.postsCount,
                subscribersCount: profile.subscribersCount,
                subscribedCount: profile.subscribedCount,
                giftsCount: profile.giftsCount,
                archivePostsCount: nextCount,
                trashBinPostsCount: profile.trashBinPostsCount,
                isSubscribed: profile.isSubscribed,
                isBlocked: profile.isBlocked,
                isMyProfile: profile.isMyProfile,
                createDate: profile.createDate,
                lastOnline: profile.lastOnline,
                isVerified: profile.isVerified,
                goldStatus: profile.goldStatus,
                isMuted: profile.isMuted
            )
        }

        do {
            try await api.toggleArchive(postID: postID, shouldArchive: shouldArchive)
        } catch {
            posts = originalPosts
            wallPosts = originalWall
            archivePosts = originalArchive
            profile = originalProfile
            actionError = error.localizedDescription
        }
    }

    func restorePost(postID: Int) async {
        do {
            try await api.restorePost(postID: postID)
            trashBinPosts.removeAll { $0.id == postID }
            if let profile, profile.trashBinPostsCount > 0 {
                self.profile = APIClient.ProfileData(
                    id: profile.id,
                    type: profile.type,
                    name: profile.name,
                    username: profile.username,
                    description: profile.description,
                    avatar: profile.avatar,
                    cover: profile.cover,
                    listeningSong: profile.listeningSong,
                    isOnline: profile.isOnline,
                    postsCount: profile.postsCount,
                    subscribersCount: profile.subscribersCount,
                    subscribedCount: profile.subscribedCount,
                    giftsCount: profile.giftsCount,
                    archivePostsCount: profile.archivePostsCount,
                    trashBinPostsCount: max(profile.trashBinPostsCount - 1, 0),
                    isSubscribed: profile.isSubscribed,
                    isBlocked: profile.isBlocked,
                    isMyProfile: profile.isMyProfile,
                    createDate: profile.createDate,
                    lastOnline: profile.lastOnline,
                    isVerified: profile.isVerified,
                    goldStatus: profile.goldStatus,
                    isMuted: profile.isMuted
                )
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func deletePostForever(postID: Int) async {
        do {
            try await api.deletePostForever(postID: postID)
            trashBinPosts.removeAll { $0.id == postID }
            if let profile, profile.trashBinPostsCount > 0 {
                self.profile = APIClient.ProfileData(
                    id: profile.id,
                    type: profile.type,
                    name: profile.name,
                    username: profile.username,
                    description: profile.description,
                    avatar: profile.avatar,
                    cover: profile.cover,
                    listeningSong: profile.listeningSong,
                    isOnline: profile.isOnline,
                    postsCount: profile.postsCount,
                    subscribersCount: profile.subscribersCount,
                    subscribedCount: profile.subscribedCount,
                    giftsCount: profile.giftsCount,
                    archivePostsCount: profile.archivePostsCount,
                    trashBinPostsCount: max(profile.trashBinPostsCount - 1, 0),
                    isSubscribed: profile.isSubscribed,
                    isBlocked: profile.isBlocked,
                    isMyProfile: profile.isMyProfile,
                    createDate: profile.createDate,
                    lastOnline: profile.lastOnline,
                    isVerified: profile.isVerified,
                    goldStatus: profile.goldStatus,
                    isMuted: profile.isMuted
                )
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func incrementCommentsCount(postID: Int) {
        _ = updatePost(in: &posts, postID: postID) { post in
            post.comments = (post.comments ?? 0) + 1
        }
        _ = updatePost(in: &wallPosts, postID: postID) { post in
            post.comments = (post.comments ?? 0) + 1
        }
    }

    func createWallPost(
        text: String,
        files: [UploadFile] = [],
        songs: [MusicSong] = [],
        poll: PostPollDraft? = nil,
        fromChannel: ChannelSummary? = nil
    ) async throws -> Int? {
        guard let profile else {
            throw APIError.serverError("Профиль не загружен")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let postID = try await api.createWallPost(
            text: trimmed,
            files: files,
            songIDs: songs.map(\.id),
            poll: poll,
            targetID: profile.id,
            targetType: profile.type,
            username: profile.username,
            fromChannelID: fromChannel?.id
        )
        return postID
    }

    func refreshWallAfterCreating(postID: Int?) async {
        await reloadWall()
        guard let postID else { return }
        if wallPosts.contains(where: { $0.id == postID }) { return }

        try? await Task.sleep(nanoseconds: 700_000_000)
        await reloadWall()
        if !wallPosts.contains(where: { $0.id == postID }) {
            await MainActor.run {
                self.actionError = "Пост отправлен, но не появился на стене. Возможно, сервер сохранил его как обычный пост."
            }
        }
    }

    func clearActionError() {
        actionError = nil
    }

    func recordUserScroll() {
        hasUserScrolled = true
    }

    func resetUserScroll() {
        hasUserScrolled = false
    }

    private func reloadWall() async {
        guard let profile else { return }
        do {
            let loadedWall = try await api.loadProfilePosts(
                postsType: "wall",
                username: profile.username,
                targetID: profile.id,
                targetType: profile.type,
                startIndex: 0
            )
            self.wallPosts = loadedWall
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func updatePost(in array: inout [Post], postID: Int, mutate: (inout Post) -> Void) -> Post? {
        guard let index = array.firstIndex(where: { $0.id == postID }) else { return nil }
        let original = array[index]
        var copy = array[index]
        mutate(&copy)
        array[index] = copy
        return original
    }
}

private struct VerticalLockScrollView<Content: View>: UIViewRepresentable {
    private let resetID: UUID?
    private let showsIndicators: Bool
    private let onRefresh: (() async -> Void)?
    private let onScroll: ((CGPoint) -> Void)?
    private let onSafeAreaTopChange: ((CGFloat) -> Void)?
    private let onReachBottom: (() -> Void)?
    private let content: Content

    init(
        resetID: UUID? = nil,
        showsIndicators: Bool = false,
        onRefresh: (() async -> Void)? = nil,
        onScroll: ((CGPoint) -> Void)? = nil,
        onSafeAreaTopChange: ((CGFloat) -> Void)? = nil,
        onReachBottom: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.resetID = resetID
        self.showsIndicators = showsIndicators
        self.onRefresh = onRefresh
        self.onScroll = onScroll
        self.onSafeAreaTopChange = onSafeAreaTopChange
        self.onReachBottom = onReachBottom
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = showsIndicators
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.backgroundColor = .clear
        // Profile handles its own top spacing; avoid extra safe-area inset that pushes the header down.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        if onRefresh != nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh), for: .valueChanged)
            scrollView.refreshControl = refreshControl
        }

        let hostingController = UIHostingController(rootView: content)
        if #available(iOS 16.0, *) {
            hostingController.sizingOptions = [.intrinsicContentSize]
        }
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear

        scrollView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        context.coordinator.hostingController = hostingController
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController?.rootView = content
        scrollView.showsVerticalScrollIndicator = showsIndicators
        context.coordinator.onRefresh = onRefresh
        context.coordinator.onScroll = onScroll
        context.coordinator.onSafeAreaTopChange = onSafeAreaTopChange
        context.coordinator.onReachBottom = onReachBottom
        if onRefresh == nil {
            scrollView.refreshControl = nil
        } else if scrollView.refreshControl == nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh), for: .valueChanged)
            scrollView.refreshControl = refreshControl
        }
        context.coordinator.hostingController?.view.invalidateIntrinsicContentSize()
        context.coordinator.hostingController?.view.setNeedsLayout()
        context.coordinator.hostingController?.view.layoutIfNeeded()
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
#if DEBUG
        print(
            "[SCROLL] contentInset=\(scrollView.contentInset) adjusted=\(scrollView.adjustedContentInset) " +
            "safeArea=\(scrollView.safeAreaInsets) offset=\(scrollView.contentOffset) size=\(scrollView.bounds.size)"
        )
#endif
        let safeAreaTop = scrollView.safeAreaInsets.top
        if context.coordinator.lastSafeAreaTop != safeAreaTop {
            context.coordinator.lastSafeAreaTop = safeAreaTop
            DispatchQueue.main.async {
                context.coordinator.onSafeAreaTopChange?(safeAreaTop)
            }
        }
        if resetID != context.coordinator.lastResetID {
            DispatchQueue.main.async {
                scrollView.setContentOffset(.zero, animated: false)
            }
            context.coordinator.lastResetID = resetID
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var hostingController: UIHostingController<Content>?
        var lastResetID: UUID?
        var onRefresh: (() async -> Void)?
        var onScroll: ((CGPoint) -> Void)?
        var onSafeAreaTopChange: ((CGFloat) -> Void)?
        var onReachBottom: (() -> Void)?
        var lastReachBottomContentHeight: CGFloat?
        var lastReachBottomTime: TimeInterval = 0
        var lastSafeAreaTop: CGFloat?

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            guard let onRefresh else {
                sender.endRefreshing()
                return
            }
            Task {
                await onRefresh()
                await MainActor.run {
                    sender.endRefreshing()
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            onScroll?(scrollView.contentOffset)
            guard let onReachBottom else { return }
            let contentHeight = scrollView.contentSize.height
            let visibleHeight = scrollView.bounds.height
            guard contentHeight > visibleHeight + 1 else { return }
            let threshold: CGFloat = 220
            let distanceFromBottom = contentHeight - (scrollView.contentOffset.y + visibleHeight)
            guard distanceFromBottom <= threshold else { return }

            let now = CACurrentMediaTime()
            if lastReachBottomContentHeight == contentHeight && (now - lastReachBottomTime) < 0.4 {
                return
            }
            lastReachBottomContentHeight = contentHeight
            lastReachBottomTime = now
            onReachBottom()
        }
    }
}

private struct ProfileCoverView: View {
    let media: MediaData?
    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    if let placeholder = UIImage(named: "ProfileCoverPattern") {
                        Image(uiImage: placeholder)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(cardBackground)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .task(id: loadKey) { await loadIfNeeded() }
    }

    private var cardBackground: Color {
        AppTheme.surface
    }

    private var loadKey: String {
        media?.imageLoadKey ?? ""
    }

    private func loadIfNeeded() async {
        guard !isLoading else { return }
        guard let media, image == nil else { return }
        isLoading = true
        defer { isLoading = false }

        if let cached = APIClient.shared.cachedMediaImageData(for: media, lossless: true),
           let loaded = UIImage(data: cached) {
            image = loaded
            return
        }

        if let data = await APIClient.shared.downloadMediaImage(media, lossless: true),
           let loaded = UIImage(data: data) {
            image = loaded
        }
    }
}


private struct ProfilePostsList: View {
    let posts: [Post]
    let emptyText: String
    let isTrashContext: Bool
    let onImageTap: ([PostImage], Int) -> Void
    let onVideoTap: (PostVideo) -> Void
    let onReactionTap: (Int, String) -> Void
    let onCommentsTap: (Post) -> Void
    let onEditTap: (Int, PostContent.EditChanges) async throws -> Void
    let onDeleteTap: (Int) -> Void
    let onRestoreTap: (Int) -> Void
    let onArchiveTap: (Int) -> Void
    let onDownloadImagesTap: (Post) -> Void
    let onDownloadPostFileTap: (PostFile) -> Void
    let onAuthorTap: (PostAuthor) -> Void
    let onUsernameTap: (String) -> Void

    var body: some View {
        LazyVStack(spacing: 8) {
            if posts.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ForEach(posts, id: \.id) { post in
                    let canDeleteChannelPost = canManageChannelPost(post.author)
                    PostRowView(
                        post: post,
                        isTrashContext: isTrashContext,
                        canManageChannelPost: canDeleteChannelPost,
                        onImageTap: onImageTap,
                        onVideoTap: onVideoTap,
                        onAuthorTap: { onAuthorTap(post.author) },
                        onUsernameTap: onUsernameTap,
                        onReactionTap: { reaction in onReactionTap(post.id, reaction) },
                        onCommentsTap: { onCommentsTap(post) },
                        onEditTap: { changes in try await onEditTap(post.id, changes) },
                        onDeleteTap: { onDeleteTap(post.id) },
                        onRestoreTap: { onRestoreTap(post.id) },
                        onArchiveTap: { onArchiveTap(post.id) },
                        onDownloadImagesTap: { onDownloadImagesTap(post) },
                        onDownloadPostFileTap: onDownloadPostFileTap
                    )
                }
            }
        }
    }

    private func canManageChannelPost(_ author: PostAuthor) -> Bool {
        guard author.type == 1, let authorID = author.id else { return false }
        let owned = APIClient.shared.currentUserChannelsSnapshot()
        return owned.contains(where: { $0.id == authorID })
    }
}

private enum NotificationsFeedCategory: String, CaseIterable {
    case all
    case reactions
    case comments
    case subscriptions
}

private enum NotificationsFeedOrder: String, CaseIterable {
    case dateDesc = "date_desc"
    case dateAsc = "date_asc"
}

struct NotificationsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let onOpenPostInFeed: (Int) -> Void
    let onOpenCommentsInFeed: (Int) -> Void
    let onOpenProfile: (String) -> Void

    @State private var selectedCategory: NotificationsFeedCategory = .all
    @State private var selectedOrder: NotificationsFeedOrder = .dateDesc
    @State private var newNotifications: [SocialNotification] = []
    @State private var readNotifications: [SocialNotification] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var didMarkViewed = false
    @State private var errorMessage: String?
    @State private var openingNotificationID: Int?
    private let cacheStore = NotificationsCacheStore.shared

    private let pageSize = 25

    private var notificationsCombined: [SocialNotification] {
        newNotifications + readNotifications
    }

    private var cacheVariant: String {
        "\(selectedCategory.rawValue)_\(selectedOrder.rawValue)"
    }

    private var isListEmpty: Bool {
        newNotifications.isEmpty && readNotifications.isEmpty
    }

    static let primaryISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let fallbackISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }()

    private func categoryLabel(_ category: NotificationsFeedCategory) -> String {
        switch category {
        case .all: return tr("Все", "All")
        case .reactions: return tr("Реакции", "Reactions")
        case .comments: return tr("Комментарии", "Comments")
        case .subscriptions: return tr("Подписки", "Subscriptions")
        }
    }

    private func orderLabel(_ order: NotificationsFeedOrder) -> String {
        switch order {
        case .dateDesc: return tr("Сначала новые", "Newest first")
        case .dateAsc: return tr("Сначала старые", "Oldest first")
        }
    }

    private var notificationsFilterBar: some View {
        let rowHeight: CGFloat = 32
        let sortButtonHeight = rowHeight - 2
        return HStack(alignment: .center, spacing: 8) {
            Picker(AppLang.tr("Раздел", "Section", code: selectedLanguageCode), selection: $selectedCategory) {
                ForEach(NotificationsFeedCategory.allCases, id: \.self) { category in
                    Text(categoryLabel(category)).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)

            Menu {
                ForEach(NotificationsFeedOrder.allCases, id: \.self) { order in
                    Button {
                        selectedOrder = order
                    } label: {
                        HStack {
                            Text(orderLabel(order))
                            if selectedOrder == order {
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.controlIcon)
                    .frame(width: sortButtonHeight, height: sortButtonHeight)
                    .background(
                        AppTheme.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func notificationListRow(_ notification: SocialNotification) -> some View {
        NotificationRowView(
            notification: notification,
            selectedLanguageCode: selectedLanguageCode,
            isOpening: openingNotificationID == notification.id,
            onOpenProfile: { username in
                onOpenProfile(username)
            }
        ) {
            Task { await handleTap(notification) }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .onAppear {
            guard notification.id == notificationsCombined.last?.id else { return }
            Task { await loadMoreIfNeeded() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            notificationsFilterBar
            Group {
                if isLoading && isListEmpty {
                    ProgressView(tr("Загружаем уведомления...", "Loading notifications..."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, isListEmpty {
                    VStack(spacing: 12) {
                        Text(tr("Ошибка загрузки", "Loading error"))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(tr("Повторить", "Retry")) {
                            Task { await reload() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isListEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bell")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(tr("Уведомлений пока нет", "No notifications yet"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !newNotifications.isEmpty {
                            Section {
                                ForEach(newNotifications) { notification in
                                    notificationListRow(notification)
                                }
                            }
                        }
                        if !readNotifications.isEmpty {
                            Section {
                                ForEach(readNotifications) { notification in
                                    notificationListRow(notification)
                                }
                            }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView(tr("Загрузка...", "Loading..."))
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .refreshable {
                        await reload()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(tr("Уведомления", "Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await refresh(resetList: false) }
        }
        .task {
            if isListEmpty {
                let cached = await cacheStore.loadAsync(username: cacheUsername, variant: cacheVariant)
                if !cached.isEmpty {
                    applyLoadedPage(cached, reset: true)
                    hasMore = cached.count >= pageSize
                } else {
                    await refresh(resetList: true)
                }
            }
        }
        .task {
            await autoRefreshLoop()
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            Task { await refresh(resetList: false) }
        }
        .onChange(of: selectedCategory) { _ in
            Task { await refresh(resetList: true) }
        }
        .onChange(of: selectedOrder) { _ in
            Task { await refresh(resetList: true) }
        }
        .alert(tr("Уведомления", "Notifications"), isPresented: Binding(
            get: { errorMessage != nil && !isListEmpty },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func reload() async {
        await refresh(resetList: isListEmpty)
    }

    @MainActor
    private func refresh(resetList: Bool) async {
        guard !isLoading, !isLoadingMore else { return }
        isLoading = true
        isLoadingMore = false
        hasMore = true
        didMarkViewed = false
        errorMessage = nil
        if resetList {
            newNotifications = []
            readNotifications = []
        }
        await loadPage(reset: true)
        isLoading = false
    }

    @MainActor
    private func loadMoreIfNeeded() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        await loadPage(reset: false)
        isLoadingMore = false
    }

    @MainActor
    private func loadPage(reset: Bool) async {
        do {
            let pageStart = reset ? 0 : notificationsCombined.count
            let loaded = try await APIClient.shared.loadNotifications(
                startIndex: pageStart,
                category: selectedCategory.rawValue,
                order: selectedOrder.rawValue
            )
            applyLoadedPage(loaded, reset: reset)
            cacheStore.save(notifications: notificationsCombined, username: cacheUsername, variant: cacheVariant)

            if loaded.count < pageSize {
                hasMore = false
            }

            let combined = notificationsCombined
            if !didMarkViewed && combined.contains(where: { !$0.viewed }) {
                do {
                    try await APIClient.shared.markNotificationsViewed()
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        return
                    }
                    errorMessage = error.localizedDescription
                }
                didMarkViewed = true
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                return
            }
            errorMessage = error.localizedDescription
            if reset {
                hasMore = false
            }
        }
    }

    private func autoRefreshLoop() async {
        while true {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                break
            }
            if Task.isCancelled {
                break
            }
            await refresh(resetList: false)
        }
    }

    private func applyLoadedPage(_ loaded: [SocialNotification], reset: Bool) {
        if reset {
            var seen = Set<Int>()
            var unread: [SocialNotification] = []
            var read: [SocialNotification] = []
            for item in loaded {
                guard seen.insert(item.id).inserted else { continue }
                if !item.viewed {
                    unread.append(item)
                } else {
                    read.append(item)
                }
            }
            newNotifications = unread
            readNotifications = read
        } else {
            var seen = Set(notificationsCombined.map(\.id))
            var unread = newNotifications
            var read = readNotifications
            for item in loaded {
                guard seen.insert(item.id).inserted else { continue }
                if !item.viewed {
                    unread.append(item)
                } else {
                    read.append(item)
                }
            }
            newNotifications = unread
            readNotifications = read
        }
    }

    @MainActor
    private func handleTap(_ notification: SocialNotification) async {
        guard let postID = notification.content.postID else {
            errorMessage = tr("Уведомление пока нельзя открыть в приложении", "This notification is not yet openable in-app")
            return
        }

        openingNotificationID = notification.id
        defer { openingNotificationID = nil }

        let action = normalizedAction(notification)
        let shouldOpenComments = action == "PostComment" || action == "ReplyComment" || notification.content.commentID != nil

        dismiss()
        if shouldOpenComments {
            onOpenCommentsInFeed(postID)
        } else {
            onOpenPostInFeed(postID)
        }
    }

    private func normalizedAction(_ notification: SocialNotification) -> String {
        if notification.action == "notification",
           let subtype = notification.content.subtype,
           !subtype.isEmpty {
            return subtype
        }
        return notification.action
    }

    private func tr(_ ru: String, _ en: String) -> String {
        AppLang.tr(ru, en, code: selectedLanguageCode)
    }

    private var cacheUsername: String {
        APIClient.shared.currentUsernameSnapshot() ?? "unknown"
    }
}

private struct NotificationRowView: View {
    let notification: SocialNotification
    let selectedLanguageCode: String
    let isOpening: Bool
    let onOpenProfile: (String) -> Void
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let authorUsername {
                Button {
                    onOpenProfile(authorUsername)
                } label: {
                    notificationAvatar
                }
                .buttonStyle(.plain)
            } else {
                notificationAvatar
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let authorUsername {
                        Button {
                            onOpenProfile(authorUsername)
                        } label: {
                            Text(rowTitle)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(rowTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if isOpening {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.secondary)
                    } else {
                        Text(relativeDateText(from: notification.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(rowBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(10)
        .postCardStyle(cornerRadius: 14)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
    }

    private var notificationAvatar: some View {
        NotificationAvatarView(author: notification.author)
            .overlay(alignment: .bottomTrailing) {
                if !notification.viewed {
                    Circle()
                        .fill(AppTheme.primary)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: 2)
                }
            }
    }

    private var authorUsername: String? {
        if let username = notification.author?.username, !username.isEmpty {
            return username
        }
        if let username = notification.content.profileUsername, !username.isEmpty {
            return username
        }
        return nil
    }

    private var normalizedAction: String {
        if notification.action == "notification", let subtype = notification.content.subtype, !subtype.isEmpty {
            return subtype
        }
        return notification.action
    }

    private var rowTitle: String {
        if let name = notification.author?.name, !name.isEmpty {
            return name
        }
        if let name = notification.content.authorName, !name.isEmpty {
            return name
        }
        return tr("Система", "System")
    }

    private var rowBody: String {
        let action = normalizedAction
        let comment = notification.content.commentText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let postText = notification.content.postText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = notification.content.messageText?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "PostLike":
            return tr("поставил(а) лайк вашему посту", "liked your post")
        case "PostDislike":
            return tr("поставил(а) дизлайк вашему посту", "disliked your post")
        case "PostComment":
            if let comment, !comment.isEmpty {
                return tr("оставил(а) комментарий: \"\(comment)\"", "commented: \"\(comment)\"")
            }
            return tr("оставил(а) комментарий", "left a comment")
        case "ReplyComment":
            if let comment, !comment.isEmpty {
                return tr("ответил(а): \"\(comment)\"", "replied: \"\(comment)\"")
            }
            return tr("ответил(а) на комментарий", "replied to your comment")
        case "ProfileSubscribe":
            return tr("подписался(ась) на ваш профиль", "subscribed to your profile")
        case "ProfileUnsubscribe":
            return tr("отписался(ась) от вашего профиля", "unsubscribed from your profile")
        case "NewPost":
            if let postText, !postText.isEmpty {
                return tr("Новый пост: \(shortPreview(postText))", "New post: \(shortPreview(postText))")
            }
            if let message, !message.isEmpty {
                return shortPreview(message)
            }
            return tr("Новый пост", "New post")
        case "NewWallPost":
            if let postText, !postText.isEmpty {
                return tr("Новый пост на стене: \(shortPreview(postText))", "New wall post: \(shortPreview(postText))")
            }
            if let message, !message.isEmpty {
                return shortPreview(message)
            }
            return tr("Новый пост на стене", "New wall post")
        case "Message":
            return message ?? tr("Новое сообщение", "New message")
        default:
            if let message, !message.isEmpty {
                return message
            }
            if let title = notification.content.title, !title.isEmpty {
                return title
            }
            return tr("Новое уведомление", "New notification")
        }
    }

    private func relativeDateText(from rawDate: String?) -> String {
        guard
            let rawDate,
            let createdAt = NotificationsView.primaryISOFormatter.date(from: rawDate)
                ?? NotificationsView.fallbackISOFormatter.date(from: rawDate)
        else {
            return rawDate ?? ""
        }

        let now = Date()
        let calendar = Calendar.current
        let seconds = Int(now.timeIntervalSince(createdAt))

        if seconds >= 0 && seconds < 60 {
            return tr("сейчас", "now")
        }
        if seconds >= 60 && seconds < 3600 {
            let minutes = max(1, seconds / 60)
            return selectedLanguageCode == "en" ? "\(minutes)m" : "\(minutes) мин"
        }
        if calendar.isDateInToday(createdAt) {
            return selectedLanguageCode == "en"
                ? "Today, \(NotificationsView.timeOnlyFormatter.string(from: createdAt))"
                : "Сегодня, \(NotificationsView.timeOnlyFormatter.string(from: createdAt))"
        }
        if calendar.isDateInYesterday(createdAt) {
            return selectedLanguageCode == "en"
                ? "Yesterday, \(NotificationsView.timeOnlyFormatter.string(from: createdAt))"
                : "Вчера, \(NotificationsView.timeOnlyFormatter.string(from: createdAt))"
        }
        return NotificationsView.fullDateFormatter.string(from: createdAt)
    }

    private func shortPreview(_ text: String, wordLimit: Int = 8) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !cleaned.isEmpty else { return text }
        if cleaned.count <= wordLimit {
            return cleaned.joined(separator: " ")
        }
        return cleaned.prefix(wordLimit).joined(separator: " ") + "..."
    }

    private func tr(_ ru: String, _ en: String) -> String {
        AppLang.tr(ru, en, code: selectedLanguageCode)
    }
}

private struct NotificationAvatarView: View {
    let author: PostAuthor?

    var body: some View {
        PostAuthorAvatarView(
            media: author?.avatarMedia,
            fallbackText: fallbackText
        )
        .frame(width: 40, height: 40)
        .background(Circle().fill(AppTheme.surfaceElevated))
        .clipShape(Circle())
    }

    private var fallbackText: String {
        let source = author?.name ?? author?.username ?? "U"
        return String(source.prefix(1)).uppercased()
    }
}

private struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 34))
            Text("Настройки")
                .font(.title3.weight(.bold))
            Text("Экран настроек (каркас)")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LogoutView: View {
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false
    @State private var isLoggingOut = false
    private let accountStore = AccountStore()

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 12) {
                PostAuthorAvatarView(
                    media: avatarMedia,
                    fallbackText: displayName,
                    size: 64
                )

                VStack(spacing: 4) {
                    Text(displayName)
                        .font(.title3.weight(.bold))
                    if let username = displayUsername {
                        Text("@\(username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let email = displayEmail {
                        Text(email)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)

            Text("Если выйдете, нужно будет заново войти в аккаунт.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            VStack(spacing: 10) {
                Button(role: .destructive) {
                    isConfirming = true
                } label: {
                    if isLoggingOut {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Выйти из аккаунта")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(width: 260)
                .disabled(isLoggingOut)

                Button("Отмена") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(width: 260)
                .disabled(isLoggingOut)
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Выйти")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Выйти из аккаунта?", isPresented: $isConfirming) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) {
                performLogout()
            }
        } message: {
            Text("Вы сможете войти снова в любое время.")
        }
    }

    private var currentAccount: AccountStore.StoredAccount? {
        accountStore.currentAccount()
    }

    private var summary: APIClient.AccountSummary {
        APIClient.shared.currentAccountSummary()
    }

    private var displayName: String {
        currentAccount?.displayName
            ?? summary.name
            ?? summary.username
            ?? summary.email
            ?? "Аккаунт"
    }

    private var displayUsername: String? {
        if let username = currentAccount?.username, !username.isEmpty {
            return username
        }
        if let username = summary.username, !username.isEmpty {
            return username
        }
        return nil
    }

    private var displayEmail: String? {
        if let email = currentAccount?.email, !email.isEmpty {
            return email
        }
        if let email = summary.email, !email.isEmpty {
            return email
        }
        return nil
    }

    private var avatarMedia: MediaData? {
        let avatar = currentAccount?.avatar ?? summary.avatar
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

    private func performLogout() {
        isLoggingOut = true
        onLogout()
    }
}

private struct SettingsSheet: View {
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) {
                        dismiss()
                        onLogout()
                    } label: {
                        Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

private struct CreatePostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var text: String
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var files: [UploadFile]
    @State private var selectedSongs: [MusicSong]
    @State private var pollDraft: PostPollDraft?
    @State private var isImportingFile = false
    @State private var isMusicPickerPresented = false
    @State private var isPollEditorPresented = false
    @Binding private var selectedChannel: ChannelSummary?
    let initialText: String
    let initialFiles: [UploadFile]
    let initialSongs: [MusicSong]
    let initialPoll: PostPollDraft?
    let availableChannels: [ChannelSummary]
    let onCreateChannel: (() -> Void)?
    let accounts: [AccountStore.StoredAccount]
    let currentAccountID: String?
    let onSelectAccount: (String) -> Void

    let onPublished: (_ text: String, _ files: [UploadFile], _ songs: [MusicSong], _ poll: PostPollDraft?, _ channel: ChannelSummary?) async throws -> Void
    private let menuTitle: (_ base: String, _ isSelected: Bool) -> String = { base, isSelected in
        isSelected ? "\(base) ✓" : base
    }

    init(
        initialText: String = "",
        initialFiles: [UploadFile] = [],
        initialSongs: [MusicSong] = [],
        initialPoll: PostPollDraft? = nil,
        availableChannels: [ChannelSummary] = [],
        selectedChannel: Binding<ChannelSummary?> = .constant(nil),
        onCreateChannel: (() -> Void)? = nil,
        accounts: [AccountStore.StoredAccount] = [],
        currentAccountID: String? = nil,
        onSelectAccount: @escaping (String) -> Void = { _ in },
        onPublished: @escaping (_ text: String, _ files: [UploadFile], _ songs: [MusicSong], _ poll: PostPollDraft?, _ channel: ChannelSummary?) async throws -> Void
    ) {
        self.initialText = initialText
        self.initialFiles = initialFiles
        self.initialSongs = initialSongs
        self.initialPoll = initialPoll
        self.availableChannels = availableChannels
        self.onCreateChannel = onCreateChannel
        self.accounts = accounts
        self.currentAccountID = currentAccountID
        self.onSelectAccount = onSelectAccount
        self.onPublished = onPublished
        _text = State(initialValue: initialText)
        _files = State(initialValue: initialFiles)
        _selectedSongs = State(initialValue: initialSongs)
        _pollDraft = State(initialValue: initialPoll)
        _selectedChannel = selectedChannel
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                VStack(spacing: 12) {
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .padding(8)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppTheme.cardStroke, lineWidth: 1)
                        )

                    HStack(spacing: 5) {
                        PhotosPicker(
                            selection: $selectedPhotoItems,
                            maxSelectionCount: 10,
                            matching: .any(of: [.images, .videos])
                        ) {
                            Image(systemName: "photo")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Circle())
                        .disabled(isPublishing)

                        Button {
                            isMusicPickerPresented = true
                        } label: {
                            Image(systemName: "music.note")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Circle())
                        .disabled(isPublishing)

                        Button {
                            isPollEditorPresented = true
                        } label: {
                            Image(systemName: "chart.bar.xaxis")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Circle())
                        .disabled(isPublishing)

                        Button {
                            isImportingFile = true
                        } label: {
                            Image(systemName: "paperclip")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Circle())
                        .disabled(isPublishing)

                        Spacer()

                        accountAndChannelMenu
                    }

                    if !selectedSongs.isEmpty {
                        attachedSongsPreview(
                            selectedSongs,
                            removeAction: { song in
                                selectedSongs.removeAll { $0.id == song.id }
                            }
                        )
                    }

                    if let pollDraft {
                        attachedPollPreview(pollDraft) {
                            self.pollDraft = nil
                        }
                    }

                    if !files.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc")
                                            .font(.caption)
                                        Text(file.name)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Button {
                                            files.remove(at: index)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(AppTheme.surface, in: Capsule())
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Новый пост")
            .navigationBarTitleDisplayMode(.inline)
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                        .disabled(isPublishing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isPublishing ? "Публикуем..." : "Опубликовать") {
                        Task { await publish() }
                    }
                    .disabled(
                        isPublishing
                        || (
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && files.isEmpty
                            && selectedSongs.isEmpty
                            && pollDraft == nil
                        )
                    )
                }
            }
        }
        .onChange(of: selectedPhotoItems.count) { _ in
            let items = selectedPhotoItems
            Task { await importPhotos(items) }
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importFiles(urls) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isMusicPickerPresented) {
            PostMusicPickerSheet(selectedSongs: $selectedSongs)
        }
        .sheet(isPresented: $isPollEditorPresented) {
            PostPollEditorSheet(initialDraft: pollDraft) { draft in
                pollDraft = draft
            }
        }
    }

    private var accountAndChannelMenu: some View {
        Menu {
            accountMenuContent
            Divider()
            channelMenuContent
            Divider()
            if let onCreateChannel {
                Button {
                    onCreateChannel()
                } label: {
                    Label(AppLang.tr("Создать канал", "Create channel", code: selectedLanguageCode), systemImage: "plus")
                }
            }
        } label: {
            Image(systemName: "person")
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
        .disabled(isPublishing || accounts.isEmpty)
    }

    @ViewBuilder
    private func attachedSongsPreview(_ songs: [MusicSong], removeAction: @escaping (MusicSong) -> Void) -> some View {
        VStack(spacing: 8) {
            ForEach(songs) { song in
                HStack(spacing: 10) {
                    MusicCoverArtworkView(media: song.cover, size: 44, cornerRadius: 12)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(song.artist)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    Spacer(minLength: 12)

                    Button {
                        removeAction(song)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func attachedPollPreview(_ poll: PostPollDraft, removeAction: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 40, height: 40)
                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Опрос · \(poll.normalizedOptions.count) вариантов")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                if !poll.normalizedQuestion.isEmpty {
                    Text("«\(poll.normalizedQuestion)»")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(poll.multipleChoice ? "Несколько вариантов ответа" : "Один вариант ответа")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                removeAction()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var accountMenuContent: some View {
        Text(AppLang.tr("Профили", "Profiles", code: selectedLanguageCode))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        ForEach(accounts) { account in
            Button {
                onSelectAccount(account.id)
                selectedChannel = nil
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                        if let username = account.username, !username.isEmpty {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if selectedChannel == nil, account.id == currentAccountID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(AppTheme.primary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var channelMenuContent: some View {
        Text(AppLang.tr("Каналы", "Channels", code: selectedLanguageCode))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        if availableChannels.isEmpty {
            Text(AppLang.key("no_channels_yet", code: selectedLanguageCode, fallback: "Вы ещё не создали ни один канал"))
                .foregroundStyle(.secondary)
        } else {
            ForEach(availableChannels.indices, id: \.self) { index in
                let channel = availableChannels[index]
                Button {
                    selectedChannel = channel
                } label: {
                    Text(menuTitle(channel.name ?? channel.username ?? "Channel", selectedChannel?.id == channel.id))
                }
            }
        }
    }

    private func publish() async {
        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }

        do {
            try await onPublished(text, files, selectedSongs, pollDraft, selectedChannel)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for (index, item) in items.enumerated() {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let name = "photo_\(Int(Date().timeIntervalSince1970))_\(index).\(ext)"
                    files.append(UploadFile(name: name, data: data))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        selectedPhotoItems = []
    }

    private func importFiles(_ urls: [URL]) async {
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent.isEmpty ? "file.bin" : url.lastPathComponent
                files.append(UploadFile(name: name, data: data))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PostMusicPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Binding var selectedSongs: [MusicSong]
    @State private var query: String = ""
    @State private var latestSongs: [MusicSong] = []
    @State private var searchResults: [MusicSong] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedInitial = false
    @State private var searchTask: Task<Void, Never>?

    private var visibleSongs: [MusicSong] {
        let base = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? latestSongs : searchResults
        var seen = Set<Int>()
        return base.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.textSecondary)

                    TextField(
                        AppLang.tr("Поиск музыки", "Search music", code: selectedLanguageCode),
                        text: $query
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if !query.isEmpty {
                        Button {
                            query = ""
                            searchResults = []
                            errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(searchFieldBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(searchFieldStroke, lineWidth: 1)
                )

                if !selectedSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLang.tr("Выбрано", "Selected", code: selectedLanguageCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedSongs) { song in
                                    HStack(spacing: 8) {
                                        MusicCoverArtworkView(media: song.cover, size: 34, cornerRadius: 10)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(song.title)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                            Text(song.artist)
                                                .font(.caption2)
                                                .lineLimit(1)
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        Button {
                                            toggleSong(song)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(searchFieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Group {
                    if isLoading && visibleSongs.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if visibleSongs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                            Text(AppLang.tr("Ничего не найдено", "Nothing found", code: selectedLanguageCode))
                                .font(.headline)
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(
                                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AppLang.tr("Здесь появятся треки для выбора.", "Tracks available for attaching will appear here.", code: selectedLanguageCode)
                                : AppLang.tr("Попробуйте другой запрос.", "Try another search query.", code: selectedLanguageCode)
                            )
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.horizontal, 20)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(visibleSongs) { song in
                                    songRow(song)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal)
            .padding(.top)
            .navigationTitle(AppLang.tr("Добавить музыку", "Add music", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLang.tr("Готово", "Done", code: selectedLanguageCode)) {
                        dismiss()
                    }
                }
            }
        }
        .task {
            guard !hasLoadedInitial else { return }
            hasLoadedInitial = true
            await loadLatestSongs()
        }
        .onChange(of: query) { newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                searchResults = []
                errorMessage = nil
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await searchSongs(query: trimmed)
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    @ViewBuilder
    private func songRow(_ song: MusicSong) -> some View {
        let isSelected = selectedSongs.contains(where: { $0.id == song.id })

        Button {
            toggleSong(song)
        } label: {
            HStack(spacing: 12) {
                MusicCoverArtworkView(media: song.cover, size: 52, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                    if let album = song.album, !album.isEmpty {
                        Text(album)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary.opacity(0.9))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.primary : AppTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(searchFieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggleSong(_ song: MusicSong) {
        if selectedSongs.contains(where: { $0.id == song.id }) {
            selectedSongs.removeAll { $0.id == song.id }
        } else {
            selectedSongs.append(song)
        }
    }

    private func loadLatestSongs() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            latestSongs = try await APIClient.shared.loadSongs(category: .latest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func searchSongs(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let results = try await APIClient.shared.search(query: query, category: .music)
            searchResults = results.songs
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var searchFieldBackground: Color {
        AppTheme.surfaceElevated
    }

    private var searchFieldStroke: Color {
        AppTheme.cardStroke
    }
}

private struct PostPollEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var question: String
    @State private var options: [String]
    @State private var isAnonymous: Bool
    @State private var isMultipleChoice: Bool
    let onSave: (PostPollDraft?) -> Void

    init(initialDraft: PostPollDraft?, onSave: @escaping (PostPollDraft?) -> Void) {
        let seedOptions = initialDraft?.options.isEmpty == false ? initialDraft?.options ?? [] : ["", ""]
        _question = State(initialValue: initialDraft?.question ?? "")
        _options = State(initialValue: Array((seedOptions + ["", ""]).prefix(max(seedOptions.count, 2))))
        _isAnonymous = State(initialValue: initialDraft?.isAnonymous ?? true)
        _isMultipleChoice = State(initialValue: initialDraft?.multipleChoice ?? false)
        self.onSave = onSave
    }

    private var validOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        validOptions.count >= 2
    }

    private var pollCardBackground: Color {
        AppTheme.postCard
    }

    private var pollCardStroke: Color {
        AppTheme.cardStroke
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLang.tr("Вопрос", "Question", code: selectedLanguageCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        TextField(
                            AppLang.tr("О чём хотите спросить? (необязательно)", "What do you want to ask? (optional)", code: selectedLanguageCode),
                            text: $question,
                            axis: .vertical
                        )
                        .lineLimit(1...3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(pollCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Варианты ответа · \(validOptions.count)/10")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        VStack(spacing: 8) {
                            ForEach(Array(options.enumerated()), id: \.offset) { index, _ in
                                HStack(spacing: 8) {
                                    TextField("Вариант \(index + 1)", text: Binding(
                                        get: { options[index] },
                                        set: { options[index] = $0 }
                                    ))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(pollCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                                    if options.count > 2 {
                                        Button {
                                            options.remove(at: index)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundStyle(AppTheme.textSecondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if options.count < 10 {
                            Button {
                                options.append("")
                            } label: {
                                Label(
                                    AppLang.tr("Добавить вариант", "Add option", code: selectedLanguageCode),
                                    systemImage: "plus"
                                )
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .background(pollCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        if !canSave {
                            Text(AppLang.tr("Нужно минимум 2 заполненных варианта", "At least 2 filled options are required", code: selectedLanguageCode))
                                .font(.footnote)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppLang.tr("Настройки", "Settings", code: selectedLanguageCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)

                        Toggle(AppLang.tr("Анонимный опрос", "Anonymous poll", code: selectedLanguageCode), isOn: $isAnonymous)
                        Toggle(AppLang.tr("Несколько вариантов ответа", "Multiple choice", code: selectedLanguageCode), isOn: $isMultipleChoice)
                    }
                    .padding(14)
                    .background(pollCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding()
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(AppLang.tr("Опрос", "Poll", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Отмена", "Cancel", code: selectedLanguageCode)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLang.tr("Сохранить", "Save", code: selectedLanguageCode)) {
                        guard canSave else { return }
                        onSave(
                            PostPollDraft(
                                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                                options: validOptions,
                                isAnonymous: isAnonymous,
                                multipleChoice: isMultipleChoice
                            )
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if canSave {
                    Button {
                        onSave(nil)
                        dismiss()
                    } label: {
                        Text(AppLang.tr("Удалить опрос", "Remove poll", code: selectedLanguageCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(.clear)
                }
            }
        }
    }
}

private struct CreateChannelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var name: String = ""
    @State private var username: String = ""
    @State private var descriptionText: String = ""
    @State private var coverItem: PhotosPickerItem?
    @State private var avatarItem: PhotosPickerItem?
    @State private var coverPreview: UIImage?
    @State private var avatarPreview: UIImage?
    @State private var coverData: Data?
    @State private var avatarData: Data?
    @State private var isLoading = false
    @State private var infoMessage: String?
    private let avatarOverlapOffset: CGFloat = 28
    let onCreated: (Bool) -> Void

    private var canSubmit: Bool {
        !isLoading
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.surface)
                            .frame(height: 140)
                            .overlay(
                                Group {
                                    if let coverPreview {
                                        Image(uiImage: coverPreview)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Image(systemName: "photo")
                                            .font(.system(size: 28, weight: .semibold))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        PhotosPicker(selection: $coverItem, matching: .images) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle")
                                Text(AppLang.tr("Обложка", "Cover", code: selectedLanguageCode))
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(AppTheme.surface.opacity(0.9), in: Capsule())
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                        ZStack {
                            if let avatarPreview {
                                Image(uiImage: avatarPreview)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        .frame(width: 70, height: 70)
                        .background(AppTheme.surface, in: Circle())
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(AppTheme.cardStroke, lineWidth: 1)
                        )
                        .offset(x: 12, y: 28)
                        .overlay {
                            PhotosPicker(selection: $avatarItem, matching: .images) {
                                Color.clear
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text("@")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AppTheme.textSecondary)
                            TextField(AppLang.tr("уникальное_имя", "unique_name", code: selectedLanguageCode), text: $username)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                        .padding(12)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        TextField(AppLang.tr("Введите название", "Enter name", code: selectedLanguageCode), text: $name)
                            .padding(12)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        TextEditor(text: $descriptionText)
                            .frame(minHeight: 120)
                            .padding(10)
                            .scrollContentBackground(.hidden)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if descriptionText.isEmpty {
                                    Text(AppLang.tr("Введите описание", "Enter description", code: selectedLanguageCode))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(.top, 16)
                                        .padding(.leading, 16)
                                }
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, avatarOverlapOffset)
                    .animation(.easeInOut(duration: 0.2), value: avatarPreview != nil)
                    .animation(.easeInOut(duration: 0.2), value: coverPreview != nil)

                    Button {
                        Task { await createChannel() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Text(AppLang.tr("Создать", "Create", code: selectedLanguageCode))
                                .font(.headline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSubmit)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle(AppLang.tr("Создать канал", "Create channel", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) {
                        dismiss()
                    }
                }
            }
            .alert(AppLang.tr("Сообщение", "Message", code: selectedLanguageCode), isPresented: Binding(
                get: { infoMessage != nil },
                set: { if !$0 { infoMessage = nil } }
            )) {
                Button("OK", role: .cancel) { infoMessage = nil }
            } message: {
                Text(infoMessage ?? "")
            }
        }
        .onChange(of: coverItem) { _ in
            Task { await loadCoverPreview() }
        }
        .onChange(of: avatarItem) { _ in
            Task { await loadAvatarPreview() }
        }
    }

    private func loadCoverPreview() async {
        guard let coverItem else { return }
        if let data = try? await coverItem.loadTransferable(type: Data.self) {
            coverData = data
            coverPreview = UIImage(data: data)
        }
    }

    private func loadAvatarPreview() async {
        guard let avatarItem else { return }
        if let data = try? await avatarItem.loadTransferable(type: Data.self) {
            avatarData = data
            avatarPreview = UIImage(data: data)
        }
    }

    @MainActor
    private func createChannel() async {
        guard canSubmit else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await APIClient.shared.createChannel(
                name: name,
                username: username,
                description: descriptionText.isEmpty ? nil : descriptionText,
                avatarData: avatarData,
                coverData: coverData
            )
            infoMessage = AppLang.tr("Канал создан", "Channel created", code: selectedLanguageCode)
            onCreated(true)
        } catch {
            infoMessage = error.localizedDescription
            onCreated(false)
        }
    }
}

private struct EditChannelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    
    let channelID: Int
    let initialName: String
    let initialUsername: String
    let initialDescription: String
    let initialAvatar: MediaData?
    let initialCover: MediaData?
    let onUpdated: () -> Void

    @State private var name: String = ""
    @State private var username: String = ""
    @State private var descriptionText: String = ""
    @State private var coverItem: PhotosPickerItem?
    @State private var avatarItem: PhotosPickerItem?
    @State private var coverPreview: UIImage?
    @State private var avatarPreview: UIImage?
    @State private var coverData: Data?
    @State private var avatarData: Data?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var infoMessage: String?
    
    @State private var originalName: String = ""
    @State private var originalUsername: String = ""
    @State private var originalDescription: String = ""

    private let avatarOverlapOffset: CGFloat = 28

    private var canSubmit: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        channelID: Int,
        initialName: String,
        initialUsername: String,
        initialDescription: String,
        initialAvatar: MediaData?,
        initialCover: MediaData?,
        onUpdated: @escaping () -> Void
    ) {
        self.channelID = channelID
        self.initialName = initialName
        self.initialUsername = initialUsername
        self.initialDescription = initialDescription
        self.initialAvatar = initialAvatar
        self.initialCover = initialCover
        self.onUpdated = onUpdated
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.surface)
                            .frame(height: 140)
                            .overlay(
                                Group {
                                    if let coverPreview {
                                        Image(uiImage: coverPreview)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Image(systemName: "photo")
                                            .font(.system(size: 28, weight: .semibold))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        PhotosPicker(selection: $coverItem, matching: .images) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle")
                                Text(AppLang.tr("Обложка", "Cover", code: selectedLanguageCode))
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(AppTheme.surface.opacity(0.9), in: Capsule())
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                        ZStack {
                            if let avatarPreview {
                                Image(uiImage: avatarPreview)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                        .frame(width: 70, height: 70)
                        .background(AppTheme.surface, in: Circle())
                        .clipShape(Circle())
                        .overlay(
                            Circle().stroke(AppTheme.cardStroke, lineWidth: 1)
                        )
                        .offset(x: 12, y: 28)
                        .overlay {
                            PhotosPicker(selection: $avatarItem, matching: .images) {
                                Color.clear
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text("@")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AppTheme.textSecondary)
                            TextField(AppLang.tr("уникальное_имя", "unique_name", code: selectedLanguageCode), text: $username)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                        .padding(12)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        TextField(AppLang.tr("Введите название", "Enter name", code: selectedLanguageCode), text: $name)
                            .padding(12)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        TextEditor(text: $descriptionText)
                            .frame(minHeight: 120)
                            .padding(10)
                            .scrollContentBackground(.hidden)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if descriptionText.isEmpty {
                                    Text(AppLang.tr("Введите описание", "Enter description", code: selectedLanguageCode))
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .padding(.top, 16)
                                        .padding(.leading, 16)
                                }
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, avatarOverlapOffset)
                    .animation(.easeInOut(duration: 0.2), value: avatarPreview != nil)
                    .animation(.easeInOut(duration: 0.2), value: coverPreview != nil)

                    Button {
                        Task { await saveChanges() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Text(AppLang.tr("Сохранить", "Save", code: selectedLanguageCode))
                                .font(.headline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSubmit)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle(AppLang.tr("Редактировать канал", "Edit channel", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) {
                        dismiss()
                    }
                }
            }
            .alert(AppLang.tr("Сообщение", "Message", code: selectedLanguageCode), isPresented: Binding(
                get: { infoMessage != nil },
                set: { if !$0 { infoMessage = nil } }
            )) {
                Button("OK", role: .cancel) { infoMessage = nil }
            } message: {
                Text(infoMessage ?? "")
            }
            .task {
                name = initialName
                username = initialUsername
                descriptionText = initialDescription
                originalName = initialName
                originalUsername = initialUsername
                originalDescription = initialDescription
                
                await loadInitialImages()
            }
            .onChange(of: coverItem) { _ in
                Task { await loadCoverPreview() }
            }
            .onChange(of: avatarItem) { _ in
                Task { await loadAvatarPreview() }
            }
        }
    }

    private func loadInitialImages() async {
        isLoading = true
        defer { isLoading = false }
        if let initialCover = initialCover {
            coverPreview = await loadRemoteImage(for: initialCover, lossless: true)
        }
        if let initialAvatar = initialAvatar {
            avatarPreview = await loadRemoteImage(for: initialAvatar, lossless: true)
        }
    }

    private func loadRemoteImage(for media: MediaData, lossless: Bool) async -> UIImage? {
        if let cached = APIClient.shared.cachedMediaImageData(for: media, lossless: lossless),
           let image = UIImage(data: cached) {
            return image
        }
        if let data = await APIClient.shared.downloadMediaImage(media, lossless: lossless),
           let image = UIImage(data: data) {
            return image
        }
        return nil
    }

    private func loadCoverPreview() async {
        guard let coverItem else { return }
        if let data = try? await coverItem.loadTransferable(type: Data.self) {
            coverData = data
            coverPreview = UIImage(data: data)
        }
    }

    private func loadAvatarPreview() async {
        guard let avatarItem else { return }
        if let data = try? await avatarItem.loadTransferable(type: Data.self) {
            avatarData = data
            avatarPreview = UIImage(data: data)
        }
    }

    @MainActor
    private func saveChanges() async {
        guard canSubmit else { return }
        isSaving = true
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if trimmedName != originalName {
                try await APIClient.shared.updateChannelName(channelID: channelID, newName: trimmedName)
                originalName = trimmedName
            }
            if trimmedUsername != originalUsername {
                try await APIClient.shared.updateChannelUsername(channelID: channelID, newUsername: trimmedUsername)
                originalUsername = trimmedUsername
            }
            if trimmedDescription != originalDescription {
                try await APIClient.shared.updateChannelDescription(channelID: channelID, newDescription: trimmedDescription)
                originalDescription = trimmedDescription
            }
            if let coverData {
                try await APIClient.shared.uploadChannelCover(channelID: channelID, data: coverData)
                self.coverData = nil
            }
            if let avatarData {
                try await APIClient.shared.uploadChannelAvatar(channelID: channelID, data: avatarData)
                self.avatarData = nil
            }

            infoMessage = AppLang.tr("Канал обновлён", "Channel updated", code: selectedLanguageCode)
            onUpdated()
            dismiss()
        } catch {
            infoMessage = error.localizedDescription
        }
    }
}

private struct MyChannelsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    let channels: [ChannelSummary]
    let onSelect: (ChannelSummary) -> Void
    let onCreate: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if channels.isEmpty {
                    Text(AppLang.key("no_channels_yet", code: selectedLanguageCode, fallback: "Вы ещё не создали ни один канал"))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(channels.indices, id: \.self) { index in
                        let channel = channels[index]
                        Button {
                            onSelect(channel)
                        } label: {
                            HStack(spacing: 10) {
                                PostAuthorAvatarView(
                                    media: channelAvatarMedia(channel),
                                    fallbackText: channel.name ?? channel.username ?? "C",
                                    size: 34
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.name ?? "Channel")
                                        .font(.headline.weight(.semibold))
                                    if let username = channel.username, !username.isEmpty {
                                        Text("@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(AppLang.key("my_channels", code: selectedLanguageCode, fallback: "Мои каналы"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLang.tr("Создать", "Create", code: selectedLanguageCode)) { onCreate() }
                }
            }
        }
    }

    private func channelAvatarMedia(_ channel: ChannelSummary) -> MediaData? {
        guard let avatar = parseChannelAvatar(raw: channel.avatar) else { return nil }
        return MediaData(
            file: avatar.file,
            path: avatar.path ?? "avatars",
            preview: nil,
            simple: avatar.simple,
            aura: avatar.aura,
            storageFileID: avatar.storageFileID
        )
    }

    private func parseChannelAvatar(raw: String?) -> PostAuthorAvatar? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PostAuthorAvatar.self, from: data) {
            return decoded
        }
        let unescaped = raw.replacingOccurrences(of: "\\\"", with: "\"")
        if let data = unescaped.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PostAuthorAvatar.self, from: data) {
            return decoded
        }
        return nil
    }
}

private struct EditPostSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var removedFileIDs: Set<Int> = []
    @State private var newFiles: [UploadFile] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var mediaItem: PhotosPickerItem?
    @State private var isFileImporterPresented = false

    private let post: Post
    private let selectedLanguageCode: String
    private let onSave: (PostContent.EditChanges) async throws -> Void

    private static let maxAttachments = 30
    private static let maxTotalBytes = 52_428_800 // web MAX_TOTAL_FILE_SIZE

    init(
        post: Post,
        selectedLanguageCode: String,
        onSave: @escaping (PostContent.EditChanges) async throws -> Void
    ) {
        self.post = post
        self.selectedLanguageCode = selectedLanguageCode
        self.onSave = onSave
        _text = State(initialValue: post.text ?? "")
    }

    private var isEnglish: Bool { selectedLanguageCode == "en" }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var existingImages: [PostImage] { post.content?.images ?? [] }
    private var existingFiles: [PostFile] { post.content?.files ?? [] }

    private var totalAttachmentCount: Int {
        existingImages.count + existingFiles.count - removedFileIDs.count + newFiles.count
    }

    private var canSave: Bool {
        let textChanged = text != (post.text ?? "")
        let hasChanges = textChanged || !removedFileIDs.isEmpty || !newFiles.isEmpty
        let hasSomething = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || totalAttachmentCount > 0
        return hasChanges && hasSomething && !isSaving
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 140)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 1)
                    )

                attachmentsStrip

                addFilesButton

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding()
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(isEnglish ? "Edit post" : "Редактировать пост")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEnglish ? "Cancel" : "Отмена") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEnglish ? "Save" : "Сохранить") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: mediaItem) { item in
                guard let item else { return }
                Task { await importPicked(item) }
                mediaItem = nil
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    importFiles(urls: urls)
                }
            }
        }
    }

    // MARK: Attachments strip (existing + new)

    private var attachmentsStrip: some View {
        Group {
            if totalAttachmentCount > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(existingImages) { img in
                            if let fid = img.imgData.storageFileID {
                                existingTile(
                                    isRemoved: removedFileIDs.contains(fid),
                                    onToggle: { toggleRemoved(fid) }
                                ) {
                                    MessengerAvatarLikeThumb(media: img.imgData)
                                }
                            }
                        }
                        ForEach(existingFiles) { file in
                            if let fid = file.serverFileID {
                                existingTile(
                                    isRemoved: removedFileIDs.contains(fid),
                                    onToggle: { toggleRemoved(fid) }
                                ) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(AppTheme.surfaceElevated)
                                        Image(systemName: "doc.fill")
                                            .foregroundStyle(AppTheme.primary)
                                    }
                                }
                            }
                        }
                        ForEach(Array(newFiles.enumerated()), id: \.offset) { index, file in
                            newFileTile(index: index, file: file)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func existingTile<Content: View>(
        isRemoved: Bool,
        onToggle: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: onToggle) {
            ZStack(alignment: .topTrailing) {
                content()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(isRemoved ? 0.3 : 1)

                Image(systemName: isRemoved ? "arrow.uturn.backward.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(isRemoved ? Color.orange : Color.white)
                    .shadow(radius: 2)
                    .offset(x: 5, y: -5)
            }
        }
        .buttonStyle(.plain)
    }

    private func newFileTile(index: Int, file: UploadFile) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let image = UIImage(data: file.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.surfaceElevated)
                        Image(systemName: "plus.doc.fill")
                            .foregroundStyle(AppTheme.primary)
                    }
                    .frame(width: 64, height: 64)
                }
            }

            Button {
                _ = withAnimation { newFiles.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .offset(x: 5, y: -5)
            }
        }
    }

    private var addFilesButton: some View {
        HStack(spacing: 10) {
            Button {
                isFileImporterPresented = true
            } label: {
                Label(
                    isEnglish ? "Add files" : "Добавить файлы",
                    systemImage: "plus.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.primary)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(totalAttachmentCount >= Self.maxAttachments)

            PhotosPicker(selection: $mediaItem, matching: .any(of: [.images, .videos])) {
                Label(
                    isEnglish ? "Photo / Video" : "Фото / Видео",
                    systemImage: "photo.on.rectangle.angled"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.primary)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(totalAttachmentCount >= Self.maxAttachments)
        }
    }

    // MARK: Actions

    private func toggleRemoved(_ id: Int) {
        if removedFileIDs.contains(id) {
            removedFileIDs.remove(id)
        } else {
            removedFileIDs.insert(id)
        }
    }

    private func importPicked(_ item: PhotosPickerItem) async {
        let types = item.supportedContentTypes
        let isVideo = types.contains { $0.conforms(to: .movie) }
        if let data = try? await item.loadTransferable(type: Data.self) {
            let (name, mime): (String, String)
            if isVideo {
                (name, mime) = ("video.mov", "video/quicktime")
            } else if let type = types.first(where: { $0.conforms(to: .image) }),
                      let ext = type.preferredFilenameExtension {
                (name, mime) = ("photo.\(ext)", type.preferredMIMEType ?? "image/jpeg")
            } else {
                (name, mime) = ("photo.jpg", "image/jpeg")
            }
            appendNewFile(name: name, mimeType: mime, data: data)
        }
    }

    private func importFiles(urls: [URL]) {
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            let mime: String
            switch ext {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "png": mime = "image/png"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            case "mp4": mime = "video/mp4"
            case "mov": mime = "video/quicktime"
            case "mp3": mime = "audio/mpeg"
            case "pdf": mime = "application/pdf"
            default: mime = "application/octet-stream"
            }
            appendNewFile(name: url.lastPathComponent, mimeType: mime, data: data)
        }
    }

    private func appendNewFile(name: String, mimeType: String, data: Data) {
        guard totalAttachmentCount < Self.maxAttachments else {
            errorMessage = isEnglish
                ? "Too many attachments (max \(Self.maxAttachments))"
                : "Слишком много вложений (максимум \(Self.maxAttachments))"
            return
        }
        let currentTotal = newFiles.reduce(0) { $0 + $1.data.count } + data.count
        guard currentTotal <= Self.maxTotalBytes else {
            errorMessage = isEnglish
                ? "Total attachment size exceeds 50 MB"
                : "Суммарный размер вложений превышает 50 МБ"
            return
        }
        errorMessage = nil
        newFiles.append(UploadFile(name: name, data: data))
        _ = mimeType
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await onSave(PostContent.EditChanges(
                text: text, // web sends the raw editor state
                newFiles: newFiles,
                removedFileIDs: Array(removedFileIDs)
            ))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Small thumbnail helper for the edit sheet (loads via existing media pipeline).
private struct MessengerAvatarLikeThumb: View {
    let media: MediaData
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            AppTheme.surfaceElevated
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .task(id: media.imageLoadKey) {
            if let data = await APIClient.shared.downloadMediaImage(media, lossless: false),
               let ui = UIImage(data: data) {
                image = ui
            }
        }
    }
}

private struct PostRowView: View {
    @AppStorage("adv_double_tap_like") private var doubleTapLike = true
    @AppStorage("adv_auto_video") private var autoVideoDownload = false
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var musicPlayerViewModel = MusicPlayerViewModel.shared
    
    let post: Post
    let isTrashContext: Bool
    let canManageChannelPost: Bool
    let onImageTap: ([PostImage], Int) -> Void
    let onVideoTap: (PostVideo) -> Void
    let onAuthorTap: () -> Void
    let onUsernameTap: (String) -> Void
    let onReactionTap: (String) -> Void
    let onCommentsTap: () -> Void
    let onEditTap: (PostContent.EditChanges) async throws -> Void
    let onDeleteTap: () -> Void
    let onRestoreTap: () -> Void
    let onArchiveTap: () -> Void
    let onDownloadImagesTap: () -> Void
    let onDownloadPostFileTap: (PostFile) -> Void
    private let maxSafeLosslessWSImageBytes = 8 * 1024 * 1024
    private static let primaryISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let fallbackISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }()
    @State private var isMenuPreviewPressed = false
    @State private var reportContext: ReportContext?
    @State private var showRestoreConfirm = false
    @State private var showDeleteForeverConfirm = false
    @State private var isTextExpanded = false
    @State private var showEditSheet = false
    @State private var songsSheetPayload: PostSongsSheetPayload?
    private var isIOS26OrNewer: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    private var isIOS17OrNewer: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }
    private var singleMediaCornerRadius: CGFloat { 14 }

    private struct PostSongsSheetPayload: Identifiable {
        let id = UUID()
        let songs: [MusicSong]
    }

    @ViewBuilder
    private func singleMediaView(
        media: MediaData?,
        maxHeight: CGFloat,
        estimatedBytes: Int? = nil,
        showPlay: Bool = false,
        allowBlurBackground: Bool = true
    ) -> some View {
        ZStack {
            if allowBlurBackground {
                MediaImageView(
                    media: media,
                    width: nil,
                    height: nil,
                    maxHeight: maxHeight,
                    prefersLossless: true,
                    estimatedBytes: estimatedBytes,
                    contentMode: .fill,
                    applyMinimumPlaceholderHeight: false
                )
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
                .clipped()
                .blur(radius: 20)
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.2 : 0.12))
            }

            MediaImageView(
                media: media,
                width: nil,
                height: nil,
                maxHeight: maxHeight,
                prefersLossless: true,
                estimatedBytes: estimatedBytes,
                contentMode: .fit,
                applyMinimumPlaceholderHeight: false
            )
            .frame(maxWidth: .infinity, maxHeight: maxHeight)

            if showPlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: singleMediaCornerRadius, style: .continuous))
    }

    private func shouldBlurBackground(for media: MediaData?) -> Bool {
        guard let size = previewSize(from: media) else { return false }
        let ratio = size.width / max(1, size.height)
        return ratio < 1.2
    }

    private func previewSize(from media: MediaData?) -> CGSize? {
        guard let preview = media?.preview else { return nil }
        let lower = preview.lowercased()
        guard lower.starts(with: "data:image"), let commaIndex = preview.firstIndex(of: ",") else {
            return nil
        }
        let base64Part = String(preview[preview.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64Part),
              let image = UIImage(data: data) else {
            return nil
        }
        return image.size
    }

    private func glassBackground(cornerRadius: CGFloat, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .light ? 0.6 : 0.12), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(colorScheme == .light ? 0.04 : 0.2), lineWidth: 1)
                    .blur(radius: 0.5)
                    .offset(y: 0.5)
            )
    }

    private func shouldCollapseText(_ text: String) -> Bool {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        if lines > 40 {
            return true
        }
            return text.count > 2000
    }

    private var songCardBackground: Color {
        colorScheme == .light ? Color(red: 244.0 / 255.0, green: 243.0 / 255.0, blue: 246.0 / 255.0) : Color.white.opacity(0.06)
    }

    private func play(song: MusicSong, queue: [MusicSong]) {
        Task {
            await musicPlayerViewModel.selectSong(song, queue: queue)
        }
    }

    private func openSongs(_ songs: [MusicSong]) {
        songsSheetPayload = PostSongsSheetPayload(songs: songs)
    }

    private func songCountLabel(_ count: Int) -> String {
        if selectedLanguageCode == "en" {
            return count == 1 ? "1 song" : "\(count) songs"
        }
        let mod10 = count % 10
        let mod100 = count % 100
        let suffix: String
        if mod10 == 1 && mod100 != 11 {
            suffix = "песня"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            suffix = "песни"
        } else {
            suffix = "песен"
        }
        return "\(count) \(suffix)"
    }

    @ViewBuilder
    private func postSongsView(_ songs: [MusicSong]) -> some View {
        if let firstSong = songs.first {
            if songs.count == 1 {
                PostSongCard(
                    song: firstSong,
                    footer: nil,
                    playQueue: songs
                )
            } else {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(songCardBackground.opacity(colorScheme == .light ? 0.7 : 0.45))
                        .frame(height: 74)
                        .offset(x: 10, y: 10)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(songCardBackground.opacity(colorScheme == .light ? 0.85 : 0.65))
                        .frame(height: 74)
                        .offset(x: 5, y: 5)

                    PostSongCard(
                        song: firstSong,
                        footer: songCountLabel(songs.count),
                        playQueue: songs,
                        onCardTap: { openSongs(songs) }
                    )
                }
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func postMenuItems() -> some View {
        Button {
            sharePost()
        } label: {
            Label(selectedLanguageCode == "en" ? "Share" : "Поделиться", systemImage: "arrowshape.turn.up.right.fill")
        }
        if let text = post.text, !text.isEmpty {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label(selectedLanguageCode == "en" ? "Copy text" : "Копировать текст", systemImage: "doc.on.doc")
            }
        }
        if post.myPost == true || canManageChannelPost {
            if isTrashContext {
                Button {
                    showRestoreConfirm = true
                } label: {
                    Label(selectedLanguageCode == "en" ? "Restore" : "Восстановить", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    showDeleteForeverConfirm = true
                } label: {
                    Label(selectedLanguageCode == "en" ? "Delete forever" : "Удалить навсегда", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .if(isIOS26OrNewer) { view in
                    view.tint(.red)
                }
            } else {
                Button {
                    showEditSheet = true
                } label: {
                    Label(selectedLanguageCode == "en" ? "Edit" : "Редактировать", systemImage: "square.and.pencil")
                }
                Button(role: .destructive) {
                    onDeleteTap()
                } label: {
                    Label(selectedLanguageCode == "en" ? "Delete" : "Удалить", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .if(isIOS26OrNewer) { view in
                    view.tint(.red)
                }
                Button {
                    onArchiveTap()
                } label: {
                    let isArchived = post.archived ?? false
                    Label(
                        selectedLanguageCode == "en"
                            ? (isArchived ? "Remove from archive" : "Archive")
                            : (isArchived ? "Убрать из архива" : "В архив"),
                        systemImage: "archivebox"
                    )
                }
            }
        }
        if let images = post.content?.images, !images.isEmpty {
            Button {
                onDownloadImagesTap()
            } label: {
                Label("Скачать фото", systemImage: "arrow.down.to.line")
            }
        }
        Button {
            reportContext = ReportContext(
                targetType: .post,
                targetId: post.id,
                title: post.author.name ?? post.author.username ?? "Unknown",
                subtitle: relativePostDateText(from: post.createDate),
                text: post.text
            )
        } label: {
            Label("Пожаловаться", systemImage: "exclamationmark.bubble")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: onAuthorTap) {
                    HStack(alignment: .top, spacing: 10) {
                        PostAuthorAvatarView(media: post.author.avatarMedia, fallbackText: post.author.name ?? post.author.username ?? "U")

                        let isVerified = post.author.isVerified ?? false
                        let hasGold = post.author.goldStatus ?? false
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                EmojiText(
                                    text: post.author.name ?? post.author.username ?? "Unknown",
                                    pointSize: 15
                                )
                                .font(.subheadline.weight(.bold))
                                .lineLimit(1)
                                if isVerified || hasGold {
                                    UserStatusBadges(isVerified: isVerified, hasGold: hasGold, size: 14)
                                }
                            }
                            Text(postDateLineText())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                Menu {
                    postMenuItems()
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(AppTheme.controlIcon)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }

            if let text = post.text, !text.isEmpty {
                let shouldCollapse = shouldCollapseText(text)
                VStack(alignment: .leading, spacing: 6) {
                    LinkifiedPostText(text: text, onUsernameTap: onUsernameTap)
                        .font(.body.weight(.medium))
                        .lineLimit(isTextExpanded ? nil : 40)

                    if shouldCollapse {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isTextExpanded.toggle()
                            }
                        } label: {
                            Text(
                                selectedLanguageCode == "en"
                                    ? (isTextExpanded ? "Show less" : "Show more...")
                                    : (isTextExpanded ? "Скрыть" : "Показать больше...")
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let poll = post.poll {
                PostPollView(postID: post.id, initialPoll: poll)
                    .padding(.top, 2)
            }

            if let images = post.content?.images, !images.isEmpty {
                if images.count == 1, let image = images.first {
                    singleMediaView(
                        media: image.imgData,
                        maxHeight: 220,
                        estimatedBytes: image.fileSize,
                        allowBlurBackground: shouldBlurBackground(for: image.imgData)
                    )
                        .contentShape(Rectangle())
                    .onTapGesture {
                        onImageTap(images, 0)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                                MediaImageView(
                                    media: image.imgData,
                                    width: nil,
                                    height: nil,
                                    maxHeight: 220,
                                    prefersLossless: true,
                                    estimatedBytes: image.fileSize,
                                    contentMode: .fit
                                )
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onImageTap(images, index)
                                }
                            }
                        }
                    }
                }
            }

            if let videos = post.content?.videos, !videos.isEmpty {
                if videos.count == 1, let video = videos.first,
                   video.file != nil || video.name != nil || video.fileName != nil || video.url != nil || video.src != nil {
                    Button {
                        onVideoTap(video)
                    } label: {
                        singleMediaView(
                            media: video.preview?.imgData,
                            maxHeight: 210,
                            showPlay: true,
                            allowBlurBackground: shouldBlurBackground(for: video.preview?.imgData)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(videos) { video in
                        if video.file != nil || video.name != nil || video.fileName != nil || video.url != nil || video.src != nil {
                            Button {
                                onVideoTap(video)
                            } label: {
                                ZStack {
                                    MediaImageView(
                                        media: video.preview?.imgData,
                                        width: nil,
                                        height: nil,
                                        maxHeight: 210,
                                        prefersLossless: true,
                                        estimatedBytes: nil,
                                        contentMode: .fit
                                    )

                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 54))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 4)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let files = post.content?.files, !files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .font(.caption)
                            Text(file.name ?? file.file ?? "Файл")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if let size = file.size {
                                Text("(\(readableSize(size)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                onDownloadPostFileTap(file)
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 4)
            }

            if let songs = post.content?.songs, !songs.isEmpty {
                let hasMediaAboveSongs = !(post.content?.images ?? []).isEmpty
                    || !(post.content?.videos ?? []).isEmpty
                postSongsView(songs)
                    .padding(.top, hasMediaAboveSongs ? -4 : 2)
            }

            HStack(alignment: .center, spacing: 8) {
                reactionGroup(commentsCount: post.comments ?? 0)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .postCardStyle(cornerRadius: 16)
        .contentShape(Rectangle())
        .contextMenu {
            postMenuItems()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard doubleTapLike else { return }
                onReactionTap("1F44D")
            }
        )
        .task(id: "\(post.id)-\(autoVideoDownload)") {
            await prefetchVideosIfNeeded()
        }
        .alert(selectedLanguageCode == "en" ? "Restore post?" : "Восстановить пост?", isPresented: $showRestoreConfirm) {
            Button(selectedLanguageCode == "en" ? "Cancel" : "Отмена", role: .cancel) {}
            Button(selectedLanguageCode == "en" ? "Restore" : "Восстановить") {
                onRestoreTap()
            }
        } message: {
            Text(selectedLanguageCode == "en"
                 ? "The post will return to your profile."
                 : "Пост вернётся в профиль.")
        }
        .alert(selectedLanguageCode == "en" ? "Delete forever?" : "Удалить навсегда?", isPresented: $showDeleteForeverConfirm) {
            Button(selectedLanguageCode == "en" ? "Cancel" : "Отмена", role: .cancel) {}
            Button(selectedLanguageCode == "en" ? "Delete forever" : "Удалить навсегда", role: .destructive) {
                onDeleteTap()
            }
        } message: {
            Text(selectedLanguageCode == "en"
                 ? "You won't be able to restore this post."
                 : "Пост нельзя будет восстановить.")
        }
        .sheet(item: $reportContext) { context in
            ReportSheet(context: context)
        }
        .sheet(isPresented: $showEditSheet) {
            EditPostSheet(
                post: post,
                selectedLanguageCode: selectedLanguageCode,
                onSave: { changes in
                    try await onEditTap(changes)
                }
            )
        }
        .sheet(item: $songsSheetPayload) { payload in
            PostSongsSheet(
                songs: payload.songs,
                selectedLanguageCode: selectedLanguageCode,
                currentSongID: musicPlayerViewModel.selectedSong?.id,
                isPlaying: musicPlayerViewModel.isPlaying,
                onSelectSong: { song in
                    play(song: song, queue: payload.songs)
                    songsSheetPayload = nil
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func postDateLineText() -> String {
        let base = relativePostDateText(from: post.createDate)
        guard post.editedAt != nil else { return base }
        return selectedLanguageCode == "en" ? "\(base) · edited" : "\(base) · изменено"
    }

    private func relativePostDateText(from rawDate: String?) -> String {
        guard
            let rawDate,
            let createdAt = Self.primaryISOFormatter.date(from: rawDate) ?? Self.fallbackISOFormatter.date(from: rawDate)
        else {
            return rawDate ?? ""
        }

        let now = Date()
        let calendar = Calendar.current
        let seconds = Int(now.timeIntervalSince(createdAt))

        if seconds >= 0 && seconds < 60 {
            return selectedLanguageCode == "en" ? "just now" : "только что"
        }
        if seconds >= 60 && seconds < 3600 {
            let minutes = max(1, seconds / 60)
            return selectedLanguageCode == "en" ? "\(minutes)m ago" : "\(minutes) мин назад"
        }
        if seconds >= 3600 && seconds < 7200 {
            return selectedLanguageCode == "en" ? "1h ago" : "час назад"
        }

        if calendar.isDateInToday(createdAt) {
            return selectedLanguageCode == "en"
                ? "Today, \(Self.timeOnlyFormatter.string(from: createdAt))"
                : "Сегодня, \(Self.timeOnlyFormatter.string(from: createdAt))"
        }
        if calendar.isDateInYesterday(createdAt) {
            return selectedLanguageCode == "en"
                ? "Yesterday, \(Self.timeOnlyFormatter.string(from: createdAt))"
                : "Вчера, \(Self.timeOnlyFormatter.string(from: createdAt))"
        }

        return Self.fullDateFormatter.string(from: createdAt)
    }

    private static let quickReactionItems: [(code: String, emoji: String, titleRu: String, titleEn: String)] = [
        ("2764-FE0F", "❤️", "Сердце", "Love"),
        ("1F44D", "👍", "Нравится", "Like"),
        ("1F44E", "👎", "Дизлайк", "Dislike"),
        ("1F525", "🔥", "Огонь", "Fire"),
        ("1F602", "😂", "Смешно", "Laugh"),
        ("1F921", "🤡", "Клоун", "Clown"),
        ("1F622", "😢", "Грустно", "Sad"),
        ("1F60D", "😍", "Вау", "Cute"),
        ("270B", "✋", "Привет", "Hand"),
        ("1F389", "🎉", "Праздник", "Party"),
        ("1F440", "👀", "Глаза", "Eyes")
    ]

    private func reactionGroup(commentsCount: Int) -> some View {
        let background = AppTheme.surfaceElevated
        let foreground = AppTheme.controlIcon
        let activeBackground = AppTheme.primary
        let reactions = post.displayReactions
        let activeReaction = reactions.activeReaction?.uppercased()
        let sortedReactions = reactions.results
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }

        return HStack(spacing: 6) {
            Menu {
                ForEach(Self.quickReactionItems, id: \.code) { item in
                    Button {
                        onReactionTap(item.code)
                    } label: {
                        Label {
                            Text(selectedLanguageCode == "en" ? item.titleEn : item.titleRu)
                        } icon: {
                            Image("emoji_\(item.code.lowercased())")
                        }
                    }
                }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 36, height: 32)
                    .background(glassBackground(cornerRadius: 16, fill: background.opacity(1.0)))
            }
            .buttonStyle(.plain)

            ForEach(sortedReactions, id: \.key) { reaction, count in
                reactionChip(
                    reaction: reaction,
                    count: count,
                    isActive: activeReaction == reaction.uppercased(),
                    foreground: foreground,
                    activeBackground: activeBackground,
                    background: background
                )
            }

            segmentDivider
            reactionSegment(
                icon: "Comment",
                count: commentsCount,
                isActive: false,
                foreground: foreground,
                activeBackground: activeBackground,
                background: background,
                action: onCommentsTap
            )
        }
        .frame(height: 32)
    }

    private func reactionChip(
        reaction: String,
        count: Int,
        isActive: Bool,
        foreground: Color,
        activeBackground: Color,
        background: Color
    ) -> some View {
        let normalizedCode = reaction.lowercased()
        return Button {
            onReactionTap(reaction)
        } label: {
            HStack(spacing: 5) {
                Image("emoji_\(normalizedCode)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text("\(count)")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(isActive ? Color.white : foreground)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(glassBackground(cornerRadius: 16, fill: isActive ? activeBackground : background.opacity(1.0)))
        }
        .buttonStyle(.plain)
    }

    private func emojiLiteral(for reaction: String) -> String {
        let code = reaction.uppercased()
        if let found = Self.quickReactionItems.first(where: { $0.code.uppercased() == code }) {
            return found.emoji
        }
        let scalars = reaction
            .split(separator: "-")
            .compactMap { UInt32($0, radix: 16) }
            .compactMap(UnicodeScalar.init)
        guard !scalars.isEmpty else { return "❤️" }
        return String(String.UnicodeScalarView(scalars))
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.1))
            .frame(width: 1)
    }

    private func reactionSegment(
        icon: String,
        count: Int,
        isActive: Bool,
        foreground: Color,
        activeBackground: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                if count > 0 {
                    Text("\(count)")
                        .font(.footnote.weight(.semibold))
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isActive ? Color.white : foreground)
            .frame(minWidth: 36)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: 32)
            .background(glassBackground(cornerRadius: 16, fill: isActive ? activeBackground : background.opacity(1.0)))
        }
        .buttonStyle(.plain)
    }

    private func sharePost() {
        UIPasteboard.general.string = "https://elemsocial.com/post/\(post.id)"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func prefetchVideosIfNeeded() async {
        guard autoVideoDownload else { return }
        guard let videos = post.content?.videos, !videos.isEmpty else { return }
        for video in videos {
            if let fileID = video.fileId {
                _ = try? await APIClient.shared.downloadStorageVideoFile(
                    fileID: fileID,
                    fileName: video.fileName ?? video.file ?? video.name
                )
            } else {
                let fileCandidates = [video.file, video.name, video.fileName, video.url, video.src]
                guard let file = fileCandidates.compactMap({ $0 }).first else { continue }
                _ = await APIClient.shared.downloadFile(path: "posts/videos", file: file)
            }
        }
    }

    private func readableSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

private actor PostSongDetailsResolver {
    static let shared = PostSongDetailsResolver()

    private var resolvedSongs: [Int: MusicSong] = [:]
    private var missingSongIDs: Set<Int> = []
    private var inFlight: [Int: Task<MusicSong?, Never>] = [:]

    func song(for song: MusicSong) async -> MusicSong? {
        if song.title != "Unknown" && song.artist != "Unknown" && song.cover != nil {
            resolvedSongs[song.id] = song
            return song
        }

        if let cached = resolvedSongs[song.id] {
            return cached
        }
        if missingSongIDs.contains(song.id) {
            return nil
        }
        if let task = inFlight[song.id] {
            return await task.value
        }

        let task = Task<MusicSong?, Never> {
            do {
                let fullSong = try await APIClient.shared.loadSong(songID: song.id)
                return fullSong
            } catch {
                return nil
            }
        }
        inFlight[song.id] = task

        let resolved = await task.value
        inFlight[song.id] = nil

        if let resolved {
            resolvedSongs[song.id] = resolved
        } else {
            missingSongIDs.insert(song.id)
        }
        return resolved
    }
}

private struct CustomMiniSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let usesArtworkBackground: Bool
    let onSeek: (Double) -> Void
    let onDragChange: (Double?) -> Void

    var body: some View {
        GeometryReader { geo in
            let progress = max(0, min(1.0, value / max(range.upperBound, 0.1)))
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(usesArtworkBackground ? Color.white.opacity(0.24) : AppTheme.textSecondary.opacity(0.18))
                    .frame(height: 4)

                // Fill track
                Capsule()
                    .fill(usesArtworkBackground ? Color.white.opacity(0.92) : AppTheme.primary)
                    .frame(width: geo.size.width * CGFloat(progress), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let location = gesture.location.x
                        let percent = max(0, min(1.0, location / geo.size.width))
                        let targetValue = range.lowerBound + percent * (range.upperBound - range.lowerBound)
                        onDragChange(targetValue)
                    }
                    .onEnded { gesture in
                        let location = gesture.location.x
                        let percent = max(0, min(1.0, location / geo.size.width))
                        let targetValue = range.lowerBound + percent * (range.upperBound - range.lowerBound)
                        onDragChange(nil)
                        onSeek(targetValue)
                    }
            )
        }
    }
}

private struct PostSongCard: View {
    let song: MusicSong
    let footer: String?
    var isInteractive: Bool = true
    var playQueue: [MusicSong]? = nil
    var onCardTap: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var resolvedSong: MusicSong?
    @State private var scrubbingTime: Double? = nil
    @ObservedObject private var playerViewModel = MusicPlayerViewModel.shared
    @ObservedObject private var playbackProgress = MusicPlayerViewModel.shared.playbackProgress

    private var activeSong: MusicSong {
        resolvedSong ?? song
    }

    private var displayedCurrentTime: Double {
        if let scrubbingTime = scrubbingTime {
            return scrubbingTime
        }
        return playbackProgress.currentTime
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private var fallbackBackgroundColor: Color {
        colorScheme == .light ? Color(red: 244.0 / 255.0, green: 243.0 / 255.0, blue: 246.0 / 255.0) : Color.white.opacity(0.08)
    }

    private var cardOverlay: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(colorScheme == .light ? 0.12 : 0.28),
                AppTheme.primary.opacity(colorScheme == .light ? 0.18 : 0.30)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var usesArtworkBackground: Bool {
        displayCover != nil
    }

    private var titleColor: Color {
        usesArtworkBackground ? .white : AppTheme.textPrimary
    }

    private var subtitleColor: Color {
        usesArtworkBackground ? .white.opacity(0.82) : AppTheme.textSecondary
    }

    private var footerColor: Color {
        usesArtworkBackground ? .white.opacity(0.72) : AppTheme.textSecondary.opacity(0.86)
    }

    var body: some View {
        let isActive = isInteractive && playerViewModel.selectedSong?.id == song.id
        let isCurrentPlaying = isActive && playerViewModel.isPlaying

        VStack(alignment: .leading, spacing: isActive ? 2 : 10) {
            HStack(spacing: 12) {
                songCover

                VStack(alignment: .leading, spacing: 3) {
                    Text(activeSong.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)

                    Text(activeSong.artist)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)

                    if let footer {
                        Text(footer)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(footerColor)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    if isActive {
                        playerViewModel.togglePlayPause()
                    } else {
                        Task { await playerViewModel.selectSong(activeSong, queue: playQueue ?? [activeSong]) }
                    }
                } label: {
                    Image(systemName: isCurrentPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [AppTheme.primary, AppTheme.primarySoft],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                }
                .buttonStyle(BubblePressButtonStyle())
            }

            if isActive {
                // One-to-one like mini player progress slider row
                HStack(spacing: 8) {
                    Text(formatTime(displayedCurrentTime))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(usesArtworkBackground ? .white.opacity(0.82) : AppTheme.textSecondary)
                        .frame(minWidth: 32, alignment: .leading)
                        .lineLimit(1)

                    CustomMiniSlider(
                        value: displayedCurrentTime,
                        range: 0...max(playbackProgress.duration, 0.1),
                        usesArtworkBackground: usesArtworkBackground,
                        onSeek: { value in
                            playerViewModel.seek(to: value)
                        },
                        onDragChange: { targetValue in
                            scrubbingTime = targetValue
                        }
                    )
                    .frame(height: 12)

                    Text("-\(formatTime(max(playbackProgress.duration - displayedCurrentTime, 0)))")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(usesArtworkBackground ? .white.opacity(0.82) : AppTheme.textSecondary)
                        .frame(minWidth: 32, alignment: .trailing)
                        .lineLimit(1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isActive ? 8 : 12)
        .background {
            if let displayCover {
                ZStack {
                    MediaImageView(
                        media: displayCover,
                        width: nil,
                        height: nil,
                        maxHeight: nil,
                        prefersLossless: false,
                        estimatedBytes: nil,
                        contentMode: .fill,
                        applyMinimumPlaceholderHeight: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 18)
                    .clipped()

                    Rectangle()
                        .fill(cardOverlay)
                }
                .clipped()
            } else {
                fallbackBackgroundColor
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture {
            onCardTap?()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
        .task(id: songArtworkLoadID) {
            await loadSongIfNeeded()
        }
    }

    @ViewBuilder
    private var songCover: some View {
        if let displayCover {
            MediaImageView(
                media: displayCover,
                width: 52,
                height: 52,
                maxHeight: 52,
                prefersLossless: false,
                estimatedBytes: nil,
                contentMode: .fill
            )
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.primary.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                )
        }
    }

    private var displayCover: MediaData? {
        activeSong.cover
    }

    private var songArtworkLoadID: String {
        "\(song.id)|\(song.title)|\(song.artist)|\(song.cover?.imageLoadKey ?? "")"
    }

    @MainActor
    private func loadSongIfNeeded() async {
        if song.title != "Unknown" && song.artist != "Unknown" && song.cover != nil {
            resolvedSong = song
            return
        }

        guard resolvedSong == nil else { return }
        if let fetched = await PostSongDetailsResolver.shared.song(for: song) {
            resolvedSong = fetched
        }
    }
}

private struct PostSongsSheet: View {
    let songs: [MusicSong]
    let selectedLanguageCode: String
    let currentSongID: Int?
    let isPlaying: Bool
    let onSelectSong: (MusicSong) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(songs) { song in
                        PostSongCard(
                            song: song,
                            footer: nil,
                            playQueue: songs
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle(selectedLanguageCode == "en" ? "Songs" : "Треки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedLanguageCode == "en" ? "Close" : "Закрыть") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PostAuthorAvatarView: View {
    let media: MediaData?
    let fallbackText: String
    let size: CGFloat
    @State private var uiImage: UIImage?
    @State private var lastLoadedKey: String?

    init(media: MediaData?, fallbackText: String, size: CGFloat = 34) {
        self.media = media
        self.fallbackText = fallbackText
        self.size = size
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        .compositingGroup()
        .task(id: avatarLoadKey) {
            await loadAvatarIfNeeded(for: avatarLoadKey)
        }
    }

    private var fallback: some View {
        let fontSize = max(12, size * 0.42)
        return ZStack {
            Circle().fill(AppTheme.surfaceElevated)
            Text(String(fallbackText.prefix(1)).uppercased())
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    private var avatarLoadKey: String {
        media?.imageLoadKey ?? ""
    }

    private func loadAvatarIfNeeded(for key: String) async {
        guard lastLoadedKey != key else { return }
        lastLoadedKey = key
        guard let media else {
            uiImage = nil
            return
        }

        if let cachedData = APIClient.shared.cachedMediaImageData(for: media, lossless: true),
           let cachedImage = UIImage(data: cachedData) {
            uiImage = cachedImage
            return
        }

        uiImage = nil

        if let data = await APIClient.shared.downloadMediaImage(media, lossless: true),
           let image = UIImage(data: data) {
            uiImage = image
            return
        }

        if let path = media.path,
           let simple = media.simple,
           let data = await APIClient.shared.downloadImage(path: path, file: simple, simple: simple, lossless: false),
           let image = UIImage(data: data) {
            uiImage = image
        }
    }
}

private struct PostPollView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    let postID: Int
    let initialPoll: PostPoll

    @State private var poll: PostPoll
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(postID: Int, initialPoll: PostPoll) {
        self.postID = postID
        self.initialPoll = initialPoll
        _poll = State(initialValue: initialPoll)
    }

    private var hasVoted: Bool { !poll.userVote.isEmpty }
    private var showResults: Bool { hasVoted || APIClient.shared.currentUserIDSnapshot() == nil }
    private var isExpired: Bool {
        guard let expiresAt = poll.expiresAt else { return false }
        return ISO8601DateFormatter().date(from: expiresAt).map { $0 < Date() } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !poll.question.isEmpty {
                Text(poll.question)
                    .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                    }

            VStack(spacing: 8) {
                ForEach(poll.options) { option in
                    Button {
                        Task { await vote(on: option.id) }
                    } label: {
                        optionRow(option)
                    }
                    .buttonStyle(.plain)
                    .disabled(APIClient.shared.currentUserIDSnapshot() == nil || isSubmitting || isExpired)
                }
            }

            HStack(spacing: 6) {
                Text(votesLabel(poll.totalVotes))
                if poll.isAnonymous {
                    Text("· Анонимный")
                }
                if poll.multipleChoice {
                    Text("· Несколько ответов")
                }
                if isExpired {
                    Text("· Завершён")
                }
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func optionRow(_ option: PostPollOption) -> some View {
        let isSelected = poll.userVote.contains(option.id)
        let percent = poll.totalVotes > 0 ? Int(round((Double(option.votesCount) / Double(poll.totalVotes)) * 100)) : 0

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? AppTheme.primary : AppTheme.textSecondary)

            Text(option.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showResults {
                Text("\(percent)%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surfaceElevated)

                    if showResults {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTheme.primary.opacity(isSelected ? 0.28 : 0.15))
                            .frame(width: geo.size.width * CGFloat(percent) / 100.0)
                    }
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? AppTheme.primary.opacity(0.35) : AppTheme.cardStroke, lineWidth: 1)
        )
    }

    private func vote(on optionID: Int) async {
        guard APIClient.shared.currentUserIDSnapshot() != nil, !isSubmitting, !isExpired else { return }

        let currentSelection = poll.userVote
        let optionIDs: [Int]
        if poll.multipleChoice {
            if currentSelection.contains(optionID) {
                optionIDs = currentSelection.filter { $0 != optionID }
            } else {
                optionIDs = currentSelection + [optionID]
            }
        } else {
            let isSame = currentSelection.count == 1 && currentSelection[0] == optionID
            optionIDs = isSame ? [] : [optionID]
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let responsePoll = try await APIClient.shared.voteInPoll(
                postID: postID,
                optionIDs: optionIDs.isEmpty ? [optionID] : optionIDs,
                currentPoll: poll
            )
            poll = responsePoll
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func votesLabel(_ count: Int) -> String {
        if selectedLanguageCode == "en" {
            return count == 1 ? "1 vote" : "\(count) votes"
        }

        let mod10 = count % 10
        let mod100 = count % 100
        let suffix: String
        if mod10 == 1 && mod100 != 11 {
            suffix = "голос"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            suffix = "голоса"
        } else {
            suffix = "голосов"
        }
        return "\(count) \(suffix)"
    }
}

private struct LinkifiedPostText: View {
    let text: String
    let onUsernameTap: (String) -> Void

    var body: some View {
        renderedText
            .tint(AppTheme.primary)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "elemsocial-profile" {
                    let username = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !username.isEmpty {
                        onUsernameTap(username)
                        return .handled
                    }
                }
                return .systemAction
            })
    }

    private var renderedText: Text {
        let rawSegments = EmojiHelper.shared.parseSegments(from: text, pointSize: 18)
        guard !rawSegments.isEmpty else { return Text(text) }

        var result = Text("")
        for segment in rawSegments {
            switch segment {
            case .text(let str):
                if let attr = makeLinkifiedAttributedString(from: str) {
                    result = result + Text(attr)
                } else {
                    result = result + Text(str)
                }
            case .attributed(let attr):
                result = result + Text(attr)
            case .emoji(let image):
                result = result + Text(Image(uiImage: image))
            }
        }
        return result
    }

    private func makeLinkifiedAttributedString(from rawText: String) -> AttributedString? {
        guard !rawText.isEmpty else { return nil }
        let nsText = rawText as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let mutable = NSMutableAttributedString(string: rawText)
        let fullRange = NSRange(location: 0, length: nsText.length)
        detector.enumerateMatches(in: rawText, options: [], range: fullRange) { match, _, _ in
            guard let match, let url = match.url else { return }
            mutable.addAttribute(.link, value: url, range: match.range)
        }

        if let mentionRegex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_.])@([\\p{L}\\p{N}_.-]+)", options: []) {
            mentionRegex.enumerateMatches(in: rawText, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                let range = match.range
                var hasLink = false
                mutable.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
                    if value != nil {
                        hasLink = true
                        stop.pointee = true
                    }
                }
                guard !hasLink else { return }
                let mention = nsText.substring(with: range)
                let username = String(mention.dropFirst())
                guard !username.isEmpty else { return }
                let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? username
                guard let url = URL(string: "elemsocial-profile://\(encoded)") else { return }
                mutable.addAttribute(.link, value: url, range: range)
            }
        }

        return try? AttributedString(mutable, including: \.foundation)
    }
}

private struct MediaImageView: View {
    let media: MediaData?
    let width: CGFloat?
    let height: CGFloat?
    let maxHeight: CGFloat?
    let prefersLossless: Bool
    let estimatedBytes: Int?
    let contentMode: ContentMode
    /// When `height` is nil, `MediaImageView` normally applies a minimum height for empty/loading layout.
    /// Set to `false` for tight backgrounds (e.g. post song card) so the view does not inflate parents.
    var applyMinimumPlaceholderHeight: Bool = true

    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var didLoadFinalImage = false

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity)
            } else if isLoading {
                Color.gray.opacity(0.12)
                ProgressView()
            } else if hasFailed {
                Color.gray.opacity(0.2)
                Text("Image error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Color.gray.opacity(0.12)
            }
        }
        .frame(width: width)
        .ifLet(height) { view, h in
            view.frame(height: h)
        }
        .ifLet(maxHeight) { view, maxH in
            view.frame(maxHeight: maxH)
        }
        .frame(minHeight: (applyMinimumPlaceholderHeight && height == nil) ? 110 : nil)
        .frame(maxWidth: .infinity, alignment: .center)
        .if(contentMode == .fill) { view in
            view.clipped()
        }
        .cornerRadius(10)
        .task(id: mediaLoadKey) {
            await loadImageIfNeeded()
        }
        .onChange(of: mediaLoadKey) { _ in
            uiImage = nil
            isLoading = false
            hasFailed = false
            didLoadFinalImage = false
        }
    }

    private func loadImageIfNeeded() async {
        guard !isLoading, !hasFailed, !didLoadFinalImage else { return }
        isLoading = true
        defer { isLoading = false }

        if let previewDataURL = media?.preview, let image = imageFromDataURL(previewDataURL) {
            uiImage = image
        }

        if let media, prefersLossless, shouldPreferDirectURL(media: media) {
            if let url = media.fullURL ?? media.simpleURL,
               let data = await APIClient.shared.downloadImageURL(url),
               let image = UIImage(data: data) {
                uiImage = image
                didLoadFinalImage = true
                return
            }
        }

        if let media {
            let lossless = prefersLossless
            if let cached = APIClient.shared.cachedMediaImageData(for: media, lossless: lossless),
               let image = UIImage(data: cached) {
                uiImage = image
                didLoadFinalImage = true
                return
            }

            if let data = await APIClient.shared.downloadMediaImage(
                media,
                lossless: lossless,
                maxLosslessBytes: lossless ? estimatedBytes : nil
            ),
               let image = UIImage(data: data) {
                uiImage = image
                didLoadFinalImage = true
                return
            }
        }

        if uiImage == nil, let url = media?.fullURL ?? media?.simpleURL {
            if let cached = APIClient.shared.cachedURLImageData(url: url), let image = UIImage(data: cached) {
                uiImage = image
                didLoadFinalImage = true
                return
            }
            if let data = await APIClient.shared.downloadImageURL(url), let image = UIImage(data: data) {
                uiImage = image
                didLoadFinalImage = true
                return
            }
        }

        hasFailed = (uiImage == nil)
    }

    private var mediaLoadKey: String {
        let previewHash = media?.preview?.hashValue ?? 0
        let sizeKey = estimatedBytes ?? 0
        return "\(media?.imageLoadKey ?? "")|\(prefersLossless)|\(sizeKey)|\(previewHash)"
    }

    private func imageFromDataURL(_ dataURLString: String) -> UIImage? {
        let lower = dataURLString.lowercased()
        guard lower.starts(with: "data:image"), let commaIndex = dataURLString.firstIndex(of: ",") else {
            return nil
        }
        let base64Part = String(dataURLString[dataURLString.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64Part) else { return nil }
        return UIImage(data: data)
    }

    private func shouldPreferDirectURL(media: MediaData) -> Bool {
        let file = (media.file ?? media.simple ?? "").lowercased()
        return file.hasSuffix(".avif")
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentY += rowHeight + spacing
                currentX = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
        currentY += rowHeight

        return CGSize(width: maxWidth, height: currentY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentY += rowHeight + spacing
                currentX = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
        let _ = maxWidth
    }
}

private struct PostCardStyleModifier: ViewModifier {

    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let _ = elevated
        content
            .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private extension View {
    func postCardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(PostCardStyleModifier(cornerRadius: cornerRadius, elevated: false))
    }

    func postElevatedCardStyle(cornerRadius: CGFloat = 14) -> some View {
        modifier(PostCardStyleModifier(cornerRadius: cornerRadius, elevated: true))
    }

    func glassCardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardStyleModifier(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

private struct GlassCardStyleModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(
                shape
                    .fill(glassFill)
                    .background(.regularMaterial, in: shape)
            )
    }

    private var glassFill: Color {
        AppTheme.postCard.opacity(0.92)
    }
}

private struct InAppBannerData: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let notification: SocialNotification?
}

private struct InAppBannerView: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String
    let onTap: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Уведомление" : title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.28))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 6)

        if let onTap {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

private func triggerLikeHaptic() {
    DispatchQueue.main.async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
