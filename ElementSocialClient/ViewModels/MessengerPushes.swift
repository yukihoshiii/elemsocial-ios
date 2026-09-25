import Foundation

extension MessengerViewModel {

    // MARK: - Push handling (web: useMessengerEvent handlers in Chat.tsx)

    func handlePush(_ kind: MessengerPushKind) {
        switch kind {
        case .newMessage(let message, let target):
            handleNewMessage(message, target: target)

        case .messageEdited(let mid, let target, let content, let lastMessage, let lastMessageDate):
            if activeChat?.target == target {
                if let index = messages.firstIndex(where: { $0.mid == mid }) {
                    var updated = messages[index]
                    if let content {
                        updated.content = content.withEditedFlag(true)
                    } else {
                        updated.content = updated.content?.withEditedFlag(true)
                    }
                    messages[index] = updated
                    storeToCache()
                }
            }
            if let lastMessage {
                updateChatPreview(target, lastMessage: lastMessage, date: lastMessageDate)
            }

        case .messageDeleted(let mid, let target, let lastMessage, let lastMessageDate):
            if activeChat?.target == target {
                messages.removeAll { $0.mid == mid }
                storeToCache()
            }
            if let lastMessage {
                updateChatPreview(target, lastMessage: lastMessage, date: lastMessageDate)
            }

        case .messageReaction(let mid, let target, let emoji, let uid, let name, let avatar, let isRemove):
            guard activeChat?.target == target,
                  let index = messages.firstIndex(where: { $0.mid == mid }) else { return }
            var msg = messages[index]
            var users = msg.reactions[emoji] ?? []
            if isRemove {
                users.removeAll { $0.uid == uid }
                if users.isEmpty {
                    msg.reactions.removeValue(forKey: emoji)
                } else {
                    msg.reactions[emoji] = users
                }
            } else if !users.contains(where: { $0.uid == uid }) {
                users.append(MessengerReactionUser(
                    uid: uid,
                    name: name ?? "...",
                    avatar: avatar,
                    date: ISO8601DateFormatter().string(from: Date())
                ))
                msg.reactions[emoji] = users
            }
            messages[index] = msg
            storeToCache()

        case .messagesRead(let target):
            guard activeChat?.target == target else { return }
            markMyMessagesRead()
            storeToCache()

        case .typing(let target, let uid, let authorName):
            guard activeChat?.target == target, uid != api.currentUserIDSnapshot() else { return }
            setIndicator(\.partnerIsTyping, group: \.groupTypingUsers, uid: uid, name: authorName, active: true, timeout: 3)

        case .recordingVoice(let target, let uid, let authorName, let stop):
            guard activeChat?.target == target, uid != api.currentUserIDSnapshot() else { return }
            setIndicator(\.partnerRecordingVoice, group: \.groupRecordingVoiceUsers, uid: uid, name: authorName, active: !stop, timeout: stop ? 0 : 60)

        case .recordingVideoCircle(let target, let uid, let authorName, let stop):
            guard activeChat?.target == target, uid != api.currentUserIDSnapshot() else { return }
            setIndicator(\.partnerRecordingVideoCircle, group: \.groupRecordingVideoCircleUsers, uid: uid, name: authorName, active: !stop, timeout: stop ? 0 : 60)

        case .sendMessageStatus(let tempMid, let status, let mid, let errorText):
            handleSendStatus(tempMid: tempMid, status: status, mid: mid, errorText: errorText)

        case .uploadComplete(let tempMid, let mid, let target):
            updateCachedMessage(target: target, tempMid: tempMid) { msg in
                msg.withStatus("sended", mid: mid)
            }

        case .reloadChats:
            Task { await reloadChats() }
        }
    }

    private func handleNewMessage(_ message: MessengerMessage, target: MessengerChatTarget) {
        // Update the chat list row.
        if chats.contains(where: { $0.target == target }) {
            let isActive = activeChat?.target == target
            if let index = chats.firstIndex(where: { $0.target == target }), !isActive {
                chats[index].unreadCount += 1
            }
            updateChatPreview(
                target,
                lastMessage: message.content?.replyPreviewText ?? "",
                date: message.date
            )
            unreadTotal = chats.reduce(0) { $0 + $1.unreadCount }
            api.setMessengerNotificationsCount(unreadTotal)
        } else {
            Task { await reloadChats() }
        }

        // Append to the open chat.
        guard activeChat?.target == target else { return }
        if message.isOutgoing {
            // Echo of our own optimistic send — match by temp_mid first
            // (empty-text attachments would otherwise cross-merge).
            if let echoTemp = message.tempMid,
               let idx = messages.firstIndex(where: { $0.tempMid == echoTemp }) {
                messages[idx] = messages[idx].withStatus("sended", mid: message.mid)
                storeToCache()
                return
            }
            if message.content?.type == "text",
               let idx = messages.firstIndex(where: { $0.mid == nil && $0.tempMid != nil && $0.content?.text == message.content?.text }) {
                messages[idx] = messages[idx].withStatus("sended", mid: message.mid)
                storeToCache()
                return
            }
        }

        let alreadyThere = messages.contains { msg in
            (message.mid != nil && msg.mid == message.mid) ||
            (message.tempMid != nil && msg.tempMid == message.tempMid)
        }
        if !alreadyThere {
            messages.append(message)
            messages.sort { parseMessengerDate($0.date) < parseMessengerDate($1.date) }
            pendingNewMessagesCount += 1
            storeToCache()
        }
        Task { await markChatViewed(target: target) }
    }

    private func handleSendStatus(tempMid: Int, status: String, mid: Int?, errorText: String?) {
        switch status.lowercased() {
        case "sended":
            if let index = messages.firstIndex(where: { $0.tempMid == tempMid }) {
                messages[index] = messages[index].withStatus("sended", mid: mid)
                storeToCache()
            } else if let target = activeChat?.target {
                updateCachedMessage(target: target, tempMid: tempMid) { msg in
                    msg.withStatus("sended", mid: mid)
                }
            }
        case "error":
            removeOptimistic(tempMid: tempMid)
            errorMessage = errorText ?? "Не удалось отправить сообщение"
        default:
            break
        }
    }

    // MARK: - Activity indicators (typing / recording)

    private func setIndicator(
        _ single: ReferenceWritableKeyPath<MessengerViewModel, Bool>,
        group: ReferenceWritableKeyPath<MessengerViewModel, [Int: String]>,
        uid: Int,
        name: String?,
        active: Bool,
        timeout: TimeInterval
    ) {
        let isGroup = activeChat?.type == 1
        if isGroup {
            var map = self[keyPath: group]
            if active {
                map[uid] = name ?? "..."
            } else {
                map.removeValue(forKey: uid)
            }
            self[keyPath: group] = map
        } else {
            self[keyPath: single] = active
        }

        indicatorResetTasks["\(uid)_\(group)"]?.cancel()
        if active && timeout > 0 {
            indicatorResetTasks["\(uid)_\(group)"] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.activeChat != nil else { return }
                    if isGroup {
                        var map = self[keyPath: group]
                        map.removeValue(forKey: uid)
                        self[keyPath: group] = map
                    } else {
                        self[keyPath: single] = false
                    }
                }
            }
        }
    }

    func resetActivityIndicators() {
        partnerIsTyping = false
        partnerRecordingVoice = false
        partnerRecordingVideoCircle = false
        groupTypingUsers.removeAll()
        groupRecordingVoiceUsers.removeAll()
        groupRecordingVideoCircleUsers.removeAll()
        for (_, task) in indicatorResetTasks { task.cancel() }
        indicatorResetTasks.removeAll()
    }

    /// Typing notification with a 2s throttle while the user keeps typing.
    func notifyTyping() {
        guard let chat = activeChat else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTypingSentAt) >= 2 else { return }
        lastTypingSentAt = now
        Task {
            try? await api.sendMessengerTyping(target: chat.target)
        }
    }

    func notifyRecordingChange(videoCircle: Bool, stop: Bool) {
        guard let chat = activeChat else { return }
        Task {
            try? await api.sendMessengerRecording(target: chat.target, videoCircle: videoCircle, stop: stop)
        }
    }

    // MARK: - Search inside chat (`search_messages` + jump & highlight)

    func searchMessages(query rawQuery: String) {
        searchDebounceTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let chat = activeChat else {
            searchResults = []
            searchIndex = 0
            isSearchLoading = false
            return
        }

        isSearchLoading = true
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                let results = try await self.api.searchMessengerMessages(target: chat.target, value: query)
                guard !Task.isCancelled else { return }
                self.searchResults = results
                self.searchIndex = 0
                self.isSearchLoading = false
                if let first = results.first {
                    await self.jumpToMessage(mid: first.mid, startIndex: first.startIndex)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.searchResults = []
                self.isSearchLoading = false
            }
        }
    }

    func moveSearchResult(direction: Int) {
        guard !searchResults.isEmpty else { return }
        let next = (searchIndex + direction + searchResults.count) % searchResults.count
        searchIndex = next
        let item = searchResults[next]
        Task {
            await jumpToMessage(mid: item.mid, startIndex: item.startIndex)
        }
    }

    func clearSearch() {
        searchDebounceTask?.cancel()
        searchResults = []
        searchIndex = 0
        isSearchLoading = false
    }

    /// Loads pages until `mid` is present, then highlights it.
    /// Web parity: fetch pages into the store WITHOUT touching the global
    /// `messagesStartIndex` cursor — overlap is resolved by dedup.
    func jumpToMessage(mid: Int, startIndex: Int?) async {
        guard let keyword, let chat = activeChat else { return }
        highlightMid = mid

        if messages.contains(where: { $0.mid == mid }) {
            objectWillChange.send()
            clearHighlightAfterDelay()
            return
        }

        var attempts = 0
        var pageStart = startIndex ?? max(0, messages.count - 25)

        while attempts < 12 {
            attempts += 1
            do {
                let page = try await api.loadMessengerMessages(
                    target: chat.target,
                    keyword: keyword,
                    startIndex: max(0, pageStart)
                )
                guard !page.isEmpty else { break }
                messages = sortMessages(messages + page)
                messageCache[chat.target.cacheKey] = (messages, true)
                objectWillChange.send()

                if messages.contains(where: { $0.mid == mid }) {
                    break
                }
                if pageStart <= 0 { break }
                pageStart -= 25
            } catch {
                break
            }
        }
        clearHighlightAfterDelay()
    }

    private func clearHighlightAfterDelay() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { [weak self] in
                self?.highlightMid = nil
            }
        }
    }
}
