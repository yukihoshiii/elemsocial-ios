import Foundation
import UIKit

extension MessengerViewModel {

    // MARK: - Files / images

    /// Web behavior: the first file goes out with typed text,
    /// every following file becomes its own text-less message.
    func sendFiles(_ files: [OutgoingAttachment]) async {
        guard let chat = activeChat, !files.isEmpty else { return }
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        for (index, file) in files.enumerated() {
            await sendSingleFile(chat: chat, attachment: file, text: index == 0 ? text : "")
        }
        composeText = ""
        replyingToMessage = nil
        updateChatPreview(chat.target, lastMessage: previewFor(files[0]), date: nil)
    }

    private func previewFor(_ file: OutgoingAttachment) -> String {
        file.mimeType.hasPrefix("image/") ? "Фото" : file.name
    }

    private func sendSingleFile(chat: MessengerActiveChat, attachment: OutgoingAttachment, text: String) async {
        let tempMid = makeTempMid()
        let isImage = attachment.mimeType.hasPrefix("image/")

        var content: MessengerMessageContent
        if isImage {
            content = MessengerMessageContent(
                text: text,
                type: "image",
                fileName: attachment.name,
                fileSize: Int64(attachment.data.count),
                mimeType: attachment.mimeType,
                previewBase64: "data:image/jpeg;base64," + attachment.data.base64EncodedString()
            )
        } else {
            content = MessengerMessageContent(
                text: text,
                type: "file",
                fileName: attachment.name,
                fileSize: Int64(attachment.data.count),
                mimeType: attachment.mimeType
            )
        }

        appendOptimistic(optimisticMessage(tempMid: tempMid, content: content).withLocalImageData(isImage ? attachment.data : nil))

        let payload: [String: MessagePackValue] = [
            "type": .string("messenger"),
            "action": .string("send_message"),
            "temp_mid": .int(Int64(tempMid)),
            "target": messengerTargetValue(chat),
            "message": .string(text),
            "files": .array([
                .map([
                    "name": .string(attachment.name),
                    "type": .string(attachment.mimeType),
                    "size": .int(Int64(attachment.data.count))
                ])
            ])
        ]
        do {
            let response = try await api.requestMap(payloadMap: payload)
            handleSendResponse(response, tempMid: tempMid, chat: chat)
            beginUploadIfAwaiting(response, tempMid: tempMid, data: attachment.data, chat: chat)
        } catch is CancellationError {
            removeOptimistic(tempMid: tempMid)
        } catch {
            removeOptimistic(tempMid: tempMid)
            errorMessage = error.localizedDescription
        }
    }

    func beginUploadIfAwaiting(_ response: [String: MessagePackValue], tempMid: Int, data: Data, chat: MessengerActiveChat? = nil) {
        let status = (stringValue(response["status"]) ?? "").lowercased()
        if status == "awaiting_file" {
            beginUpload(tempMid: tempMid, data: data, chat: chat)
        }
    }

    private func stringValue(_ value: MessagePackValue?) -> String? {
        switch value {
        case .string(let s): return s
        default: return nil
        }
    }

    func beginUpload(tempMid: Int, data: Data, chat: MessengerActiveChat? = nil) {
        let session = UploadSession(tempMid: tempMid, api: api)
        uploadSessions[tempMid] = session

        if let index = messages.firstIndex(where: { $0.tempMid == tempMid }) {
            messages[index].uploadProgress = 0
            objectWillChange.send()
        }

        // Mirror chunk progress into the optimistic message (progress ring),
        // surviving chat switches via the per-chat cache.
        session.onProgress = { [weak self] percent in
            guard let self else { return }
            Task { @MainActor in
                if let index = self.messages.firstIndex(where: { $0.tempMid == tempMid }) {
                    self.messages[index].uploadProgress = percent
                    return
                }
                if let chat {
                    self.updateCachedMessage(target: chat.target, tempMid: tempMid) { msg in
                        var copy = msg
                        copy.uploadProgress = percent
                        return copy
                    }
                }
            }
        }

        Task { [weak self] in
            do {
                try await session.run(data: data)
            } catch is CancellationError {
                // Upload cancelled by user; message already removed.
            } catch {
                await MainActor.run { [weak self] in
                    self?.removeOptimistic(tempMid: tempMid)
                    self?.errorMessage = error.localizedDescription
                }
            }
            await MainActor.run { [weak self] in
                self?.uploadSessions[tempMid] = nil
            }
        }
    }

    func cancelUpload(tempMid: Int) {
        uploadSessions[tempMid]?.cancel()
        uploadSessions[tempMid] = nil
        removeOptimistic(tempMid: tempMid)
    }
}

extension MessengerMessage {
    func withLocalImageData(_ data: Data?) -> MessengerMessage {
        var copy = self
        copy.localImageData = data ?? localImageData
        return copy
    }

    func withLocalFileURL(_ url: URL?) -> MessengerMessage {
        var copy = self
        copy.localFileURL = url ?? localFileURL
        return copy
    }

    func withStatus(_ newStatus: String?, mid newMid: Int?) -> MessengerMessage {
        let resolvedMid = newMid ?? self.mid
        return MessengerMessage(
            mid: resolvedMid,
            tempMid: newMid != nil ? nil : tempMid,
            uid: uid,
            author: author,
            content: content,
            date: date,
            isOutgoing: isOutgoing,
            status: newStatus ?? status,
            isRead: isRead,
            uploadProgress: uploadProgress,
            downloadProgress: downloadProgress,
            reactions: reactions,
            localImageData: localImageData,
            localFileURL: localFileURL,
            isListened: isListened
        )
    }
}
