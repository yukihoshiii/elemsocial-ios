import Foundation
import AVFoundation
import UIKit

struct OutgoingAttachment {
    let name: String
    let mimeType: String
    let data: Data
}

@MainActor
final class MessengerViewModel: ObservableObject {
    // MARK: - Published state

    @Published var chats: [MessengerChatSummary] = []
    @Published var activeChat: MessengerActiveChat?
    @Published var messages: [MessengerMessage] = []
    @Published var isKeywordReady = false
    @Published var isLoadingChats = false
    @Published var isLoadingMessages = false
    @Published var unreadTotal: Int = 0

    @Published var passphrase = ""
    @Published var composeText = ""
    @Published var errorMessage: String?
    @Published var replyingToMessage: MessengerMessage?
    @Published var editingMessage: MessengerMessage?

    /// Partner activity indicators (DM).
    @Published var partnerIsTyping = false
    @Published var partnerRecordingVoice = false
    @Published var partnerRecordingVideoCircle = false
    /// Group activity: uid → name.
    @Published var groupTypingUsers: [Int: String] = [:]
    @Published var groupRecordingVoiceUsers: [Int: String] = [:]
    @Published var groupRecordingVideoCircleUsers: [Int: String] = [:]

    // Search inside chat.
    @Published var searchResults: [APIClient.MessengerSearchResult] = []
    @Published var searchIndex = 0
    @Published var isSearchLoading = false

    /// Message id that should flash-highlight after a search/reply jump.
    @Published var highlightMid: Int?
    /// Bump whenever the list should scroll to bottom.
    @Published var scrollToBottomToken = 0
    /// New messages arrived while the user is scrolled up ("↓ N новых сообщений").
    @Published var pendingNewMessagesCount = 0

    // MARK: - Private state

    var keyword: String?
    var messagesStartIndex = 25
    var messagesLoaded = false
    let api = APIClient.shared

    /// Per-chat message caches (`state.chats[type][id].messages` on the web).
    var messageCache: [String: (messages: [MessengerMessage], loaded: Bool)] = [:]

    /// Active chunked uploads keyed by temp_mid.
    var uploadSessions: [Int: UploadSession] = [:]
    /// Attachment fetch progress per mid (0...1; -1 = error).
    var attachmentProgress: [Int: Double] = [:]

    var lastTypingSentAt = Date.distantPast
    var indicatorResetTasks: [String: Task<Void, Never>] = [:]
    var searchDebounceTask: Task<Void, Never>?

    init() {
        if let stored = api.storedMessengerKeyword(), !stored.isEmpty {
            keyword = stored
            isKeywordReady = true
        }
        unreadTotal = api.currentUserMessengerNotificationsSnapshot()
        MessengerPushCenter.shared.handler = { [weak self] kind in
            self?.handlePush(kind)
        }

        // Account switched elsewhere (accounts menu / re-login) — drop all
        // cached per-account state and go through the keyword gate again.
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: APIClient.accountDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resetForAccountChange()
            }
        }
    }

    private var accountChangeObserver: NSObjectProtocol?

    /// Clears everything tied to the previous account.
    func resetForAccountChange() {
        for (_, session) in uploadSessions { session.cancel() }
        uploadSessions.removeAll()
        attachmentProgress.removeAll()

        activeChat = nil
        messages = []
        messagesLoaded = false
        messagesStartIndex = 25
        messageCache.removeAll()
        chats = []
        unreadTotal = 0

        composeText = ""
        replyingToMessage = nil
        editingMessage = nil
        highlightMid = nil
        pendingNewMessagesCount = 0
        clearSearch()
        resetActivityIndicators()
        searchDebounceTask?.cancel()

        // The messenger keyword is validated per-account on the server;
        // force the gate so the user confirms the phrase for this account.
        keyword = nil
        isKeywordReady = false
        passphrase = ""

        Task { await bootstrap() }
    }

    var messengerBadgeText: String? {
        guard unreadTotal > 0 else { return nil }
        return unreadTotal > 99 ? "99+" : "\(unreadTotal)"
    }

    func isFavoritesChat(_ target: MessengerChatTarget) -> Bool {
        target.type == 0 && target.id == (api.currentUserIDSnapshot() ?? -1)
    }

    var currentKeyword: String? { keyword }

    func requestScrollToBottom() {
        scrollToBottomToken += 1
        pendingNewMessagesCount = 0
    }

    // MARK: - Keyword gate

    func bootstrap() async {
        errorMessage = nil
        do {
            try await api.restoreMessengerKeywordIfNeeded()
            if let stored = api.storedMessengerKeyword(), !stored.isEmpty {
                keyword = stored
                isKeywordReady = true
            }
            if isKeywordReady {
                await reloadChats()
            }
        } catch is CancellationError {
            return
        } catch {
            // Stored keyword rejected by the server — force the passphrase gate
            // so the user can enter the correct one (same as the web alert).
            keyword = nil
            isKeywordReady = false
            errorMessage = error.localizedDescription
        }
    }

    func submitKeyword() async {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Введите ключевую фразу"
            return
        }
        isLoadingChats = true
        errorMessage = nil
        defer { isLoadingChats = false }
        do {
            let serverKeyword = try await api.submitMessengerKeyword(passphrase: trimmed)
            keyword = serverKeyword
            isKeywordReady = true
            passphrase = ""
            await reloadChats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAllChats() async {
        do {
            try await api.deleteAllMessengerChats()
            chats.removeAll()
            messageCache.removeAll()
            if activeChat != nil {
                closeChat()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Join group by link (`/join/:link`, web JoinGroup.tsx)

    enum JoinGroupState {
        case loading
        case preview(MessengerActiveChat)
        case joined(groupTarget: MessengerChatTarget)
    }

    @Published var joinGroupState: JoinGroupState?
    @Published var isJoiningGroup = false
    /// Link code of the group currently being previewed/joined.
    private var activeJoinCode: String?

    /// Pending deep link (`elemsocial.com/join/:code`) captured before the
    /// messenger tab existed.
    static let pendingJoinLinkKey = "messenger_pending_join_link"
    /// Fired when the app is asked to open a join link while running.
    static let openJoinLinkNotification = Notification.Name("MessengerOpenJoinLink")

    static func storePendingJoinLink(_ code: String) {
        UserDefaults.standard.set(code, forKey: pendingJoinLinkKey)
    }

    static func takePendingJoinLink() -> String? {
        let key = pendingJoinLinkKey
        guard let code = UserDefaults.standard.string(forKey: key), !code.isEmpty else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return code
    }

    /// Accepts a raw code or a full `elemsocial.com/join/…` URL.
    func beginJoinGroup(rawInput: String) {
        let code = Self.extractJoinCode(from: rawInput)
        guard !code.isEmpty else {
            errorMessage = "Некорректная ссылка"
            return
        }
        activeJoinCode = code
        joinGroupState = .loading
        Task {
            do {
                let group = try await api.loadMessengerGroup(link: code)
                joinGroupState = .preview(group)
            } catch {
                errorMessage = error.localizedDescription
                joinGroupState = nil
            }
        }
    }

    func confirmJoinGroup() async {
        guard case .preview(let group) = joinGroupState, let code = activeJoinCode else { return }
        isJoiningGroup = true
        defer { isJoiningGroup = false }
        do {
            // Web navigates to /chat/t1i{group.id} using the PREVIEW id —
            // the join response itself is not relied upon.
            _ = try await api.joinMessengerGroup(link: code)
            await reloadChats()
            let target: MessengerChatTarget
            if let summary = chats.first(where: { $0.target.type == 1 && $0.target.id == group.target.id }) {
                target = summary.target
            } else {
                target = group.target
            }
            joinGroupState = .joined(groupTarget: target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func finishJoinGroup() -> MessengerChatTarget? {
        defer { joinGroupState = nil }
        if case .joined(let target) = joinGroupState {
            return target
        }
        return nil
    }

    static func extractJoinCode(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), let host = url.host?.lowercased(), host.contains("elemsocial") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, parts[0].lowercased() == "join" {
                return parts[1]
            }
        }
        // Bare code or trailing-slash link pasted without scheme.
        if let idx = trimmed.range(of: "/join/") {
            let tail = String(trimmed[idx.upperBound...])
            return tail.split(separator: "/").first.map(String.init) ?? tail
        }
        return trimmed
    }

    // MARK: - Chat list

    func reloadChats() async {
        guard isKeywordReady else { return }
        isLoadingChats = true
        errorMessage = nil
        defer { isLoadingChats = false }
        do {
            let loaded = try await api.loadMessengerChats()
            chats = loaded.sorted(by: sortChats)
            unreadTotal = chats.reduce(0) { $0 + $1.unreadCount }
            api.setMessengerNotificationsCount(unreadTotal)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sortChats(_ lhs: MessengerChatSummary, _ rhs: MessengerChatSummary) -> Bool {
        parseMessengerDate(lhs.lastMessageDate) > parseMessengerDate(rhs.lastMessageDate)
    }

    // MARK: - Open / close chat

    /// Updates a message in the per-chat cache regardless of which chat is
    /// open (web Redux keys updates by chat_id/chat_type). Falls through to
    /// the live array when the target chat is active.
    func updateCachedMessage(
        target: MessengerChatTarget,
        tempMid: Int,
        transform: (MessengerMessage) -> MessengerMessage
    ) {
        if var cached = messageCache[target.cacheKey]?.messages {
            if let idx = cached.firstIndex(where: { $0.tempMid == tempMid }) {
                cached[idx] = transform(cached[idx])
                messageCache[target.cacheKey]?.messages = cached
            }
        }
        if activeChat?.target == target,
           let idx = messages.firstIndex(where: { $0.tempMid == tempMid }) {
            messages[idx] = transform(messages[idx])
        }
    }

    func openChat(_ summary: MessengerChatSummary) async {
        errorMessage = nil
        clearSearch()
        let cacheKey = summary.target.cacheKey
        var cached = messageCache[cacheKey]?.messages ?? []
        // Drop optimistic bubbles whose upload died with the chat — the
        // server list is the source of truth on reopen.
        cached.removeAll { msg in
            msg.status == "not_sent" && msg.mid == nil &&
            (msg.tempMid.flatMap { uploadSessions[$0] } == nil)
        }
        if messageCache[cacheKey] != nil {
            messageCache[cacheKey]?.messages = cached
        }
        messages = cached
        messagesLoaded = messageCache[cacheKey]?.loaded ?? false
        resetActivityIndicators()

        if !messagesLoaded {
            isLoadingMessages = true
        }
        defer { isLoadingMessages = false }

        do {
            let chat = try await api.loadMessengerChat(target: summary.target)
            activeChat = chat
            if !messagesLoaded {
                let loaded = try await api.loadMessengerMessages(target: chat.target, keyword: keyword ?? "")
                messages = sortMessages(loaded)
                messagesLoaded = true
                messagesStartIndex = max(messages.count, 25)
                messageCache[cacheKey] = (messages, true)
            } else {
                messagesStartIndex = max(messages.count, 25)
            }
            scrollToBottomToken += 1
            pendingNewMessagesCount = 0
            await markChatViewed(target: chat.target)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeChat() {
        if let chat = activeChat {
            messageCache[chat.target.cacheKey] = (messages, messagesLoaded)
        }
        activeChat = nil
        messages = []
        messagesLoaded = false
        composeText = ""
        replyingToMessage = nil
        editingMessage = nil
        clearSearch()
        highlightMid = nil
        pendingNewMessagesCount = 0
    }

    func loadMoreMessages() async {
        guard let keyword, let chat = activeChat, messagesLoaded else { return }
        let startIndex = messagesStartIndex
        do {
            let older = try await api.loadMessengerMessages(
                target: chat.target,
                keyword: keyword,
                startIndex: startIndex
            )
            guard !older.isEmpty else { return }
            messagesStartIndex = startIndex + 25
            messages = sortMessages(messages + older)
            messageCache[chat.target.cacheKey] = (messages, true)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Viewed / unread

    func markChatViewed(target: MessengerChatTarget) async {
        try? await api.markMessengerMessagesViewed(target: target)
        setUnread(for: target, count: 0)
    }

    private func setUnread(for target: MessengerChatTarget, count: Int) {
        if let index = chats.firstIndex(where: { $0.target == target }) {
            chats[index].unreadCount = count
        }
        unreadTotal = chats.reduce(0) { $0 + $1.unreadCount }
        api.setMessengerNotificationsCount(unreadTotal)
    }

    func markMyMessagesRead() {
        for i in messages.indices where messages[i].isOutgoing && !messages[i].isRead {
            messages[i].isRead = true
        }
    }

    // MARK: - Message list helpers

    private func deduplicateMessages(_ items: [MessengerMessage]) -> [MessengerMessage] {
        var seenMids = Set<Int>()
        var seenTempMids = Set<Int>()
        var result: [MessengerMessage] = []
        for msg in items {
            if let mid = msg.mid {
                if !seenMids.contains(mid) {
                    seenMids.insert(mid)
                    result.append(msg)
                }
            } else if let tempMid = msg.tempMid {
                if !seenTempMids.contains(tempMid) {
                    seenTempMids.insert(tempMid)
                    result.append(msg)
                }
            } else {
                result.append(msg)
            }
        }
        return result
    }

    func sortMessages(_ items: [MessengerMessage]) -> [MessengerMessage] {
        deduplicateMessages(items).sorted {
            parseMessengerDate($0.date) < parseMessengerDate($1.date)
        }
    }

    func updateChatPreview(_ target: MessengerChatTarget, lastMessage: String, date: String?) {
        guard let index = chats.firstIndex(where: { $0.target == target }) else { return }
        chats[index].lastMessage = lastMessage
        chats[index].lastMessageDate = date ?? ISO8601DateFormatter().string(from: Date())
        chats.sort(by: sortChats)
    }

    func storeToCache() {
        guard let chat = activeChat else { return }
        messageCache[chat.target.cacheKey] = (messages, messagesLoaded)
    }
}

// MARK: - Date parsing

func parseMessengerDate(_ raw: String) -> Date {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = Double(trimmed) {
        let seconds = value > 9_999_999_999 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: trimmed) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: trimmed) ?? .distantPast
}
