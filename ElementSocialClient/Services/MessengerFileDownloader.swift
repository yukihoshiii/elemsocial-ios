import Foundation

/// Coordinator for encrypted messenger attachments.
///
/// Mirrors the web client's flow: a `messenger/download_files` request is sent,
/// the server answers either with one whole encrypted binary
/// (`download_files` push) or with per-file chunks (`download_file` pushes,
/// one chunk per `file_id`). Chunks are assembled in `file_map` order and
/// decrypted with the message's `encrypted_key` / `encrypted_iv`.
///
/// Decrypted files are persisted under `Caches/MessengerFiles/{mid}.{ext}` —
/// the native analog of the web's Dexie `files` table — so reopening a chat
/// never re-downloads an already fetched attachment.
final class MessengerFileDownloader: @unchecked Sendable {
    static let shared = MessengerFileDownloader()

    struct Request {
        let mid: Int
        let fileMap: [Int]
        let encryptedKey: String
        let encryptedIV: String
        let fileName: String?
        let isVideoCircle: Bool

        var fileExtension: String {
            if isVideoCircle { return "mp4" }
            if let name = fileName, name.contains("."), !name.hasSuffix(".") {
                return name.split(separator: ".").last.map(String.init) ?? "bin"
            }
            return "bin"
        }
    }

    private final class Entry {
        let request: Request
        var chunks: [Int: Data] = [:]
        var wholeData: Data?
        var cancelled = false
        var watchers: [(Double) -> Void] = []
        var continuations: [CheckedContinuation<URL, Error>] = []
        var requestTask: Task<Void, Never>?

        init(request: Request) {
            self.request = request
        }

        var progress: Double {
            if wholeData != nil { return 1 }
            guard !request.fileMap.isEmpty else { return 0 }
            return Double(chunks.count) / Double(request.fileMap.count)
        }
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private let fm = FileManager.default

    private var filesDirectory: URL {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MessengerFiles", isDirectory: true)
    }

    private init() {
        try? fm.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Dexie `db.files.where('mid').equals(mid).first()` analog.
    func cachedFileURL(mid: Int) -> URL? {
        let dir = filesDirectory
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let prefix = "\(mid)."
        if let match = items.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) {
            return match
        }
        return nil
    }

    func cachedImageData(mid: Int) -> Data? {
        guard let url = cachedFileURL(mid: mid) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Starts (or joins) a download for `mid`. Resolves with the decrypted local file URL.
    func download(_ partial: Request) async throws -> URL {
        if let existing = cachedFileURL(mid: partial.mid) {
            return existing
        }

        return try await withCheckedThrowingContinuation { continuation in
            var shouldStartRequest = false

            lock.lock()
            let entry: Entry
            if let current = entries[partial.mid] {
                entry = current
            } else {
                entry = Entry(request: partial)
                entries[partial.mid] = entry
                shouldStartRequest = true
            }

            if let url = cachedFileURLLocked(mid: partial.mid) {
                lock.unlock()
                continuation.resume(returning: url)
                return
            }

            entry.continuations.append(continuation)
            lock.unlock()

            if shouldStartRequest {
                // Fire the server request. Results normally arrive via
                // deliverWhole/deliverChunk pushes; if the server answers the
                // ray inline with the whole binary, use that too.
                let requestTask = Task { [weak self] in
                    do {
                        let response = try await APIClient.shared.requestMap(
                            payloadMap: [
                                "type": .string("messenger"),
                                "action": .string("download_files"),
                                "mid": .int(Int64(partial.mid)),
                                "file_ids": .array(partial.fileMap.map { .int(Int64($0)) })
                            ],
                            timeoutNanoseconds: 120_000_000_000
                        )

                        lock.lock()
                        let stillActive = entries[partial.mid] != nil
                        lock.unlock()
                        guard stillActive else { return }

                        let status = self?.responseStatus(response) ?? ""
                        if status == "error" {
                            self?.fail(mid: partial.mid, error: APIError.serverError(
                                self?.responseStringValue(response["message"]) ?? "Не удалось загрузить файл"
                            ))
                            return
                        }

                        if let binary = self?.extractBinary(response["binary"]) {
                            self?.deliverWhole(mid: partial.mid, binary: binary)
                        }
                        // Otherwise the payload comes via download_file pushes.
                    } catch {
                        self?.fail(mid: partial.mid, error: error)
                    }
                }
                lock.lock()
                entries[partial.mid]?.requestTask = requestTask
                lock.unlock()
            }
        }
    }

    func cancelDownload(mid: Int) {
        lock.lock()
        let entry = entries.removeValue(forKey: mid)
        let continuations = entry?.continuations ?? []
        let requestTask = entry?.requestTask
        entry?.watchers.forEach { $0(-1) }
        lock.unlock()

        requestTask?.cancel()
        // Resume waiters so they don't hang forever; retry becomes possible.
        for c in continuations {
            c.resume(throwing: CancellationError())
        }
    }

    // MARK: - Push entry points (called from APIClient)

    func deliverWhole(mid: Int, binary: Data) {
        var entry: Entry?
        lock.lock()
        entry = entries[mid]
        lock.unlock()

        guard let entry, !entry.cancelled else { return }
        entry.wholeData = binary
        notify(entry)

        assembleAndStore(entry)
    }

    func deliverChunk(mid: Int, fileID: Int, binary: Data) {
        lock.lock()
        let entry = entries[mid]
        if let entry, entry.chunks[fileID] == nil {
            entry.chunks[fileID] = binary
        }
        let progress = entry?.progress ?? 0
        let watchers = entry?.watchers ?? []
        lock.unlock()

        guard let entry, !entry.cancelled else { return }
        for w in watchers { w(progress) }

        let haveAll = entry.request.fileMap.allSatisfy { id in entry.chunks[id] != nil } || entry.wholeData != nil
        if haveAll {
            assembleAndStore(entry)
        }
    }

    // MARK: - Assembly

    private func assembleAndStore(_ entry: Entry) {
        do {
            var encrypted: Data
            if let whole = entry.wholeData {
                encrypted = whole
            } else {
                encrypted = Data()
                for id in entry.request.fileMap {
                    guard let chunk = entry.chunks[id] else { continue }
                    encrypted.append(chunk)
                }
            }

            let decrypted = try ElementCrypto.aesDecryptFile(
                encrypted,
                keyBase64: entry.request.encryptedKey,
                ivBase64: entry.request.encryptedIV
            )

            let url = filesDirectory.appendingPathComponent("\(entry.request.mid).\(entry.request.fileExtension)")
            try decrypted.write(to: url, options: .atomic)

            finishEntry(mid: entry.request.mid, with: url)
        } catch {
            fail(mid: entry.request.mid, error: error)
        }
    }

    private func finishEntry(mid: Int, with url: URL) {
        lock.lock()
        let entry = entries.removeValue(forKey: mid)
        let continuations = entry?.continuations ?? []
        entry?.watchers.forEach { $0(1) }
        lock.unlock()

        for c in continuations {
            c.resume(returning: url)
        }
    }

    private func fail(mid: Int, error: Error) {
        lock.lock()
        let entry = entries.removeValue(forKey: mid)
        let continuations = entry?.continuations ?? []
        entry?.watchers.forEach { $0(-1) }
        lock.unlock()

        for c in continuations {
            c.resume(throwing: error)
        }
    }

    private func notify(_ entry: Entry) {
        lock.lock()
        let watchers = entry.watchers
        let progress = entry.progress
        lock.unlock()
        for w in watchers { w(progress) }
    }

    private func cachedFileURLLocked(mid: Int) -> URL? {
        let dir = filesDirectory
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let prefix = "\(mid)."
        return items.first(where: { $0.lastPathComponent.hasPrefix(prefix) })
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

    private func extractBinary(_ value: MessagePackValue?) -> Data? {
        switch value {
        case .binary(let d):
            return d.isEmpty ? nil : d
        case .map(let map):
            if case .binary(let d)? = map["buffer"] { return d.isEmpty ? nil : d }
            return nil
        default:
            return nil
        }
    }
}
