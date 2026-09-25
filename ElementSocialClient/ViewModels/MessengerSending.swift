import Foundation
import UIKit

/// Chunked upload session with cancel support (`sendFile` on the web).
@MainActor
final class UploadSession: ObservableObject {
    let tempMid: Int
    private let api: APIClient
    @Published var progress: Double = 0
    private var cancelled = false
    /// Percent (0...100) callback for UI updates.
    var onProgress: ((Double) -> Void)?

    init(tempMid: Int, api: APIClient) {
        self.tempMid = tempMid
        self.api = api
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        Task {
            try? await api.stopMessengerUpload(tempMid: tempMid)
        }
    }

    func run(data: Data) async throws {
        let chunkSize = 10 * 1024
        let totalChunks = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))

        for chunkIndex in 0..<totalChunks {
            if cancelled || Task.isCancelled { throw CancellationError() }

            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, data.count)
            let chunkData = data.subdata(in: start..<end)

            try await api.sendMap(payloadMap: [
                "type": .string("messenger"),
                "action": .string("upload_file"),
                "temp_mid": .int(Int64(tempMid)),
                "current_chunk": .int(Int64(chunkIndex)),
                "total_chunks": .int(Int64(totalChunks)),
                "binary": .binary(chunkData)
            ])

            progress = Double(chunkIndex + 1) / Double(totalChunks) * 100.0
            onProgress?(progress)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

// MARK: - Text / reply / edit / delete / reactions

extension MessengerViewModel {

    func makeTempMid() -> Int {
        while true {
            var id = ""
            for _ in 0..<10 { id += String(Int.random(in: 0...9)) }
            let value = Int(id) ?? Int.random(in: 100_000_000...999_999_999)
            if !messages.contains(where: { $0.tempMid == value }) && uploadSessions[value] == nil {
                return value
            }
        }
    }

    func buildReplyContent(from message: MessengerMessage) -> MessengerReplyTo {
        MessengerReplyTo(
            mid: message.mid,
            author: message.isOutgoing ? "Вы" : (message.author?.name ?? "Пользователь"),
            text: message.content?.replyPreviewText ?? "",
            type: message.content?.type ?? "text"
        )
    }

    func optimisticMessage(
        tempMid: Int,
        content: MessengerMessageContent,
        date: Date = Date()
    ) -> MessengerMessage {
        MessengerMessage(
            mid: nil,
            tempMid: tempMid,
            uid: api.currentUserIDSnapshot() ?? 0,
            author: nil,
            content: content,
            date: ISO8601DateFormatter().string(from: date),
            isOutgoing: true,
            status: "not_sent",
            reactions: [:]
        )
    }

    func appendOptimistic(_ message: MessengerMessage) {
        messages.append(message)
        messages.sort { parseMessengerDate($0.date) < parseMessengerDate($1.date) }
        scrollToBottomToken += 1
        storeToCache()
    }

    func removeOptimistic(tempMid: Int) {
        messages.removeAll { $0.tempMid == tempMid }
        storeToCache()
    }

    /// Sends composer text (regular or reply). Handles the edit flow too.
    func sendMessage() async {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chat = activeChat else { return }
        guard !text.isEmpty || editingMessage != nil else { return }

        // ---- Edit flow ----
        if let editing = editingMessage, let mid = editing.mid {
            guard !text.isEmpty else { return }
            composeText = ""
            let previous = editingMessage
            editingMessage = nil
            do {
                let result = try await api.editMessengerMessage(
                    mid: mid,
                    target: chat.target,
                    text: text,
                    keyword: keyword ?? ""
                )
                applyEditedContent(mid: mid, newContent: result.content, fallbackText: text)
                if let lastMessage = result.lastMessage {
                    updateChatPreview(chat.target, lastMessage: lastMessage, date: result.lastMessageDate)
                }
                storeToCache()
            } catch {
                errorMessage = error.localizedDescription
                editingMessage = previous
                composeText = text
            }
            return
        }

        // ---- Regular / reply send ----
        let replyTo = replyingToMessage
        replyingToMessage = nil
        let tempMid = makeTempMid()
        let contentReply: MessengerReplyTo? = replyTo.map { buildReplyContent(from: $0) }

        var payload: [String: MessagePackValue] = [
            "type": .string("messenger"),
            "action": .string("send_message"),
            "temp_mid": .int(Int64(tempMid)),
            "target": messengerTargetValue(chat),
            "message": .string(text)
        ]
        if let replyTo {
            var replyPayload: [String: MessagePackValue] = [:]
            replyPayload["mid"] = .int(Int64(replyTo.mid ?? 0))
            replyPayload["author"] = .string(contentReply?.author ?? "")
            replyPayload["text"] = .string(contentReply?.text ?? "")
            replyPayload["type"] = .string(contentReply?.type ?? "text")
            payload["reply_to"] = .map(replyPayload)
        }

        appendOptimistic(
            optimisticMessage(
                tempMid: tempMid,
                content: MessengerMessageContent(text: text, type: "text", replyTo: contentReply)
            )
        )
        composeText = ""
        updateChatPreview(chat.target, lastMessage: text, date: nil)

        do {
            let response = try await api.requestMap(payloadMap: payload)
            handleSendResponse(response, tempMid: tempMid)
        } catch is CancellationError {
            removeOptimistic(tempMid: tempMid)
        } catch {
            removeOptimistic(tempMid: tempMid)
            errorMessage = error.localizedDescription
        }
    }

    /// Handles the direct reply to `send_message`:
    /// `awaiting_file` → begin chunked upload; `sended` → attach real mid.
    func handleSendResponse(_ response: [String: MessagePackValue], tempMid: Int, chat: MessengerActiveChat? = nil) {
        let status = (responseStatus(response)).lowercased()
        switch status {
        case "awaiting_file":
            if let index = messages.firstIndex(where: { $0.tempMid == tempMid }) {
                messages[index].status = "not_sent"
                messages[index].uploadProgress = 0
            }
        case "error":
            removeOptimistic(tempMid: tempMid)
            errorMessage = responseStringValue(response["text"])
                ?? responseStringValue(response["message"])
                ?? "Не удалось отправить сообщение"
        default:
            // "sended" or similar — attach the assigned mid (cache-aware:
            // the user may have left the chat while the request was in flight).
            let mid = intValue(response["mid"])
            if let index = messages.firstIndex(where: { $0.tempMid == tempMid }) {
                messages[index] = messages[index].withStatus("sended", mid: mid)
                storeToCache()
            } else if let chat {
                updateCachedMessage(target: chat.target, tempMid: tempMid) { msg in
                    msg.withStatus("sended", mid: mid)
                }
            }
        }
    }

    private func responseStatus(_ response: [String: MessagePackValue]) -> String {
        responseStringValue(response["status"]) ?? ""
    }

    private func responseStringValue(_ value: MessagePackValue?) -> String? {
        switch value {
        case .string(let s): return s
        default: return nil
        }
    }

    private func intValue(_ value: MessagePackValue?) -> Int? {
        switch value {
        case .int(let i): return Int(i)
        case .uint(let u): return Int(u)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private func applyEditedContent(mid: Int, newContent: MessengerMessageContent?, fallbackText: String) {
        guard let index = messages.firstIndex(where: { $0.mid == mid }) else { return }
        var updated = messages[index]
        let base = newContent ?? updated.content ?? MessengerMessageContent(text: fallbackText, type: "text")
        updated.content = base.withEditedFlag(true)
        messages[index] = updated
    }

    func startEditing(_ message: MessengerMessage) {
        guard message.content?.type == "text", message.isOutgoing, message.status != "not_sent" else { return }
        replyingToMessage = nil
        editingMessage = message
        composeText = message.content?.text ?? ""
    }

    func cancelReplyOrEdit() {
        replyingToMessage = nil
        editingMessage = nil
        composeText = ""
    }

    // MARK: Delete

    func deleteMessage(_ message: MessengerMessage) async {
        guard let mid = message.mid, let chat = activeChat else { return }
        messages.removeAll { $0.mid == mid }
        storeToCache()
        do {
            _ = try await api.requestMap(payloadMap: [
                "type": .string("messenger"),
                "action": .string("delete_message"),
                "mid": .int(Int64(mid)),
                "target": messengerTargetValue(chat)
            ])
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Reactions

    func toggleReaction(_ message: MessengerMessage, emoji: String) async {
        guard let mid = message.mid, let chat = activeChat else { return }
        let myID = api.currentUserIDSnapshot() ?? 0

        if let index = messages.firstIndex(where: { $0.mid == mid }) {
            var msg = messages[index]
            var users = msg.reactions[emoji] ?? []
            if let mineIndex = users.firstIndex(where: { $0.uid == myID }) {
                users.remove(at: mineIndex)
                if users.isEmpty {
                    msg.reactions.removeValue(forKey: emoji)
                } else {
                    msg.reactions[emoji] = users
                }
            } else {
                users.append(MessengerReactionUser(uid: myID, name: "Вы", avatar: nil, date: nil))
                msg.reactions[emoji] = users
            }
            messages[index] = msg
            storeToCache()
        }

        do {
            try await api.sendMap(payloadMap: [
                "type": .string("messenger"),
                "action": .string("react_message"),
                "mid": .int(Int64(mid)),
                "emoji": .string(emoji),
                "target": messengerTargetValue(chat)
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Groups

    func createGroup(name: String, avatarData: Data?) async -> Bool {
        isLoadingChats = true
        defer { isLoadingChats = false }
        do {
            _ = try await api.createMessengerGroup(name: name, avatarData: avatarData)
            await reloadChats()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadGroupMembers(gid: Int) async -> [MessengerGroupMember] {
        do {
            return try await api.loadMessengerGroupMembers(gid: gid)
        } catch {
            return []
        }
    }

    func regenerateGroupLink() async {
        guard let chat = activeChat else { return }
        do {
            let link = try await api.generateMessengerGroupLink(gid: chat.target.id)
            var updated = chat
            updated.joinLink = link
            activeChat = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension MessengerMessageContent {
    func withEditedFlag(_ edited: Bool) -> MessengerMessageContent {
        MessengerMessageContent(
            text: text,
            type: type,
            replyTo: replyTo,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            previewBase64: previewBase64,
            fileBase64: fileBase64,
            fileMap: fileMap,
            encryptedKey: encryptedKey,
            encryptedIV: encryptedIV,
            waveform: waveform,
            duration: duration,
            isVideoCircle: isVideoCircle,
            thumbnailBase64: thumbnailBase64,
            isEdited: edited,
            isError: isError
        )
    }
}
