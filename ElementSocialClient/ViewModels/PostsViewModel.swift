import Foundation

@MainActor
final class PostsViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var state: State = .idle
    @Published var posts: [Post] = []
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var actionError: String?
    @Published private(set) var postsType: String = "last"

    private let apiClient: APIClient
    private var startIndex = 0
    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    func loadPosts(reset: Bool = false) async {
        guard !isLoading, !isLoadingMore else { return }

        let previousPosts = posts
        let previousStartIndex = startIndex
        let previousHasMore = hasMore
        let previousState = state

        if reset {
            startIndex = 0
            hasMore = true
        }

        guard hasMore else { return }

        if reset || posts.isEmpty {
            state = .loading
        } else {
            isLoadingMore = true
        }

        defer { isLoadingMore = false }

        do {
            let response = try await apiClient.loadPosts(startIndex: startIndex, postsType: postsType)
            let newPosts = response.posts ?? []

            if reset {
                posts = newPosts
            } else {
                let existing = Set(posts.map(\.id))
                posts.append(contentsOf: newPosts.filter { !existing.contains($0.id) })
            }

            startIndex += newPosts.count
            // Backend can return less than nominal page size even when older posts still exist.
            hasMore = !newPosts.isEmpty
            state = .loaded
        } catch is CancellationError {
            if reset {
                posts = previousPosts
                startIndex = previousStartIndex
                hasMore = previousHasMore
                state = previousState
            }
        } catch {
            if reset {
                startIndex = previousStartIndex
                hasMore = previousHasMore
            }

            if posts.isEmpty && previousPosts.isEmpty {
                state = .error(error.localizedDescription)
            } else {
                state = .loaded
            }
        }
    }

    func loadMoreIfNeeded(currentPost: Post) async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        guard let index = posts.firstIndex(where: { $0.id == currentPost.id }) else { return }
        let threshold = max(posts.count - 5, 0)
        if index >= threshold {
            await loadPosts(reset: false)
        }
    }

    func refresh() async {
        await loadPosts(reset: true)
    }

    func setPostsType(_ type: String) async {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != postsType else { return }

        postsType = trimmed
        startIndex = 0
        hasMore = true
        posts = []
        state = .idle
        await loadPosts(reset: true)
    }

    func createPost(
        text: String,
        files: [UploadFile] = [],
        songs: [MusicSong] = [],
        poll: PostPollDraft? = nil,
        fromChannel: ChannelSummary? = nil
    ) async throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let postID = try await apiClient.createPost(
            text: trimmed,
            files: files,
            songIDs: songs.map(\.id),
            poll: poll,
            fromChannelID: fromChannel?.id
        )
        addOptimisticPost(postID: postID, text: trimmed, songs: songs, poll: poll, fromChannel: fromChannel)
        return postID
    }

    func toggleReaction(postID: Int, reaction: String) async {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        let original = posts[index]

        let isRemoving = posts[index].toggleReaction(reaction)
        do {
            try await apiClient.setPostReaction(postID: postID, reaction: reaction, isRemoving: isRemoving)
        } catch {
            posts[index] = original
        }
    }

    func toggleArchive(postID: Int, shouldArchive: Bool) async {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        let original = posts[index]

        posts[index].archived = shouldArchive
        if shouldArchive {
            posts.remove(at: index)
        }

        do {
            try await apiClient.toggleArchive(postID: postID, shouldArchive: shouldArchive)
        } catch {
            if shouldArchive {
                posts.insert(original, at: min(index, posts.count))
            } else if index < posts.count {
                posts[index] = original
            }
            actionError = error.localizedDescription
        }
    }

    func refreshAfterCreating(postID: Int?) async {
        await refresh()
        guard let postID else { return }
        if posts.contains(where: { $0.id == postID }) { return }

        // Backend can lag briefly after successful posts/add.
        try? await Task.sleep(nanoseconds: 700_000_000)
        await refresh()
    }

    func incrementCommentsCount(postID: Int) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[index].comments = (posts[index].comments ?? 0) + 1
    }

    func ensurePostAvailable(postID: Int) async -> Post? {
        if let existing = posts.first(where: { $0.id == postID }) {
            return existing
        }

        var attempts = 0
        while hasMore && attempts < 40 {
            await loadPosts(reset: false)
            if let found = posts.first(where: { $0.id == postID }) {
                return found
            }
            attempts += 1
        }

        do {
            let post = try await apiClient.loadPost(postID: postID)
            if !posts.contains(where: { $0.id == postID }) {
                posts.insert(post, at: 0)
            }
            state = .loaded
            return post
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func deletePost(postID: Int) async {
        do {
            try await apiClient.deletePost(postID: postID)
            posts.removeAll { $0.id == postID }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func editPost(postID: Int, changes: PostContent.EditChanges) async throws {
        guard !changes.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || changes.hasAttachmentChanges else {
            throw APIError.serverError("Введите текст поста")
        }
        let trimmed = changes.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let editedAt = ISO8601DateFormatter().string(from: Date())
        let original = updatePost(postID: postID) { post in
            post.text = trimmed
            post.editedAt = editedAt
        }

        do {
            let blocks = try await apiClient.editPost(
                postID: postID,
                text: trimmed,
                newFiles: changes.newFiles,
                removedFileIDs: changes.removedFileIDs
            )
            // Web mergeContentBlock: the server returns the FULL updated
            // blocks — replace, never append (null block = type removed).
            updatePost(postID: postID) { post in
                var content = post.content ?? PostContent()
                if blocks.images != nil || changes.hasAttachmentChanges {
                    content.images = blocks.images
                }
                if blocks.files != nil || changes.hasAttachmentChanges {
                    content.files = blocks.files
                }
                post.content = content
            }
        } catch {
            if let original {
                _ = updatePost(postID: postID) { post in
                    post = original
                }
            }
            actionError = error.localizedDescription
            throw error
        }
    }

    func clearActionError() {
        actionError = nil
    }

    private func addOptimisticPost(
        postID: Int?,
        text: String,
        songs: [MusicSong],
        poll: PostPollDraft?,
        fromChannel: ChannelSummary?
    ) {
        guard !text.isEmpty || !songs.isEmpty || poll != nil else { return }
        let id = postID ?? Int(Date().timeIntervalSince1970 * 1000)
        guard !posts.contains(where: { $0.id == id }) else { return }

        let now = ISO8601DateFormatter().string(from: Date())
        let authorOverride = fromChannel.flatMap { channelAuthor(from: $0) }
        let optimistic = Post(
            id: id,
            text: text,
            createDate: now,
            author: authorOverride ?? apiClient.currentAuthorSnapshot(),
            poll: optimisticPoll(from: poll),
            content: songs.isEmpty ? nil : PostContent(images: nil, videos: nil, files: nil, songs: songs)
        )
        posts.insert(optimistic, at: 0)
        state = .loaded
    }

    private func optimisticPoll(from draft: PostPollDraft?) -> PostPoll? {
        guard let draft, draft.isValid else { return nil }
        let options = draft.normalizedOptions.enumerated().map { index, option in
            PostPollOption(id: index + 1, text: option, votesCount: 0)
        }
        return PostPoll(
            id: 0,
            question: draft.normalizedQuestion,
            isAnonymous: draft.isAnonymous,
            multipleChoice: draft.multipleChoice,
            expiresAt: nil,
            totalVotes: 0,
            userVote: [],
            options: options
        )
    }

    private func channelAuthor(from channel: ChannelSummary) -> PostAuthor {
        let avatar = parseAvatar(raw: channel.avatar)
        return PostAuthor(
            id: channel.id,
            type: 1,
            name: channel.name,
            username: channel.username,
            avatar: avatar
        )
    }

    private func parseAvatar(raw: String?) -> PostAuthorAvatar? {
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

    private func updatePost(postID: Int, mutate: (inout Post) -> Void) -> Post? {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return nil }
        let original = posts[index]
        var copy = posts[index]
        mutate(&copy)
        posts[index] = copy
        return original
    }
}
