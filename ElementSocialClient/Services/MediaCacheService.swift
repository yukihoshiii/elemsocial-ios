import Foundation
import CryptoKit

/// Disk record mirroring the web client's Dexie `file_cacheV2` table.
struct MediaCacheRecord: Codable {
    let fileID: Int
    let variant: String
    var path: String?
    var mime: String?
    var size: Int
    var hashSHA256: String?
    var isHashVerified: Bool
    var downloadDate: Date

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case variant
        case path
        case mime
        case size
        case hashSHA256 = "hash_sha256"
        case isHashVerified = "is_hash_verified"
        case downloadDate = "download_date"
    }
}

/// Chunked media cache — a native port of the site's `downloadService.ts`
/// (Dexie tables `file_cacheV2` + `files_chunksV2`).
///
/// Flow is identical to the web frontend:
/// 1. `storage/get_file_data {file_id, variant}` → metadata (`hash_sha256`, `size`, `mime`, …).
///    If the requested variant is still processing, retry every few seconds.
/// 2. Loop `storage/download {file_id, variant, offset}` → `{buffer, offset}` chunks.
///    Every chunk is persisted under `chunks/<file>_<variant>/<offset>.bin`.
/// 3. When `offset + chunk.count >= size`, assemble all chunks ordered by offset,
///    verify SHA-256 against `hash_sha256` and store the assembled blob.
///    Only verified blobs are ever handed out (like `is_hash_verified`).
final class MediaCacheService: @unchecked Sendable {
    static let shared = MediaCacheService()

    private let ioQueue = DispatchQueue(label: "elemsocial.media.cache.io")
    private let fm = FileManager.default

    private final class InFlight {
        let task: Task<Data, Error>
        var watchers: [(Double) -> Void] = []

        init(task: Task<Data, Error>, watchers: [(Double) -> Void]) {
            self.task = task
            self.watchers = watchers
        }
    }

    private var inFlight: [String: InFlight] = [:]
    private let lock = NSLock()

    private var rootURL: URL {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("ElementMediaCacheV2", isDirectory: true)
    }

    private var metaURL: URL { rootURL.appendingPathComponent("meta", isDirectory: true) }
    private var chunksURL: URL { rootURL.appendingPathComponent("chunks", isDirectory: true) }
    private var blobsURL: URL { rootURL.appendingPathComponent("blobs", isDirectory: true) }

    private init() {
        for dir in [rootURL, metaURL, chunksURL, blobsURL] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Keys / paths

    private func key(_ fileID: Int, _ variant: String) -> String {
        "\(fileID)_\(variant)"
    }

    private func metaFileURL(_ fileID: Int, _ variant: String) -> URL {
        metaURL.appendingPathComponent(key(fileID, variant) + ".json")
    }

    private func blobFileURL(_ fileID: Int, _ variant: String) -> URL {
        blobsURL.appendingPathComponent(key(fileID, variant) + ".bin")
    }

    private func chunkDirURL(_ fileID: Int, _ variant: String) -> URL {
        chunksURL.appendingPathComponent(key(fileID, variant), isDirectory: true)
    }

    private func chunkFileURL(_ fileID: Int, _ variant: String, offset: Int) -> URL {
        chunkDirURL(fileID, variant).appendingPathComponent(String(format: "%016d", offset))
    }

    // MARK: - Public API (mirrors downloadService)

    /// Dexie `db.file_cacheV2.get([file_id, variant])`
    func record(fileID: Int, variant: String) -> MediaCacheRecord? {
        ioQueue.sync {
            guard let data = try? Data(contentsOf: metaFileURL(fileID, variant)) else { return nil }
            return try? JSONDecoder().decode(MediaCacheRecord.self, from: data)
        }
    }

    /// `downloadService.validateFile` — only hash-verified records count.
    func validatedRecord(fileID: Int, variant: String) -> MediaCacheRecord? {
        guard let rec = record(fileID: fileID, variant: variant), rec.isHashVerified else { return nil }
        return rec
    }

    func verifiedBlobExists(fileID: Int, variant: String) -> Bool {
        guard validatedRecord(fileID: fileID, variant: variant) != nil else { return false }
        return fm.fileExists(atPath: blobFileURL(fileID, variant).path)
    }

    /// Returns cached verified data without triggering any network activity.
    func cachedData(fileID: Int, variant: String, maxBytes: Int? = nil) -> Data? {
        guard validatedRecord(fileID: fileID, variant: variant) != nil else { return nil }
        let url = blobFileURL(fileID, variant)
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int else { return nil }
        if let maxBytes, fileSize > maxBytes { return nil }
        return ioQueue.sync { try? Data(contentsOf: url) }
    }

    func cachedFileURL(fileID: Int, variant: String) -> URL? {
        guard validatedRecord(fileID: fileID, variant: variant) != nil else { return nil }
        let url = blobFileURL(fileID, variant)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// `downloadService.startDownload` — resolves with fully assembled + verified data.
    @discardableResult
    func startDownload(
        fileID: Int,
        variant: String = "original",
        progress: ((Double) -> Void)? = nil,
        maxBytes: Int = 300 * 1024 * 1024
    ) async throws -> Data {
        let cacheKey = k(fileID, variant)

        // Fast path: already verified.
        if let cached = cachedData(fileID: fileID, variant: variant) {
            progress?(1)
            return cached
        }

        lock.lock()
        if let existing = inFlight[cacheKey] {
            if let progress { existing.watchers.append(progress) }
            lock.unlock()
            return try await existing.task.value
        }
        let task = Task { [weak self] () throws -> Data in
            guard let self else { throw APIError.invalidResponse }
            return try await self.performDownload(fileID: fileID, variant: variant, maxBytes: maxBytes)
        }
        inFlight[cacheKey] = InFlight(task: task, watchers: progress.map { [$0] } ?? [])
        lock.unlock()

        do {
            let data = try await task.value
            finishEntry(cacheKey, error: nil)
            return data
        } catch {
            finishEntry(cacheKey, error: error)
            throw error
        }
    }

    private func finishEntry(_ cacheKey: String, error: Error?) {
        lock.lock()
        let entry = inFlight.removeValue(forKey: cacheKey)
        lock.unlock()
        guard let entry else { return }
        let watchers = entry.watchers
        if error == nil {
            for w in watchers { w(1) }
        } else {
            for w in watchers { w(-1) }
        }
    }

    private func k(_ fileID: Int, _ variant: String) -> String { "\(fileID):\(variant)" }

    // MARK: - Core download pipeline

    private func performDownload(fileID: Int, variant: String, maxBytes: Int) async throws -> Data {
        // Step 1 — metadata.
        let meta = try await fetchFileMetadata(fileID: fileID, variant: variant)
        guard meta.size <= maxBytes else {
            throw APIError.serverError("Файл слишком большой (\(meta.size) байт)")
        }

        persistRecord(MediaCacheRecord(
            fileID: fileID,
            variant: variant,
            path: meta.path,
            mime: meta.mime,
            size: meta.size,
            hashSHA256: meta.hash,
            isHashVerified: false,
            downloadDate: Date()
        ))

        // Step 2 — chunk loop.
        try? fm.createDirectory(at: chunkDirURL(fileID, variant), withIntermediateDirectories: true)

        var offset = 0
        var iterations = 0
        while offset < meta.size {
            if Task.isCancelled || isCancelled(fileID: meta.resolvedFileID, variant: variant) {
                throw CancellationError()
            }

            iterations += 1
            if iterations > 100_000 { throw APIError.serverError("Слишком много чанков") }

            let response = try await APIClient.shared.requestMap(payloadMap: [
                "type": .string("storage"),
                "action": .string("download"),
                "file_id": .int(Int64(meta.resolvedFileID)),
                "variant": .string(variant),
                "offset": .int(Int64(offset))
            ])

            let statusCode = intValue(response["status"])
            guard statusCode == 200 else {
                throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить файл")
            }

            guard let buffer = extractBuffer(response["buffer"]), !buffer.isEmpty else {
                throw APIError.serverError("Сервер вернул пустой чанк")
            }

            let chunkOffset = intValue(response["offset"]) ?? offset
            writeChunk(buffer, fileID: fileID, variant: variant, offset: chunkOffset)
            offset = chunkOffset + buffer.count

            reportProgress(fileID: fileID, variant: variant, min(0.99, Double(offset) / Double(max(1, meta.size))))
        }

        // Step 3 — assemble.
        let assembled = try assembleChunks(fileID: fileID, variant: variant, expectedSize: meta.size)

        // Step 4 — verify hash.
        if let expected = meta.hash, !expected.isEmpty {
            let digest = SHA256.hash(data: assembled)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex.lowercased() == expected.lowercased() else {
                purgeChunks(fileID: fileID, variant: variant)
                removeRecord(fileID: fileID, variant: variant)
                throw APIError.serverError("Хэш файла не совпал")
            }
        }

        // Step 5 — persist blob + mark verified.
        let blobURL = blobFileURL(fileID, variant)
        try assembled.write(to: blobURL, options: .atomic)
        persistRecord(MediaCacheRecord(
            fileID: fileID,
            variant: variant,
            path: meta.path,
            mime: meta.mime,
            size: meta.size,
            hashSHA256: meta.hash,
            isHashVerified: true,
            downloadDate: Date()
        ))
        purgeChunks(fileID: fileID, variant: variant)

        return assembled
    }

    private struct FileMeta {
        let resolvedFileID: Int
        let path: String?
        let mime: String?
        let size: Int
        let hash: String?
    }

    private func fetchFileMetadata(fileID: Int, variant: String) async throws -> FileMeta {
        var processingRetries = 0
        while true {
            let response = try await APIClient.shared.requestMap(
                payloadMap: [
                    "type": .string("storage"),
                    "action": .string("get_file_data"),
                    "payload": .map([
                        "file_id": .int(Int64(fileID)),
                        "variant": .string(variant)
                    ])
                ],
                timeoutNanoseconds: 30_000_000_000
            )

            let statusCode = intValue(response["status"])
            guard statusCode == 200 else {
                throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось получить данные файла")
            }
            guard case .map(let fileData)? = response["file_data"] else {
                throw APIError.invalidResponse
            }

            // Variant still being generated server-side — web retries up to 30×5s.
            if let status = stringValue(fileData["variant_status"]), status == "processing" {
                processingRetries += 1
                if processingRetries > 30 {
                    throw APIError.serverError("Вариант '\(variant)' слишком долго генерируется")
                }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }

            let resolvedID = intValue(fileData["id"]) ?? fileID
            var size: Int?
            var hash: String?
            var path: String?
            var mime: String?

            if variant == "original" || fileData["variants"] == nil {
                size = intValue(fileData["size"])
                hash = stringValue(fileData["hash_sha256"])
                path = stringValue(fileData["path"])
                mime = stringValue(fileData["mime"])
            }
            let variantsRaw: MessagePackValue? = fileData["variants"]
            if case .map(let variants)? = variantsRaw,
               case .map(let v)? = variants[variant] {
                size = intValue(v["size"]) ?? size
                hash = stringValue(v["hash_sha256"]) ?? hash
                path = stringValue(v["path"]) ?? path
                mime = stringValue(v["mime"]) ?? mime
            }

            guard let finalSize = size, finalSize > 0 else {
                throw APIError.serverError("Сервер не вернул размер файла")
            }

            return FileMeta(resolvedFileID: resolvedID, path: path, mime: mime, size: finalSize, hash: hash)
        }
    }

    // MARK: - Storage helpers

    private func persistRecord(_ record: MediaCacheRecord) {
        ioQueue.sync {
            if let data = try? JSONEncoder().encode(record) {
                try? data.write(to: metaFileURL(record.fileID, record.variant), options: .atomic)
            }
        }
    }

    private func removeRecord(fileID: Int, variant: String) {
        ioQueue.sync {
            try? fm.removeItem(at: metaFileURL(fileID, variant))
            try? fm.removeItem(at: blobFileURL(fileID, variant))
        }
    }

    private func writeChunk(_ data: Data, fileID: Int, variant: String, offset: Int) {
        ioQueue.sync {
            try? data.write(to: chunkFileURL(fileID, variant, offset: offset), options: .atomic)
        }
    }

    private func assembleChunks(fileID: Int, variant: String, expectedSize: Int) throws -> Data {
        let dir = chunkDirURL(fileID, variant)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var assembled = Data()
        assembled.reserveCapacity(expectedSize)
        for f in sorted {
            guard let chunk = try? Data(contentsOf: f) else { continue }
            assembled.append(chunk)
        }
        guard assembled.count >= expectedSize else {
            throw APIError.serverError("Неполный файл: \(assembled.count)/\(expectedSize)")
        }
        return assembled.prefix(expectedSize)
    }

    private func purgeChunks(fileID: Int, variant: String) {
        ioQueue.sync {
            try? fm.removeItem(at: chunkDirURL(fileID, variant))
        }
    }

    // MARK: - Small helpers

    private func isCancelled(fileID: Int, variant: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight[k(fileID, variant)] == nil
    }

    private func reportProgress(fileID: Int, variant: String, _ value: Double) {
        lock.lock()
        let watchers = inFlight[k(fileID, variant)]?.watchers ?? []
        lock.unlock()
        for w in watchers { w(value) }
    }

    private func intValue(_ value: MessagePackValue?) -> Int? {
        switch value {
        case .int(let i): return Int(i)
        case .uint(let u): return Int(u)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private func stringValue(_ value: MessagePackValue?) -> String? {
        switch value {
        case .string(let s): return s
        default: return nil
        }
    }

    private func extractBuffer(_ value: MessagePackValue?) -> Data? {
        switch value {
        case .binary(let d):
            return d
        case .map(let map):
            if case .binary(let d)? = map["buffer"] { return d }
            return nil
        default:
            return nil
        }
    }
}
