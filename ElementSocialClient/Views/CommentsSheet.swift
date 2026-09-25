import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import AVKit
import AVFoundation

struct CommentsSheet: View {
    let post: Post
    let onCommentSent: () -> Void
    let onOpenProfile: (String) -> Void
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var viewModel: CommentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var infoMessage: String?
    @State private var reportContext: ReportContext?
    @FocusState private var isComposerFocused: Bool

    @State private var selectedImagePayload: SelectedImagePayload?
    @State private var selectedVideo: PostVideo?
    @State private var sharePayload: SharePayload?
    @State private var exportPayload: FileExportPayload?

    init(post: Post, onCommentSent: @escaping () -> Void, onOpenProfile: @escaping (String) -> Void) {
        self.post = post
        self.onCommentSent = onCommentSent
        self.onOpenProfile = onOpenProfile
        _viewModel = StateObject(wrappedValue: CommentsViewModel(post: post))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.backgroundGradient
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    content
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                dismissKeyboard()
                            }
                        )
                    composer
                }
            }
            .navigationTitle("Пост #\(post.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .task {
            await viewModel.loadComments()
        }
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
            if let video = selectedVideo {
                VideoPlayerScreen(video: video)
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
        .sheet(item: $reportContext) { context in
            ReportSheet(context: context)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading where viewModel.comments.isEmpty:
            VStack {
                Spacer()
                ProgressView("Загружаем комментарии...")
                Spacer()
            }
        case .error(let message) where viewModel.comments.isEmpty:
            VStack(spacing: 10) {
                Spacer()
                Text("Ошибка загрузки")
                    .font(.headline.weight(.bold))
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Повторить") {
                    Task { await viewModel.loadComments() }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
        default:
            if viewModel.comments.isEmpty {
                VStack {
                    Spacer()
                    Text("Пока нет комментариев")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(viewModel.comments) { comment in
                        commentRow(comment)
                            .commentCardStyle(cornerRadius: 14)
                            .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    @ViewBuilder
    private func commentRow(_ comment: PostComment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Button {
                    openProfileFromComment(comment)
                } label: {
                    HStack(alignment: .top, spacing: 5) {
                        CommentAuthorAvatarView(
                            media: comment.author.avatarMedia,
                            aura: comment.author.avatarAura,
                            fallbackText: comment.author.name ?? comment.author.username ?? "U"
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            let isVerified = comment.author.isVerified ?? false
                            let hasGold = comment.author.goldStatus ?? false
                            HStack(spacing: 4) {
                                Text(comment.author.name ?? comment.author.username ?? "Unknown")
                                    .font(.subheadline.weight(.bold))
                                    .lineLimit(1)
                                if isVerified || hasGold {
                                    UserStatusBadges(isVerified: isVerified, hasGold: hasGold, size: 14)
                                }
                            }
                            Text(relativeCommentDateText(from: comment.createDate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                Spacer()
                Menu {
                    commentMenuItems(for: comment)
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(Color(red: 139.0 / 255.0, green: 134.0 / 255.0, blue: 147.0 / 255.0))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }

            if let reply = viewModel.replyPreview(for: comment) {
                ReplyPreviewBlock(preview: reply)
                    .padding(.top, 2)
                    .padding(.bottom, 2)
            }
            if !comment.text.isEmpty {
                Text(comment.text)
                    .font(.body.weight(.medium))
            }
            if let images = comment.content?.images, !images.isEmpty {
                commentImagesView(images)
                    .padding(.top, 4)
            }
            if let videos = comment.content?.videos, !videos.isEmpty {
                commentVideosView(videos)
                    .padding(.top, 4)
            }
            if let files = comment.content?.files, !files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .font(.caption)
                            Text(file.name ?? "Файл")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            if let size = file.size {
                                Text("(\(readableSize(size)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                Task { await downloadCommentFile(file) }
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
        }
        .contentShape(Rectangle())
        .contextMenu {
            commentMenuItems(for: comment)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private func commentImagesView(_ images: [PostCommentImage]) -> some View {
        if images.count == 1, let image = images.first, image.imgData != nil {
            commentSingleMediaView(
                media: image.imgData,
                maxHeight: 220,
                estimatedBytes: image.fileSize,
                showPlay: false,
                allowBlurBackground: shouldBlurCommentBackground(for: image.imgData)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedImagePayload = makeCommentImagePayload(images: images, startIndex: 0)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        CommentMediaImageView(
                            media: image.imgData,
                            estimatedBytes: image.fileSize,
                            contentMode: .fit
                        )
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedImagePayload = makeCommentImagePayload(images: images, startIndex: index)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commentVideosView(_ videos: [PostVideo]) -> some View {
        let playable = videos.filter(commentHasPlayableVideo)
        if playable.count == 1, let video = playable.first {
            Button {
                selectedVideo = video
            } label: {
                commentSingleMediaView(
                    media: video.preview?.imgData,
                    maxHeight: 210,
                    estimatedBytes: nil,
                    showPlay: true,
                    allowBlurBackground: shouldBlurCommentBackground(for: video.preview?.imgData)
                )
            }
            .buttonStyle(.plain)
        } else {
            ForEach(playable) { video in
                Button {
                    selectedVideo = video
                } label: {
                    ZStack {
                        CommentMediaImageView(
                            media: video.preview?.imgData,
                            estimatedBytes: nil,
                            contentMode: .fit
                        )
                        .frame(maxHeight: 210)

                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func commentSingleMediaView(
        media: MediaData?,
        maxHeight: CGFloat,
        estimatedBytes: Int? = nil,
        showPlay: Bool = false,
        allowBlurBackground: Bool = true
    ) -> some View {
        ZStack {
            if allowBlurBackground {
                CommentMediaImageView(
                    media: media,
                    estimatedBytes: estimatedBytes,
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity, minHeight: maxHeight, maxHeight: maxHeight)
                .clipped()
                .blur(radius: 20)
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.2 : 0.12))
            }

            CommentMediaImageView(
                media: media,
                estimatedBytes: estimatedBytes,
                contentMode: .fit
            )
            .frame(maxWidth: .infinity, maxHeight: maxHeight)

            if showPlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func commentHasPlayableVideo(_ video: PostVideo) -> Bool {
        video.file != nil || video.name != nil || video.fileName != nil || video.url != nil || video.src != nil
    }

    private func shouldBlurCommentBackground(for media: MediaData?) -> Bool {
        guard let size = commentPreviewSize(from: media) else { return false }
        let ratio = size.width / max(1, size.height)
        return ratio < 1.2
    }

    private func commentPreviewSize(from media: MediaData?) -> CGSize? {
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

    @ViewBuilder
    private func commentMenuItems(for comment: PostComment) -> some View {
        Button {
            viewModel.startReply(to: comment)
        } label: {
            Label(selectedLanguageCode == "en" ? "Reply" : "Ответить", systemImage: "arrowshape.turn.up.left")
        }
        if !comment.text.isEmpty {
            Button {
                UIPasteboard.general.string = comment.text
            } label: {
                Label(selectedLanguageCode == "en" ? "Copy text" : "Копировать текст", systemImage: "doc.on.doc")
            }
        }
        Button {
            if let serverID = comment.serverID {
                reportContext = ReportContext(
                    targetType: .comment,
                    targetId: serverID,
                    title: comment.author.name ?? comment.author.username ?? "Unknown",
                    subtitle: relativeCommentDateText(from: comment.createDate),
                    text: comment.text
                )
            } else {
                infoMessage = selectedLanguageCode == "en" ? "Failed to identify comment" : "Не удалось определить комментарий"
            }
        } label: {
            Label(selectedLanguageCode == "en" ? "Report" : "Пожаловаться", systemImage: "exclamationmark.bubble")
        }
        if viewModel.canDelete(comment: comment) {
            Button(role: .destructive) {
                Task { await viewModel.deleteComment(comment: comment) }
            } label: {
                Label(selectedLanguageCode == "en" ? "Delete" : "Удалить", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .tint(.red)
        }
        if let images = comment.content?.images, !images.isEmpty {
            Button {
                Task {
                    do {
                        let items = images.compactMap { image -> ImageSaveItem? in
                            guard let media = image.imgData else { return nil }
                            return ImageSaveItem(media: media, estimatedBytes: image.fileSize)
                        }
                        let count = try await PhotoLibrarySaver.saveImages(from: items)
                        infoMessage = selectedLanguageCode == "en" ? "Saved photos: \(count)" : "Сохранено фото: \(count)"
                    } catch {
                        infoMessage = error.localizedDescription
                    }
                }
            } label: {
                Label(selectedLanguageCode == "en" ? "Save photo" : "Скачать фото", systemImage: "arrow.down.to.line")
            }
        }
        if let videos = comment.content?.videos?.filter(commentHasPlayableVideo), !videos.isEmpty, let video = videos.first {
            Button {
                Task { await downloadCommentVideo(video) }
            } label: {
                Label(selectedLanguageCode == "en" ? "Download video" : "Скачать видео", systemImage: "arrow.down.to.line")
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let replyingTo = viewModel.replyingTo {
                    ReplyComposerBanner(comment: replyingTo) {
                        viewModel.cancelReply()
                    }
                }

                TextField("Написать комментарий...", text: $viewModel.draft, axis: .vertical)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .lineLimit(1...5)
                    .focused($isComposerFocused)

                if !viewModel.draftFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(viewModel.draftFiles.enumerated()), id: \.offset) { index, file in
                                DraftFilePreview(file: file) {
                                    viewModel.removeDraftFile(at: index)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack(spacing: 8) {
                    PhotosPicker(
                        selection: $viewModel.selectedPhotoItems,
                        maxSelectionCount: 10,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.controlIcon)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSending)

                    Button {
                        viewModel.isImportingFiles = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.controlIcon)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSending)

                    Spacer()

                    let canSend = !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.draftFiles.isEmpty
                    Button(viewModel.isSending ? "..." : (selectedLanguageCode == "en" ? "Send" : "Отправить")) {
                        Task {
                            let sent = await viewModel.sendComment()
                            if sent {
                                onCommentSent()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(canSend ? .white : AppTheme.controlIcon)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        canSend
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [AppTheme.primary, AppTheme.primarySoft],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(AppTheme.surfaceElevated),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .disabled(viewModel.isSending || !canSend)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .padding(.top, 6)

            if let sendError = viewModel.sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.clear)
        .onChange(of: viewModel.selectedPhotoItems.count) { _ in
            let items = viewModel.selectedPhotoItems
            Task { await viewModel.importSelectedPhotos(items) }
        }
        .fileImporter(
            isPresented: $viewModel.isImportingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await viewModel.importFiles(urls) }
            case .failure(let error):
                viewModel.sendError = error.localizedDescription
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
    }

    private func openProfileFromComment(_ comment: PostComment) {
        guard let username = comment.author.username, !username.isEmpty else { return }
        dismiss()
        onOpenProfile(username)
    }

    private func dismissKeyboard() {
        isComposerFocused = false
    }

    private func readableSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func downloadCommentFile(_ file: PostCommentFile) async {
        let candidates = attachmentPathCandidates(rawFile: file.file, preferredPaths: ["posts/files", "files", "comments/files"])
        for (path, filename) in candidates {
            if let url = await APIClient.shared.downloadFile(path: path, file: filename) {
                if let exportURL = prepareExportURL(from: url, filename: filename) {
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

    private func downloadCommentVideo(_ video: PostVideo) async {
        if let fileID = video.fileId {
            let filename = video.fileName ?? video.file ?? video.name ?? "video_\(fileID).mp4"
            if let url = try? await APIClient.shared.downloadStorageVideoFile(fileID: fileID, fileName: filename) {
                if let exportURL = prepareExportURL(from: url, filename: filename) {
                    await MainActor.run {
                        exportPayload = FileExportPayload(url: exportURL)
                    }
                } else {
                    await MainActor.run {
                        infoMessage = "Не удалось подготовить видео"
                    }
                }
                return
            }
        }

        let names = [video.file, video.name, video.fileName, video.url, video.src]
        for raw in names {
            let candidates = attachmentPathCandidates(rawFile: raw, preferredPaths: ["posts/videos", "videos"])
            for (path, filename) in candidates {
                if let url = await APIClient.shared.downloadFile(path: path, file: filename) {
                    if let exportURL = prepareExportURL(from: url, filename: filename) {
                        await MainActor.run {
                            exportPayload = FileExportPayload(url: exportURL)
                        }
                    } else {
                        await MainActor.run {
                            infoMessage = "Не удалось подготовить видео"
                        }
                    }
                    return
                }
            }
        }
        infoMessage = "Не удалось скачать видео"
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

    private func relativeCommentDateText(from rawDate: String?) -> String {
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
}

@MainActor
final class CommentsViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var state: State = .idle
    @Published var comments: [PostComment] = []
    @Published var draft = ""
    @Published var draftFiles: [UploadFile] = []
    @Published var selectedPhotoItems: [PhotosPickerItem] = []
    @Published var isImportingFiles = false
    @Published var isSending = false
    @Published var sendError: String?
    @Published var replyingTo: PostComment?
    @Published var actionError: String?

    private let post: Post
    private let apiClient: APIClient
    private let currentUserID: Int?

    init(post: Post, apiClient: APIClient = .shared) {
        self.post = post
        self.apiClient = apiClient
        self.currentUserID = apiClient.currentUserIDSnapshot()
    }

    func loadComments() async {
        state = .loading
        do {
            comments = try await apiClient.loadPostComments(postID: post.id, startIndex: 0)
            state = .loaded
        } catch is CancellationError {
            state = .loaded
        } catch {
            if comments.isEmpty {
                state = .error(error.localizedDescription)
            } else {
                state = .loaded
            }
        }
    }

    func sendComment() async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftFiles.isEmpty else { return false }

        isSending = true
        sendError = nil
        defer { isSending = false }

        do {
            let draftFilesCount = draftFiles.count
            let created = try await apiClient.sendPostComment(
                postID: post.id,
                targetID: post.author.id,
                targetType: post.author.type,
                text: text,
                files: draftFiles,
                replyToID: replyingTo?.serverID
            )
            draft = ""
            draftFiles = []
            selectedPhotoItems = []
            replyingTo = nil

            // comments/add often returns only comment_id, so fetch the authoritative comment payload
            // (with content/images) to show media immediately without manual refresh.
            await refreshAfterSend(createdCommentID: created.serverID, expectedText: text, hadFiles: draftFilesCount > 0)
            return true
        } catch is CancellationError {
            return false
        } catch {
            sendError = error.localizedDescription
            return false
        }
    }

    func startReply(to comment: PostComment) {
        replyingTo = comment
    }

    func cancelReply() {
        replyingTo = nil
    }

    func canDelete(comment: PostComment) -> Bool {
        guard let currentUserID else { return false }
        return comment.author.id == currentUserID
    }

    func deleteComment(comment: PostComment) async {
        guard let commentID = comment.serverID else { return }
        do {
            try await apiClient.deleteComment(commentID: commentID, postID: post.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func clearActionError() {
        actionError = nil
    }

    fileprivate func replyPreview(for comment: PostComment) -> CommentReplyPreview? {
        if let replyToID = comment.replyToID,
           let target = comments.first(where: { $0.serverID == replyToID }) {
            return CommentReplyPreview(
                authorName: target.author.name ?? target.author.username ?? "Unknown",
                text: target.text.isEmpty ? "Комментарий" : target.text,
                aura: target.author.avatarAura
            )
        }

        if let preview = comment.replyPreview {
            let author = preview.author
            return CommentReplyPreview(
                authorName: author?.name ?? author?.username ?? "Unknown",
                text: (preview.text?.isEmpty == false) ? (preview.text ?? "Комментарий") : "Комментарий",
                aura: author?.avatarAura
            )
        }

        return nil
    }

    private func refreshAfterSend(createdCommentID: Int?, expectedText: String, hadFiles: Bool) async {
        let initialCount = comments.count
        for attempt in 0..<4 {
            do {
                let loaded = try await apiClient.loadPostComments(postID: post.id, startIndex: 0)
                comments = loaded
                state = .loaded

                let hasCreatedCommentByID = createdCommentID != nil && loaded.contains { $0.serverID == createdCommentID }
                let hasCreatedCommentByText = loaded.contains { $0.text == expectedText }
                let hasNewTopComment = loaded.count > initialCount
                let hasMediaComment = hadFiles && loaded.contains {
                    ($0.content?.images?.isEmpty == false)
                    || ($0.content?.videos?.isEmpty == false)
                    || ($0.content?.files?.isEmpty == false)
                }

                if hasCreatedCommentByID || hasCreatedCommentByText || hasNewTopComment || hasMediaComment {
                    return
                }
            } catch {
                // Keep retrying; network race after upload is expected.
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    func removeDraftFile(at index: Int) {
        guard draftFiles.indices.contains(index) else { return }
        draftFiles.remove(at: index)
    }

    func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for (index, item) in items.enumerated() {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let name = "comment_photo_\(Int(Date().timeIntervalSince1970))_\(index).\(ext)"
                    draftFiles.append(UploadFile(name: name, data: data))
                }
            } catch {
                sendError = error.localizedDescription
            }
        }
        selectedPhotoItems = []
    }

    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer {
                if granted { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent.isEmpty ? "file.bin" : url.lastPathComponent
                draftFiles.append(UploadFile(name: name, data: data))
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}

fileprivate struct CommentReplyPreview {
    let authorName: String
    let text: String
    let aura: String?
}

private struct ReplyPreviewBlock: View {
    let preview: CommentReplyPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(preview.authorName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            Text(preview.text)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(colorFromAura(preview.aura).opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}

private struct ReplyComposerBanner: View {
    let comment: PostComment
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ответ: \(comment.author.name ?? "Unknown")")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(comment.text.isEmpty ? "Комментарий" : comment.text)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(colorFromAura(comment.author.avatarAura).opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}

private func colorFromAura(_ aura: String?) -> Color {
    guard let aura else { return AppTheme.surfaceElevated }
    let scanner = Scanner(string: aura)
    _ = scanner.scanString("rgb(")
    let defaultValue = 255.0
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
    return Color(
        red: min(max(rValue, 0), 255) / 255.0,
        green: min(max(gValue, 0), 255) / 255.0,
        blue: min(max(bValue, 0), 255) / 255.0
    )
}

private struct CommentAuthorAvatarView: View {
    let media: MediaData?
    let aura: String?
    let fallbackText: String

    @State private var uiImage: UIImage?
    @State private var lastLoadedKey: String?

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
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .task(id: avatarLoadKey) {
            await loadAvatarIfNeeded(for: avatarLoadKey)
        }
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(colorFromAura(aura).opacity(0.34))
            Text(String(fallbackText.prefix(1)).uppercased())
                .font(.caption.weight(.bold))
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

private struct CommentMediaImageView: View {
    let media: MediaData?
    let estimatedBytes: Int?
    let contentMode: ContentMode

    init(
        media: MediaData?,
        estimatedBytes: Int?,
        contentMode: ContentMode = .fit
    ) {
        self.media = media
        self.estimatedBytes = estimatedBytes
        self.contentMode = contentMode
    }

    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var didLoadFinalImage = false

    @ViewBuilder
    var body: some View {
        let content = ZStack {
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
        .frame(minHeight: 90)
        .frame(maxWidth: .infinity, alignment: .center)
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

        if contentMode == .fill {
            content.clipped()
        } else {
            content
        }
    }

    private func loadImageIfNeeded() async {
        guard !isLoading, !hasFailed, !didLoadFinalImage else { return }
        isLoading = true
        defer { isLoading = false }

        if let previewDataURL = media?.preview, let image = imageFromDataURL(previewDataURL) {
            uiImage = image
        }

        if let media,
           let data = await APIClient.shared.downloadMediaImage(
               media,
               lossless: true,
               maxLosslessBytes: estimatedBytes
           ),
           let image = UIImage(data: data) {
            uiImage = image
            didLoadFinalImage = true
            return
        }

        hasFailed = (uiImage == nil)
    }

    private var mediaLoadKey: String {
        let previewHash = media?.preview?.hashValue ?? 0
        return "\(media?.imageLoadKey ?? "")|\(previewHash)"
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
}

private struct CommentCardStyleModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private extension View {
    func commentCardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(CommentCardStyleModifier(cornerRadius: cornerRadius))
    }
}

private struct DraftFilePreview: View {
    let file: UploadFile
    let onRemove: () -> Void
    
    var isImage: Bool {
        let name = file.name.lowercased()
        return name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".png") || name.hasSuffix(".heic") || name.hasSuffix(".webp")
    }
    
    var body: some View {
        if isImage, let uiImage = UIImage(data: file.data) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            .frame(width: 64, height: 64)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.caption)
                Text(file.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.surfaceElevated, in: Capsule())
        }
    }
}
