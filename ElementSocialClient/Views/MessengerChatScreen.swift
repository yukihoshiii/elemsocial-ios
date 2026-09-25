import SwiftUI
import UIKit

struct MessengerChatScreen: View {
    @ObservedObject var viewModel: MessengerViewModel
    let chat: MessengerActiveChat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    @State private var isSearchOpen = false
    @State private var searchQuery = ""
    @State private var isInfoPresented = false
    @State private var menuMessage: MessengerMessage?
    @State private var showCallUnavailable = false
    /// Tracks the bottom of the loaded range to distinguish appends from prepends.
    @State private var lastKnownBottomMessageID: String?

    private var isGroup: Bool { chat.type == 1 }
    private var isFavorites: Bool { viewModel.isFavoritesChat(chat.target) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if isSearchOpen {
                searchBar
            }

            messagesArea

            MessengerBottomBar(
                viewModel: viewModel,
                chatTarget: chat.target,
                isGroup: isGroup
            )
        }
        .background(chatWallpaper.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isInfoPresented) {
            MessengerChatInfoSheet(viewModel: viewModel, chat: chat)
        }
        .overlay {
            if let menuMessage {
                MessageContextMenuOverlay(
                    message: menuMessage,
                    viewModel: viewModel,
                    onDismiss: { self.menuMessage = nil },
                    onReply: {
                        viewModel.replyingToMessage = menuMessage
                        self.menuMessage = nil
                    },
                    onEdit: {
                        viewModel.startEditing(menuMessage)
                        self.menuMessage = nil
                    },
                    onDelete: {
                        Task {
                            await viewModel.deleteMessage(menuMessage)
                        }
                        self.menuMessage = nil
                    }
                )
            }
        }
        .alert(isEnglish ? "Calls" : "Звонки", isPresented: $showCallUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(isEnglish
                 ? "Audio and video calls are not supported in the iOS client yet."
                 : "Аудио- и видеозвонки пока не поддерживаются в iOS-клиенте.")
        }
    }

    // MARK: - Top bar (web TopBar.tsx)

    private var statusText: String? {
        if !isGroup && isFavorites { return nil }
        if viewModel.partnerRecordingVideoCircle {
            return AppLang.tr("записывает видео", "recording video circle", code: selectedLanguageCode)
        }
        if viewModel.partnerRecordingVoice {
            return AppLang.tr("записывает голосовое", "recording voice", code: selectedLanguageCode)
        }
        if viewModel.partnerIsTyping {
            return AppLang.tr("печатает", "typing", code: selectedLanguageCode)
        }
        if isGroup {
            let combined = groupStatusText
            if let combined { return combined }
            if let count = chat.membersCount {
                return "\(count) \(membersPlural(count))"
            }
            return AppLang.tr("Участники", "Members", code: selectedLanguageCode)
        }
        if chat.isOnline {
            return AppLang.tr("в сети", "online", code: selectedLanguageCode)
        }
        return AppLang.tr("не в сети", "offline", code: selectedLanguageCode)
    }

    private var groupStatusText: String? {
        var actions: [String] = []
        let typing = viewModel.groupTypingUsers.values
        let voiceRec = viewModel.groupRecordingVoiceUsers.values
        let videoRec = viewModel.groupRecordingVideoCircleUsers.values

        func join(_ names: [String], action: String) -> String? {
            guard !names.isEmpty else { return nil }
            if names.count == 1 { return "\(names[0]) \(action)" }
            if names.count == 2 { return "\(names[0]) и \(names[1]) \(action)" }
            return "\(names[0]) и ещё \(names.count - 1) \(action)"
        }
        if let s = join(Array(videoRec), action: AppLang.tr("записывает видео", "recording a video", code: selectedLanguageCode)) { actions.append(s) }
        if let s = join(Array(voiceRec), action: AppLang.tr("записывает голосовое", "recording a voice message", code: selectedLanguageCode)) { actions.append(s) }
        if let s = join(Array(typing), action: AppLang.tr("печатает", "is typing", code: selectedLanguageCode)) { actions.append(s) }
        guard !actions.isEmpty else { return nil }
        return actions.joined(separator: ", ")
    }

    private func membersPlural(_ n: Int) -> String {
        let mod100 = n % 100
        let mod10 = n % 10
        if selectedLanguageCode == "en" {
            return n == 1 ? "member" : "members"
        }
        if mod100 > 10 && mod100 < 20 { return "участников" }
        if mod10 > 1 && mod10 < 5 { return "участника" }
        if mod10 == 1 { return "участник" }
        return "участников"
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.closeChat()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)
            }

            Button {
                isInfoPresented = true
            } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        if isFavorites {
                            MessengerSavesAvatarView(size: 38)
                        } else {
                            MessengerAvatarView(media: chat.avatar, name: chat.name, size: 38)
                        }
                        if !isGroup && !isFavorites && chat.isOnline {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(AppTheme.surface, lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isFavorites
                             ? AppLang.key("chat_fav", code: selectedLanguageCode, fallback: isEnglish ? "Favorites" : "Избранное")
                             : chat.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        if let status = statusText, !isFavorites {
                            HStack(spacing: 3) {
                                if activityIndicatorActive {
                                    ForEach(0..<3, id: \.self) { _ in
                                        Circle()
                                            .fill(AppTheme.primary)
                                            .frame(width: 4, height: 4)
                                    }
                                }
                                Text(status)
                                    .font(.system(size: 11))
                                    .foregroundStyle(activityIndicatorActive ? AppTheme.primary : (chat.isOnline || isGroup ? AppTheme.primary : AppTheme.textSecondary))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isSearchOpen {
                        searchQuery = ""
                        viewModel.clearSearch()
                    }
                    isSearchOpen.toggle()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSearchOpen ? AppTheme.primary : AppTheme.textPrimary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(BubblePressButtonStyle())

            if !isFavorites {
                Menu {
                    Button {
                        showCallUnavailable = true
                    } label: {
                        Label(isEnglish ? "Audio call" : "Аудиозвонок", systemImage: "phone")
                    }
                    Button {
                        showCallUnavailable = true
                    } label: {
                        Label(isEnglish ? "Video call" : "Видеозвонок", systemImage: "video")
                    }
                } label: {
                    Image(systemName: "phone")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(BubblePressButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var activityIndicatorActive: Bool {
        viewModel.partnerIsTyping || viewModel.partnerRecordingVoice || viewModel.partnerRecordingVideoCircle ||
        !viewModel.groupTypingUsers.isEmpty || !viewModel.groupRecordingVoiceUsers.isEmpty || !viewModel.groupRecordingVideoCircleUsers.isEmpty
    }

    // MARK: - Search bar (web Chat-SearchBar)

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)

            TextField(AppLang.tr("Поиск", "Search", code: selectedLanguageCode), text: $searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { viewModel.moveSearchResult(direction: 1) }
                .onChange(of: searchQuery) { newValue in
                    viewModel.searchMessages(query: newValue)
                }

            if viewModel.isSearchLoading {
                ProgressView().scaleEffect(0.7)
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                let total = viewModel.searchResults.count
                Text(total > 0 ? "\(viewModel.searchIndex + 1)/\(total)" : "0")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .monospacedDigit()
            }

            Button {
                viewModel.moveSearchResult(direction: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(viewModel.searchResults.isEmpty ? AppTheme.textSecondary : AppTheme.primary)
            }
            .disabled(viewModel.searchResults.isEmpty)

            Button {
                viewModel.moveSearchResult(direction: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(viewModel.searchResults.isEmpty ? AppTheme.textSecondary : AppTheme.primary)
            }
            .disabled(viewModel.searchResults.isEmpty)

            Button {
                searchQuery = ""
                viewModel.clearSearch()
                isSearchOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.surface)
    }

    // MARK: - Wallpaper (web chatWallpaper())

    private var chatWallpaper: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color(red: 0.95, green: 0.95, blue: 0.97))
                .ignoresSafeArea()
            GeometryReader { geo in
                VStack {
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: min(geo.size.width, geo.size.height) * 0.6))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.03))
                        .frame(width: geo.size.width, alignment: .center)
                }
            }
        }
    }

    // MARK: - Messages list (web ChatView.tsx)

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if viewModel.isLoadingMessages, viewModel.messages.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                loadMoreTrigger

                                if viewModel.messages.isEmpty {
                                    emptyChatPlaceholder
                                } else {
                                    groupedMessagesList
                                }

                                Color.clear.frame(height: 8).id("chat-bottom")
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            // Scoped tap-to-dismiss: message bubbles contain no
                            // text inputs, so this can never fight the composer
                            // field and reset its cursor.
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                            )
                        }
                        .opacity(viewModel.isLoadingMessages && viewModel.messages.isEmpty ? 0 : 1)
                    }
                }

            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: viewModel.scrollToBottomToken) { _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: viewModel.highlightMid) { mid in
                guard let mid else { return }
                // The row may not exist yet (jump is still loading pages);
                // the count handler below scrolls once it appears.
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("m-\(mid)", anchor: .center)
                }
            }
            .onChange(of: viewModel.messages.count) { count in
                guard count > 0 else { return }

                // 1) A search/reply jump takes priority once its row exists.
                if let mid = viewModel.highlightMid,
                   viewModel.messages.contains(where: { $0.mid == mid }) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("m-\(mid)", anchor: .center)
                    }
                    return
                }

                // 2) Follow only genuinely NEW messages (append at the end).
                //    Prepending older history pages must not yank the user.
                let newLast = viewModel.messages.last?.id
                if newLast != lastKnownBottomMessageID {
                    let isNewAppend = lastKnownBottomMessageID == nil
                        || viewModel.messages.contains(where: { $0.id == lastKnownBottomMessageID })
                    lastKnownBottomMessageID = newLast
                    if isNewAppend {
                        scrollToBottom(proxy, animated: true)
                    }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            viewModel.pendingNewMessagesCount = 0
        }
    }

    private var loadMoreTrigger: some View {
        Group {
            if viewModel.messages.count >= 25 {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .onAppear {
                        Task { await viewModel.loadMoreMessages() }
                    }
            }
        }
    }

    private var emptyChatPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
            Text(AppLang.key("chat_non_messages", code: selectedLanguageCode,
                             fallback: isEnglish ? "No messages yet. Correspondence is end-to-end encrypted." : "Пока нет сообщений. Переписка защищена сквозным шифрованием."))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// Messages sorted ascending and split into day groups (Сегодня / Вчера / дата).
    private var groupedMessagesList: some View {
        let sorted = viewModel.messages.sorted { parseMessengerDate($0.date) < parseMessengerDate($1.date) }
        return ForEach(messageDayGroups(sorted), id: \.label) { group in
            DaySeparator(label: group.label)
            ForEach(Array(group.messages.enumerated()), id: \.element.id) { index, message in
                let nextSameAuthor = index + 1 < group.messages.count && group.messages[index + 1].uid == message.uid
                MessageRow(
                    message: message,
                    hasTail: !nextSameAuthor,
                    showAvatar: !nextSameAuthor,
                    isGroupChat: isGroup,
                    viewModel: viewModel,
                    highlightMid: viewModel.highlightMid,
                    onLongPress: { menuMessage = message }
                )
                .id(rowID(message))
            }
        }
    }

    private func rowID(_ message: MessengerMessage) -> String {
        if let mid = message.mid { return "m-\(mid)" }
        return "row-" + message.id
    }

    private func newMessagesLabel(_ count: Int) -> String {
        if isEnglish {
            return count == 1 ? "new message" : "new messages"
        }
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14) {
            return "новых сообщения"
        }
        return "новых сообщений"
    }
}

// MARK: - Helpers

struct DaySeparator: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(AppTheme.surface.opacity(0.9)))
            .padding(.vertical, 8)
    }
}

struct MessengerMessageDayGroup {
    let label: String
    let messages: [MessengerMessage]
}

func messageDayGroups(_ messages: [MessengerMessage]) -> [MessengerMessageDayGroup] {
    var order: [String] = []
    var buckets: [String: [MessengerMessage]] = [:]
    let calendar = Calendar.current

    for message in messages {
        let date = parseMessengerDisplayDate(message.date)
        let label: String
        if calendar.isDateInToday(date) {
            label = "Сегодня"
        } else if calendar.isDateInYesterday(date) {
            label = "Вчера"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM"
            label = formatter.string(from: date)
        }
        if buckets[label] == nil {
            order.append(label)
        }
        buckets[label, default: []].append(message)
    }

    return order.map { MessengerMessageDayGroup(label: $0, messages: buckets[$0] ?? []) }
}

func messengerRelativeTime(_ raw: String) -> String {
    let date = parseMessengerDisplayDate(raw)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

func messengerMessageTime(_ raw: String) -> String {
    let date = parseMessengerDisplayDate(raw)
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

extension View {
    func maxLength(_ limit: Int, text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { newValue in
            if newValue.count > limit {
                text.wrappedValue = String(newValue.prefix(limit))
            }
        }
    }
}
