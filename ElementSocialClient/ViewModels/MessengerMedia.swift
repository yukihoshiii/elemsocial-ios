import Foundation
import UIKit

/// `target: {id, type}` payload builder shared across send helpers.
func messengerTargetValue(_ chat: MessengerActiveChat) -> MessagePackValue {
    .map([
        "id": .int(Int64(chat.target.id)),
        "type": .int(Int64(chat.target.type))
    ])
}

extension MessengerViewModel {

    // MARK: - Voice messages

    func sendVoiceMessage(url: URL, duration: Double, waveform: [Double]) async {
        guard let chat = activeChat else { return }
        guard let data = try? Data(contentsOf: url) else { return }

        let tempMid = makeTempMid()
        let fileName = "voice_message_\(Int(Date().timeIntervalSince1970 * 1000)).m4a"

        appendOptimistic(
            optimisticMessage(
                tempMid: tempMid,
                content: MessengerMessageContent(
                    text: "",
                    type: "voice",
                    fileName: fileName,
                    fileSize: Int64(data.count),
                    mimeType: "audio/mp4",
                    waveform: waveform,
                    duration: duration
                )
            ).withLocalFileURL(url)
        )
        updateChatPreview(chat.target, lastMessage: "Голосовое сообщение", date: nil)

        var filePayload: [String: MessagePackValue] = [
            "name": .string(fileName),
            "type": .string("audio/mp4"),
            "size": .int(Int64(data.count))
        ]
        if !waveform.isEmpty {
            let bars: [MessagePackValue] = waveform.map { .float($0) }
            filePayload["waveform"] = .array(bars)
            filePayload["duration"] = .float(duration)
        }

        let voicePayload: [String: MessagePackValue] = [
            "type": .string("messenger"),
            "action": .string("send_message"),
            "temp_mid": .int(Int64(tempMid)),
            "target": messengerTargetValue(chat),
            "message": .string(""),
            "files": .array([.map(filePayload)])
        ]

        do {
            let response = try await api.requestMap(payloadMap: voicePayload)
            handleSendResponse(response, tempMid: tempMid, chat: chat)
            beginUploadIfAwaiting(response, tempMid: tempMid, data: data, chat: chat)
        } catch is CancellationError {
            removeOptimistic(tempMid: tempMid)
        } catch {
            removeOptimistic(tempMid: tempMid)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Video circles («кружочки»)

    func sendVideoCircleMessage(fileURL: URL, duration: Double, thumbnailDataURL: String?) async {
        guard let chat = activeChat else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }

        let tempMid = makeTempMid()
        let fileName = "video_message_\(Int(Date().timeIntervalSince1970 * 1000)).mp4"

        var filesPayload: [String: MessagePackValue] = [
            "name": .string(fileName),
            "type": .string("video/mp4"),
            "size": .int(Int64(data.count)),
            "duration": .float(duration),
            "is_video_circle": .bool(true)
        ]
        if let thumbnailDataURL {
            filesPayload["thumbnail"] = .string(thumbnailDataURL)
        }

        appendOptimistic(
            optimisticMessage(
                tempMid: tempMid,
                content: MessengerMessageContent(
                    text: "",
                    type: "video",
                    fileName: fileName,
                    fileSize: Int64(data.count),
                    mimeType: "video/mp4",
                    duration: duration,
                    isVideoCircle: true,
                    thumbnailBase64: thumbnailDataURL
                )
            ).withLocalFileURL(fileURL)
        )
        updateChatPreview(chat.target, lastMessage: "Видео сообщение", date: nil)

        let circlePayload: [String: MessagePackValue] = [
            "type": .string("messenger"),
            "action": .string("send_message"),
            "temp_mid": .int(Int64(tempMid)),
            "target": messengerTargetValue(chat),
            "message": .string(""),
            "files": .array([.map(filesPayload)])
        ]

        do {
            let response = try await api.requestMap(payloadMap: circlePayload)
            handleSendResponse(response, tempMid: tempMid, chat: chat)
            beginUploadIfAwaiting(response, tempMid: tempMid, data: data, chat: chat)
        } catch is CancellationError {
            removeOptimistic(tempMid: tempMid)
        } catch {
            removeOptimistic(tempMid: tempMid)
            errorMessage = error.localizedDescription
        }
    }

    /// `export_video_circle` — server-side conversion, then the mp4 is shared/saved.
    func exportVideoCircle(for message: MessengerMessage) async -> URL? {
        guard let mid = message.mid else { return nil }
        do {
            let binary = try await api.exportMessengerVideoCircle(mid: mid)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("element_circle_\(mid)_\(Int(Date().timeIntervalSince1970)).mp4")
            try binary.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Attachment downloads (images / voice / video / files)

    func progressForAttachment(_ message: MessengerMessage) -> Double? {
        guard let mid = message.mid else { return message.downloadProgress }
        if message.downloadProgress != nil { return message.downloadProgress }
        return attachmentProgress[mid]
    }

    func cancelAttachmentDownload(mid: Int?) {
        guard let mid else { return }
        MessengerFileDownloader.shared.cancelDownload(mid: mid)
        attachmentProgress[mid] = -1
        objectWillChange.send()
    }

    /// Loads an image attachment fully (decrypted) — from cache or via chunked download.
    func ensureImageLoaded(for message: MessengerMessage) async -> Data? {
        if let local = message.localImageData { return local }
        guard let mid = message.mid, let content = message.content,
              let fileIDs = content.fileMap,
              content.encryptedKey != nil, content.encryptedIV != nil else { return nil }

        if let cached = MessengerFileDownloader.shared.cachedImageData(mid: mid) {
            setLocalImageData(cached, for: mid)
            return cached
        }

        do {
            attachmentProgress[mid] = 0.01
            objectWillChange.send()
            let url = try await MessengerFileDownloader.shared.download(MessengerFileDownloader.Request(
                mid: mid,
                fileMap: fileIDs,
                encryptedKey: content.encryptedKey!,
                encryptedIV: content.encryptedIV!,
                fileName: content.fileName ?? "image.jpg",
                isVideoCircle: false
            ))
            let data = try? Data(contentsOf: url)
            attachmentProgress[mid] = 1
            if let data {
                setLocalImageData(data, for: mid)
            }
            return data
        } catch {
            attachmentProgress[mid] = -1
            objectWillChange.send()
            return nil
        }
    }

    /// Loads a voice/video/file attachment to a decrypted local file URL.
    func ensureAttachmentFileLoaded(for message: MessengerMessage) async -> URL? {
        if let local = message.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        guard let mid = message.mid, let content = message.content,
              let fileIDs = content.fileMap,
              content.encryptedKey != nil, content.encryptedIV != nil else { return nil }

        if let cached = MessengerFileDownloader.shared.cachedFileURL(mid: mid) {
            setLocalFileURL(cached, for: mid)
            return cached
        }

        do {
            attachmentProgress[mid] = 0.01
            objectWillChange.send()
            let url = try await MessengerFileDownloader.shared.download(MessengerFileDownloader.Request(
                mid: mid,
                fileMap: fileIDs,
                encryptedKey: content.encryptedKey!,
                encryptedIV: content.encryptedIV!,
                fileName: content.fileName,
                isVideoCircle: content.isVideoCircle
            ))
            attachmentProgress[mid] = 1
            setLocalFileURL(url, for: mid)
            return url
        } catch {
            attachmentProgress[mid] = -1
            objectWillChange.send()
            return nil
        }
    }

    private func setLocalImageData(_ data: Data, for mid: Int) {
        guard let index = messages.firstIndex(where: { $0.mid == mid }) else { return }
        messages[index].localImageData = data
        storeToCache()
    }

    private func setLocalFileURL(_ url: URL, for mid: Int) {
        guard let index = messages.firstIndex(where: { $0.mid == mid }) else { return }
        messages[index].localFileURL = url
        storeToCache()
    }

    func markListened(_ message: MessengerMessage) {
        guard !message.isListened else { return }
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isListened = true
    }
}
