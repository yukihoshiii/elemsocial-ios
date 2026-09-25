import Foundation
import UIKit

struct UploadFile {
    let name: String
    let data: Data
}

struct SocketEndpoint: Identifiable, Codable, Equatable {
    let id: String
    let url: String
}

final class SocketEndpointStore {
    static let shared = SocketEndpointStore()

    private let endpointsKey = "socket_endpoints"
    private let selectedKey = "socket_selected_id"
    private let defaults = UserDefaults.standard

    private let defaultEndpoint = SocketEndpoint(id: "default", url: "wss://ws.elemsocial.com/user_api")

    func loadEndpoints() -> [SocketEndpoint] {
        if let data = defaults.data(forKey: endpointsKey),
           let decoded = try? JSONDecoder().decode([SocketEndpoint].self, from: data) {
            return ensureDefault(in: decoded)
        }
        let initial = [defaultEndpoint]
        saveEndpoints(initial)
        return initial
    }

    func saveEndpoints(_ endpoints: [SocketEndpoint]) {
        let normalized = ensureDefault(in: endpoints)
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: endpointsKey)
        }
    }

    func selectedID() -> String? {
        defaults.string(forKey: selectedKey)
    }

    func setSelectedID(_ id: String) {
        defaults.set(id, forKey: selectedKey)
    }

    func currentEndpoint() -> SocketEndpoint {
        let endpoints = loadEndpoints()
        if let selected = selectedID(), let match = endpoints.first(where: { $0.id == selected }) {
            return match
        }
        return endpoints.first ?? defaultEndpoint
    }

    func currentURL() -> URL? {
        URL(string: currentEndpoint().url)
    }

    func upsertEndpoint(from rawValue: String) -> SocketEndpoint? {
        guard let normalized = normalize(rawValue) else { return nil }
        var endpoints = loadEndpoints()
        if let existing = endpoints.first(where: { $0.url == normalized }) {
            return existing
        }
        let endpoint = SocketEndpoint(id: UUID().uuidString, url: normalized)
        endpoints.append(endpoint)
        saveEndpoints(endpoints)
        return endpoint
    }

    func removeEndpoint(id: String) {
        guard id != defaultEndpoint.id else { return }
        var endpoints = loadEndpoints()
        endpoints.removeAll { $0.id == id }
        saveEndpoints(endpoints)
        if selectedID() == id {
            setSelectedID(defaultEndpoint.id)
        }
    }

    func defaultID() -> String { defaultEndpoint.id }

    private func ensureDefault(in endpoints: [SocketEndpoint]) -> [SocketEndpoint] {
        if endpoints.contains(where: { $0.id == defaultEndpoint.id || $0.url == defaultEndpoint.url }) {
            return endpoints
        }
        return [defaultEndpoint] + endpoints
    }

    private func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "wss://" + value
        }
        if let url = URL(string: value), url.path.isEmpty {
            value = value.hasSuffix("/") ? value + "user_api" : value + "/user_api"
        }
        return URL(string: value) == nil ? nil : value
    }
}

actor PendingRequests {
    private var continuations: [String: CheckedContinuation<[String: MessagePackValue], Error>] = [:]

    func add(rayID: String, continuation: CheckedContinuation<[String: MessagePackValue], Error>) {
        continuations[rayID] = continuation
    }

    func resolve(rayID: String, payload: [String: MessagePackValue]) {
        guard let cont = continuations.removeValue(forKey: rayID) else { return }
        cont.resume(returning: payload)
    }

    func reject(rayID: String, error: Error) {
        guard let cont = continuations.removeValue(forKey: rayID) else { return }
        cont.resume(throwing: error)
    }

    func rejectAll(error: Error) {
        let values = continuations.values
        continuations.removeAll()
        values.forEach { $0.resume(throwing: error) }
    }
}

private actor MusicDownloadCoordinator {
    private var inFlightFileTasks: [Int: Task<URL, Error>] = [:]

    func sharedFileURL(
        for fileID: Int,
        start: @escaping @Sendable () async throws -> URL
    ) async throws -> URL {
        if let existingTask = inFlightFileTasks[fileID] {
            return try await existingTask.value
        }

        let task = Task { try await start() }
        inFlightFileTasks[fileID] = task

        do {
            let url = try await task.value
            inFlightFileTasks[fileID] = nil
            return url
        } catch {
            inFlightFileTasks[fileID] = nil
            throw error
        }
    }
}

final class APIClient: NSObject {
    static let shared = APIClient()
    static let socketFailureNotification = Notification.Name("SocketFailureNotification")
    static let inAppNotification = Notification.Name("InAppNotification")
    static let messengerPush = Notification.Name("MessengerPush")
    /// Fired when the authorized user identity changes (account switch / re-login).
    static let accountDidChangeNotification = Notification.Name("AccountDidChange")

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let socketStore = SocketEndpointStore.shared
    private var wsURL: URL? { socketStore.currentURL() }

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?

    private var keyMaterial: RSAKeyMaterial?
    private var clientAESKey: String?
    private var serverAESKey: String?
    private var currentSKey: String?
    private var currentUserID: Int?
    private var currentUserName: String?
    private var currentUsername: String?
    private var currentUserEmail: String?
    private var currentUserEBalls: String?
    private var currentUserNotifications: Int?
    private var currentUserMessengerNotifications: Int?
    private var currentUserAvatar: PostAuthorAvatar?
    private var currentUserPermissions: UserPermissions?
    private var currentUserGoldStatus: Bool?
    private var currentUserGoldHistory: [GoldHistoryItem] = []
    private var currentUserChannels: [ChannelSummary] = []
    private var currentSelectedChannel: ChannelSummary?

    private var isConnected = false
    private var isSocketReady = false
    /// Bumped on every disconnect/new connect; stale async callbacks
    /// (receive-loop errors, URLSession completions from an old session)
    /// must never tear down a newer connection.
    private var connectionGeneration = 0
    private var lastSocketFailureAt: Date?
    private var lastSocketFailure: (message: String, url: String, date: Date)?
    private var isSocketSuspended = false
    private var socketFailureHandled = false

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private let connectLock = NSLock()
    private var connectTask: Task<Void, Error>?
    private var connectTaskID: UUID?
    private var receiveLoopTask: Task<Void, Never>?
    private let imageCache = NSCache<NSString, NSData>()
    private let imageDiskCache = ImageDiskCache.shared
    private let musicDownloadCoordinator = MusicDownloadCoordinator()

    private let pending = PendingRequests()

    private override init() {
        super.init()
    }

    func applySocketEndpoint(_ endpoint: SocketEndpoint) {
        resumeSocket()
        socketStore.setSelectedID(endpoint.id)
        disconnect()
    }

    func applySocketURLString(_ value: String) -> SocketEndpoint? {
        guard let endpoint = socketStore.upsertEndpoint(from: value) else { return nil }
        resumeSocket()
        applySocketEndpoint(endpoint)
        return endpoint
    }

    func connectIfNeeded() async throws {
        if isSocketSuspended { throw APIError.socketSuspended }
        if isSocketReady { return }
        let (task, taskID) = startConnectTaskIfNeeded()
        do {
            try await task.value
            clearConnectTask(taskID)
        } catch {
            clearConnectTask(taskID)
            notifySocketFailure(error)
            throw error
        }
    }

    func disconnect() {
        connectionGeneration += 1
        connectLock.lock()
        connectTask?.cancel()
        connectTask = nil
        connectLock.unlock()

        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: APIError.socketNotConnected)
        }

        receiveLoopTask?.cancel()
        receiveLoopTask = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session = nil

        isConnected = false
        isSocketReady = false

        keyMaterial = nil
        clientAESKey = nil
        serverAESKey = nil
        // Keep auth context across transient socket reconnects.
        // Session must only be cleared on explicit logout.

        Task {
            await pending.rejectAll(error: APIError.socketNotConnected)
        }

        print("[WS] Disconnected")
    }

    func suspendSocket() {
        isSocketSuspended = true
    }

    func resumeSocket() {
        isSocketSuspended = false
        socketFailureHandled = false
    }

    func isSocketSuspendedSnapshot() -> Bool {
        isSocketSuspended
    }

    func hasUnhandledSocketFailure() -> Bool {
        isSocketSuspended && !socketFailureHandled
    }

    func markSocketFailureHandled() {
        socketFailureHandled = true
    }

    func lastSocketFailureSnapshot() -> (message: String, url: String, date: Date)? {
        lastSocketFailure
    }

    func clearSessionForLogout() {
        currentSKey = nil
        currentUserID = nil
        currentUserName = nil
        currentUsername = nil
        currentUserEmail = nil
        currentUserEBalls = nil
        currentUserNotifications = nil
        currentUserMessengerNotifications = nil
        currentUserAvatar = nil
        currentUserPermissions = nil
        currentUserGoldStatus = nil
        currentUserGoldHistory = []
        currentUserChannels = []
        currentSelectedChannel = nil
        disconnect()
    }

    struct SessionInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let isCurrent: Bool
    }

    struct AccountSummary {
        let userID: Int?
        let name: String?
        let username: String?
        let email: String?
        let avatar: PostAuthorAvatar?
    }

    struct ProfileData: Identifiable {
        let id: Int
        let type: Int
        let name: String
        let username: String
        let description: String?
        let avatar: MediaData?
        let cover: MediaData?
        let listeningSong: MusicSong?
        let isOnline: Bool
        let postsCount: Int
        let subscribersCount: Int
        let subscribedCount: Int
        let giftsCount: Int
        let archivePostsCount: Int
        let trashBinPostsCount: Int
        let isSubscribed: Bool
        let isBlocked: Bool
        let isMyProfile: Bool
        let createDate: String?
        let lastOnline: String?
        let isVerified: Bool?
        let goldStatus: Bool?
        let isMuted: Bool
        let links: [ProfileLink]

        init(
            id: Int,
            type: Int,
            name: String,
            username: String,
            description: String?,
            avatar: MediaData?,
            cover: MediaData?,
            listeningSong: MusicSong? = nil,
            isOnline: Bool = false,
            postsCount: Int,
            subscribersCount: Int,
            subscribedCount: Int,
            giftsCount: Int,
            archivePostsCount: Int,
            trashBinPostsCount: Int,
            isSubscribed: Bool,
            isBlocked: Bool,
            isMyProfile: Bool,
            createDate: String?,
            lastOnline: String?,
            isVerified: Bool? = nil,
            goldStatus: Bool? = nil,
            isMuted: Bool = false,
            links: [ProfileLink] = []
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.username = username
            self.description = description
            self.avatar = avatar
            self.cover = cover
            self.listeningSong = listeningSong
            self.isOnline = isOnline
            self.postsCount = postsCount
            self.subscribersCount = subscribersCount
            self.subscribedCount = subscribedCount
            self.giftsCount = giftsCount
            self.archivePostsCount = archivePostsCount
            self.trashBinPostsCount = trashBinPostsCount
            self.isSubscribed = isSubscribed
            self.isBlocked = isBlocked
            self.isMyProfile = isMyProfile
            self.createDate = createDate
            self.lastOnline = lastOnline
            self.isVerified = isVerified
            self.goldStatus = goldStatus
            self.isMuted = isMuted
            self.links = links
        }
    }

    func request<T: Decodable, Body: Encodable>(payload: Body, responseType: T.Type) async throws -> T {
        try await connectIfNeeded()
        let payloadMap = try encodableToMap(payload)
        let responseMap = try await requestMap(payloadMap: payloadMap)

        let object = MessagePack.toJSONObject(.map(responseMap))
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try decoder.decode(T.self, from: data)
        return decoded
    }

    func cachedImageData(path: String, file: String, simple: String? = nil, lossless: Bool = true) -> Data? {
        let simpleValue = simple ?? file
        let cacheKey = imageCacheKey(path: path, file: file, simpleValue: simpleValue, lossless: lossless)
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            return cached as Data
        }
        if let diskData = imageDiskCache.data(forKey: cacheKey) {
            imageCache.setObject(diskData as NSData, forKey: cacheKey as NSString)
            return diskData
        }
        if lossless {
            let simpleKey = imageCacheKey(path: path, file: file, simpleValue: simpleValue, lossless: false)
            if let cached = imageCache.object(forKey: simpleKey as NSString) {
                return cached as Data
            }
            if let diskData = imageDiskCache.data(forKey: simpleKey) {
                imageCache.setObject(diskData as NSData, forKey: simpleKey as NSString)
                return diskData
            }
        }
        return nil
    }

    private func storageImageCacheKey(fileID: Int) -> String {
        "storage#\(fileID)"
    }

    func cachedStorageImageData(fileID: Int) -> Data? {
        let cacheKey = storageImageCacheKey(fileID: fileID)
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            return cached as Data
        }
        if let diskData = imageDiskCache.data(forKey: cacheKey) {
            imageCache.setObject(diskData as NSData, forKey: cacheKey as NSString)
            return diskData
        }
        return nil
    }

    func cachedMediaImageData(for media: MediaData, lossless: Bool = true) -> Data? {
        if let fileID = media.storageFileID {
            return cachedStorageImageData(fileID: fileID)
        }
        guard let path = media.path, let file = media.file else { return nil }
        return cachedImageData(path: path, file: file, simple: media.simple, lossless: lossless)
    }

    func downloadMediaImage(
        _ media: MediaData,
        lossless: Bool = true,
        maxLosslessBytes: Int? = nil
    ) async -> Data? {
        if let fileID = media.storageFileID {
            return await downloadStorageImageData(fileID: fileID)
        }
        guard let path = media.path, let file = media.file else { return nil }
        return await downloadImage(
            path: path,
            file: file,
            simple: media.simple,
            lossless: lossless,
            maxLosslessBytes: maxLosslessBytes
        )
    }

    func downloadImage(
        path: String,
        file: String,
        simple: String? = nil,
        lossless: Bool = true,
        maxLosslessBytes: Int? = nil
    ) async -> Data? {
        let normalizedPath = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileLower = file.lowercased()
        let simpleLower = (simple ?? "").lowercased()
        let shouldDropSimpleForAvifPreview = normalizedPath == "posts/videos_preview"
            && fileLower.hasSuffix(".avif")
            && (simpleLower.isEmpty || simpleLower.hasSuffix(".avif"))

        let simpleValue = shouldDropSimpleForAvifPreview ? nil : (simple ?? file)
        let cacheSimpleValue = simpleValue ?? file
        let cacheKey = imageCacheKey(path: path, file: file, simpleValue: cacheSimpleValue, lossless: lossless)
        let simpleKey = imageCacheKey(path: path, file: file, simpleValue: cacheSimpleValue, lossless: false)
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            return cached as Data
        }
        if let diskData = imageDiskCache.data(forKey: cacheKey) {
            imageCache.setObject(diskData as NSData, forKey: cacheKey as NSString)
            return diskData
        }
        if lossless {
            if let cached = imageCache.object(forKey: simpleKey as NSString) {
                return cached as Data
            }
            if let diskData = imageDiskCache.data(forKey: simpleKey) {
                imageCache.setObject(diskData as NSData, forKey: simpleKey as NSString)
                return diskData
            }
        }

        let losslessAllowed = lossless && (maxLosslessBytes == nil || (maxLosslessBytes ?? 0) <= 7_800_000)

        // Images are served via WS `download/image` in current backend setup.
        if losslessAllowed,
           let wsLossless = await downloadImageViaWS(path: path, file: file, simpleValue: simpleValue, lossless: true) {
            imageCache.setObject(wsLossless as NSData, forKey: cacheKey as NSString)
            imageDiskCache.store(wsLossless, forKey: cacheKey)
            return wsLossless
        }

        // Compact WS fallback.
        if !shouldDropSimpleForAvifPreview,
           let wsSimple = await downloadImageViaWS(path: path, file: file, simpleValue: simpleValue, lossless: false) {
            imageCache.setObject(wsSimple as NSData, forKey: simpleKey as NSString)
            imageDiskCache.store(wsSimple, forKey: simpleKey)
            return wsSimple
        }

        return nil
    }

    func cachedURLImageData(url: URL) -> Data? {
        let cacheKey = urlCacheKey(url)
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            return cached as Data
        }
        if let diskData = imageDiskCache.data(forKey: cacheKey) {
            imageCache.setObject(diskData as NSData, forKey: cacheKey as NSString)
            return diskData
        }
        return nil
    }

    func downloadImageURL(_ url: URL) async -> Data? {
        let cacheKey = urlCacheKey(url)
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            return cached as Data
        }
        if let diskData = imageDiskCache.data(forKey: cacheKey) {
            imageCache.setObject(diskData as NSData, forKey: cacheKey as NSString)
            return diskData
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            imageCache.setObject(data as NSData, forKey: cacheKey as NSString)
            imageDiskCache.store(data, forKey: cacheKey)
            return data
        } catch {
            return nil
        }
    }

    private func imageCacheKey(path: String, file: String, simpleValue: String, lossless: Bool) -> String {
        "\(path)/\(file)#\(simpleValue)#\(lossless ? "lossless" : "simple")"
    }

    private func urlCacheKey(_ url: URL) -> String {
        "url|\(url.absoluteString)"
    }

    private func downloadImageViaWS(path: String, file: String, simpleValue: String?, lossless: Bool) async -> Data? {
        var imageMap: [String: MessagePackValue] = [
            "path": .string(path),
            "file": .string(file)
        ]
        if let simpleValue, !simpleValue.isEmpty {
            imageMap["simple"] = .string(simpleValue)
        }

        let payloadMap: [String: MessagePackValue] = [
            "type": .string("download"),
            "action": .string("image"),
            "image": .map(imageMap),
            "lossless": .bool(lossless)
        ]

        guard let response = try? await requestMap(payloadMap: payloadMap) else {
            return nil
        }

        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else { return nil }

        for key in ["file", "simple"] {
            guard let imageValue = response[key] else { continue }

            switch imageValue {
            case .binary(let data):
                return data
            case .map(let map):
                if case .binary(let data)? = map["buffer"] {
                    return data
                }
            default:
                continue
            }
        }

        return nil
    }

    func downloadFile(path: String, file: String) async -> URL? {
        guard let normalizedPath = normalized(path),
              let normalizedFile = normalized(file) else {
            return nil
        }

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("ElementVideoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let safeName = normalizedPath.replacingOccurrences(of: "/", with: "_") + "_" + normalizedFile
        let targetURL = cacheDir.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            return targetURL
        }

        guard let fullData = await downloadFileData(path: normalizedPath, file: normalizedFile, maxTotalBytes: 300 * 1024 * 1024) else {
            return nil
        }

        do {
            try fullData.write(to: targetURL, options: .atomic)
            return targetURL
        } catch {
            return nil
        }
    }

    private func downloadFileData(path: String, file: String, maxTotalBytes: Int) async -> Data? {
        var offset = 0
        var fullData = Data()
        var isLastChunk = false
        var iteration = 0

        while !isLastChunk {
            iteration += 1
            if iteration > 50_000 { return nil }

            let payloadMap: [String: MessagePackValue] = [
                "type": .string("download"),
                "action": .string("file"),
                "payload": .map([
                    "path": .string(path),
                    "file": .string(file),
                    "offset": .int(Int64(offset))
                ])
            ]

            guard let response = try? await requestMap(payloadMap: payloadMap) else {
                return nil
            }

            let statusCode = intValue(response["status"])
            guard statusCode == 200 else { return nil }

            guard let chunk = extractBinary(response["buffer"]), !chunk.isEmpty else {
                return nil
            }

            fullData.append(chunk)
            if fullData.count > maxTotalBytes {
                return nil
            }

            offset += chunk.count
            isLastChunk = boolValue(response["is_last_chunk"]) ?? false
        }

        return fullData
    }

    private func normalized(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: "\\/", with: "/")
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func filesURL(path rawPath: String, file rawFile: String) -> URL? {
        guard let file = normalized(rawFile) else { return nil }
        let path = normalized(rawPath)?
            .replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        let normalizedFile = file
            .replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        let relative: String
        if normalizedFile.contains("/") {
            relative = normalizedFile
        } else if let path, !path.isEmpty {
            relative = "\(path)/\(normalizedFile)"
        } else {
            relative = normalizedFile
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "elemsocial.com"
        components.path = "/files/\(relative)"
        return components.url
    }

    private func fetchData(url: URL) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            print("[HTTP][GET] \(url.absoluteString)")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("[HTTP][ERROR] invalid response \(url.absoluteString)")
                return nil
            }
            print("[HTTP][STATUS] \(http.statusCode) \(url.absoluteString)")
            guard (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            print("[HTTP][ERROR] \(error.localizedDescription) \(url.absoluteString)")
            return nil
        }
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        let payload = LoginRequest(email: username, password: password)
        let response: LoginResponse = try await request(payload: payload, responseType: LoginResponse.self)

        if response.needsEmailVerification {
            return response
        }

        if response.status.lowercased() == "error" {
            throw APIError.serverError(response.message ?? "Ошибка логина")
        }

        guard let sKey = response.sKey else {
            return response
        }

        let accountData = try await completeSession(sKey: sKey)

        return LoginResponse(
            status: response.status,
            sKey: sKey,
            message: response.message,
            email: response.email,
            accountData: accountData
        )
    }

    /// `social/auth/reg` — web Authorization.tsx parity.
    /// hCaptcha token is required by the server (`h_captcha`).
    func registerAccount(
        name: String,
        username: String,
        email: String,
        password: String,
        referralCode: String,
        accept: Bool,
        captchaToken: String
    ) async throws -> LoginResponse {
        // Web parity: auth/reg sends ONLY these fields (device_* — login only).
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("auth/reg"),
            "name": .string(name),
            "username": .string(username),
            "email": .string(email),
            "password": .string(password),
            "referral_code": .string(referralCode),
            "accept": .bool(accept),
            "h_captcha": .string(captchaToken)
        ])

        return try await parseAuthResponse(response)
    }

    /// `social/auth/verify_email` — confirms the code and authorizes.
    func verifyEmail(email: String, code: String) async throws -> LoginResponse {
        // Web strips every whitespace char: code.replace(/\s/g, '')
        let normalizedCode = code.components(separatedBy: .whitespacesAndNewlines).joined()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("auth/verify_email"),
            "email": .string(email),
            "code": .string(normalizedCode),
            "device_type": .string("ios_app"),
            "device": .string("Element iOS v\(version)")
        ])

        return try await parseAuthResponse(response)
    }

    /// `social/auth/resend_verification`
    func resendEmailVerification(email: String) async throws {
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("auth/resend_verification"),
            "email": .string(email)
        ])
        guard stringValue(response["status"])?.lowercased() == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось отправить код")
        }
    }

    private func parseAuthResponse(_ response: [String: MessagePackValue]) async throws -> LoginResponse {
        let status = stringValue(response["status"])?.lowercased() ?? "error"

        if status == "verify_email" {
            return LoginResponse(
                status: "verify_email",
                sKey: nil,
                message: stringValue(response["message"]),
                email: stringValue(response["email"]),
                accountData: nil
            )
        }

        if status == "error" {
            throw APIError.serverError(stringValue(response["message"]) ?? "Ошибка авторизации")
        }

        guard let sKey = stringValue(response["S_KEY"]) ?? stringValue(response["s_key"]) else {
            throw APIError.serverError("Сервер не вернул ключ сессии")
        }

        let accountData = try await completeSession(sKey: sKey)

        return LoginResponse(
            status: "success",
            sKey: sKey,
            message: stringValue(response["message"]),
            email: stringValue(response["email"]),
            accountData: accountData
        )
    }

    /// Runs `authorization/connect` for a fresh S_KEY and populates the
    /// current-user snapshot (shared by login / register / verify flows).
    @discardableResult
    private func completeSession(sKey: String) async throws -> User? {
        currentSKey = sKey

        let connectResponse: ConnectResponse = try await request(payload: ConnectRequest(sKey: sKey), responseType: ConnectResponse.self)
        if connectResponse.status.lowercased() == "error" {
            throw APIError.serverError(connectResponse.message ?? "Ошибка connect")
        }

        let previousID = currentUserID
        currentUserID = connectResponse.accountData?.id
        currentUserName = connectResponse.accountData?.name
        currentUsername = connectResponse.accountData?.username
        currentUserEmail = connectResponse.accountData?.email
        currentUserEBalls = connectResponse.accountData?.eBalls
        currentUserNotifications = connectResponse.accountData?.notifications
        currentUserMessengerNotifications = connectResponse.accountData?.messengerNotifications
        currentUserAvatar = parseAvatar(raw: connectResponse.accountData?.avatar)
        currentUserPermissions = connectResponse.accountData?.permissions
        currentUserGoldStatus = connectResponse.accountData?.goldStatus
        currentUserGoldHistory = connectResponse.accountData?.goldHistory ?? []
        currentUserChannels = connectResponse.accountData?.channels ?? []
        currentSelectedChannel = nil

        if let previousID, let newID = currentUserID, previousID != newID {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: APIClient.accountDidChangeNotification,
                    object: self,
                    userInfo: ["userID": newID]
                )
            }
        }

        return connectResponse.accountData
    }

    /// Site-parity account switch (`WebSocket.jsx → update()`): the web client
    /// never drops the socket — it just re-sends `authorization/connect` with
    /// the new S_KEY over the live connection. Falls back to a full reconnect
    /// only when there is no healthy socket.
    @MainActor
    func switchAccountSession(sKey: String) async -> Bool {
        if isSocketReady {
            do {
                try await restoreAuthorization(sKey: sKey)
                currentSKey = sKey
                return true
            } catch is CancellationError {
                return false
            } catch {
                print("[AUTH][SWITCH] live re-auth failed: \(error.localizedDescription) — falling back to reconnect")
            }
        }
        return await restoreSession(sKey: sKey, forceReconnect: true)
    }

    /// Restores (or switches) the session for `sKey`.
    ///
    /// - `forceReconnect` drops the current socket first — mandatory for account
    ///   switching, otherwise `connectIfNeeded()` short-circuits on the live
    ///   socket and the server never sees the new `authorization/connect`.
    /// - Calls are serialized: concurrent invocations (double taps, scenePhase
    ///   bootstraps) no longer destroy each other's connection attempts.
    ///   Same-key requests coalesce into the running one instead of fighting.
    @MainActor
    func restoreSession(sKey: String, forceReconnect: Bool = false) async -> Bool {
        // Fast path: this identity is already live on a healthy socket.
        if sKey == currentSKey, isSocketReady, !forceReconnect {
            return true
        }

        // Serialize behind an in-flight restore.
        if restoreState.runningKey != nil {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                restoreState.doneContinuations.append(cont)
            }
            // An identical request completed while waiting → done.
            if sKey == currentSKey, isSocketReady, !forceReconnect {
                return true
            }
        }

        restoreState.runningKey = sKey
        defer {
            restoreState.runningKey = nil
            let conts = restoreState.doneContinuations
            restoreState.doneContinuations.removeAll()
            conts.forEach { $0.resume() }
        }

        return await performRestoreWithRetry(sKey: sKey, forceReconnect: forceReconnect)
    }

    @MainActor
    private func performRestoreWithRetry(sKey: String, forceReconnect: Bool) async -> Bool {
        let attemptRestore: () async throws -> Void = { [self] in
            if forceReconnect {
                disconnect()
            }
            self.currentSKey = sKey
            try await self.connectIfNeeded()
            self.currentSKey = sKey
        }

        do {
            try await attemptRestore()
            return true
        } catch is CancellationError {
            print("[AUTH][RESTORE] cancelled, retrying once")
            disconnect()
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                try await attemptRestore()
                return true
            } catch {
                print("[AUTH][RESTORE] failed after retry: \(error.localizedDescription)")
                return false
            }
        } catch {
            print("[AUTH][RESTORE] failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Serialized restore bookkeeping. Only touched from `@MainActor`
    /// restore paths (`restoreSession` / `performRestoreWithRetry`).
    private final class RestoreState {
        var runningKey: String?
        var doneContinuations: [CheckedContinuation<Void, Never>] = []
    }

    private var restoreState = RestoreState()

    func loadPosts(startIndex: Int = 0, postsType: String = "last") async throws -> LoadPostsResponse {
        let attempts: [LoadPostsRequest] = [
            LoadPostsRequest(postsType: postsType, startIndex: startIndex, sKey: currentSKey),
            LoadPostsRequest(postsType: "rec", startIndex: startIndex, sKey: currentSKey),
            LoadPostsRequest(postsType: "subscribe", startIndex: startIndex, sKey: currentSKey),
            LoadPostsRequest(
                postsType: "profile",
                startIndex: startIndex,
                authorID: currentUserID,
                authorType: 0,
                sKey: currentSKey
            )
        ]

        var lastError: String = "Ошибка загрузки постов"

        for payload in attempts {
            do {
                print("[POSTS][LOAD][ATTEMPT] type=\(payload.payload.postsType) start=\(payload.payload.startIndex)")
                let response: LoadPostsResponse = try await request(payload: payload, responseType: LoadPostsResponse.self)
                if response.status.lowercased() == "success" {
                    let count = response.posts?.count ?? 0
                    let firstDate = response.posts?.first?.createDate ?? "-"
                    let lastDate = response.posts?.last?.createDate ?? "-"
                    print("[POSTS][LOAD][OK] type=\(payload.payload.postsType) count=\(count) first=\(firstDate) last=\(lastDate)")
                    return response
                }
                if (response.message ?? "").localizedCaseInsensitiveContains("Ошибка при выводе постов") {
                    print("[POSTS][LOAD][EMPTY] type=\(payload.payload.postsType) server_message=Ошибка при выводе постов")
                    return LoadPostsResponse(status: "success   ", message: nil, posts: [])
                }
                print("[POSTS][LOAD][FAIL] type=\(payload.payload.postsType) message=\(response.message ?? "unknown")")
                lastError = response.message ?? lastError
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("[POSTS][LOAD][ERROR] type=\(payload.payload.postsType) error=\(error.localizedDescription)")
                lastError = error.localizedDescription
            }
        }

        throw APIError.serverError(lastError)
    }

    func loadProfile(username: String) async throws -> ProfileData {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("get_profile"),
            "username": .string(username)
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить профиль")
        }

        guard case .map(let data)? = response["data"] else {
            throw APIError.invalidResponse
        }

        guard let id = intValue(data["id"]) else {
            throw APIError.invalidResponse
        }

        let typeRaw = intValue(data["type"])
        let typeString = stringValue(data["type"])?.lowercased()
        let type: Int
        if let typeRaw {
            type = typeRaw
        } else if typeString == "channel" {
            type = 1
        } else {
            type = 0
        }
        let name = stringValue(data["name"]) ?? username
        let profileUsername = stringValue(data["username"]) ?? username
        let description = stringValue(data["description"])
        let postsCount = intValue(data["posts"]) ?? 0
        let subscribersCount = intValue(data["subscribers"]) ?? 0
        let subscribedCount = intValue(data["subscriptions"]) ?? intValue(data["subscribed"]) ?? 0
        let giftsCount = intValue(data["gifts_count"]) ?? 0
        let archivePostsCount = intValue(data["archive_posts_count"]) ?? 0
        let trashBinPostsCount = intValue(data["trash_bin_posts_count"]) ?? 0
        let isSubscribed = boolValue(data["subscribed"]) ?? false
        let isBlocked = boolValue(data["blocked"]) ?? false
        let isMyProfile = boolValue(data["my_profile"]) ?? false
        let isOnline = boolValue(data["online"]) ?? false
        let isMuted = boolValue(data["muted"]) ?? false
        let createDate = stringValue(data["create_date"])
        let lastOnline = stringValue(data["last_online"])
        let iconIDs = parseIconIDs(data["icons"])
        let iconHasVerify = iconIDs.contains("VERIFY")
        let iconHasGold = iconIDs.contains("GOLD")
        let isVerified = boolValue(data["verified"])
            ?? boolValue(data["verify"])
            ?? boolValue(data["is_verified"])
            ?? (iconHasVerify ? true : nil)
        let goldStatus = boolValue(data["gold_status"])
            ?? boolValue(data["gold"])
            ?? boolValue(data["subscription"])
            ?? boolValue(data["is_gold"])
            ?? boolValue(data["premium"])
            ?? (iconHasGold ? true : nil)

        let avatar = parseMediaData(value: data["avatar"], defaultPath: "avatars")
        let cover = parseMediaData(value: data["cover"], defaultPath: "covers")
        let listeningSong: MusicSong?
        if case .map(let songMap)? = data["listening_song"] {
            listeningSong = parseMusicSong(from: songMap)
        } else {
            listeningSong = nil
        }

        let links = parseProfileLinks(data["links"])

        return ProfileData(
            id: id,
            type: type,
            name: name,
            username: profileUsername,
            description: description,
            avatar: avatar,
            cover: cover,
            listeningSong: listeningSong,
            isOnline: isOnline,
            postsCount: postsCount,
            subscribersCount: subscribersCount,
            subscribedCount: subscribedCount,
            giftsCount: giftsCount,
            archivePostsCount: archivePostsCount,
            trashBinPostsCount: trashBinPostsCount,
            isSubscribed: isSubscribed,
            isBlocked: isBlocked,
            isMyProfile: isMyProfile,
            createDate: createDate,
            lastOnline: lastOnline,
            isVerified: isVerified,
            goldStatus: goldStatus,
            isMuted: isMuted,
            links: links
        )
    }

    private func parseProfileLinks(_ value: MessagePackValue?) -> [ProfileLink] {
        guard case .array(let arr)? = value else { return [] }
        return arr.compactMap { item -> ProfileLink? in
            guard case .map(let m) = item,
                  let id = intValue(m["id"]),
                  let title = stringValue(m["title"]),
                  let url = stringValue(m["url"]) ?? stringValue(m["link"])
            else { return nil }
            return ProfileLink(id: id, title: title, url: url)
        }
    }

    func toggleProfileSubscription(username: String) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Пустой username")
        }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("profile/subscribe"),
            "payload": .map([
                "username": .string(trimmed)
            ])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error" || response["message"] != nil && !(stringValue(response["message"]) ?? "").isEmpty
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "profile/subscribe") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось обновить подписку")
        }
    }

    func toggleProfileMuted(username: String, mute: Bool) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Пустой username")
        }

        let action = mute ? "profile/mute" : "profile/unmute"
        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string(action),
            "payload": .map([
                "username": .string(trimmed)
            ])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let expectedAction = action.lowercased()
        let hasExplicitError = statusString == "error" || response["message"] != nil && !(stringValue(response["message"]) ?? "").isEmpty
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == expectedAction) && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить статус уведомлений")
        }
    }

    func payGoldSubscription() async throws {
        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("gold/pay")
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        try ensureGoldActionSuccess(response, fallbackError: "Не удалось оплатить подписку")

        applyGoldSuccessUpdate(shouldChargeBalance: true)
    }

    func activateGoldSubscription(code: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Введите код")
        }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("gold/activate"),
            "code": .string(trimmed)
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        try ensureGoldActionSuccess(response, fallbackError: "Не удалось активировать подписку")

        applyGoldSuccessUpdate(shouldChargeBalance: false)
    }

    func blockProfile(username: String) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("block_profile"),
            "username": .string(trimmed)
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось заблокировать")
        }
    }

    func unblockProfile(username: String) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("unblock_profile"),
            "username": .string(trimmed)
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось разблокировать")
        }
    }

    func sendReport(targetType: String, targetId: Int, category: String, message: String) async throws {
        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("moderation/send_report"),
            "payload": .map([
                "target_type": .string(targetType),
                "target_id": .int(Int64(targetId)),
                "category": .string(category),
                "message": .string(message)
            ])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось отправить жалобу")
        }
    }

    func loadProfileSubscribers(username: String, startIndex: Int = 0) async throws -> [PostAuthor] {
        return try await loadProfileUsers(action: "profile/load_subscribers", username: username, startIndex: startIndex)
    }

    func loadProfileSubscriptions(username: String, startIndex: Int = 0) async throws -> [PostAuthor] {
        return try await loadProfileUsers(action: "profile/load_subscriptions", username: username, startIndex: startIndex)
    }

    func loadProfilePosts(
        postsType: String,
        username: String?,
        targetID: Int,
        targetType: Int,
        startIndex: Int = 0
    ) async throws -> [Post] {
        var attempts: [[String: MessagePackValue]] = []
        let targetTypeString = targetType == 1 ? "channel" : "user"
        let authorIDString = String(targetID)

        var primaryPayload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "payload": .map([
                "posts_type": .string(postsType),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let username, !username.isEmpty {
            if case .map(let payload)? = primaryPayload["payload"] {
                var updated = payload
                updated["username"] = .string(username)
                primaryPayload["payload"] = .map(updated)
            }
        }
        if postsType == "profile" {
            if case .map(let payload)? = primaryPayload["payload"] {
                var updated = payload
                updated["author_type"] = .string(targetTypeString)
                updated["author_id"] = .string(authorIDString)
                primaryPayload["payload"] = .map(updated)
            }
        }
        if let currentSKey {
            primaryPayload["S_KEY"] = .string(currentSKey)
        }
        attempts.append(primaryPayload)

        var flatPayload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "posts_type": .string(postsType),
            "target_id": .int(Int64(targetID)),
            "target_type": .int(Int64(targetType)),
            "start_index": .int(Int64(startIndex))
        ]
        if let username, !username.isEmpty {
            flatPayload["username"] = .string(username)
        }
        if let currentSKey {
            flatPayload["S_KEY"] = .string(currentSKey)
        }
        attempts.append(flatPayload)

        var flatPayloadStringType: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "posts_type": .string(postsType),
            "target_id": .int(Int64(targetID)),
            "target_type": .string(targetTypeString),
            "start_index": .int(Int64(startIndex))
        ]
        if let username, !username.isEmpty {
            flatPayloadStringType["username"] = .string(username)
        }
        if let currentSKey {
            flatPayloadStringType["S_KEY"] = .string(currentSKey)
        }
        attempts.append(flatPayloadStringType)

        var flatCompatibility: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "posts_type": .string(postsType),
            "author_id": .int(Int64(targetID)),
            "author_type": .int(Int64(targetType)),
            "start_index": .int(Int64(startIndex))
        ]
        if let username, !username.isEmpty {
            flatCompatibility["username"] = .string(username)
        }
        if let currentSKey {
            flatCompatibility["S_KEY"] = .string(currentSKey)
        }
        attempts.append(flatCompatibility)

        var flatCompatibilityStringType: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "posts_type": .string(postsType),
            "author_id": .int(Int64(targetID)),
            "author_type": .string(targetTypeString),
            "start_index": .int(Int64(startIndex))
        ]
        if let username, !username.isEmpty {
            flatCompatibilityStringType["username"] = .string(username)
        }
        if let currentSKey {
            flatCompatibilityStringType["S_KEY"] = .string(currentSKey)
        }
        attempts.append(flatCompatibilityStringType)

        var flatTargetMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "posts_type": .string(postsType),
            "target": .map([
                "id": .int(Int64(targetID)),
                "type": .int(Int64(targetType))
            ]),
            "start_index": .int(Int64(startIndex))
        ]
        if let username, !username.isEmpty {
            flatTargetMap["username"] = .string(username)
        }
        if let currentSKey {
            flatTargetMap["S_KEY"] = .string(currentSKey)
        }
        attempts.append(flatTargetMap)

        var flatTargetMapStringType: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "posts_type": .string(postsType),
            "target": .map([
                "id": .int(Int64(targetID)),
                "type": .string(targetTypeString)
            ]),
            "start_index": .int(Int64(startIndex))
        ]
        if let username, !username.isEmpty {
            flatTargetMapStringType["username"] = .string(username)
        }
        if let currentSKey {
            flatTargetMapStringType["S_KEY"] = .string(currentSKey)
        }
        attempts.append(flatTargetMapStringType)

        var canonicalPayload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "payload": .map([
                "posts_type": .string(postsType),
                "target_id": .int(Int64(targetID)),
                "target_type": .int(Int64(targetType)),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let username, !username.isEmpty {
            if case .map(let payload)? = canonicalPayload["payload"] {
                var updated = payload
                updated["username"] = .string(username)
                canonicalPayload["payload"] = .map(updated)
            }
        }
        if let currentSKey {
            canonicalPayload["S_KEY"] = .string(currentSKey)
        }
        attempts.append(canonicalPayload)

        var canonicalPayloadStringType: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "payload": .map([
                "posts_type": .string(postsType),
                "target_id": .int(Int64(targetID)),
                "target_type": .string(targetTypeString),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let username, !username.isEmpty {
            if case .map(let payload)? = canonicalPayloadStringType["payload"] {
                var updated = payload
                updated["username"] = .string(username)
                canonicalPayloadStringType["payload"] = .map(updated)
            }
        }
        if let currentSKey {
            canonicalPayloadStringType["S_KEY"] = .string(currentSKey)
        }
        attempts.append(canonicalPayloadStringType)

        var compatibilityPayload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "payload": .map([
                "posts_type": .string(postsType),
                "author_id": .int(Int64(targetID)),
                "author_type": .int(Int64(targetType)),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let username, !username.isEmpty {
            if case .map(let payload)? = compatibilityPayload["payload"] {
                var updated = payload
                updated["username"] = .string(username)
                compatibilityPayload["payload"] = .map(updated)
            }
        }
        if let currentSKey {
            compatibilityPayload["S_KEY"] = .string(currentSKey)
        }
        attempts.append(compatibilityPayload)

        var compatibilityPayloadStringType: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "payload": .map([
                "posts_type": .string(postsType),
                "author_id": .int(Int64(targetID)),
                "author_type": .string(targetTypeString),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let username, !username.isEmpty {
            if case .map(let payload)? = compatibilityPayloadStringType["payload"] {
                var updated = payload
                updated["username"] = .string(username)
                compatibilityPayloadStringType["payload"] = .map(updated)
            }
        }
        if let currentSKey {
            compatibilityPayloadStringType["S_KEY"] = .string(currentSKey)
        }
        attempts.append(compatibilityPayloadStringType)

        var payloadTargetMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "payload": .map([
                "posts_type": .string(postsType),
                "target": .map([
                    "id": .int(Int64(targetID)),
                    "type": .int(Int64(targetType))
                ]),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let username, !username.isEmpty {
            if case .map(let payload)? = payloadTargetMap["payload"] {
                var updated = payload
                updated["username"] = .string(username)
                payloadTargetMap["payload"] = .map(updated)
            }
        }
        if let currentSKey {
            payloadTargetMap["S_KEY"] = .string(currentSKey)
        }
        attempts.append(payloadTargetMap)

        var payloadTargetMapStringType: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_posts"),
            "payload": .map([
                "posts_type": .string(postsType),
                "target": .map([
                    "id": .int(Int64(targetID)),
                    "type": .string(targetTypeString)
                ]),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let username, !username.isEmpty {
            if case .map(let payload)? = payloadTargetMapStringType["payload"] {
                var updated = payload
                updated["username"] = .string(username)
                payloadTargetMapStringType["payload"] = .map(updated)
            }
        }
        if let currentSKey {
            payloadTargetMapStringType["S_KEY"] = .string(currentSKey)
        }
        attempts.append(payloadTargetMapStringType)

        if postsType == "profile" {
            let fallbackType = "last"
            var authorFlat: [String: MessagePackValue] = [
                "type": .string("social"),
                "action": .string("load_posts"),
                "posts_type": .string(fallbackType),
                "author_id": .int(Int64(targetID)),
                "author_type": .int(Int64(targetType)),
                "start_index": .int(Int64(startIndex))
            ]
            if let username, !username.isEmpty {
                authorFlat["username"] = .string(username)
            }
            if let currentSKey {
                authorFlat["S_KEY"] = .string(currentSKey)
            }
            attempts.append(authorFlat)

            var authorPayload: [String: MessagePackValue] = [
                "type": .string("social"),
                "action": .string("load_posts"),
                "payload": .map([
                    "posts_type": .string(fallbackType),
                    "author_id": .int(Int64(targetID)),
                    "author_type": .int(Int64(targetType)),
                    "start_index": .int(Int64(startIndex))
                ])
            ]
            if let username, !username.isEmpty {
                if case .map(let payload)? = authorPayload["payload"] {
                    var updated = payload
                    updated["username"] = .string(username)
                    authorPayload["payload"] = .map(updated)
                }
            }
            if let currentSKey {
                authorPayload["S_KEY"] = .string(currentSKey)
            }
            attempts.append(authorPayload)

            var authorFlatStringType: [String: MessagePackValue] = [
                "type": .string("social"),
                "action": .string("load_posts"),
                "posts_type": .string(fallbackType),
                "author_id": .int(Int64(targetID)),
                "author_type": .string(targetTypeString),
                "start_index": .int(Int64(startIndex))
            ]
            if let username, !username.isEmpty {
                authorFlatStringType["username"] = .string(username)
            }
            if let currentSKey {
                authorFlatStringType["S_KEY"] = .string(currentSKey)
            }
            attempts.append(authorFlatStringType)

            var authorPayloadStringType: [String: MessagePackValue] = [
                "type": .string("social"),
                "action": .string("load_posts"),
                "payload": .map([
                    "posts_type": .string(fallbackType),
                    "author_id": .int(Int64(targetID)),
                    "author_type": .string(targetTypeString),
                    "start_index": .int(Int64(startIndex))
                ])
            ]
            if let username, !username.isEmpty {
                if case .map(let payload)? = authorPayloadStringType["payload"] {
                    var updated = payload
                    updated["username"] = .string(username)
                    authorPayloadStringType["payload"] = .map(updated)
                }
            }
            if let currentSKey {
                authorPayloadStringType["S_KEY"] = .string(currentSKey)
            }
            attempts.append(authorPayloadStringType)
        }

        var lastError = "Не удалось загрузить посты профиля"

        for payload in attempts {
            do {
                let response = try await requestMap(payloadMap: payload)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let isSuccess = statusCode == 200 || statusString == "success"
                guard isSuccess else {
                    if let message = stringValue(response["message"]), !message.isEmpty {
                        lastError = message
                    }
                    if lastError.localizedCaseInsensitiveContains("Ошибка при выводе постов") {
                        return []
                    }
                    continue
                }

                guard case .array(let postsArray)? = response["posts"] else {
                    return []
                }

                let posts = postsArray.compactMap { value -> Post? in
                    guard case .map(let map) = value else { return nil }
                    return decodeMap(map, as: Post.self)
                }
                return posts
            } catch {
                lastError = error.localizedDescription
            }
        }

        throw APIError.serverError(lastError)
    }

    func loadPost(postID: Int) async throws -> Post {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_post"),
            "pid": .int(Int64(postID))
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "load_post") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить пост")
        }

        if case .map(let map)? = response["post"],
           let post: Post = decodeMap(map, as: Post.self) {
            return post
        }

        if let post: Post = decodeMap(response, as: Post.self) {
            return post
        }

        throw APIError.invalidResponse
    }

    func createPost(
        text: String,
        files: [UploadFile] = [],
        songIDs: [Int] = [],
        poll: PostPollDraft? = nil,
        fromChannelID: Int? = nil
    ) async throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty || !songIDs.isEmpty || poll != nil else {
            throw APIError.serverError("Текст поста пустой")
        }

        let filesPayload: [MessagePackValue] = files.map { file in
            .map([
                "name": .string(file.name),
                "buffer": .binary(file.data)
            ])
        }

        var payload: [String: MessagePackValue] = [
            "text": .string(trimmed),
            "files": .array(filesPayload),
            "settings": .map([
                "clear_metadata_img": .bool(true),
                "censoring_img": .bool(false)
            ])
        ]
        if let fromChannelID {
            payload["from"] = .map([
                "type": .int(1),
                "id": .int(Int64(fromChannelID))
            ])
        }
        if !songIDs.isEmpty {
            payload["songs"] = .array(songIDs.map { .int(Int64($0)) })
        }
        if let poll, poll.isValid {
            payload["poll"] = .map([
                "question": .string(poll.normalizedQuestion),
                "options": .array(poll.normalizedOptions.map { .string($0) }),
                "is_anonymous": .bool(poll.isAnonymous),
                "multiple_choice": .bool(poll.multipleChoice)
            ])
        }

        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("posts/add"),
            "payload": .map(payload)
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось опубликовать пост")
        }

        return intValue(response["post_id"])
    }

    func createWallPost(
        text: String,
        files: [UploadFile] = [],
        songIDs: [Int] = [],
        poll: PostPollDraft? = nil,
        targetID: Int,
        targetType: Int,
        username: String?,
        fromChannelID: Int? = nil
    ) async throws -> Int? {
        _ = targetID
        _ = targetType
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty || !songIDs.isEmpty || poll != nil else {
            throw APIError.serverError("Текст поста пустой")
        }

        let filesPayload: [MessagePackValue] = files.map { file in
            .map([
                "name": .string(file.name),
                "buffer": .binary(file.data)
            ])
        }

        guard let username, !username.isEmpty else {
            throw APIError.serverError("Не указан профиль стены")
        }

        var basePayload: [String: MessagePackValue] = [
            "text": .string(trimmed),
            "files": .array(filesPayload),
            "settings": .map([
                "clear_metadata_img": .bool(true),
                "censoring_img": .bool(false)
            ]),
            "type": .string("wall"),
            "wall": .map([
                "username": .string(username)
            ])
        ]
        if let fromChannelID {
            basePayload["from"] = .map([
                "type": .int(1),
                "id": .int(Int64(fromChannelID))
            ])
        }
        if !songIDs.isEmpty {
            basePayload["songs"] = .array(songIDs.map { .int(Int64($0)) })
        }
        if let poll, poll.isValid {
            basePayload["poll"] = .map([
                "question": .string(poll.normalizedQuestion),
                "options": .array(poll.normalizedOptions.map { .string($0) }),
                "is_anonymous": .bool(poll.isAnonymous),
                "multiple_choice": .bool(poll.multipleChoice)
            ])
        }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("posts/add"),
            "payload": .map(basePayload)
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось опубликовать пост на стене")
        }

        return intValue(response["post_id"])
    }

    func setPostReaction(postID: Int, action: String) async throws {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string(action),
            "payload": .map([
                "post_id": .int(Int64(postID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let expectedAction = action.lowercased()
        let hasExplicitError = statusString == "error" || response["message"] != nil && !(stringValue(response["message"]) ?? "").isEmpty

        // Backend often replies for reactions without `status` (only `action` + `ray_id`).
        // Treat matching action as success unless explicit error is provided.
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == expectedAction) && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось обновить реакцию")
        }
    }

    func setPostReaction(postID: Int, reaction: String, isRemoving: Bool) async throws {
        let action = isRemoving ? "post/unset_reaction" : "post/set_reaction"
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string(action),
            "payload": .map([
                "post_id": .int(Int64(postID)),
                "reaction": .string(reaction.uppercased())
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error" || response["message"] != nil && !(stringValue(response["message"]) ?? "").isEmpty
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == action) && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось обновить реакцию")
        }
    }

    func deletePost(postID: Int) async throws {
        let attempts: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/delete"),
                    "payload": .map([
                        "post_id": .int(Int64(postID))
                    ])
                ],
                "posts/delete"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/remove"),
                    "payload": .map([
                        "post_id": .int(Int64(postID))
                    ])
                ],
                "posts/remove"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("post/delete"),
                    "payload": .map([
                        "id": .int(Int64(postID))
                    ])
                ],
                "post/delete"
            )
        ]

        var lastError = "Не удалось удалить пост"
        for (payload, expectedAction) in attempts {
            do {
                let response = try await requestMap(payloadMap: payload)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let responseAction = stringValue(response["action"])?.lowercased()
                let isSuccess = statusCode == 200 || statusString == "success" || responseAction == expectedAction
                if isSuccess {
                    return
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    /// `posts/edit` — web EditPostModal parity: text + new attachment uploads
    /// (`[{name, buffer}]`) + `removed_file_ids` of existing images/files.
    /// Returns refreshed attachment blocks for local merge.
    func editPost(
        postID: Int,
        text: String,
        newFiles: [UploadFile] = [],
        removedFileIDs: [Int] = []
    ) async throws -> (images: [PostImage]?, files: [PostFile]?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachmentChanges = !newFiles.isEmpty || !removedFileIDs.isEmpty
        guard !trimmed.isEmpty || hasAttachmentChanges else {
            throw APIError.serverError("Введите текст поста")
        }

        var payloadInner: [String: MessagePackValue] = [
            "post_id": .int(Int64(postID)),
            "text": .string(trimmed)
        ]
        if !removedFileIDs.isEmpty {
            payloadInner["removed_file_ids"] = .array(removedFileIDs.map { .int(Int64($0)) })
        }
        if !newFiles.isEmpty {
            payloadInner["files"] = .array(newFiles.map { file in
                .map([
                    "name": .string(file.name),
                    "buffer": .binary(file.data)
                ])
            })
        }

        let attempts: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/edit"),
                    "payload": .map(payloadInner)
                ],
                "posts/edit"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("post/edit"),
                    "payload": .map([
                        "id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "post/edit"
            )
        ]

        var lastError = "Не удалось изменить пост"
        for (index, attempt) in attempts.enumerated() {
            // The legacy fallback only makes sense for text-only edits.
            if index > 0 && hasAttachmentChanges { break }
            let (payload, expectedAction) = attempt
            do {
                let response = try await requestMap(payloadMap: payload)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let responseAction = stringValue(response["action"])?.lowercased()
                let isSuccess = statusCode == 200 || statusString == "success" || responseAction == expectedAction
                if isSuccess {
                    return (
                        images: decodePostAttachmentBlock(response["images"], as: PostEditImagesBlock.self)?.items,
                        files: decodePostAttachmentBlock(response["files"], as: PostEditFilesBlock.self)?.items
                    )
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    private struct PostEditImagesBlock: Decodable {
        let items: [PostImage]?
    }

    private struct PostEditFilesBlock: Decodable {
        let items: [PostFile]?
    }

    private func decodePostAttachmentBlock<T: Decodable>(_ value: MessagePackValue?, as type: T.Type) -> T? {
        guard let value else { return nil }
        let object = MessagePack.toJSONObject(value)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? decoder.decode(T.self, from: data) else {
            return nil
        }
        return decoded
    }

    func restorePost(postID: Int) async throws {
        let attempts: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/restore"),
                    "payload": .map([
                        "post_id": .int(Int64(postID))
                    ])
                ],
                "posts/restore"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("post/restore"),
                    "payload": .map([
                        "id": .int(Int64(postID))
                    ])
                ],
                "post/restore"
            )
        ]

        var lastError = "Не удалось восстановить пост"
        for (payload, expectedAction) in attempts {
            do {
                let response = try await requestMap(payloadMap: payload)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let responseAction = stringValue(response["action"])?.lowercased()
                let isSuccess = statusCode == 200 || statusString == "success" || responseAction == expectedAction
                if isSuccess {
                    return
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    func deletePostForever(postID: Int) async throws {
        let attempts: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/delete_forever"),
                    "payload": .map([
                        "post_id": .int(Int64(postID))
                    ])
                ],
                "posts/delete_forever"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("post/delete_forever"),
                    "payload": .map([
                        "id": .int(Int64(postID))
                    ])
                ],
                "post/delete_forever"
            )
        ]

        var lastError = "Не удалось удалить пост навсегда"
        for (payload, expectedAction) in attempts {
            do {
                let response = try await requestMap(payloadMap: payload)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let responseAction = stringValue(response["action"])?.lowercased()
                let isSuccess = statusCode == 200 || statusString == "success" || responseAction == expectedAction
                if isSuccess {
                    return
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    func toggleArchive(postID: Int, shouldArchive: Bool) async throws {
        let action = shouldArchive ? "posts/add_to_archive" : "posts/remove_from_archive"
        let fallbackAction = shouldArchive ? "posts/archive" : "posts/archive_remove"
        let attempts: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string(action),
                    "payload": .map([
                        "post_id": .int(Int64(postID))
                    ])
                ],
                action
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string(fallbackAction),
                    "payload": .map([
                        "post_id": .int(Int64(postID))
                    ])
                ],
                fallbackAction
            )
        ]

        var lastError = shouldArchive ? "Не удалось архивировать пост" : "Не удалось удалить из архива"
        for (payload, expectedAction) in attempts {
            do {
                let response = try await requestMap(payloadMap: payload)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let responseAction = stringValue(response["action"])?.lowercased()
                let isSuccess = statusCode == 200 || statusString == "success" || responseAction == expectedAction
                if isSuccess {
                    return
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    func deleteComment(commentID: Int, postID: Int) async throws {
        let attempts: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/delete"),
                    "payload": .map([
                        "comment_id": .int(Int64(commentID)),
                        "post_id": .int(Int64(postID))
                    ])
                ],
                "comments/delete"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/remove"),
                    "payload": .map([
                        "comment_id": .int(Int64(commentID)),
                        "post_id": .int(Int64(postID))
                    ])
                ],
                "comments/remove"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comment/delete"),
                    "payload": .map([
                        "id": .int(Int64(commentID)),
                        "post_id": .int(Int64(postID))
                    ])
                ],
                "comment/delete"
            )
        ]

        var lastError = "Не удалось удалить комментарий"
        for (payload, expectedAction) in attempts {
            do {
                let response = try await requestMap(payloadMap: payload)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let responseAction = stringValue(response["action"])?.lowercased()
                let isSuccess = statusCode == 200 || statusString == "success" || responseAction == expectedAction
                if isSuccess {
                    return
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    func loadPostComments(postID: Int, startIndex: Int = 0) async throws -> [PostComment] {
        print("[COMMENTS][LOAD][START] post_id=\(postID) start_index=\(startIndex)")
        let attempts: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/load"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "start_index": .int(Int64(startIndex))
                    ])
                ],
                "comments/load"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/load_comments"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "start_index": .int(Int64(startIndex))
                    ])
                ],
                "posts/load_comments"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("load_comments"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "start_index": .int(Int64(startIndex))
                    ])
                ],
                "load_comments"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/comments/load"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "start_index": .int(Int64(startIndex))
                    ])
                ],
                "posts/comments/load"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/load_comments"),
                    "post_id": .int(Int64(postID)),
                    "start_index": .int(Int64(startIndex))
                ],
                "posts/load_comments"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("load_comments"),
                    "post_id": .int(Int64(postID)),
                    "start_index": .int(Int64(startIndex))
                ],
                "load_comments"
            )
        ]

        var lastErrorMessage = "Не удалось загрузить комментарии"

        for (idx, pair) in attempts.enumerated() {
            let (request, expectedAction) = pair
            print("[COMMENTS][LOAD][TRY \(idx + 1)/\(attempts.count)] expected_action=\(expectedAction)")
            do {
                let response = try await requestMap(payloadMap: request)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let message = stringValue(response["message"])
                let responseAction = stringValue(response["action"])?.lowercased()
                print("[COMMENTS][LOAD][RESP \(idx + 1)] status_code=\(statusCode.map(String.init) ?? "nil") status=\(statusString ?? "nil") action=\(responseAction ?? "nil") message=\(message ?? "nil")")

                if statusString == "error" {
                    if let message { lastErrorMessage = message }
                    continue
                }

                if let comments = parseComments(from: response) {
                    print("[COMMENTS][LOAD][SUCCESS] count=\(comments.count)")
                    return comments
                }

                // Treat explicit success as empty comments list when backend returns no array.
                if statusCode == 200 || statusString == "success" || responseAction == expectedAction.lowercased() {
                    return []
                }

                if let message { lastErrorMessage = message }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }

        print("[COMMENTS][LOAD][FAIL] \(lastErrorMessage)")
        throw APIError.serverError(lastErrorMessage)
    }

    func sendPostComment(postID: Int, targetID: Int?, targetType: Int?, text: String, files: [UploadFile] = [], replyToID: Int? = nil) async throws -> PostComment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else {
            throw APIError.serverError("Комментарий пустой")
        }
        print("[COMMENTS][SEND][START] post_id=\(postID) target_id=\(targetID.map(String.init) ?? "nil") target_type=\(targetType.map(String.init) ?? "nil") text_len=\(trimmed.count) has_s_key=\(currentSKey != nil)")

        var attempts: [([String: MessagePackValue], String)] = []
        let filesPayload: [MessagePackValue] = files.map { file in
            .map([
                "name": .string(file.name),
                "buffer": .binary(file.data)
            ])
        }

        // Canonical payload from official Element frontend:
        // { type:'social', action:'comments/add', payload:{ text, files:[], post_id, reply_to } }
        attempts.append(
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "text": .string(trimmed),
                        "files": .array(filesPayload),
                        "post_id": .int(Int64(postID)),
                        "reply_to": .int(Int64(replyToID ?? 0))
                    ])
                ],
                "comments/add"
            )
        )

        if let targetID, let targetType {
            attempts.append(
                (
                    [
                        "type": .string("social"),
                        "action": .string("comments/add"),
                        "payload": .map([
                            "post_id": .int(Int64(postID)),
                            "target_id": .int(Int64(targetID)),
                            "target_type": .int(Int64(targetType)),
                            "text": .string(trimmed)
                        ])
                    ],
                    "comments/add"
                )
            )
            attempts.append(
                (
                    [
                        "type": .string("social"),
                        "action": .string("comments/add"),
                        "payload": .map([
                            "post_id": .int(Int64(postID)),
                            "target": .map([
                                "id": .int(Int64(targetID)),
                                "type": .int(Int64(targetType))
                            ]),
                            "text": .string(trimmed)
                        ])
                    ],
                    "comments/add"
                )
            )
            attempts.append(
                (
                    [
                        "type": .string("social"),
                        "action": .string("comments/add"),
                        "post_id": .int(Int64(postID)),
                        "target_id": .int(Int64(targetID)),
                        "target_type": .int(Int64(targetType)),
                        "text": .string(trimmed)
                    ],
                    "comments/add"
                )
            )
        }

        if let sKey = currentSKey, !sKey.isEmpty {
            attempts.append(
                (
                    [
                        "type": .string("social"),
                        "action": .string("comments/add"),
                        "S_KEY": .string(sKey),
                        "payload": .map([
                            "post_id": .int(Int64(postID)),
                            "text": .string(trimmed),
                            "S_KEY": .string(sKey)
                        ])
                    ],
                    "comments/add"
                )
            )
            attempts.append(
                (
                    [
                        "type": .string("social"),
                        "action": .string("comments/add"),
                        "S_KEY": .string(sKey),
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ],
                    "comments/add"
                )
            )
            attempts.append(
                (
                    [
                        "type": .string("social"),
                        "action": .string("comments/add"),
                        "S_KEY": .string(sKey),
                        "payload": .map([
                            "post_id": .int(Int64(postID)),
                            "text": .string(trimmed),
                            "reply_to": .int(Int64(replyToID ?? 0)),
                            "parent_id": .int(Int64(replyToID ?? 0)),
                            "S_KEY": .string(sKey)
                        ])
                    ],
                    "comments/add"
                )
            )
        }

        attempts.append(contentsOf: [
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "pid": .string(String(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "post_id": .string(String(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "pid": .int(Int64(postID)),
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "pid": .int(Int64(postID)),
                        "post_id": .int(Int64(postID)),
                        "comment": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "pid": .int(Int64(postID)),
                        "post_id": .int(Int64(postID)),
                        "message": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "target_id": .int(Int64(postID)),
                        "target_type": .int(2),
                        "text": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "target_id": .int(Int64(postID)),
                        "target_type": .string("post"),
                        "text": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed),
                        "reply_to": .int(Int64(replyToID ?? 0)),
                        "parent_id": .int(Int64(replyToID ?? 0))
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/add_comment"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "posts/add_comment"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/add_comment"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "comment": .string(trimmed)
                    ])
                ],
                "posts/add_comment"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("add_comment"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "add_comment"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "comment": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "message": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "pid": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "pid": .int(Int64(postID)),
                        "comment": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "payload": .map([
                        "pid": .int(Int64(postID)),
                        "message": .string(trimmed)
                    ])
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "post_id": .int(Int64(postID)),
                    "text": .string(trimmed)
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "post_id": .int(Int64(postID)),
                    "comment": .string(trimmed)
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "post_id": .int(Int64(postID)),
                    "message": .string(trimmed)
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "pid": .int(Int64(postID)),
                    "text": .string(trimmed)
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "pid": .int(Int64(postID)),
                    "comment": .string(trimmed)
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("comments/add"),
                    "pid": .int(Int64(postID)),
                    "message": .string(trimmed)
                ],
                "comments/add"
            ),
            (
                [
                    "type": .string("comments"),
                    "action": .string("add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "add"
            ),
            (
                [
                    "type": .string("comments"),
                    "action": .string("add"),
                    "payload": .map([
                        "pid": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/comments/add"),
                    "payload": .map([
                        "post_id": .int(Int64(postID)),
                        "text": .string(trimmed)
                    ])
                ],
                "posts/comments/add"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("posts/add_comment"),
                    "post_id": .int(Int64(postID)),
                    "text": .string(trimmed)
                ],
                "posts/add_comment"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("add_comment"),
                    "post_id": .int(Int64(postID)),
                    "text": .string(trimmed)
                ],
                "add_comment"
            )
        ])

        var lastErrorMessage = "Не удалось отправить комментарий"

        for (idx, pair) in attempts.enumerated() {
            let (request, expectedAction) = pair
            print("[COMMENTS][SEND][TRY \(idx + 1)/\(attempts.count)] expected_action=\(expectedAction)")
            do {
                let response = try await requestMap(payloadMap: request)
                let statusCode = intValue(response["status"])
                let statusString = stringValue(response["status"])?.lowercased()
                let message = stringValue(response["message"])
                let responseAction = stringValue(response["action"])?.lowercased()
                let hasExplicitError = statusString == "error"
                print("[COMMENTS][SEND][RESP \(idx + 1)] status_code=\(statusCode.map(String.init) ?? "nil") status=\(statusString ?? "nil") action=\(responseAction ?? "nil") message=\(message ?? "nil")")

                // `comments/add` is recognized by backend, so if it returns an explicit error,
                // keep that server message and stop fallback attempts to avoid masking it.
                if expectedAction.lowercased() == "comments/add",
                   hasExplicitError,
                   let message,
                   !message.isEmpty {
                    print("[COMMENTS][SEND][SERVER-ERROR] comments/add -> \(message)")
                    throw APIError.serverError(message)
                }

                let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == expectedAction.lowercased()) && !hasExplicitError
                guard isSuccess else {
                    if let message { lastErrorMessage = message }
                    continue
                }

                if let created = parseCreatedComment(from: response) {
                    print("[COMMENTS][SEND][SUCCESS] created_comment_id=\(created.serverID.map(String.init) ?? "nil")")
                    return created
                }
                print("[COMMENTS][SEND][SUCCESS] created_without_body")
                return makeLocalComment(text: trimmed)
            } catch is CancellationError {
                throw CancellationError()
            } catch let apiError as APIError {
                // Preserve authoritative server error from a recognized comments/add endpoint.
                print("[COMMENTS][SEND][ERROR \(idx + 1)] \(apiError.localizedDescription)")
                throw apiError
            } catch {
                print("[COMMENTS][SEND][ERROR \(idx + 1)] \(error.localizedDescription)")
                lastErrorMessage = error.localizedDescription
            }
        }

        print("[COMMENTS][SEND][FAIL] \(lastErrorMessage)")
        throw APIError.serverError(lastErrorMessage)
    }

    func sendPostComment(postID: Int, text: String, files: [UploadFile] = [], replyToID: Int? = nil) async throws -> PostComment {
        try await sendPostComment(postID: postID, targetID: nil, targetType: nil, text: text, files: files, replyToID: replyToID)
    }

    func currentAuthorSnapshot() -> PostAuthor {
        PostAuthor(
            id: currentUserID,
            type: 0,
            name: currentUserName,
            username: currentUsername,
            avatar: currentUserAvatar,
            goldStatus: currentUserGoldStatus
        )
    }

    func currentAccountSummary() -> AccountSummary {
        AccountSummary(
            userID: currentUserID,
            name: currentUserName,
            username: currentUsername,
            email: currentUserEmail,
            avatar: currentUserAvatar
        )
    }

    func currentUserChannelsSnapshot() -> [ChannelSummary] {
        currentUserChannels
    }

    func appendCurrentUserChannel(_ channel: ChannelSummary) {
        currentUserChannels.append(channel)
    }

    func currentSelectedChannelSnapshot() -> ChannelSummary? {
        currentSelectedChannel
    }

    func setSelectedChannel(_ channel: ChannelSummary?) {
        currentSelectedChannel = channel
    }

    func setSessionKey(_ sKey: String?) {
        currentSKey = sKey
    }

    func currentUserIDSnapshot() -> Int? {
        currentUserID
    }

    func currentUserNameSnapshot() -> String? {
        currentUserName
    }

    func currentUsernameSnapshot() -> String? {
        currentUsername
    }

    func currentUserEmailSnapshot() -> String? {
        currentUserEmail
    }

    func currentUserEBallsSnapshot() -> String? {
        currentUserEBalls
    }

    func updateCurrentUserEBalls(_ newValue: Double) {
        currentUserEBalls = String(format: "%.3f", newValue)
    }

    private func applyGoldSuccessUpdate(shouldChargeBalance: Bool) {
        currentUserGoldStatus = true
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = GoldHistoryItem(status: 1, date: formatter.string(from: Date()))
        currentUserGoldHistory.insert(entry, at: 0)

        guard shouldChargeBalance else { return }
        let normalized = currentUserEBalls?.replacingOccurrences(of: ",", with: ".") ?? "0"
        let value = Double(normalized) ?? 0
        currentUserEBalls = String(format: "%.3f", max(0, value - 0.1))
    }

    private func ensureGoldActionSuccess(_ response: [String: MessagePackValue], fallbackError: String) throws {
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? fallbackError)
        }
    }

    func currentUserNotificationsSnapshot() -> Int {
        currentUserNotifications ?? 0
    }

    func currentUserMessengerNotificationsSnapshot() -> Int {
        currentUserMessengerNotifications ?? 0
    }

    /// Current user's avatar as `MediaData` (used for group-chat message avatars).
    func currentUserAvatarSnapshotMedia() -> MediaData? {
        guard let avatar = currentUserAvatar else { return nil }
        return MediaData(
            file: avatar.file,
            path: avatar.path,
            preview: nil,
            simple: avatar.simple,
            aura: avatar.aura,
            storageFileID: avatar.storageFileID
        )
    }

    func setMessengerNotificationsCount(_ count: Int) {
        currentUserMessengerNotifications = max(0, count)
    }

    func currentUserPermissionsSnapshot() -> UserPermissions? {
        currentUserPermissions
    }

    func currentUserGoldStatusSnapshot() -> Bool {
        currentUserGoldStatus ?? false
    }

    func currentUserGoldHistorySnapshot() -> [GoldHistoryItem] {
        currentUserGoldHistory
    }

    func clearImageMemoryCache() {
        imageCache.removeAllObjects()
    }

    func loadNotifications(
        startIndex: Int = 0,
        category: String = "all",
        order: String = "date_desc"
    ) async throws -> [SocialNotification] {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("notifications/load"),
            "payload": .map([
                "start_index": .int(Int64(startIndex)),
                "category": .string(category),
                "order": .string(order)
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "notifications/load") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить уведомления")
        }

        return parseNotifications(from: response)
    }

    func markNotificationsViewed() async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("notifications/view")
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "notifications/view") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось отметить уведомления как прочитанные")
        }

        currentUserNotifications = 0
    }

    // MARK: - Messenger

    private static let messengerKeywordStorageKey = "M-Keyword"

    func storedMessengerKeyword() -> String? {
        UserDefaults.standard.string(forKey: Self.messengerKeywordStorageKey)
    }

    func storeMessengerKeyword(_ keyword: String) {
        UserDefaults.standard.set(keyword, forKey: Self.messengerKeywordStorageKey)
    }

    func submitMessengerKeyword(passphrase: String) async throws -> String {
        let derived = ElementCrypto.aesKeyFromWord(passphrase)
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("aes_messages_key"),
            "key": .string(derived)
        ])
        try ensureMessengerSuccess(response, fallback: "Не удалось установить ключ")
        guard let keyword = stringValue(response["keyword"]) else {
            throw APIError.serverError(stringValue(response["content"]) ?? "Некорректный ответ сервера")
        }
        storeMessengerKeyword(keyword)
        return keyword
    }

    /// Re-sends the stored keyword after reconnect.
    /// Throws when the server rejects it (wrong passphrase) so the UI can
    /// fall back to the keyword gate — mirrors the web alert on failure.
    func restoreMessengerKeywordIfNeeded() async throws {
        guard let stored = storedMessengerKeyword(), !stored.isEmpty else { return }
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("aes_messages_key"),
            "key": .string(stored)
        ])
        if stringValue(response["status"])?.lowercased() == "success",
           let keyword = stringValue(response["keyword"]) {
            storeMessengerKeyword(keyword)
        } else if stringValue(response["status"])?.lowercased() == "error" {
            throw APIError.serverError(
                stringValue(response["content"])
                    ?? stringValue(response["message"])
                    ?? "Ключевая фраза не подходит — введите её заново"
            )
        }
    }

    func loadMessengerChats() async throws -> [MessengerChatSummary] {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("load_chats")
        ])
        guard case .array(let chats)? = response["chats"] else { return [] }
        return chats.compactMap { value -> MessengerChatSummary? in
            guard case .map(let map) = value,
                  case .map(let targetMap)? = map["target"],
                  let chatType = intValue(targetMap["type"]),
                  let chatID = intValue(targetMap["id"]) else { return nil }
            let target = MessengerChatTarget(type: chatType, id: chatID)
            return MessengerChatSummary(
                target: target,
                name: stringValue(map["name"]) ?? "Chat",
                avatar: parseMediaData(value: map["avatar"], defaultPath: "avatars"),
                lastMessage: stringValue(map["last_message"]) ?? "",
                lastMessageDate: stringValue(map["last_message_date"]) ?? "",
                unreadCount: intValue(map["notifications"]) ?? 0
            )
        }
    }

    func loadMessengerChat(target: MessengerChatTarget) async throws -> MessengerActiveChat {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("load_chat"),
            "target": messengerTargetMap(target)
        ])
        try ensureMessengerSuccess(response, fallback: "Не удалось загрузить чат")
        guard case .map(let chatMap)? = response["chat_data"] else {
            throw APIError.invalidResponse
        }
        return parseMessengerActiveChat(from: chatMap, fallbackTarget: target)
    }

    func loadMessengerMessages(
        target: MessengerChatTarget,
        keyword: String,
        startIndex: Int = 0
    ) async throws -> [MessengerMessage] {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("load_messages"),
            "target": messengerTargetMap(target),
            "startIndex": .int(Int64(startIndex))
        ])
        guard case .array(let rawMessages)? = response["messages"] else { return [] }
        let myID = currentUserID ?? 0
        return rawMessages.compactMap { parseMessengerMessage(from: $0, keyword: keyword, myID: myID) }
    }

    func markMessengerMessagesViewed(target: MessengerChatTarget) async throws {
        _ = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("view_messages"),
            "target": messengerTargetMap(target)
        ])
    }

    func sendMessengerText(
        target: MessengerChatTarget,
        text: String,
        tempMid: Int
    ) async throws {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("send_message"),
            "temp_mid": .int(Int64(tempMid)),
            "target": messengerTargetMap(target),
            "message": .string(text)
        ])
        if stringValue(response["status"])?.lowercased() == "error" {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось отправить сообщение")
        }
    }

    func downloadMessengerFiles(mid: Int, fileIDs: [Int]) async throws -> Data {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("download_files"),
            "mid": .int(Int64(mid)),
            "file_ids": .array(fileIDs.map { .int(Int64($0)) })
        ])
        try ensureMessengerSuccess(response, fallback: "Не удалось загрузить файл")
        guard let binary = messengerBinaryData(from: response["binary"]), !binary.isEmpty else {
            throw APIError.serverError("Сервер не вернул файл")
        }
        return binary
    }

    // MARK: Messenger — extended actions (parity with the web client)

    struct MessengerSearchResult: Identifiable {
        let mid: Int
        let startIndex: Int?
        var id: Int { mid }
    }

    func searchMessengerMessages(
        target: MessengerChatTarget,
        value: String,
        offset: Int = 0,
        limit: Int = 80
    ) async throws -> [MessengerSearchResult] {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("search_messages"),
            "target": messengerTargetMap(target),
            "value": .string(value),
            "offset": .int(Int64(offset)),
            "limit": .int(Int64(limit))
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .array(let results)? = response["results"] else { return [] }
        return results.compactMap { item in
            guard case .map(let map) = item, let mid = intValue(map["mid"]) else { return nil }
            return MessengerSearchResult(mid: mid, startIndex: intValue(map["startIndex"]) ?? intValue(map["start_index"]))
        }
    }

    /// Returns decrypted replacement content plus updated chat preview values.
    func editMessengerMessage(
        mid: Int,
        target: MessengerChatTarget,
        text: String,
        keyword: String
    ) async throws -> (content: MessengerMessageContent?, lastMessage: String?, lastMessageDate: String?) {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("edit_message"),
            "mid": .int(Int64(mid)),
            "target": messengerTargetMap(target),
            "message": .string(text)
        ])
        if stringValue(response["status"])?.lowercased() == "error" {
            throw APIError.serverError(stringValue(response["text"]) ?? stringValue(response["message"]) ?? "Не удалось отредактировать сообщение")
        }
        let content: MessengerMessageContent?
        if let decryptedVal = response["decrypted"] {
            content = parseMessengerDecryptedContent(from: decryptedVal)
        } else if case .map(let map)? = response["decrypted_map"] {
            content = messengerContent(from: map)
        } else {
            content = nil
        }
        return (
            content,
            stringValue(response["last_message"]),
            stringValue(response["last_message_date"])
        )
    }

    func stopMessengerUpload(tempMid: Int) async throws {
        _ = try? await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("stop_upload"),
            "temp_mid": .int(Int64(tempMid))
        ])
    }

    func deleteAllMessengerChats() async throws {
        _ = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("delete_all_chats")
        ])
    }

    func createMessengerGroup(name: String, avatarData: Data?) async throws -> MessengerActiveChat? {
        var payload: [String: MessagePackValue] = [
            "type": .string("messenger"),
            "action": .string("create_group"),
            "name": .string(name)
        ]
        if let avatarData, !avatarData.isEmpty {
            payload["avatar"] = .binary(avatarData)
        }
        let response = try await requestMap(payloadMap: payload)
        if stringValue(response["status"])?.lowercased() != "success" {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось создать группу")
        }
        if case .map(let groupMap)? = response["group_data"] {
            return parseMessengerActiveChat(from: groupMap, fallbackTarget: MessengerChatTarget(type: 1, id: intValue(groupMap["id"]) ?? 0))
        }
        return nil
    }

    func loadMessengerGroupMembers(gid: Int) async throws -> [MessengerGroupMember] {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("load_group_members"),
            "gid": .int(Int64(gid))
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .array(let members)? = response["members"] else { return [] }
        return members.compactMap { item in
            guard case .map(let map) = item, let id = intValue(map["id"]) else { return nil }
            return MessengerGroupMember(
                id: id,
                name: stringValue(map["name"]) ?? "...",
                avatar: parseMediaData(value: map["avatar"], defaultPath: "avatars")
            )
        }
    }

    func generateMessengerGroupLink(gid: Int) async throws -> String {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("generate_group_link"),
            "gid": .int(Int64(gid))
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              let link = stringValue(response["link"]) else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось сгенерировать ссылку")
        }
        return link
    }

    /// `messenger/load_group` — preview a group behind a join link (`/join/:link`).
    func loadMessengerGroup(link: String) async throws -> MessengerActiveChat {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("load_group"),
            "link": .string(link)
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .map(let groupMap)? = response["group_data"] else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Группа не найдена")
        }
        let fallbackTarget = MessengerChatTarget(type: 1, id: intValue(groupMap["id"]) ?? 0)
        return parseMessengerActiveChat(from: groupMap, fallbackTarget: fallbackTarget)
    }

    /// `messenger/join_group` — resolves the joined group id.
    func joinMessengerGroup(link: String) async throws -> Int {
        let response = try await requestMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("join_group"),
            "link": .string(link)
        ])
        guard stringValue(response["status"])?.lowercased() == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось вступить в группу")
        }
        guard let gid = intValue(response["group_id"]) ?? intValue(response["id"]) else {
            throw APIError.serverError("Сервер не вернул группу")
        }
        return gid
    }

    /// Exports a video circle ("кружок") as mp4 bytes. Server-side conversion may take a while.
    func exportMessengerVideoCircle(mid: Int) async throws -> Data {
        let response = try await requestMap(
            payloadMap: [
                "type": .string("messenger"),
                "action": .string("export_video_circle"),
                "mid": .int(Int64(mid))
            ],
            timeoutNanoseconds: 60_000_000_000
        )
        guard let binary = messengerBinaryData(from: response["binary"]), !binary.isEmpty else {
            throw APIError.serverError("Сервер не вернул видео")
        }
        return binary
    }

    func sendMessengerTyping(target: MessengerChatTarget) async throws {
        try await sendMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string("typing"),
            "target": messengerTargetMap(target)
        ])
    }

    func sendMessengerRecording(target: MessengerChatTarget, videoCircle: Bool, stop: Bool) async throws {
        try await sendMap(payloadMap: [
            "type": .string("messenger"),
            "action": .string(videoCircle ? "recording_video_circle" : "recording_voice"),
            "status": .string(stop ? "stop" : "start"),
            "target": messengerTargetMap(target)
        ])
    }

    private func messengerTargetMap(_ target: MessengerChatTarget) -> MessagePackValue {
        .map([
            "id": .int(Int64(target.id)),
            "type": .int(Int64(target.type))
        ])
    }

    private func ensureMessengerSuccess(_ response: [String: MessagePackValue], fallback: String) throws {
        let status = stringValue(response["status"])?.lowercased()
        if status == "error" {
            throw APIError.serverError(stringValue(response["message"]) ?? stringValue(response["content"]) ?? fallback)
        }
    }

    private func parseMessengerActiveChat(
        from map: [String: MessagePackValue],
        fallbackTarget: MessengerChatTarget
    ) -> MessengerActiveChat {
        let target: MessengerChatTarget
        if case .map(let targetMap)? = map["target"],
           let chatType = intValue(targetMap["type"]),
           let chatID = intValue(targetMap["id"]) {
            target = MessengerChatTarget(type: chatType, id: chatID)
        } else {
            target = fallbackTarget
        }

        // load_chat wraps 1-on-1 partner info inside "user_data"
        let userData: [String: MessagePackValue]?
        if case .map(let ud)? = map["user_data"] { userData = ud } else { userData = nil }

        let source = userData ?? map

        let name = stringValue(map["name"]) ?? (userData.flatMap { stringValue($0["name"]) }) ?? "Chat"
        let username = stringValue(source["username"])
        let avatar = parseMediaData(value: source["avatar"], defaultPath: "avatars")
        let cover = parseMediaData(value: source["cover"], defaultPath: "covers")
        let description = stringValue(source["description"])

        var icons: [String] = []
        if case .array(let iconsArray)? = source["icons"] {
            icons = iconsArray.compactMap { stringValue($0) }
        }

        let statusRaw = stringValue(source["status"])
        let isOnline: Bool
        if let onlineBool = boolValue(source["online"]) {
            isOnline = onlineBool
        } else if let statusStr = statusRaw {
            isOnline = statusStr == "online"
        } else {
            isOnline = false
        }

        return MessengerActiveChat(
            target: target,
            name: name,
            username: username,
            avatar: avatar,
            cover: cover,
            description: description,
            icons: icons,
            type: intValue(map["type"]) ?? target.type,
            unreadCount: intValue(map["notifications"]) ?? 0,
            isOnline: isOnline,
            statusRaw: statusRaw,
            membersCount: intValue(map["members_count"]),
            joinLink: stringValue(map["join_link"]),
            isOwner: boolValue(map["is_owner"]) ?? false
        )
    }

    func parseMessengerMessage(
        from value: MessagePackValue,
        keyword: String,
        myID: Int
    ) -> MessengerMessage? {
        guard case .map(let map) = value else { return nil }
        let uid = intValue(map["uid"]) ?? 0
        let content = parseMessengerMessageContent(from: map, keyword: keyword)
        let reactions = parseMessengerReactions(from: map["reactions"])
        return MessengerMessage(
            mid: intValue(map["mid"]),
            tempMid: intValue(map["temp_mid"]),
            uid: uid,
            author: parseMessengerMessageAuthor(from: map["author"]),
            content: content,
            date: stringValue(map["date"]) ?? "",
            isOutgoing: uid == myID,
            status: stringValue(map["status"]),
            isRead: boolValue(map["is_read"]) ?? false,
            uploadProgress: nil,
            downloadProgress: nil,
            reactions: reactions,
            localImageData: nil,
            localFileURL: nil,
            isListened: boolValue(map["is_listened"]) ?? false
        )
    }

    private func parseMessengerMessageAuthor(from value: MessagePackValue?) -> MessengerMessageAuthor? {
        guard case .map(let map)? = value,
              let id = intValue(map["id"]) else { return nil }
        return MessengerMessageAuthor(
            id: id,
            name: stringValue(map["name"]) ?? "...",
            avatar: parseMediaData(value: map["avatar"], defaultPath: "avatars")
        )
    }

    private func parseMessengerMessageContent(
        from map: [String: MessagePackValue],
        keyword: String
    ) -> MessengerMessageContent? {
        if let decrypted = parseMessengerDecryptedContent(from: map["decrypted"]) {
            return decrypted
        }
        if let encrypted = messengerBinaryData(from: map["encrypted"]),
           let decryptedData = try? ElementCrypto.aesDecryptMessengerPayload(encrypted, keyword: keyword),
           let decrypted = parseMessengerDecryptedContent(fromJSONData: decryptedData) {
            return decrypted
        }
        if let raw = stringValue(map["message"]),
           let decrypted = parseMessengerDecryptedContent(fromJSONString: raw) {
            return decrypted
        }

        // Encrypted payload present but undecryptable (wrong keyword) —
        // show a placeholder instead of an empty bubble.
        if map["encrypted"] != nil || map["decrypted"] == nil && stringValue(map["message"]) == nil {
            return MessengerMessageContent(
                text: "🔒 Сообщение не удалось расшифровать",
                type: "text",
                isError: true
            )
        }
        return nil
    }

    private func parseMessengerDecryptedContent(from value: MessagePackValue?) -> MessengerMessageContent? {
        switch value {
        case .map(let map):
            return messengerContent(from: map)
        case .string(let raw):
            return parseMessengerDecryptedContent(fromJSONString: raw)
        default:
            return nil
        }
    }

    private func parseMessengerDecryptedContent(fromJSONString raw: String) -> MessengerMessageContent? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return parseMessengerDecryptedContent(fromJSONData: data)
    }

    private func parseMessengerDecryptedContent(fromJSONData data: Data) -> MessengerMessageContent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return messengerContent(from: object)
    }

    private func parseReplyTo(from value: MessagePackValue?) -> MessengerReplyTo? {
        guard let value = value, case .map(let map) = value else { return nil }
        return MessengerReplyTo(
            mid: intValue(map["mid"]),
            author: stringValue(map["author"]),
            text: stringValue(map["text"]),
            type: stringValue(map["type"])
        )
    }

    private func parseReplyTo(from dict: [String: Any]?) -> MessengerReplyTo? {
        guard let dict = dict else { return nil }
        return MessengerReplyTo(
            mid: dict["mid"] as? Int ?? (dict["mid"] as? String).flatMap(Int.init),
            author: dict["author"] as? String,
            text: dict["text"] as? String,
            type: dict["type"] as? String
        )
    }

    /// Reactions come in two shapes: legacy `[uid, …]` and new `[{uid, name, avatar, date}, …]`.
    private func parseMessengerReactions(from value: MessagePackValue?) -> [String: [MessengerReactionUser]] {
        guard let value = value, case .map(let map) = value else { return [:] }
        var result: [String: [MessengerReactionUser]] = [:]
        for (emoji, val) in map {
            guard case .array(let arr) = val else { continue }
            let users: [MessengerReactionUser] = arr.compactMap { item in
                switch item {
                case .int(let i):
                    return MessengerReactionUser.fallback(uid: Int(i))
                case .uint(let u):
                    return MessengerReactionUser.fallback(uid: Int(u))
                case .map(let userMap):
                    guard let uid = intValue(userMap["uid"]) else { return nil }
                    return MessengerReactionUser(
                        uid: uid,
                        name: stringValue(userMap["name"]) ?? "...",
                        avatar: parseMediaData(value: userMap["avatar"], defaultPath: "avatars"),
                        date: stringValue(userMap["date"])
                    )
                default:
                    return nil
                }
            }
            if !users.isEmpty {
                result[emoji] = users
            }
        }
        return result
    }

    private func messengerContent(from map: [String: MessagePackValue]) -> MessengerMessageContent? {
        let text = stringValue(map["text"]) ?? ""
        let type = stringValue(map["type"]) ?? "text"
        let replyTo = parseReplyTo(from: map["reply_to"])

        var fileName: String? = nil
        var fileSize: Int64? = nil
        var mimeType: String? = nil
        var fileBase64: String? = nil
        var fileIDs: [Int]? = nil
        var encryptedKey: String? = nil
        var encryptedIV: String? = nil
        var waveform: [Double]? = nil
        var duration: Double? = nil
        var isVideoCircle = false
        var thumbnailBase64: String? = nil

        if let fileVal = map["file"], case .map(let fileObj) = fileVal {
            fileName = stringValue(fileObj["name"])
            if let sizeVal = intValue(fileObj["size"]) {
                fileSize = Int64(sizeVal)
            }
            mimeType = stringValue(fileObj["type"]) ?? stringValue(fileObj["mime"])
            fileBase64 = stringValue(fileObj["base64"])
            if case .array(let arr)? = fileObj["file_map"] {
                let ids = arr.compactMap { intValue($0) }
                fileIDs = ids.isEmpty ? nil : ids
            }
            encryptedKey = stringValue(fileObj["encrypted_key"])
            encryptedIV = stringValue(fileObj["encrypted_iv"])
            if case .array(let wf)? = fileObj["waveform"] {
                let bars = wf.compactMap { doubleValue($0) }
                waveform = bars.isEmpty ? nil : bars
            }
            duration = doubleValue(fileObj["duration"])
            isVideoCircle = boolValue(fileObj["is_video_circle"]) ?? false
            thumbnailBase64 = stringValue(fileObj["thumbnail"])
        }

        var previewBase64: String? = nil
        if let previewVal = map["preview"], case .map(let previewMap) = previewVal {
            previewBase64 = stringValue(previewMap["base64"])
        }

        let isEdited = boolValue(map["is_edited"]) ?? false
        let isError = boolValue(map["error"]) ?? false
        let callInfo = parseMessengerCallInfo(from: map["call"])

        if text.isEmpty && type == "text" && fileName == nil { return nil }
        return MessengerMessageContent(
            text: text.isEmpty ? messengerPlaceholder(for: type) : text,
            type: type,
            replyTo: replyTo,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            previewBase64: previewBase64,
            fileBase64: fileBase64,
            fileMap: fileIDs,
            encryptedKey: encryptedKey,
            encryptedIV: encryptedIV,
            waveform: waveform,
            duration: duration,
            isVideoCircle: isVideoCircle,
            thumbnailBase64: thumbnailBase64,
            isEdited: isEdited,
            isError: isError,
            call: callInfo
        )
    }

    private func messengerContent(from object: [String: Any]) -> MessengerMessageContent? {
        let text = object["text"] as? String ?? ""
        let type = object["type"] as? String ?? "text"
        let replyTo = parseReplyTo(from: object["reply_to"] as? [String: Any])

        var fileName: String? = nil
        var fileSize: Int64? = nil
        var mimeType: String? = nil
        var fileBase64: String? = nil
        var fileIDs: [Int]? = nil
        var encryptedKey: String? = nil
        var encryptedIV: String? = nil
        var waveform: [Double]? = nil
        var duration: Double? = nil
        var isVideoCircle = false
        var thumbnailBase64: String? = nil

        if let fileObj = object["file"] as? [String: Any] {
            fileName = fileObj["name"] as? String
            if let sizeVal = fileObj["size"] as? NSNumber {
                fileSize = sizeVal.int64Value
            } else if let sizeStr = fileObj["size"] as? String, let sizeVal = Int64(sizeStr) {
                fileSize = sizeVal
            } else if let sizeDouble = fileObj["size"] as? Double {
                fileSize = Int64(sizeDouble)
            }
            mimeType = (fileObj["type"] as? String) ?? (fileObj["mime"] as? String)
            fileBase64 = fileObj["base64"] as? String
            if let arr = fileObj["file_map"] as? [Any] {
                let ints = arr.compactMap { item -> Int? in
                    if let i = item as? Int { return i }
                    if let n = item as? NSNumber { return n.intValue }
                    if let s = item as? String { return Int(s) }
                    return nil
                }
                fileIDs = ints.isEmpty ? nil : ints
            }
            encryptedKey = fileObj["encrypted_key"] as? String
            encryptedIV = fileObj["encrypted_iv"] as? String
            if let arr = fileObj["waveform"] as? [Any] {
                let bars = arr.compactMap { item -> Double? in
                    if let d = item as? Double { return d }
                    if let n = item as? NSNumber { return n.doubleValue }
                    return nil
                }
                waveform = bars.isEmpty ? nil : bars
            }
            if let durNumber = fileObj["duration"] as? NSNumber {
                duration = durNumber.doubleValue
            } else if let durString = fileObj["duration"] as? String {
                duration = Double(durString)
            }
            isVideoCircle = (fileObj["is_video_circle"] as? Bool) ?? false
            thumbnailBase64 = fileObj["thumbnail"] as? String
        }

        var previewBase64: String? = nil
        if let previewMap = object["preview"] as? [String: Any] {
            previewBase64 = previewMap["base64"] as? String
        }

        let isEdited = (object["is_edited"] as? Bool) ?? false
        let isError = (object["error"] as? Bool) ?? false
        let callInfo = parseMessengerCallInfo(fromObject: object["call"] as? [String: Any])

        if text.isEmpty && type == "text" && fileName == nil { return nil }
        return MessengerMessageContent(
            text: text.isEmpty ? messengerPlaceholder(for: type) : text,
            type: type,
            replyTo: replyTo,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            previewBase64: previewBase64,
            fileBase64: fileBase64,
            fileMap: fileIDs,
            encryptedKey: encryptedKey,
            encryptedIV: encryptedIV,
            waveform: waveform,
            duration: duration,
            isVideoCircle: isVideoCircle,
            thumbnailBase64: thumbnailBase64,
            isEdited: isEdited,
            isError: isError,
            call: callInfo
        )
    }

    private func parseMessengerCallInfo(from value: MessagePackValue?) -> MessengerCallInfo? {
        guard case .map(let map)? = value else { return nil }
        return MessengerCallInfo(
            isMissed: boolValue(map["missed"]) ?? false,
            isVideo: stringValue(map["call_type"]) == "video",
            isGroup: boolValue(map["is_group"]) ?? false,
            duration: doubleValue(map["duration"]) ?? 0
        )
    }

    private func parseMessengerCallInfo(fromObject object: [String: Any]?) -> MessengerCallInfo? {
        guard let object else { return nil }
        return MessengerCallInfo(
            isMissed: (object["missed"] as? Bool) ?? false,
            isVideo: (object["call_type"] as? String) == "video",
            isGroup: (object["is_group"] as? Bool) ?? false,
            duration: (object["duration"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private func messengerPlaceholder(for type: String) -> String {
        switch type {
        case "image": return "📷 Фото"
        case "voice": return "🎤 Голосовое сообщение"
        case "video": return "📹 Видео сообщение"
        case "video_circle": return "📹 Видео"
        case "call": return "📞 Звонок"
        case "file": return "📎 Файл"
        default: return "Сообщение"
        }
    }

    private func messengerBinaryData(from value: MessagePackValue?) -> Data? {
        switch value {
        case .binary(let data):
            return data
        case .array(let values):
            let bytes: [UInt8] = values.compactMap { item in
                if case .int(let number) = item, number >= 0, number <= 255 {
                    return UInt8(number)
                }
                if case .uint(let number) = item, number <= 255 {
                    return UInt8(number)
                }
                return nil
            }
            return bytes.isEmpty ? nil : Data(bytes)
        case .map(let map):
            let sortedKeys = map.keys.compactMap { Int($0) }.sorted()
            if !sortedKeys.isEmpty {
                let bytes: [UInt8] = sortedKeys.compactMap { key in
                    guard let value = map[String(key)] else { return nil }
                    if case .int(let number) = value, number >= 0, number <= 255 { return UInt8(number) }
                    if case .uint(let number) = value, number <= 255 { return UInt8(number) }
                    return nil
                }
                return bytes.isEmpty ? nil : Data(bytes)
            }
            return nil
        default:
            return nil
        }
    }

    private func parseMessengerPush(_ map: [String: MessagePackValue]) {
        guard let action = stringValue(map["action"])?.lowercased() else { return }
        let keyword = storedMessengerKeyword() ?? ""

        func parseTarget() -> MessengerChatTarget? {
            guard case .map(let targetMap)? = map["target"],
                  let chatType = intValue(targetMap["type"]),
                  let chatID = intValue(targetMap["id"]) else { return nil }
            return MessengerChatTarget(type: chatType, id: chatID)
        }

        switch action {
        case "new_message":
            guard let target = parseTarget() else { return }

            // Fallback message composition if decrypted/encrypted are missing
            var syntheticMap = map
            if syntheticMap["message"] == nil {
                syntheticMap["message"] = map["content"]
            }

            guard let message = parseMessengerMessage(
                from: .map(syntheticMap),
                keyword: keyword,
                myID: currentUserID ?? 0
            ) else { return }

            // Background notification (web parity: Web Push «Message» template).
            if message.isOutgoing == false {
                PushNotificationsService.shared.presentIfBackgrounded(
                    title: message.author?.name ?? "Новое сообщение",
                    body: message.content?.replyPreviewText ?? "Открыть чат",
                    identifier: "msg-\(message.mid ?? Int(Date().timeIntervalSince1970))"
                )
            }

            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.newMessage(message, target: target))
            }
        case "messages_read":
            guard let target = parseTarget() else { return }
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.messagesRead(target: target))
            }
        case "message_edited", "edit_message":
            guard let target = parseTarget(), let mid = intValue(map["mid"]) else { return }
            let content: MessengerMessageContent?
            if let decryptedVal = map["decrypted"] {
                content = parseMessengerDecryptedContent(from: decryptedVal)
            } else if case .string(let raw)? = map["message"], let data = raw.data(using: .utf8) {
                content = parseMessengerDecryptedContent(fromJSONData: data)
            } else {
                content = nil
            }
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.messageEdited(
                    mid: mid,
                    target: target,
                    content: content,
                    lastMessage: stringValue(map["last_message"]),
                    lastMessageDate: stringValue(map["last_message_date"])
                ))
            }
        case "message_deleted", "delete_message":
            guard let target = parseTarget(), let mid = intValue(map["mid"]) else { return }
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.messageDeleted(
                    mid: mid,
                    target: target,
                    lastMessage: stringValue(map["last_message"]),
                    lastMessageDate: stringValue(map["last_message_date"])
                ))
            }
        case "message_reaction":
            guard let target = parseTarget(),
                  let mid = intValue(map["mid"]),
                  let emoji = stringValue(map["emoji"]) else { return }
            var avatar: MediaData? = nil
            if case .map(let avatarMap)? = map["avatar"] {
                avatar = parseMediaData(value: .map(avatarMap), defaultPath: "avatars")
            } else {
                avatar = parseMediaData(value: map["avatar"], defaultPath: "avatars")
            }
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.messageReaction(
                    mid: mid,
                    target: target,
                    emoji: emoji,
                    uid: intValue(map["uid"]) ?? 0,
                    name: stringValue(map["name"]),
                    avatar: avatar,
                    isRemove: boolValue(map["is_remove"]) ?? false
                ))
            }
        case "typing":
            guard let target = parseTarget() else { return }
            let authorName: String?
            if case .map(let authorMap)? = map["author"] {
                authorName = stringValue(authorMap["name"])
            } else {
                authorName = nil
            }
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.typing(
                    target: target,
                    uid: intValue(map["uid"]) ?? 0,
                    authorName: authorName
                ))
            }
        case "recording_voice":
            guard let target = parseTarget() else { return }
            let authorName: String?
            if case .map(let authorMap)? = map["author"] {
                authorName = stringValue(authorMap["name"])
            } else {
                authorName = nil
            }
            let stop = stringValue(map["status"]) == "stop"
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.recordingVoice(
                    target: target, uid: intValue(map["uid"]) ?? 0,
                    authorName: authorName, stop: stop
                ))
            }
        case "recording_video_circle":
            guard let target = parseTarget() else { return }
            let authorName: String?
            if case .map(let authorMap)? = map["author"] {
                authorName = stringValue(authorMap["name"])
            } else {
                authorName = nil
            }
            let stop = stringValue(map["status"]) == "stop"
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.recordingVideoCircle(
                    target: target, uid: intValue(map["uid"]) ?? 0,
                    authorName: authorName, stop: stop
                ))
            }
        case "send_message":
            // Status of our own optimistic send.
            guard let tempMid = intValue(map["temp_mid"]) else { return }
            let status = stringValue(map["status"]) ?? ""
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.sendMessageStatus(
                    tempMid: tempMid,
                    status: status,
                    mid: intValue(map["mid"]),
                    errorText: stringValue(map["text"])
                ))
            }
        case "upload_file":
            guard case .map(let targetMap)? = map["target"],
                  let chatType = intValue(targetMap["type"]),
                  let chatID = intValue(targetMap["id"]),
                  let tempMid = intValue(map["temp_mid"]),
                  let mid = intValue(map["mid"]),
                  stringValue(map["status"]) == "sended" else { return }
            let target = MessengerChatTarget(type: chatType, id: chatID)
            Task { @MainActor in
                MessengerPushCenter.shared.deliver(.uploadComplete(tempMid: tempMid, mid: mid, target: target))
            }
        case "download_files":
            // Whole-file variant: single encrypted binary for the message attachment.
            guard let mid = intValue(map["mid"]),
                  let binary = messengerBinaryData(from: map["binary"]) else { return }
            Task { @MainActor in
                MessengerFileDownloader.shared.deliverWhole(mid: mid, binary: binary)
            }
        case "download_file":
            // Chunked variant: one encrypted chunk per file_id.
            guard let mid = intValue(map["mid"]),
                  let fileID = intValue(map["file_id"]),
                  let binary = messengerBinaryData(from: map["binary"]) else { return }
            Task { @MainActor in
                MessengerFileDownloader.shared.deliverChunk(mid: mid, fileID: fileID, binary: binary)
            }
        default:
            break
        }
    }

    // MARK: - Referral / appeals / reports / apps

    /// `social/referral/load` — dashboard (web ReferralProgram.tsx).
    func loadReferralDashboard() async throws -> ReferralDashboard {
        try await connectIfNeeded()
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("referral/load")
        ])
        guard stringValue(response["status"])?.lowercased() == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить реферальную программу")
        }

        var dashboard = ReferralDashboard()
        if case .map(let profile)? = response["profile"] {
            dashboard.refCode = stringValue(profile["ref_code"])
            dashboard.inviteLink = stringValue(profile["invite_link"])
        }
        if case .map(let stats)? = response["stats"] {
            dashboard.totalInvited = intValue(stats["total_invited"]) ?? 0
            dashboard.rewarded = intValue(stats["rewarded"]) ?? 0
            dashboard.pending = intValue(stats["pending"]) ?? 0
            dashboard.totalEarned = doubleValue(stats["total_earned"]) ?? 0
        }
        if case .map(let invitedBy)? = response["invited_by"] {
            dashboard.invitedByUsername = stringValue(invitedBy["inviter_username"])
                ?? intValue(invitedBy["inviter_id"]).map { String($0) }
        }
        return dashboard
    }

    /// `social/referral/history`
    func loadReferralHistory(startIndex: Int, limit: Int = 25) async throws -> [ReferralHistoryEntry] {
        try await connectIfNeeded()
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("referral/history"),
            "payload": .map([
                "start_index": .int(Int64(startIndex)),
                "limit": .int(Int64(limit))
            ])
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .array(let items)? = response["history"] else { return [] }

        return items.compactMap { item in
            guard case .map(let map) = item else { return nil }
            var invitedName: String?
            var invitedUsername: String?
            var invitedAvatar: MediaData?
            if case .map(let invited)? = map["invited"] {
                invitedName = stringValue(invited["name"])
                invitedUsername = stringValue(invited["username"])
                invitedAvatar = parseMediaData(value: invited["avatar"], defaultPath: "avatars")
            }
            var rewardAmount: Double?
            if case .map(let rewards)? = map["rewards"] {
                rewardAmount = doubleValue(rewards["inviter"])
            }
            return ReferralHistoryEntry(
                id: intValue(map["id"]) ?? Int.random(in: 1...1_000_000),
                invitedName: invitedName,
                invitedUsername: invitedUsername,
                invitedAvatar: invitedAvatar,
                status: stringValue(map["status"]) ?? "pending",
                date: stringValue(map["reward_date"]) ?? stringValue(map["created_at"]) ?? "",
                rewardAmount: rewardAmount
            )
        }
    }

    /// `social/moderation/load_my_reports`
    func loadMyReports() async throws -> [MyReportItem] {
        try await connectIfNeeded()
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("moderation/load_my_reports"),
            "payload": .map([:])
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .array(let items)? = response["reports"] else { return [] }

        return items.compactMap { item in
            guard case .map(let map) = item, let id = intValue(map["id"]) else { return nil }
            var targetText: String?
            var targetUsername: String?
            if case .map(let info)? = map["target_info"] {
                targetText = stringValue(info["text"]) ?? stringValue(info["content"])
                targetUsername = stringValue(info["username"])
            }
            var moderatorName: String?
            if case .map(let mod)? = map["moderator_info"] {
                moderatorName = stringValue(mod["name"]) ?? stringValue(mod["username"])
            }
            return MyReportItem(
                id: id,
                category: stringValue(map["category"]) ?? "",
                status: stringValue(map["status"]) ?? "pending",
                message: stringValue(map["message"]),
                targetText: targetText,
                targetUsername: targetUsername,
                resolution: stringValue(map["resolution"]),
                moderatorName: moderatorName,
                createdAt: stringValue(map["created_at"]) ?? ""
            )
        }
    }

    /// `social/appeals/load_my`
    func loadMyAppeals() async throws -> [MyAppealItem] {
        try await connectIfNeeded()
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("appeals/load_my"),
            "payload": .map([:])
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .array(let items)? = response["appeals"] else { return [] }

        return items.compactMap { item in
            guard case .map(let map) = item, let id = intValue(map["id"]) else { return nil }
            return MyAppealItem(
                id: id,
                restrictionType: stringValue(map["restriction_type"]) ?? "posts",
                reason: stringValue(map["reason"]) ?? "",
                status: stringValue(map["status"]) ?? "pending",
                createdAt: stringValue(map["created_at"]) ?? "",
                reviewedAt: stringValue(map["reviewed_at"]),
                response: stringValue(map["response"])
            )
        }
    }

    /// `social/appeals/check_existing`
    func checkExistingAppeal(restrictionType: String) async throws -> Bool {
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("appeals/check_existing"),
            "payload": .map([
                "restriction_type": .string(restrictionType)
            ])
        ])
        let status = stringValue(response["status"])?.lowercased()
        if status == "error", stringValue(response["message"]) == "APPEAL_EXISTS" {
            return true
        }
        return false
    }

    /// `social/appeals/submit`
    func submitAppeal(restrictionType: String, reason: String) async throws {
        let response = try await requestMap(payloadMap: [
            "type": .string("social"),
            "action": .string("appeals/submit"),
            "payload": .map([
                "restriction_type": .string(restrictionType),
                "reason": .string(reason)
            ])
        ])
        guard stringValue(response["status"])?.lowercased() == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось подать апелляцию")
        }
    }

    /// `apps/load_apps` — user's registered third-party apps.
    func loadApps() async throws -> [ThirdPartyApp] {
        try await connectIfNeeded()
        let response = try await requestMap(payloadMap: [
            "type": .string("apps"),
            "action": .string("load_apps")
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .array(let items)? = response["apps"] else { return [] }

        return items.compactMap { item in
            guard case .map(let map) = item, let id = intValue(map["id"]) else { return nil }
            return ThirdPartyApp(
                id: id,
                name: stringValue(map["name"]) ?? "App",
                description: stringValue(map["description"]),
                url: stringValue(map["url"]),
                apiKey: stringValue(map["api_key"]),
                iconBase64: stringValue(map["icon"])
            )
        }
    }

    /// `apps/add_app`
    func addApp(name: String, description: String, iconBase64: String?) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("apps"),
            "action": .string("add_app"),
            "name": .string(name),
            "description": .string(description)
        ]
        if let iconBase64 {
            payload["icon"] = .string(iconBase64)
        }
        let response = try await requestMap(payloadMap: payload)
        guard stringValue(response["status"])?.lowercased() == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось создать приложение")
        }
    }

    /// `apps/edit_app` — pass nil for unchanged fields (server contract).
    func editApp(appID: Int, name: String?, description: String?, url: String?, iconBase64: String?) async throws {
        let response = try await requestMap(payloadMap: [
            "type": .string("apps"),
            "action": .string("edit_app"),
            "edit": .map([
                "app_id": .int(Int64(appID)),
                "name": name.map { .string($0) } ?? .null,
                "description": description.map { .string($0) } ?? .null,
                "url": url.map { .string($0) } ?? .null,
                "icon": iconBase64.map { .string($0) } ?? .null
            ])
        ])
        guard stringValue(response["status"])?.lowercased() == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить приложение")
        }
    }

    /// `apps/load_app` — preview for the connect confirmation screen.
    func loadApp(appID: Int) async throws -> ThirdPartyApp {
        let response = try await requestMap(payloadMap: [
            "type": .string("apps"),
            "action": .string("load_app"),
            "app_id": .int(Int64(appID))
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              case .map(let map)? = response["app"] else {
            throw APIError.serverError("Такого приложения нет")
        }
        return ThirdPartyApp(
            id: appID,
            name: stringValue(map["name"]) ?? "App",
            description: stringValue(map["description"]),
            url: stringValue(map["url"]),
            apiKey: nil,
            iconBase64: stringValue(map["icon"])
        )
    }

    /// `apps/connect_app` — returns the connect key appended to the app URL.
    func connectApp(appID: Int) async throws -> String {
        let response = try await requestMap(payloadMap: [
            "type": .string("apps"),
            "action": .string("connect_app"),
            "app_id": .int(Int64(appID))
        ])
        guard stringValue(response["status"])?.lowercased() == "success",
              let key = stringValue(response["connect_key"]) else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось подключить приложение")
        }
        return key
    }

    func loadOnlineUsers() async throws -> [PostAuthor] {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("get_online_users")
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "get_online_users") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить пользователей онлайн")
        }

        return parseOnlineUsers(from: response)
    }

    func loadSongs(category: MusicCategory, startIndex: Int = 0) async throws -> [MusicSong] {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_songs"),
            "songs_type": .string(category.rawValue),
            "start_index": .int(Int64(startIndex))
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "load_songs") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить музыку")
        }

        return parseMusicSongs(from: response)
    }

    func loadSong(songID: Int) async throws -> MusicSong {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/get_track"),
            "payload": .map([
                "song_id": .int(Int64(songID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "music/get_track" || responseAction == "load_song") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить трек")
        }

        guard case .map(let songMap)? = response["song"],
              let song = parseMusicSong(from: songMap) else {
            throw APIError.serverError("Некорректный ответ сервера")
        }

        return song
    }

    func loadArtists() async throws -> [MusicArtist] {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/get_artists")
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить исполнителей")
        }

        guard case .array(let array)? = response["artists"] else {
            return []
        }
        return array.compactMap { parseMusicArtist(from: $0) }
    }

    func searchArtists(query: String) async throws -> [MusicArtist] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/search_artists"),
            "payload": .map([
                "query": .string(trimmed)
            ])
        ]
        do {
            let response = try await requestMap(payloadMap: payloadMap)
            if case .array(let array)? = response["artists"] {
                return array.compactMap { parseMusicArtist(from: $0) }
            }
        } catch {}
        return []
    }

    func saveSongLyrics(songID: Int, lines: [LyricsLine]) async throws {
        try await connectIfNeeded()
        let linesData: [MessagePackValue] = lines.map { line in
            .map([
                "start_time_ms": .int(Int64(line.startTimeMs)),
                "words": .string(line.words)
            ])
        }
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/save_lyrics"),
            "payload": .map([
                "song_id": .int(Int64(songID)),
                "lines": .array(linesData)
            ])
        ]
        _ = try? await requestMap(payloadMap: payloadMap)
    }

    func editSongCover(songID: Int, coverData: Data) async throws -> MediaData? {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/upload_cover"),
            "payload": .map([
                "song_id": .int(Int64(songID)),
                "cover_file": .binary(coverData)
            ])
        ]
        if let response = try? await requestMap(payloadMap: payloadMap) {
            return parseMediaData(value: response["cover"], defaultPath: "music/covers")
        }
        return nil
    }

    func editSongMetadata(
        songID: Int,
        title: String?,
        artist: String?,
        album: String?,
        lyrics: [LyricsLine]?,
        coverData: Data?
    ) async throws {
        try await connectIfNeeded()
        var payloadDict: [String: MessagePackValue] = [
            "song_id": .int(Int64(songID))
        ]
        if let title, !title.isEmpty { payloadDict["title"] = .string(title) }
        if let artist, !artist.isEmpty { payloadDict["artist"] = .string(artist) }
        if let album { payloadDict["album"] = .string(album) }
        if let coverData { payloadDict["cover_file"] = .binary(coverData) }
        if let lyrics {
            payloadDict["lines"] = .array(lyrics.map {
                .map([
                    "start_time_ms": .int(Int64($0.startTimeMs)),
                    "words": .string($0.words)
                ])
            })
        }

        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/edit_song"),
            "payload": .map(payloadDict)
        ]
        _ = try? await requestMap(payloadMap: payloadMap)
    }

    func loadArtistDetails(slug: String) async throws -> (artist: MusicArtist, songs: [MusicSong], albums: [MusicAlbum]) {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/artists/get"),
            "payload": .map([
                "slug": .string(slug)
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить информацию об исполнителе")
        }

        guard case .map(let artistMap)? = response["artist"],
              let artist = parseMusicArtist(from: .map(artistMap)) else {
            throw APIError.serverError("Некорректная информация об исполнителе")
        }

        var songs: [MusicSong] = []
        if case .array(let songsArray)? = artistMap["songs"] {
            songs = songsArray.compactMap { value in
                guard case .map(let songMap) = value else { return nil }
                return parseMusicSong(from: songMap)
            }
        }

        var albums: [MusicAlbum] = []
        if case .array(let albumsArray)? = artistMap["albums"] {
            for item in albumsArray {
                guard case .map(let albumMap) = item else { continue }
                let id = intValue(albumMap["id"]) ?? 0
                let title = stringValue(albumMap["title"]) ?? ""
                let cover = parseMediaData(value: albumMap["cover"], defaultPath: "music/covers")
                let tracksCount = intValue(albumMap["tracks_count"])
                var releaseDate: String? = stringValue(albumMap["release_date"])
                if releaseDate == nil, case .map(let dateMap)? = albumMap["release_date"] {
                    releaseDate = stringValue(dateMap["iso"]) ?? stringValue(dateMap["date"])
                }
                let releaseType = stringValue(albumMap["release_type"])
                let desc = stringValue(albumMap["description"])
                albums.append(MusicAlbum(
                    id: id,
                    title: title,
                    artistName: artist.name,
                    description: desc,
                    cover: cover,
                    tracksCount: tracksCount,
                    releaseDate: releaseDate,
                    releaseType: releaseType
                ))
            }
        }

        return (artist, songs, albums)
    }

    func loadMusicLibrary() async throws -> [MusicPlaylist] {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/load_library")
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить плейлисты")
        }

        return parseMusicLibrary(from: response)
    }

    /// Public playlists discovery — same WebSocket contract as the site (`load_songs`, `songs_type: playlists`).
    func loadDiscoverPlaylists(startIndex: Int = 0) async throws -> [MusicPlaylist] {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("load_songs"),
            "songs_type": .string("playlists"),
            "start_index": .int(Int64(startIndex))
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "load_songs") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить плейлисты")
        }

        return parseDiscoverPlaylists(from: response)
    }

    func loadMusicPlaylist(playlistID: Int) async throws -> MusicPlaylistDetails {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/playlists/load"),
            "payload": .map([
                "playlist_id": .int(Int64(playlistID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить плейлист")
        }

        return try parseMusicPlaylistDetails(from: response)
    }

    func addPlaylistToFavorites(playlistID: Int) async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/playlists/add"),
            "payload": .map([
                "playlist_id": .int(Int64(playlistID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось добавить плейлист в избранное")
        }
    }

    func removePlaylistFromFavorites(playlistID: Int) async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/playlists/remove"),
            "payload": .map([
                "playlist_id": .int(Int64(playlistID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось удалить плейлист из избранного")
        }
    }

    func addMusicFav(songID: Int) async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/fav/add"),
            "payload": .map([
                "song_id": .int(Int64(songID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось добавить в избранное")
        }
    }

    func addAlbumToFavorites(albumID: Int) async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/albums/add"),
            "payload": .map([
                "album_id": .int(Int64(albumID))
            ])
        ]
        _ = try? await requestMap(payloadMap: payloadMap)
    }

    func removeAlbumFromFavorites(albumID: Int) async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/albums/remove"),
            "payload": .map([
                "album_id": .int(Int64(albumID))
            ])
        ]
        _ = try? await requestMap(payloadMap: payloadMap)
    }

    func removeMusicFav(songID: Int) async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/fav/remove"),
            "payload": .map([
                "song_id": .int(Int64(songID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось убрать из избранного")
        }
    }

    func voteInPoll(postID: Int, optionIDs: [Int], currentPoll: PostPoll) async throws -> PostPoll {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("posts/vote"),
            "payload": .map([
                "post_id": .int(Int64(postID)),
                "option_ids": .array(optionIDs.map { .int(Int64($0)) })
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось проголосовать")
        }

        guard case .map(let pollMap)? = response["poll"] else {
            throw APIError.invalidResponse
        }

        let updatedOptions: [PostPollOption]
        if case .array(let optionsArray)? = pollMap["options"] {
            updatedOptions = optionsArray.compactMap { value in
                guard case .map(let optionMap) = value else { return nil }
                return decodeMap(optionMap, as: PostPollOption.self)
            }
        } else {
            updatedOptions = currentPoll.options
        }

        return PostPoll(
            id: intValue(pollMap["id"]) ?? currentPoll.id,
            question: stringValue(pollMap["question"]) ?? currentPoll.question,
            isAnonymous: boolValue(pollMap["is_anonymous"]) ?? currentPoll.isAnonymous,
            multipleChoice: boolValue(pollMap["multiple_choice"]) ?? currentPoll.multipleChoice,
            expiresAt: stringValue(pollMap["expires_at"]) ?? currentPoll.expiresAt,
            totalVotes: intValue(pollMap["total_votes"]) ?? currentPoll.totalVotes,
            userVote: parseIntArray(pollMap["user_vote"]) ?? currentPoll.userVote,
            options: updatedOptions
        )
    }

    @discardableResult
    func createMusicPlaylist(name: String, description: String, coverData: Data? = nil) async throws -> Int? {
        try await connectIfNeeded()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw APIError.serverError("Введите название плейлиста")
        }

        var payloadFields: [String: MessagePackValue] = [
            "name": .string(trimmedName),
            "description": .string(trimmedDescription),
            "privacy": .int(0)
        ]
        if let coverData, !coverData.isEmpty {
            payloadFields["cover"] = .binary(coverData)
        }

        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/playlists/create"),
            "payload": .map(payloadFields)
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let explicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !explicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось создать плейлист")
        }

        return intValue(response["playlist_id"])
    }

    func editMusicPlaylist(
        playlistID: Int,
        name: String,
        description: String,
        privacy: Int,
        coverData: Data?
    ) async throws {
        try await connectIfNeeded()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw APIError.serverError("Введите название плейлиста")
        }

        var payloadFields: [String: MessagePackValue] = [
            "playlist_id": .int(Int64(playlistID)),
            "name": .string(trimmedName),
            "description": .string(trimmedDescription),
            "privacy": .int(Int64(privacy))
        ]
        if let coverData, !coverData.isEmpty {
            payloadFields["cover"] = .binary(coverData)
        }

        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/playlists/edit"),
            "payload": .map(payloadFields)
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let explicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !explicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось сохранить плейлист")
        }
    }

    func addSongToMusicPlaylist(songID: Int, playlistID: Int) async throws {
        try await connectIfNeeded()
        let payloads: [([String: MessagePackValue], String)] = [
            ([
                "type": .string("social"),
                "action": .string("music/playlists/add"),
                "payload": .map([
                    "playlist_id": .int(Int64(playlistID)),
                    "song_id": .int(Int64(songID))
                ])
            ], "music/playlists/add"),
            ([
                "type": .string("social"),
                "action": .string("music/playlists/add_song"),
                "payload": .map([
                    "playlist_id": .int(Int64(playlistID)),
                    "song_id": .int(Int64(songID))
                ])
            ], "music/playlists/add_song")
        ]

        try await executeMusicAction(payloads: payloads, fallbackError: "Не удалось добавить трек в плейлист")
    }

    func removeSongFromMusicPlaylist(songID: Int, playlistID: Int) async throws {
        try await connectIfNeeded()
        let payloads: [([String: MessagePackValue], String)] = [
            ([
                "type": .string("social"),
                "action": .string("music/playlists/remove"),
                "payload": .map([
                    "playlist_id": .int(Int64(playlistID)),
                    "song_id": .int(Int64(songID))
                ])
            ], "music/playlists/remove")
        ]

        try await executeMusicAction(payloads: payloads, fallbackError: "Не удалось удалить трек из плейлиста")
    }

    func deleteMusicPlaylist(playlistID: Int) async throws {
        try await connectIfNeeded()
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/playlists/delete"),
            "payload": .map([
                "playlist_id": .int(Int64(playlistID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let explicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success") && !explicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось удалить плейлист")
        }
    }

    func uploadMusicTrack(
        fileData: Data,
        fileName: String,
        coverData: Data?,
        coverFileName: String?,
        title: String,
        artist: String,
        album: String?,
        trackNumber: Int?,
        genre: String?,
        releaseDate: String?,
        composer: String?
    ) async throws {
        try await connectIfNeeded()

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGenre = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReleaseDate = releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComposer = composer?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty, !trimmedArtist.isEmpty else {
            throw APIError.serverError("Заполните название и исполнителя")
        }
        guard !trimmedFileName.isEmpty else {
            throw APIError.serverError("Выберите аудиофайл")
        }

        var payloadFields: [String: MessagePackValue] = [
            "title": .string(trimmedTitle),
            "artist": .string(trimmedArtist),
            "audio_file": .binary(fileData)
        ]

        if let trimmedAlbum, !trimmedAlbum.isEmpty {
            payloadFields["album"] = .string(trimmedAlbum)
        }
        if let trackNumber {
            payloadFields["track_number"] = .int(Int64(trackNumber))
        }
        if let trimmedGenre, !trimmedGenre.isEmpty {
            payloadFields["genre"] = .string(trimmedGenre)
        }
        if let trimmedReleaseDate, !trimmedReleaseDate.isEmpty {
            payloadFields["release_year"] = .string(trimmedReleaseDate)
        }
        if let trimmedComposer, !trimmedComposer.isEmpty {
            payloadFields["composer"] = .string(trimmedComposer)
        }
        if let coverData {
            payloadFields["cover_file"] = .binary(coverData)
        }

        let requests: [([String: MessagePackValue], String)] = [
            ([
                "type": .string("social"),
                "action": .string("music/upload"),
                "payload": .map(payloadFields)
            ], "music/upload"),
        ]

        do {
            try await executeMusicAction(
                payloads: requests,
                fallbackError: "Не удалось загрузить трек",
                requestTimeoutNanoseconds: 60_000_000_000
            )
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("таймаут") {
                throw APIError.serverError("Сервер слишком долго обрабатывает загрузку трека. Формат запроса уже совпадает с веб-клиентом, так что теперь похоже на медленную обработку или лимит размера файла.")
            }
            throw error
        }
    }

    func cachedMusicFileURL(fileID: Int, audioFormat: String?, mimeType: String? = nil) -> URL {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("ElementMusicCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let ext = musicFileExtension(for: audioFormat, mimeType: mimeType)
        return cacheDir.appendingPathComponent("file_\(fileID).\(ext)")
    }

    func downloadMusicFile(
        fileID: Int,
        audioFormat: String?,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let metadata = try await loadStorageFileMetadata(fileID: fileID)
        let resolvedFileID = metadata.id
        let targetURL = cachedMusicFileURL(fileID: resolvedFileID, audioFormat: audioFormat, mimeType: metadata.mimeType)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            print("[Music][CACHE HIT] file_id=\(resolvedFileID) path=\(targetURL.lastPathComponent)")
            onProgress?(1)
            return targetURL
        }

        return try await musicDownloadCoordinator.sharedFileURL(for: resolvedFileID) { [self] in
            if FileManager.default.fileExists(atPath: targetURL.path) {
                onProgress?(1)
                return targetURL
            }

            print("[Music][DOWNLOAD START] file_id=\(resolvedFileID) size=\(metadata.size ?? -1)")
            let data = try await downloadMusicFileData(
                fileID: resolvedFileID,
                expectedSize: metadata.size,
                onProgress: onProgress
            )
            try data.write(to: targetURL, options: .atomic)
            print("[Music][DOWNLOAD COMPLETE] file_id=\(resolvedFileID) bytes=\(data.count)")
            onProgress?(1)
            return targetURL
        }
    }

    func downloadStorageVideoFile(
        fileID: Int,
        fileName: String? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let metadata = try await loadStorageFileMetadata(fileID: fileID)
        let resolvedFileID = metadata.id

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("ElementVideoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let ext: String
        if let fileName, let dotIdx = fileName.lastIndex(of: ".") {
            ext = String(fileName[fileName.index(after: dotIdx)...])
        } else if let mime = metadata.mimeType, mime.contains("mp4") {
            ext = "mp4"
        } else if let mime = metadata.mimeType, mime.contains("mov") || mime.contains("quicktime") {
            ext = "mov"
        } else {
            ext = "mp4"
        }

        let targetURL = cacheDir.appendingPathComponent("video_\(resolvedFileID).\(ext)")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            onProgress?(1)
            return targetURL
        }

        print("[Video][DOWNLOAD START] file_id=\(resolvedFileID) size=\(metadata.size ?? -1)")
        let data = try await downloadMusicFileData(
            fileID: resolvedFileID,
            expectedSize: metadata.size,
            onProgress: onProgress
        )
        try data.write(to: targetURL, options: .atomic)
        print("[Video][DOWNLOAD COMPLETE] file_id=\(resolvedFileID) bytes=\(data.count)")
        onProgress?(1)
        return targetURL
    }

    /// Loads an image from storage (`file_id`). Backed by `MediaCacheService`
    /// (chunked downloads + SHA-256 verification — the native analog of the
    /// web client's Dexie `file_cacheV2` / `files_chunksV2` tables),
    /// with the legacy in-memory cache layered on top.
    func downloadStorageImageData(fileID: Int, maxBytes: Int = 25 * 1024 * 1024) async -> Data? {
        let cacheKey = storageImageCacheKey(fileID: fileID)
        if let cached = cachedStorageImageData(fileID: fileID) {
            return cached
        }
        if MediaCacheService.shared.verifiedBlobExists(fileID: fileID, variant: "original"),
           let data = MediaCacheService.shared.cachedData(fileID: fileID, variant: "original", maxBytes: maxBytes) {
            imageCache.setObject(data as NSData, forKey: cacheKey as NSString)
            return data
        }

        do {
            let data = try await MediaCacheService.shared.startDownload(
                fileID: fileID,
                variant: "original",
                progress: nil,
                maxBytes: maxBytes
            )
            imageCache.setObject(data as NSData, forKey: cacheKey as NSString)
            imageDiskCache.store(data, forKey: cacheKey)
            return data
        } catch {
            print("[Storage][image] chunked download failed file_id=\(fileID): \(error.localizedDescription)")
        }

        // Legacy sequential fallback (no hash verification available there).
        do {
            let metadata = try await loadStorageFileMetadata(fileID: fileID)
            if let size = metadata.size, size > maxBytes {
                print("[Storage][image] file_id=\(fileID) exceeds maxBytes=\(maxBytes) (size=\(size))")
                return nil
            }
            let data = try await downloadMusicFileData(
                fileID: metadata.id,
                expectedSize: metadata.size,
                onProgress: nil
            )
            guard data.count <= maxBytes else {
                print("[Storage][image] file_id=\(fileID) downloaded \(data.count) bytes, over cap")
                return nil
            }
            imageCache.setObject(data as NSData, forKey: cacheKey as NSString)
            imageDiskCache.store(data, forKey: cacheKey)
            return data
        } catch {
            print("[Storage][image] download failed file_id=\(fileID): \(error.localizedDescription)")
            return nil
        }
    }

    private func loadStorageFileMetadata(fileID: Int) async throws -> (id: Int, mimeType: String?, size: Int?) {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("storage"),
            "action": .string("get_file_data"),
            "payload": .map([
                "file_id": .int(Int64(fileID))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        guard statusCode == 200 else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось получить данные файла")
        }

        guard case .map(let fileData)? = response["file_data"],
              let resolvedFileID = intValue(fileData["id"]) else {
            throw APIError.serverError("Сервер не вернул данные аудиофайла")
        }

        return (
            id: resolvedFileID,
            mimeType: stringValue(fileData["mime"]),
            size: intValue(fileData["size"])
        )
    }

    private func downloadMusicFileData(
        fileID: Int,
        expectedSize: Int?,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> Data {
        var offset = 0
        var fullData = Data()
        var iterations = 0

        while true {
            iterations += 1
            if iterations > 50_000 {
                throw APIError.serverError("Слишком большой файл")
            }

            let payloadMap: [String: MessagePackValue] = [
                "type": .string("storage"),
                "action": .string("download"),
                "payload": .map([
                    "file_id": .int(Int64(fileID)),
                    "offset": .int(Int64(offset))
                ])
            ]

            let response = try await requestMap(payloadMap: payloadMap)
            let statusCode = intValue(response["status"])
            guard statusCode == 200 else {
                throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить аудио")
            }

            let chunk = extractBinary(response["buffer"]) ?? Data()
            if chunk.isEmpty {
                if let expectedSize, expectedSize > 0, fullData.count >= expectedSize {
                    break
                }

                let serverOffset = intValue(response["offset"]) ?? offset
                if serverOffset == offset, expectedSize == nil || fullData.isEmpty == false {
                    break
                }

                throw APIError.serverError("Пустой аудио-чанк")
            }

            fullData.append(chunk)
            offset += chunk.count
            if let expectedSize, expectedSize > 0 {
                onProgress?(min(1, Double(fullData.count) / Double(expectedSize)))
            }

            if let expectedSize, expectedSize > 0, fullData.count >= expectedSize {
                break
            }

            if boolValue(response["is_last_chunk"]) ?? false {
                break
            }
        }

        if let expectedSize, expectedSize > 0, fullData.count != expectedSize {
            throw APIError.serverError("Аудиофайл загружен не полностью")
        }

        return fullData
    }

    private func musicFileExtension(for audioFormat: String?, mimeType: String? = nil) -> String {
        let format = audioFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if format.contains("flac") { return "flac" }
        if format.contains("wav") { return "wav" }
        if format.contains("aac") || format.contains("m4a") || format.contains("mp4") { return "m4a" }
        if format.contains("mpeg") || format.contains("mp3") { return "mp3" }

        let mime = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if mime == "audio/flac" { return "flac" }
        if mime == "audio/wav" || mime == "audio/x-wav" { return "wav" }
        if mime == "audio/mp4" || mime == "audio/aac" || mime == "audio/x-m4a" { return "m4a" }
        if mime == "audio/mpeg" || mime == "audio/mp3" { return "mp3" }

        return "bin"
    }

    func updateUsername(_ newUsername: String) async throws {
        let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Пустой username")
        }

        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/username"),
            "username": .string(trimmed)
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить username")
        }

        currentUsername = trimmed
        currentUserName = trimmed
    }

    func updateEmail(_ newEmail: String) async throws {
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Пустая почта")
        }

        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/email"),
            "email": .string(trimmed)
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить почту")
        }

        currentUserEmail = trimmed
    }

    func updateProfileName(_ newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Пустое имя")
        }

        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/name"),
            "name": .string(trimmed)
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить имя")
        }

        currentUserName = trimmed
    }

    func updateProfileDescription(_ newDescription: String) async throws {
        let trimmed = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/description"),
            "description": .string(trimmed)
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить описание")
        }
    }

    func uploadProfileAvatar(data: Data) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/avatar/upload"),
            "file": .binary(data)
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить аватар")
        }

        if case .map(let map)? = response["avatar"],
           let decoded: PostAuthorAvatar = decodeMap(map, as: PostAuthorAvatar.self) {
            currentUserAvatar = decoded
        } else if let raw = stringValue(response["avatar"]) {
            currentUserAvatar = parseAvatar(raw: raw)
        }
    }

    func uploadProfileCover(data: Data) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/cover/upload"),
            "file": .binary(data)
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить обложку")
        }
    }

    func deleteProfileAvatar() async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/avatar/delete")
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось удалить аватар")
        }
        currentUserAvatar = nil
    }

    func deleteProfileCover() async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/cover/delete")
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось удалить обложку")
        }
    }

    // MARK: - Profile Links

    @discardableResult
    func addLink(title: String, url: String) async throws -> Int {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("add_link"),
            "title": .string(title),
            "link": .string(url)
        ]
        if let currentSKey { payload["S_KEY"] = .string(currentSKey) }

        let response = try await requestMap(payloadMap: payload)
        let statusString = stringValue(response["status"])?.lowercased()
        let statusCode = intValue(response["status"])
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось добавить ссылку")
        }
        return intValue(response["link_id"]) ?? 0
    }

    func editLink(linkID: Int, title: String, url: String) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("edit_link"),
            "link_id": .int(Int64(linkID)),
            "title": .string(title),
            "link": .string(url)
        ]
        if let currentSKey { payload["S_KEY"] = .string(currentSKey) }

        let response = try await requestMap(payloadMap: payload)
        let statusString = stringValue(response["status"])?.lowercased()
        let statusCode = intValue(response["status"])
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить ссылку")
        }
    }

    func deleteLink(linkID: Int) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("delete_link"),
            "link_id": .int(Int64(linkID))
        ]
        if let currentSKey { payload["S_KEY"] = .string(currentSKey) }

        let response = try await requestMap(payloadMap: payload)
        let statusString = stringValue(response["status"])?.lowercased()
        let statusCode = intValue(response["status"])
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось удалить ссылку")
        }
    }

    func createChannel(
        name: String,
        username: String,
        description: String?,
        avatarData: Data?,
        coverData: Data?
    ) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty, !trimmedUsername.isEmpty else {
            throw APIError.serverError("Заполните название и уникальное имя")
        }

        var channelPayload: [String: MessagePackValue] = [
            "name": .string(trimmedName),
            "username": .string(trimmedUsername)
        ]
        if let trimmedDescription, !trimmedDescription.isEmpty {
            channelPayload["description"] = .string(trimmedDescription)
        }
        if let avatarData {
            channelPayload["avatar"] = .binary(avatarData)
        }
        if let coverData {
            channelPayload["cover"] = .binary(coverData)
        }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("channels/create"),
            "payload": .map(channelPayload)
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось создать канал")
        }

        let snapshot = ChannelSummary(
            id: nil,
            name: trimmedName,
            username: trimmedUsername,
            avatar: nil,
            cover: nil,
            description: trimmedDescription,
            subscribers: 0,
            posts: 0,
            createDate: nil
        )
        appendCurrentUserChannel(snapshot)
    }

    func updateChannelName(channelID: Int, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Пустое название")
        }

        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("channels/change/name"),
            "payload": .map([
                "channel_id": .int(Int64(channelID)),
                "name": .string(trimmed)
            ])
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить название канала")
        }

        if let idx = currentUserChannels.firstIndex(where: { $0.id == channelID }) {
            let old = currentUserChannels[idx]
            currentUserChannels[idx] = ChannelSummary(
                id: old.id,
                name: trimmed,
                username: old.username,
                avatar: old.avatar,
                cover: old.cover,
                description: old.description,
                subscribers: old.subscribers,
                posts: old.posts,
                createDate: old.createDate
            )
        }
    }

    func updateChannelUsername(channelID: Int, newUsername: String) async throws {
        let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.serverError("Пустой username")
        }

        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("channels/change/username"),
            "payload": .map([
                "channel_id": .int(Int64(channelID)),
                "username": .string(trimmed)
            ])
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить имя канала")
        }

        if let idx = currentUserChannels.firstIndex(where: { $0.id == channelID }) {
            let old = currentUserChannels[idx]
            currentUserChannels[idx] = ChannelSummary(
                id: old.id,
                name: old.name,
                username: trimmed,
                avatar: old.avatar,
                cover: old.cover,
                description: old.description,
                subscribers: old.subscribers,
                posts: old.posts,
                createDate: old.createDate
            )
        }
    }

    func updateChannelDescription(channelID: Int, newDescription: String) async throws {
        let trimmed = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("channels/change/description"),
            "payload": .map([
                "channel_id": .int(Int64(channelID)),
                "description": .string(trimmed)
            ])
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить описание канала")
        }

        if let idx = currentUserChannels.firstIndex(where: { $0.id == channelID }) {
            let old = currentUserChannels[idx]
            currentUserChannels[idx] = ChannelSummary(
                id: old.id,
                name: old.name,
                username: old.username,
                avatar: old.avatar,
                cover: old.cover,
                description: trimmed,
                subscribers: old.subscribers,
                posts: old.posts,
                createDate: old.createDate
            )
        }
    }

    func uploadChannelAvatar(channelID: Int, data: Data) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("channels/change/avatar/upload"),
            "payload": .map([
                "channel_id": .int(Int64(channelID)),
                "file": .binary(data)
            ])
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить аватар канала")
        }

        if let idx = currentUserChannels.firstIndex(where: { $0.id == channelID }) {
            let old = currentUserChannels[idx]
            let newAvatar = stringValue(response["avatar"]) ?? old.avatar
            currentUserChannels[idx] = ChannelSummary(
                id: old.id,
                name: old.name,
                username: old.username,
                avatar: newAvatar,
                cover: old.cover,
                description: old.description,
                subscribers: old.subscribers,
                posts: old.posts,
                createDate: old.createDate
            )
        }
    }

    func uploadChannelCover(channelID: Int, data: Data) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("channels/change/cover/upload"),
            "payload": .map([
                "channel_id": .int(Int64(channelID)),
                "file": .binary(data)
            ])
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить обложку канала")
        }

        if let idx = currentUserChannels.firstIndex(where: { $0.id == channelID }) {
            let old = currentUserChannels[idx]
            let newCover = stringValue(response["cover"]) ?? old.cover
            currentUserChannels[idx] = ChannelSummary(
                id: old.id,
                name: old.name,
                username: old.username,
                avatar: old.avatar,
                cover: newCover,
                description: old.description,
                subscribers: old.subscribers,
                posts: old.posts,
                createDate: old.createDate
            )
        }
    }

    func updatePassword(oldPassword: String, newPassword: String) async throws {
        let oldTrimmed = oldPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty else {
            throw APIError.serverError("Заполните оба поля пароля")
        }

        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("change_profile/password"),
            "old_password": .string(oldTrimmed),
            "new_password": .string(newTrimmed)
        ]
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось изменить пароль")
        }
    }

    func requestDataExport() async throws {
        _ = try await createAccountExport()
    }

    func createAccountExport() async throws -> String? {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("account/create_export")
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "account/create_export") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось запросить экспорт")
        }
        return stringValue(response["message"])
    }

    func loadAccountExports() async throws -> [AccountExportItem] {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("account/load_exports")
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let message = stringValue(response["message"]) ?? ""
        let hasExplicitError = statusString == "error"
        let exportsValue = response["exports"]
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "account/load_exports" || exportsValue != nil) && !hasExplicitError
        if !isSuccess {
            if message.lowercased().contains("нет экспортов") {
                return []
            }
            throw APIError.serverError(message.isEmpty ? "Не удалось загрузить экспорты" : message)
        }

        guard case .array(let items)? = exportsValue else {
            return []
        }

        var results: [AccountExportItem] = []
        results.reserveCapacity(items.count)
        for item in items {
            guard case .map(let map) = item else { continue }
            let name = stringValue(map["name"]) ?? "export.7z"
            let size = intValue(map["size"])
            results.append(AccountExportItem(name: name, size: size))
        }
        return results
    }

    func deleteAccount(deletePosts: Bool) async throws {
        let payloads: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("settings"),
                    "action": .string("settings/delete_account"),
                    "payload": .map([
                        "delete_posts": .bool(deletePosts)
                    ])
                ],
                "settings/delete_account"
            ),
            (
                [
                    "type": .string("authorization"),
                    "action": .string("account/delete"),
                    "payload": .map([
                        "delete_posts": .bool(deletePosts)
                    ])
                ],
                "account/delete"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("account/delete"),
                    "payload": .map([
                        "delete_posts": .bool(deletePosts)
                    ])
                ],
                "account/delete"
            )
        ]

        try await executeSettingsAction(payloads: payloads, fallbackError: "Не удалось удалить аккаунт")
    }

    func loadSessions() async throws -> [SessionInfo] {
        let payloads: [([String: MessagePackValue], String)] = [
            (
                [
                    "type": .string("social"),
                    "action": .string("auth/sessions/load"),
                    "payload": .map([:])
                ],
                "auth/sessions/load"
            ),
            (
                [
                    "type": .string("settings"),
                    "action": .string("sessions/load"),
                    "payload": .map([:])
                ],
                "sessions/load"
            ),
            (
                [
                    "type": .string("authorization"),
                    "action": .string("account/sessions"),
                    "payload": .map([:])
                ],
                "account/sessions"
            ),
            (
                [
                    "type": .string("social"),
                    "action": .string("sessions/load"),
                    "payload": .map([:])
                ],
                "sessions/load"
            )
        ]

        var lastError = "Не удалось загрузить сессии"
        for (payload, expectedAction) in payloads {
            do {
                let response = try await requestMap(payloadMap: payload)
                if !isSettingsActionSuccess(response, expectedAction: expectedAction) {
                    if let message = stringValue(response["message"]), !message.isEmpty {
                        lastError = message
                    }
                    continue
                }
                if let merged = parseSessionsWithCurrent(from: response) {
                    return merged
                }
                let sessions = parseSessions(from: response)
                if !sessions.isEmpty {
                    return sessions
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    func terminateSession(sessionID: String) async throws {
        var payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("auth/sessions/delete")
        ]
        if let numericID = Int64(sessionID) {
            payload["session_id"] = .int(numericID)
        } else {
            payload["session_id"] = .string(sessionID)
        }
        if let currentSKey {
            payload["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error"
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == "auth/sessions/delete") && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось удалить сессию")
        }
    }

    func updateInactiveSessionLifetime(seconds: Int) async throws {
        let payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("account/settings/change"),
            "payload": .map([
                "settings": .map([
                    "inactive_session_lifetime": .int(Int64(seconds))
                ])
            ])
        ]
        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось сохранить настройку")
        }
    }

    func loadBlockedUsers() async throws -> [BlockedUserItem] {
        let payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("account/get_blocked")
        ]
        let response = try await requestMap(payloadMap: payload)
        guard case .array(let users)? = response["blocked_users"] else {
            return []
        }

        var results: [BlockedUserItem] = []
        for userVal in users {
            guard case .map(let uMap) = userVal else { continue }
            let id = intValue(uMap["id"]) ?? 0
            let createdAt = stringValue(uMap["created_at"]) ?? ""
            let targetAuthor: PostAuthor
            if case .map(let targetMap)? = uMap["target"] {
                let name = stringValue(targetMap["name"]) ?? ""
                let username = stringValue(targetMap["username"]) ?? ""
                let avatar = parseAvatarValue(targetMap["avatar"])
                targetAuthor = PostAuthor(
                    id: intValue(targetMap["id"]),
                    type: intValue(targetMap["type"]) ?? 0,
                    name: name,
                    username: username,
                    avatar: avatar,
                    goldStatus: nil
                )
            } else {
                targetAuthor = PostAuthor(id: nil, type: 0, name: "", username: "", avatar: nil, goldStatus: nil)
            }
            results.append(BlockedUserItem(id: id, target: targetAuthor, createdAt: createdAt))
        }
        return results
    }

    func unblockUser(username: String) async throws {
        let payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("profile/unblock"),
            "payload": .map([
                "username": .string(username)
            ])
        ]
        let response = try await requestMap(payloadMap: payload)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось разблокировать пользователя")
        }
    }

    func getProfileMedia(username: String) async throws -> [ProfileMediaItem] {
        let payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("get_profile_media"),
            "payload": .map([
                "username": .string(username)
            ])
        ]
        let response = try await requestMap(payloadMap: payload)
        guard case .array(let items)? = response["items"] else {
            return []
        }

        var results: [ProfileMediaItem] = []
        for itemVal in items {
            guard case .map(let itemMap) = itemVal else { continue }
            let postID = intValue(itemMap["post_id"]) ?? 0
            if let imageMedia = parseMediaData(value: itemMap["image"], defaultPath: "posts/images") {
                results.append(ProfileMediaItem(postID: postID, image: imageMedia))
            }
        }
        return results
    }

    func loadSongLyrics(songID: Int) async throws -> [LyricsLine] {
        let payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/get_song"),
            "payload": .map([
                "song_id": .int(Int64(songID)),
                "includes": .array([.string("lyrics")])
            ])
        ]
        let response = try await requestMap(payloadMap: payload)
        guard case .map(let songMap)? = response["song"] else {
            return []
        }

        guard case .array(let lyricsArray)? = songMap["lyrics"], let firstLyrics = lyricsArray.first, case .map(let lyricsMap) = firstLyrics else {
            return []
        }

        var lines: [LyricsLine] = []
        if case .array(let linesArray)? = lyricsMap["lines"] {
            for lineVal in linesArray {
                guard case .map(let lineMap) = lineVal else { continue }
                let startMs = intValue(lineMap["start_time_ms"]) ?? 0
                let words = stringValue(lineMap["words"]) ?? ""
                lines.append(LyricsLine(startTimeMs: startMs, words: words))
            }
        } else if let linesString = stringValue(lyricsMap["lines"]), let data = linesString.data(using: .utf8) {
            if let parsed = try? JSONDecoder().decode([LyricsLine].self, from: data) {
                lines = parsed
            }
        }
        return lines
    }

    func loadSongDetails(songID: Int) async throws -> MusicSongDetails {
        let payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/get_song"),
            "payload": .map([
                "song_id": .int(Int64(songID)),
                "includes": .array([
                    .string("album"),
                    .string("composer"),
                    .string("genre"),
                    .string("release_year"),
                    .string("bitrate"),
                    .string("lyrics")
                ])
            ])
        ]
        let response = try await requestMap(payloadMap: payload)
        guard case .map(let songMap)? = response["song"] else {
            throw APIError.invalidResponse
        }

        let song = parseMusicSong(from: songMap) ?? MusicSong(
            id: songID,
            originalFileID: nil,
            title: "",
            artist: "",
            artists: [],
            album: nil,
            cover: nil,
            fileDescriptor: nil,
            type: 0,
            duration: nil,
            dateAdded: nil,
            liked: false,
            genre: nil,
            trackNumber: nil,
            releaseYear: nil,
            composer: nil,
            bitrate: nil,
            audioFormat: nil
        )

        var lyrics: [LyricsLine] = []
        if case .array(let lyricsArray)? = songMap["lyrics"], let firstLyrics = lyricsArray.first, case .map(let lyricsMap) = firstLyrics {
            if case .array(let linesArray)? = lyricsMap["lines"] {
                for lineVal in linesArray {
                    guard case .map(let lineMap) = lineVal else { continue }
                    let startMs = intValue(lineMap["start_time_ms"]) ?? 0
                    let words = stringValue(lineMap["words"]) ?? ""
                    lyrics.append(LyricsLine(startTimeMs: startMs, words: words))
                }
            } else if let linesString = stringValue(lyricsMap["lines"]), let data = linesString.data(using: .utf8) {
                if let parsed = try? JSONDecoder().decode([LyricsLine].self, from: data) {
                    lyrics = parsed
                }
            }
        }

        return MusicSongDetails(
            song: song,
            lyrics: lyrics,
            albumName: stringValue(songMap["album"]),
            composer: stringValue(songMap["composer"]),
            genre: stringValue(songMap["genre"]),
            releaseYear: intValue(songMap["release_year"]),
            bitrate: intValue(songMap["bitrate"]),
            duration: doubleValue(songMap["duration"])
        )
    }

    func loadAlbum(albumID: Int) async throws -> (album: MusicAlbum, tracks: [MusicSong]) {
        let payload: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("music/get_album"),
            "payload": .map([
                "album_id": .int(Int64(albumID))
            ])
        ]
        let response = try await requestMap(payloadMap: payload)
        guard case .map(let albumMap)? = response["album"] else {
            throw APIError.invalidResponse
        }

        let cover = parseMediaData(value: albumMap["cover"], defaultPath: "music/covers")
        var releaseDate: String? = stringValue(albumMap["release_date"])
        if releaseDate == nil, case .map(let dateMap)? = albumMap["release_date"] {
            releaseDate = stringValue(dateMap["iso"]) ?? stringValue(dateMap["date"])
        }

        var tracks: [MusicSong] = []
        if case .array(let tracksArray)? = response["tracks"] {
            for trackVal in tracksArray {
                if case .map(let trackMap) = trackVal, let song = parseMusicSong(from: trackMap) {
                    tracks.append(song)
                }
            }
        }

        var artistName = stringValue(albumMap["artist"]) ?? stringValue(albumMap["author"])
        if artistName == nil, case .map(let artistMap)? = response["artist"] {
            artistName = stringValue(artistMap["name"])
        }
        if artistName == nil, let firstTrack = tracks.first {
            artistName = firstTrack.artist
        }

        let album = MusicAlbum(
            id: intValue(albumMap["id"]) ?? albumID,
            title: stringValue(albumMap["title"]) ?? "",
            artistName: artistName,
            description: stringValue(albumMap["description"]),
            cover: cover,
            tracksCount: intValue(albumMap["tracks_count"]) ?? (tracks.isEmpty ? nil : tracks.count),
            releaseDate: releaseDate,
            releaseType: stringValue(albumMap["release_type"])
        )

        return (album, tracks)
    }

    func makeLocalComment(text: String) -> PostComment {
        PostComment(
            serverID: nil,
            text: text,
            createDate: ISO8601DateFormatter().string(from: Date()),
            author: PostCommentAuthor(id: currentUserID, name: currentUserName, username: currentUsername, avatarAura: nil)
        )
    }

    private func waitForOpen() async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.connectContinuation = continuation
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw APIError.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            if let continuation = connectContinuation {
                connectContinuation = nil
                continuation.resume(throwing: error)
            }
            throw error
        }
    }

    func sendMap(payloadMap: [String: MessagePackValue]) async throws {
        try await connectIfNeeded()
        guard let webSocketTask else { throw APIError.socketNotConnected }
        guard let serverAESKey else { throw APIError.socketNotConnected }

        let rayID = generateRayID()
        var requestMap = payloadMap
        requestMap["ray_id"] = .string(rayID)

        let requestData = try MessagePack.encode(.map(requestMap))
        let encrypted = try ElementCrypto.aesEncryptCBC(requestData, keyBase64: serverAESKey)

        print("[WS][OUT][send][ray_id=\(rayID)] \(describeMap(requestMap))")
        try await webSocketTask.send(.data(encrypted))
    }

    func requestMap(
        payloadMap: [String: MessagePackValue],
        timeoutNanoseconds: UInt64 = 20_000_000_000
    ) async throws -> [String: MessagePackValue] {
        try await connectIfNeeded()
        guard let webSocketTask else { throw APIError.socketNotConnected }
        guard let serverAESKey else { throw APIError.socketNotConnected }

        let rayID = generateRayID()
        var requestMap = payloadMap
        requestMap["ray_id"] = .string(rayID)

        let requestData = try MessagePack.encode(.map(requestMap))
        let encrypted = try ElementCrypto.aesEncryptCBC(requestData, keyBase64: serverAESKey)

        print("[WS][OUT][ray_id=\(rayID)] \(describeMap(requestMap))")
        try await webSocketTask.send(.data(encrypted))

        let responseMap: [String: MessagePackValue]
        do {
            responseMap = try await withThrowingTaskGroup(of: [String: MessagePackValue].self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: MessagePackValue], Error>) in
                        Task { await self.pending.add(rayID: rayID, continuation: continuation) }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw APIError.timeout
                }

                guard let first = try await group.next() else {
                    throw APIError.timeout
                }
                group.cancelAll()
                return first
            }
        } catch {
            await pending.reject(rayID: rayID, error: error)
            throw error
        }

        print("[WS][IN][ray_id=\(rayID)] \(describeMap(responseMap))")
        return responseMap
    }

    private func executeSettingsAction(payloads: [([String: MessagePackValue], String)], fallbackError: String) async throws {
        var lastError = fallbackError
        for (payload, expectedAction) in payloads {
            do {
                let response = try await requestMap(payloadMap: payload)
                if isSettingsActionSuccess(response, expectedAction: expectedAction) {
                    return
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw APIError.serverError(lastError)
    }

    private func executeMusicAction(
        payloads: [([String: MessagePackValue], String)],
        fallbackError: String,
        requestTimeoutNanoseconds: UInt64 = 20_000_000_000
    ) async throws {
        var lastError = fallbackError
        for (payload, expectedAction) in payloads {
            do {
                let response = try await requestMap(
                    payloadMap: payload,
                    timeoutNanoseconds: requestTimeoutNanoseconds
                )
                if isSettingsActionSuccess(response, expectedAction: expectedAction) {
                    return
                }
                if let message = stringValue(response["message"]), !message.isEmpty {
                    lastError = message
                }
            } catch {
                lastError = error.localizedDescription
                if shouldStopRetryingMusicUpload(after: error) {
                    break
                }
            }
        }
        throw APIError.serverError(lastError)
    }

    private func makeMusicUploadAttachmentFields(
        fileData: Data,
        fileName: String,
        coverData: Data?,
        coverFileName: String?
    ) -> [String: MessagePackValue] {
        var attachments: [String: MessagePackValue] = [
            "file": .binary(fileData),
            "file_name": .string(fileName)
        ]

        if let coverData {
            attachments["cover"] = .binary(coverData)
        }
        if let coverFileName, !coverFileName.isEmpty {
            attachments["cover_file_name"] = .string(coverFileName)
            attachments["cover_name"] = .string(coverFileName)
        }

        return attachments
    }

    private func shouldStopRetryingMusicUpload(after error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .socketNotConnected, .socketSuspended:
                return true
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("socket is not connected")
            || message.contains("network connection was lost")
            || message.contains("not connected to internet")
            || message.contains("таймаут")
            || message.contains("соединение")
    }

    private func isSettingsActionSuccess(_ response: [String: MessagePackValue], expectedAction: String) -> Bool {
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let actionString = stringValue(response["action"])?.lowercased()
        let expected = expectedAction.lowercased()
        let explicitError = statusString == "error"
        return (statusCode == 200 || statusString == "success" || actionString == expected) && !explicitError
    }

    private func parseSessions(from response: [String: MessagePackValue]) -> [SessionInfo] {
        let candidates = ["sessions", "items", "data"]
        for key in candidates {
            guard case .array(let array)? = response[key] else { continue }
            let parsed = array.compactMap { value -> SessionInfo? in
                guard case .map(let map) = value else { return nil }
                let id = stringValue(map["session_id"]) ?? stringValue(map["id"]) ?? UUID().uuidString
                let title = stringValue(map["device_name"]) ?? stringValue(map["title"]) ?? stringValue(map["device"]) ?? stringValue(map["platform"]) ?? "Сессия"
                let subtitle = stringValue(map["client_name"]) ?? stringValue(map["subtitle"]) ?? stringValue(map["app"]) ?? stringValue(map["user_agent"]) ?? "Element"
                let isCurrent = boolValue(map["is_current"]) ?? boolValue(map["current"]) ?? false
                return SessionInfo(id: id, title: title, subtitle: subtitle, isCurrent: isCurrent)
            }
            if !parsed.isEmpty {
                return parsed
            }
        }
        return []
    }

    private func parseSessionsWithCurrent(from response: [String: MessagePackValue]) -> [SessionInfo]? {
        let current = parseSession(mapValue: response["current_session"], isCurrent: true)
        let sessionsArray = arrayValue(response["sessions"]) ?? arrayValue(response["items"]) ?? arrayValue(response["data"])
        guard current != nil || sessionsArray != nil else { return nil }

        var sessions: [SessionInfo] = []
        if let current {
            sessions.append(current)
        }
        if let sessionsArray {
            for item in sessionsArray {
                guard case .map(let map) = item else { continue }
                let parsed = parseSession(map: map, isCurrent: false)
                if let parsed {
                    if current?.id == parsed.id {
                        continue
                    }
                    sessions.append(parsed)
                }
            }
        }
        return sessions
    }

    private func parseSession(mapValue: MessagePackValue?, isCurrent: Bool) -> SessionInfo? {
        guard case .map(let map)? = mapValue else { return nil }
        return parseSession(map: map, isCurrent: isCurrent)
    }

    private func parseSession(map: [String: MessagePackValue], isCurrent: Bool) -> SessionInfo? {
        let id = stringValue(map["session_id"]) ?? stringValue(map["id"]) ?? UUID().uuidString
        let deviceTypeValue = map["device_type"] ?? map["type"]
        let device = stringValue(map["device_name"]) ?? stringValue(map["device"])
        let title = stringValue(map["device_name"])
            ?? stringValue(map["title"])
            ?? deviceTypeLabel(deviceTypeValue)
            ?? formatDeviceType(stringValue(deviceTypeValue))
            ?? device
            ?? "Сессия"
        let subtitle = stringValue(map["client_name"]) ?? stringValue(map["subtitle"]) ?? device ?? stringValue(map["app"]) ?? "Element"
        return SessionInfo(id: id, title: title, subtitle: subtitle, isCurrent: isCurrent || (boolValue(map["is_current"]) ?? boolValue(map["current"]) ?? false))
    }

    private func deviceTypeLabel(_ value: MessagePackValue?) -> String? {
        let intValue: Int?
        switch value {
        case .int(let i): intValue = Int(i)
        case .uint(let u): intValue = Int(u)
        case .string(let s): intValue = Int(s)
        default: intValue = nil
        }
        switch intValue {
        case 0: return "Аноним"
        case 1: return "Браузер"
        case 2: return "Android"
        case 3: return "iOS"
        case 4: return "Windows"
        default: return nil
        }
    }

    private func formatDeviceType(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("ios") {
            return "iOS"
        }
        if raw.contains("android") {
            return "Android"
        }
        if raw.contains("windows") {
            return "Windows"
        }
        if raw.contains("mac") || raw.contains("macos") {
            return "macOS"
        }
        if raw.contains("browser") || raw.contains("web") {
            return "Браузер"
        }
        return raw
    }

    private func parseNotifications(from response: [String: MessagePackValue]) -> [SocialNotification] {
        guard case .array(let array)? = response["notifications"] else {
            return []
        }

        var notifications: [SocialNotification] = []
        notifications.reserveCapacity(array.count)

        for item in array {
            guard case .map(let map) = item,
                  let id = intValue(map["id"]) else {
                continue
            }

            var author: PostAuthor?
            if case .map(let authorMap)? = map["author"] {
                author = parseNotificationAuthor(from: authorMap) ?? decodeMap(authorMap, as: PostAuthor.self)
            } else {
                author = nil
            }

            // For many notifications (e.g. NewPost), backend sends author in content.author
            if author == nil,
               case .map(let contentMap)? = map["content"],
               case .map(let contentAuthorMap)? = contentMap["author"] {
                author = parseNotificationAuthor(from: contentAuthorMap) ?? decodeMap(contentAuthorMap, as: PostAuthor.self)
            }

            let action = stringValue(map["action"]) ?? "unknown"
            let viewed = boolValue(map["viewed"]) ?? false
            let date = stringValue(map["date"])
            let content = parseNotificationContent(map["content"])

            notifications.append(
                SocialNotification(
                    id: id,
                    author: author,
                    action: action,
                    content: content,
                    viewed: viewed,
                    date: date
                )
            )
        }

        return notifications
    }

    func loadEBallHistory(startIndex: Int = 0) async throws -> [EBallTransaction] {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("eball/load_history"),
            "payload": .map([
                "start_index": .int(Int64(startIndex))
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let object = MessagePack.toJSONObject(.map(response))
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try decoder.decode(EBallHistoryResponse.self, from: data)

        if decoded.status.lowercased() == "success" {
            return decoded.transactions ?? []
        }

        throw APIError.serverError(decoded.message ?? "Не удалось загрузить историю")
    }

    func loadEBallHall() async throws -> [EBallHallUser] {
        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("eball/hall/load")
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить зал славы")
        }

        guard case .array(let items)? = response["users"] else {
            return []
        }

        var users: [EBallHallUser] = []
        users.reserveCapacity(items.count)

        for item in items {
            guard case .map(let map) = item else { continue }
            let id = intValue(map["id"]) ?? 0
            let username = stringValue(map["username"]) ?? ""
            let name = stringValue(map["name"]) ?? username
            let avatar = parseAvatarValue(map["avatar"])
            let eballs = doubleValue(map["eballs"]) ?? 0
            users.append(
                EBallHallUser(
                    id: id,
                    name: name,
                    username: username,
                    avatar: avatar,
                    eballs: eballs
                )
            )
        }

        return users.sorted { $0.eballs > $1.eballs }
    }

    func loadGifts(username: String) async throws -> [GiftItem] {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("gifts/get"),
            "payload": .map([
                "username": .string(trimmed)
            ])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        return try parseGiftItems(from: response, fallbackMessage: "Не удалось загрузить подарки")
    }

    func loadGiftCatalog() async throws -> [GiftItem] {
        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("gifts/get"),
            "payload": .map([:])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        return try parseGiftItems(from: response, fallbackMessage: "Не удалось загрузить каталог подарков")
    }

    func sendGift(username: String, giftID: Int) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("gifts/send"),
            "payload": .map([
                "username": .string(trimmed),
                "gift_id": .int(Int64(giftID))
            ])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось отправить подарок")
        }
    }

    func setGiftHidden(_ hidden: Bool, giftID: Int, username: String) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string(hidden ? "gifts/hide" : "gifts/show"),
            "payload": .map([
                "id": .int(Int64(giftID)),
                "username": .string(trimmed)
            ])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось обновить подарок")
        }
    }

    private func parseGiftItems(from response: [String: MessagePackValue], fallbackMessage: String) throws -> [GiftItem] {
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? fallbackMessage)
        }
        guard case .array(let giftsArray)? = response["gifts"] else { return [] }

        var gifts: [GiftItem] = []
        gifts.reserveCapacity(giftsArray.count)

        for item in giftsArray {
            guard case .map(let map) = item else { continue }
            let id = intValue(map["id"]) ?? 0
            let giftID = intValue(map["gift_id"])
            let name = stringValue(map["name"]) ?? "Подарок"
            let description = stringValue(map["description"])
            let price = doubleValue(map["price"])
            let image = parseMediaData(value: map["image"], defaultPath: "gifts")
            let quantity = intValue(map["quantity"])
            let sender = parseGiftSender(from: map["sender"])
            let message = stringValue(map["message"])
            let isHidden = boolValue(map["is_hidden"]) ?? false
            let date = stringValue(map["gifted_at"]) ?? stringValue(map["date"])

            gifts.append(
                GiftItem(
                    id: id,
                    giftID: giftID,
                    name: name,
                    description: description,
                    price: price,
                    image: image,
                    quantity: quantity,
                    sender: sender,
                    message: message,
                    isHidden: isHidden,
                    date: date
                )
            )
        }

        return gifts
    }

    func searchUsers(query: String) async throws -> [PostAuthor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("search"),
            "category": .string("users"),
            "value": .string(trimmed)
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось найти пользователей")
        }
        guard case .array(let results)? = response["results"] else { return [] }

        var users: [PostAuthor] = []
        users.reserveCapacity(results.count)

        for item in results {
            guard case .map(let map) = item else { continue }
            let id = intValue(map["id"])
            let type = intValue(map["type"])
            let name = stringValue(map["name"])
            let username = stringValue(map["username"])
            let avatar = parseAuthorAvatar(map["avatar"])
            users.append(PostAuthor(id: id, type: type, name: name, username: username, avatar: avatar))
        }

        return users
    }

    func search(query: String, category: SearchCategory) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("search"),
            "category": .string(category.rawValue),
            "value": .string(trimmed)
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось выполнить поиск")
        }

        guard case .array(let results)? = response["results"] else { return .empty }

        var users: [PostAuthor] = []
        var posts: [SearchPost] = []
        var songs: [MusicSong] = []
        users.reserveCapacity(results.count)
        posts.reserveCapacity(results.count)
        songs.reserveCapacity(results.count)

        for item in results {
            guard case .map(let map) = item else { continue }
            let type = stringValue(map["type"])?.lowercased() ?? ""

            switch type {
            case "user", "channel":
                let id = intValue(map["id"])
                let name = stringValue(map["name"])
                let username = stringValue(map["username"])
                let avatar = parseAuthorAvatar(map["avatar"])
                let typeValue = type == "channel" ? 1 : 0
                users.append(PostAuthor(id: id, type: typeValue, name: name, username: username, avatar: avatar))
            case "post":
                guard let postID = intValue(map["id"]) else { continue }
                let text = stringValue(map["text"])
                let createDate = stringValue(map["create_date"])
                let author = parseSearchAuthor(from: map["author"])
                posts.append(SearchPost(id: postID, author: author, text: text, createDate: createDate))
            case "music", "song", "track":
                if let song = parseMusicSong(from: map) {
                    songs.append(song)
                }
            default:
                if let song = parseSearchMusicSongFallback(from: map) {
                    songs.append(song)
                    continue
                }
                continue
            }
        }

        return SearchResults(users: users, posts: posts, songs: songs)
    }

    func sendEBall(recipientID: Int, amount: Double, message: String?) async throws {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string("eball/send"),
            "payload": .map([
                "recipient": .int(Int64(recipientID)),
                "amount": .float(amount),
                "message": .string(message ?? "")
            ])
        ]

        let response = try await requestMap(payloadMap: payloadMap)
        let status = stringValue(response["status"])?.lowercased() ?? "error"
        guard status == "success" else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось отправить перевод")
        }
    }

    private func parseSearchAuthor(from value: MessagePackValue?) -> PostAuthor {
        guard case .map(let map) = value else {
            return PostAuthor(id: nil, type: nil, name: nil, username: nil, avatar: nil)
        }
        let id = intValue(map["id"])
        let name = stringValue(map["name"])
        let username = stringValue(map["username"])
        let avatar = parseAuthorAvatar(map["avatar"])
        return PostAuthor(id: id, type: nil, name: name, username: username, avatar: avatar)
    }

    private func parseSearchMusicSongFallback(from map: [String: MessagePackValue]) -> MusicSong? {
        guard map["artist"] != nil, map["title"] != nil else { return nil }
        return parseMusicSong(from: map)
    }

    private func parseGiftSender(from value: MessagePackValue?) -> PostAuthor? {
        guard case .map(let map) = value else { return nil }
        let id = intValue(map["id"])
        let name = stringValue(map["name"])
        let username = stringValue(map["username"])
        let avatar = parseAuthorAvatar(map["avatar"])
        return PostAuthor(id: id, type: nil, name: name, username: username, avatar: avatar)
    }

    private func parseOnlineUsers(from response: [String: MessagePackValue]) -> [PostAuthor] {
        guard case .array(let array)? = response["users"] else {
            return []
        }

        var users: [PostAuthor] = []
        users.reserveCapacity(array.count)

        for item in array {
            guard case .map(let map) = item else { continue }
            let id = intValue(map["id"])
            let type = intValue(map["type"])
            let name = stringValue(map["name"])
            let username = stringValue(map["username"])
            let avatar = parseAuthorAvatar(map["avatar"])
            users.append(PostAuthor(id: id, type: type, name: name, username: username, avatar: avatar))
        }

        return users
    }

    private func loadProfileUsers(action: String, username: String, startIndex: Int) async throws -> [PostAuthor] {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var payloadMap: [String: MessagePackValue] = [
            "type": .string("social"),
            "action": .string(action),
            "payload": .map([
                "username": .string(trimmed),
                "start_index": .int(Int64(startIndex))
            ])
        ]
        if let currentSKey {
            payloadMap["S_KEY"] = .string(currentSKey)
        }

        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let responseAction = stringValue(response["action"])?.lowercased()
        let hasExplicitError = statusString == "error" || response["message"] != nil && !(stringValue(response["message"]) ?? "").isEmpty
        let isSuccess = (statusCode == 200 || statusString == "success" || responseAction == action.lowercased()) && !hasExplicitError
        guard isSuccess else {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось загрузить список")
        }

        return parseProfileUsers(from: response)
    }

    private func parseProfileUsers(from response: [String: MessagePackValue]) -> [PostAuthor] {
        guard case .array(let array)? = response["users"] else {
            return []
        }

        var users: [PostAuthor] = []
        users.reserveCapacity(array.count)

        for item in array {
            guard case .map(let map) = item else { continue }
            let id = intValue(map["id"])
            let name = stringValue(map["name"])
            let username = stringValue(map["username"])
            let avatar = parseAuthorAvatar(map["avatar"])
            users.append(PostAuthor(id: id, type: 0, name: name, username: username, avatar: avatar))
        }

        return users
    }

    private func parseMusicSongs(from response: [String: MessagePackValue]) -> [MusicSong] {
        guard case .array(let array)? = response["songs"] else {
            return []
        }

        return array.compactMap { value in
            guard case .map(let map) = value else { return nil }
            return parseMusicSong(from: map)
        }
    }

    private func parseMusicArtist(from value: MessagePackValue) -> MusicArtist? {
        guard case .map(let map) = value,
              let name = stringValue(map["name"]) else { return nil }
        
        let id = intValue(map["id"]) ?? 0
        let slug = stringValue(map["slug"])
        let avatar = parseMediaData(value: map["avatar"], defaultPath: "music/artists")
        return MusicArtist(id: id, name: name, slug: slug, avatar: avatar)
    }

    private func parseMusicArtists(from value: MessagePackValue?) -> [MusicArtist] {
        guard let value = value, case .array(let array) = value else { return [] }
        return array.compactMap { parseMusicArtist(from: $0) }
    }

    private func parseOriginalFileID(from map: [String: MessagePackValue]) -> Int? {
        intValue(map["original_file_id"]) ?? intValue(map["original_file"])
    }

    private func parseMusicSong(from map: [String: MessagePackValue]) -> MusicSong? {
        guard let id = intValue(map["id"]) else { return nil }

        let parsedArtists = parseMusicArtists(from: map["artists"])
        let rawArtist = stringValue(map["artist"])
        let isRawArtistUsable = rawArtist.map { !$0.isEmpty && $0.lowercased() != "unknown" } ?? false
        let joinedArtists = parsedArtists.map { $0.name }.joined(separator: ", ")
        let artistName = isRawArtistUsable ? rawArtist! : (joinedArtists.isEmpty ? "Unknown" : joinedArtists)

        return MusicSong(
            id: id,
            originalFileID: parseOriginalFileID(from: map),
            title: stringValue(map["title"]) ?? "Unknown",
            artist: artistName,
            artists: parsedArtists,
            album: stringValue(map["album"]),
            cover: parseMediaData(value: map["cover"], defaultPath: "music/covers"),
            fileDescriptor: parseMusicFileDescriptor(from: map["file"]),
            type: intValue(map["type"]) ?? 0,
            duration: doubleValue(map["duration"]),
            dateAdded: stringValue(map["date_added"]),
            liked: boolValue(map["liked"]) ?? false,
            genre: stringValue(map["genre"]),
            trackNumber: intValue(map["track_number"]),
            releaseYear: intValue(map["release_year"]),
            composer: stringValue(map["composer"]),
            bitrate: intValue(map["bitrate"]),
            audioFormat: stringValue(map["audio_format"])
        )
    }

    private func parseMusicLibrary(from response: [String: MessagePackValue]) -> [MusicPlaylist] {
        guard case .array(let array)? = response["playlists"] else {
            return []
        }

        return array.compactMap { value in
            guard case .map(let map) = value else { return nil }
            return parseMusicPlaylistFromMap(map)
        }
    }

    /// `load_songs` with `songs_type: playlists` returns rows under `songs` (same as web `Main.tsx`).
    private func parseDiscoverPlaylists(from response: [String: MessagePackValue]) -> [MusicPlaylist] {
        guard case .array(let array)? = response["songs"] else {
            return []
        }

        return array.compactMap { value -> MusicPlaylist? in
            guard case .map(let map) = value else { return nil }
            if intValue(map["type"]) == 0 { return nil }
            if let playlist = parseMusicPlaylistFromMap(map) {
                return playlist
            }
            if let song = parseMusicSong(from: map), song.type != 0 {
                return MusicPlaylist(
                    id: song.id,
                    type: song.type,
                    title: song.title,
                    authorName: song.artist == "Unknown" ? nil : song.artist,
                    authorUsername: nil,
                    addDate: song.dateAdded,
                    cover: song.cover
                )
            }
            return nil
        }
    }

    private func parseMusicPlaylistFromMap(_ map: [String: MessagePackValue]) -> MusicPlaylist? {
        guard let id = intValue(map["id"]) else { return nil }

        let authorName: String?
        let authorUsername: String?
        if case .map(let authorMap)? = map["author"] {
            authorName = stringValue(authorMap["name"])
            authorUsername = stringValue(authorMap["username"])
        } else {
            authorName = nil
            authorUsername = nil
        }

        return MusicPlaylist(
            id: id,
            type: intValue(map["type"]) ?? 1,
            title: stringValue(map["title"]) ?? "Playlist",
            authorName: authorName,
            authorUsername: authorUsername,
            addDate: stringValue(map["add_date"]),
            cover: parseMediaData(value: map["cover"], defaultPath: "music/covers")
        )
    }

    private func parseMusicPlaylistDetails(from response: [String: MessagePackValue]) throws -> MusicPlaylistDetails {
        guard case .map(let playlistMap)? = response["playlist_data"] else {
            throw APIError.serverError("Некорректный ответ сервера")
        }
        let authorMap: [String: MessagePackValue]?
        if case .map(let map)? = playlistMap["author"] {
            authorMap = map
        } else {
            authorMap = nil
        }

        return MusicPlaylistDetails(
            id: intValue(playlistMap["id"]) ?? 0,
            title: stringValue(playlistMap["title"]) ?? "Playlist",
            description: stringValue(playlistMap["description"]),
            createDate: stringValue(playlistMap["create_date"]),
            privacy: intValue(playlistMap["privacy"]) ?? 0,
            cover: parseMediaData(value: playlistMap["cover"], defaultPath: "music/covers"),
            authorName: authorMap.flatMap { stringValue($0["name"]) },
            authorUsername: authorMap.flatMap { stringValue($0["username"]) },
            songs: parseMusicSongs(from: response),
            isLiked: boolValue(playlistMap["is_liked"]),
            isMyPlaylist: boolValue(playlistMap["is_my_playlist"])
        )
    }

    private func parseMusicFileDescriptor(from value: MessagePackValue?) -> MusicFileDescriptor? {
        switch value {
        case .map(let map):
            return MusicFileDescriptor(file: stringValue(map["file"]), path: stringValue(map["path"]))
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return MusicFileDescriptor(
                    file: object["file"] as? String,
                    path: object["path"] as? String
                )
            }
            return MusicFileDescriptor(file: trimmed, path: "music/files")
        default:
            return nil
        }
    }

    private func parseNotificationAuthor(from map: [String: MessagePackValue]) -> PostAuthor? {
        let id = intValue(map["id"])
        let type = intValue(map["type"])
        let name = stringValue(map["name"])
        let username = stringValue(map["username"])
        let avatar = parseAuthorAvatar(map["avatar"])
        return PostAuthor(id: id, type: type, name: name, username: username, avatar: avatar)
    }

    private func parseAuthorAvatar(_ value: MessagePackValue?) -> PostAuthorAvatar? {
        switch value {
        case .map(let avatarMap):
            if let decoded: PostAuthorAvatar = decodeMap(avatarMap, as: PostAuthorAvatar.self) {
                return decoded
            }
            let file = stringValue(avatarMap["file"])
            let path = stringValue(avatarMap["path"])
            let simple = stringValue(avatarMap["simple"])
            let aura = stringValue(avatarMap["aura"])
            let fileID = intValue(avatarMap["file_id"])
            return PostAuthorAvatar(file: file, path: path, simple: simple, aura: aura, storageFileID: fileID)
        case .string(let raw):
            return parseAvatar(raw: raw)
        default:
            return nil
        }
    }

    private func parseNotificationContent(_ value: MessagePackValue?) -> SocialNotificationContent {
        guard case .map(let map)? = value else {
            return SocialNotificationContent(
                postID: nil,
                commentID: nil,
                profileUsername: nil,
                commentText: nil,
                postText: nil,
                messageText: nil,
                authorName: nil,
                title: nil,
                subtype: nil
            )
        }

        func nestedValue(_ path: [String]) -> MessagePackValue? {
            guard let first = path.first else { return nil }
            var current: MessagePackValue? = map[first]
            for key in path.dropFirst() {
                guard case .map(let inner)? = current else { return nil }
                current = inner[key]
            }
            return current
        }

        func nestedString(_ path: [String]) -> String? {
            stringValue(nestedValue(path))
        }

        func nestedInt(_ path: [String]) -> Int? {
            intValue(nestedValue(path))
        }

        let postID = nestedInt(["post", "id"]) ?? intValue(map["post_id"]) ?? intValue(map["pid"])
        let commentID = nestedInt(["comment", "id"]) ?? intValue(map["comment_id"]) ?? intValue(map["cid"])
        let profileUsername = nestedString(["profile", "username"]) ?? nestedString(["author", "username"])
        let commentText = nestedString(["comment", "text"])
        let postText = nestedString(["post", "text"])
            ?? nestedString(["post_data", "text"])
            ?? nestedString(["payload", "post", "text"])
        let messageText = nestedString(["message", "text"]) ?? stringValue(map["text"]) ?? stringValue(map["message"])
        let authorName = nestedString(["author", "name"])
        let title = stringValue(map["title"])
        let subtype = stringValue(map["subtype"])

        return SocialNotificationContent(
            postID: postID,
            commentID: commentID,
            profileUsername: profileUsername,
            commentText: commentText,
            postText: postText,
            messageText: messageText,
            authorName: authorName,
            title: title,
            subtype: subtype
        )
    }

    private func performHandshake() async throws {
        guard let webSocketTask else { throw APIError.socketNotConnected }

        let keyMaterial = try ElementCrypto.generateRSAKeyMaterial()
        self.keyMaterial = keyMaterial

        let hello: [String: String] = [
            "type": "key_exchange",
            "key": keyMaterial.publicKeyPEM
        ]

        let helloData = try JSONSerialization.data(withJSONObject: hello)
        guard let helloString = String(data: helloData, encoding: .utf8) else {
            throw APIError.encodingError
        }

        print("[WS][OUT][handshake] key_exchange")
        try await webSocketTask.send(.string(helloString))

        let serverJSON = try await webSocketTask.receive()
        guard case .string(let text) = serverJSON,
              let data = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "key_exchange",
              let serverPublicPEM = obj["key"] as? String else {
            throw APIError.invalidResponse
        }

        print("[WS][IN][handshake] key_exchange")

        let clientAES = try ElementCrypto.generateAESKeyBase64()
        self.clientAESKey = clientAES

        let aesPayload: [String: MessagePackValue] = [
            "type": .string("aes_key"),
            "key": .string(clientAES)
        ]

        let aesPayloadData = try MessagePack.encode(.map(aesPayload))
        let encryptedKey = try ElementCrypto.rsaEncrypt(aesPayloadData, publicKeyPEM: serverPublicPEM)

        print("[WS][OUT][handshake] aes_key (rsa encrypted)")
        try await webSocketTask.send(.data(encryptedKey))

        let serverAESMessage = try await webSocketTask.receive()
        guard case .data(let serverAESData) = serverAESMessage,
              let privateKey = self.keyMaterial?.privateKey else {
            throw APIError.invalidResponse
        }

        let decrypted = try ElementCrypto.rsaDecrypt(serverAESData, privateKey: privateKey)
        let decoded = try MessagePack.decode(decrypted)

        guard case .map(let map) = decoded,
              case .string(let serverType)? = map["type"],
              serverType == "aes_key",
              case .string(let serverAES)? = map["key"] else {
            throw APIError.invalidResponse
        }

        self.serverAESKey = serverAES
        self.isSocketReady = true
        print("[WS][IN][handshake] aes_key received; socket_ready")
    }

    private func restoreAuthorization(sKey: String) async throws {
        let payloadMap: [String: MessagePackValue] = [
            "type": .string("authorization"),
            "action": .string("connect"),
            "S_KEY": .string(sKey)
        ]
        let response = try await requestMap(payloadMap: payloadMap)
        let statusCode = intValue(response["status"])
        let statusString = stringValue(response["status"])?.lowercased()
        let isSuccess = statusCode == 200 || statusString == "success"
        if !isSuccess {
            throw APIError.serverError(stringValue(response["message"]) ?? "Не удалось восстановить сессию")
        }
        if case .map(let accountData)? = response["accountData"],
           let restoredID = intValue(accountData["id"]) {
            let previousID = currentUserID
            currentUserID = restoredID
            currentUserName = stringValue(accountData["name"])
            currentUsername = stringValue(accountData["username"])
            currentUserEmail = stringValue(accountData["email"])
            currentUserEBalls = stringValue(accountData["e_balls"])
            currentUserNotifications = intValue(accountData["notifications"])
            currentUserMessengerNotifications = intValue(accountData["messenger_notifications"])
            currentUserAvatar = parseAvatarValue(accountData["avatar"])
            currentUserGoldStatus = boolValue(accountData["gold_status"])
            currentUserGoldHistory = parseGoldHistory(value: accountData["gold_history"])
            currentUserChannels = parseChannels(value: accountData["channels"])
            if case .map(let permissionsMap)? = accountData["permissions"] {
                let permissionsObject = MessagePack.toJSONObject(.map(permissionsMap))
                if let data = try? JSONSerialization.data(withJSONObject: permissionsObject),
                   let decoded = try? decoder.decode(UserPermissions.self, from: data) {
                    currentUserPermissions = decoded
                }
            } else {
                currentUserPermissions = nil
            }

            // Identity actually changed — notify listeners (messenger reset etc.).
            if let previousID, previousID != restoredID {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: APIClient.accountDidChangeNotification,
                        object: self,
                        userInfo: ["userID": restoredID]
                    )
                }
            }
        }
        print("[WS][AUTH-RESTORE] success")
    }

    private func parseAvatar(raw: String?) -> PostAuthorAvatar? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let data = raw.data(using: .utf8),
           let decoded = try? decoder.decode(PostAuthorAvatar.self, from: data) {
            return decoded
        }

        let unescaped = raw.replacingOccurrences(of: "\\\"", with: "\"")
        if let data = unescaped.data(using: .utf8),
           let decoded = try? decoder.decode(PostAuthorAvatar.self, from: data) {
            return decoded
        }

        return nil
    }

    private func parseChannels(value: MessagePackValue?) -> [ChannelSummary] {
        guard case .array(let items) = value else { return [] }
        var channels: [ChannelSummary] = []
        channels.reserveCapacity(items.count)
        for item in items {
            guard case .map(let map) = item else {
                continue
            }
            channels.append(
                ChannelSummary(
                    id: intValue(map["id"]),
                    name: stringValue(map["name"]),
                    username: stringValue(map["username"]),
                    avatar: stringifyMessagePackValue(map["avatar"]),
                    cover: stringifyMessagePackValue(map["cover"]),
                    description: stringValue(map["description"]),
                    subscribers: intValue(map["subscribers"]),
                    posts: intValue(map["posts"]),
                    createDate: stringValue(map["create_date"])
                )
            )
        }
        return channels
    }

    private func stringifyMessagePackValue(_ value: MessagePackValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .map, .array:
            let object = MessagePack.toJSONObject(value)
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        default:
            return stringValue(value)
        }
    }

    private func parseMediaData(value: MessagePackValue?, defaultPath: String) -> MediaData? {
        switch value {
        case .map(let map):
            let file = stringValue(map["file"])
            let path = stringValue(map["path"])
            if let fid = intValue(map["file_id"]) {
                let dominant = stringValue(map["dominant_color"])
                let blur = stringValue(map["blur_hash"])
                return MediaData(
                    file: file,
                    path: path ?? defaultPath,
                    preview: stringValue(map["preview"]) ?? blur,
                    simple: stringValue(map["simple"]),
                    aura: dominant ?? stringValue(map["aura"]),
                    storageFileID: fid
                )
            }
            return MediaData(
                file: file,
                path: path ?? defaultPath,
                preview: stringValue(map["preview"]),
                simple: stringValue(map["simple"]),
                aura: stringValue(map["aura"]),
                storageFileID: nil
            )
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
                return MediaData(file: trimmed, path: nil, preview: nil, simple: nil, aura: nil)
            }

            if let object = parseJSONObject(from: trimmed) ?? parseJSONObject(from: trimmed.replacingOccurrences(of: "\\\"", with: "\"")) {
                let file = object["file"] as? String
                let resolvedFileID: Int? = {
                    if let fid = object["file_id"] as? Int { return fid }
                    if let fidNum = object["file_id"] as? NSNumber { return fidNum.intValue }
                    return nil
                }()
                if let fid = resolvedFileID {
                    return MediaData(
                        file: file,
                        path: (object["path"] as? String) ?? defaultPath,
                        preview: (object["preview"] as? String) ?? (object["blur_hash"] as? String),
                        simple: object["simple"] as? String,
                        aura: (object["dominant_color"] as? String) ?? (object["aura"] as? String),
                        storageFileID: fid
                    )
                }
                return MediaData(
                    file: file,
                    path: (object["path"] as? String) ?? defaultPath,
                    preview: object["preview"] as? String,
                    simple: object["simple"] as? String,
                    aura: object["aura"] as? String
                )
            }

            return MediaData(file: trimmed, path: defaultPath, preview: nil, simple: nil, aura: nil)
        default:
            return nil
        }
    }

    private func parseAvatarValue(_ value: MessagePackValue?) -> PostAuthorAvatar? {
        switch value {
        case .map(let map):
            return PostAuthorAvatar(
                file: stringValue(map["file"]),
                path: stringValue(map["path"]) ?? "avatars",
                simple: stringValue(map["simple"]),
                aura: stringValue(map["aura"]),
                storageFileID: intValue(map["file_id"])
            )
        case .string(let raw):
            return parseAvatar(raw: raw)
        default:
            return nil
        }
    }

    private func parseIconIDs(_ value: MessagePackValue?) -> Set<String> {
        guard case .array(let array) = value else { return [] }
        var ids = Set<String>()
        for item in array {
            if case .map(let map) = item, let id = stringValue(map["icon_id"]) {
                ids.insert(id.uppercased())
            } else if case .string(let str) = item {
                ids.insert(str.uppercased())
            }
        }
        return ids
    }

    private func parseGoldHistory(value: MessagePackValue?) -> [GoldHistoryItem] {
        switch value {
        case .array(let array):
            let object = array.map { MessagePack.toJSONObject($0) }
            if let data = try? JSONSerialization.data(withJSONObject: object),
               let decoded = try? decoder.decode([GoldHistoryItem].self, from: data) {
                return decoded
            }
        case .string(let raw):
            guard let data = raw.data(using: .utf8),
                  let decoded = try? decoder.decode([GoldHistoryItem].self, from: data) else {
                return []
            }
            return decoded
        default:
            break
        }
        return []
    }

    private func parseJSONObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func startReceiveLoop() {
        receiveLoopTask?.cancel()
        let generation = connectionGeneration
        receiveLoopTask = Task {
            while !Task.isCancelled {
                do {
                    guard let webSocketTask else { return }
                    let msg = try await webSocketTask.receive()
                    try await handleIncomingMessage(msg)
                } catch {
                    // This loop belongs to a connection that was already
                    // replaced/cancelled — never tear down the newer one.
                    guard !Task.isCancelled, generation == connectionGeneration else { return }
                    print("[WS][LOOP] error: \(error.localizedDescription)")
                    disconnect()
                    return
                }
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let clientAESKey else { return }

        let encryptedData: Data
        switch message {
        case .data(let data):
            encryptedData = data
        case .string(let text):
            // Server may occasionally send plain JSON service messages.
            print("[WS][IN][text] \(text)")
            return
        @unknown default:
            return
        }

        let decrypted = try ElementCrypto.aesDecryptCBC(encryptedData, keyBase64: clientAESKey)
        let decoded: MessagePackValue
        do {
            decoded = try MessagePack.decode(decrypted)
        } catch {
            print("[WS][IN] decode error: \(error.localizedDescription) bytes=\(decrypted.count) head=\(hexPrefix(decrypted, count: 16))")
            throw error
        }
        guard case .map(let map) = decoded else { return }

        if case .string(let rayID)? = map["ray_id"] {
            await pending.resolve(rayID: rayID, payload: map)
        } else {
            print("[WS][IN][push] \(describeMap(map))")
            if stringValue(map["type"]) == "messenger" {
                handleMessengerPush(map)
            } else {
                handleInAppPush(map)
            }
        }
    }

    private func handleMessengerPush(_ map: [String: MessagePackValue]) {
        parseMessengerPush(map)
    }

    private func handleInAppPush(_ map: [String: MessagePackValue]) {
        guard stringValue(map["type"]) == "social" else { return }
        guard let rawAction = stringValue(map["action"])?.lowercased() else { return }

        switch rawAction {
        case "new_message":
            let messageText = extractPushMessageText(from: map["message"])
            let payload: [String: Any] = [
                "kind": "message",
                "title": "Новое сообщение",
                "message": messageText ?? "Открыть чат"
            ]
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: APIClient.inAppNotification,
                    object: self,
                    userInfo: payload
                )
            }
        case "notify":
            guard case .map(let notificationMap)? = map["notification"] else { return }
            let notification = parsePushNotification(from: notificationMap)
            let title =
                notification?.author?.name
                ?? notification?.content.authorName
                ?? stringValue(notificationMap["title"])
                ?? stringValue(notificationMap["author_name"])
                ?? "Уведомление"
            let message =
                notification?.content.messageText
                ?? notification?.content.postText
                ?? notification?.content.commentText
                ?? stringValue(notificationMap["text"])
                ?? stringValue(notificationMap["message"])
                ?? stringValue(notificationMap["body"])
                ?? ""

            // Background notification (web parity: Web Push templates).
            PushNotificationsService.shared.presentIfBackgrounded(
                title: title,
                body: message,
                identifier: "notif-\(notification?.id ?? Int(Date().timeIntervalSince1970))"
            )

            var payload: [String: Any] = [
                "kind": "notification",
                "title": title,
                "message": message
            ]
            if let notification {
                payload["notification"] = notification
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: APIClient.inAppNotification,
                    object: self,
                    userInfo: payload
                )
            }
        default:
            break
        }
    }

    private func extractPushMessageText(from value: MessagePackValue?) -> String? {
        switch value {
        case .string(let raw):
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = obj["text"] as? String,
               !text.isEmpty {
                return text
            }
            return raw.isEmpty ? nil : raw
        case .map(let map):
            return stringValue(map["text"]) ?? stringValue(map["message"]) ?? stringValue(map["body"])
        default:
            return nil
        }
    }

    private func parsePushNotification(from map: [String: MessagePackValue]) -> SocialNotification? {
        let id = intValue(map["id"]) ?? Int(Date().timeIntervalSince1970 * 1000)
        let action = stringValue(map["action"]) ?? "notification"
        let viewed = boolValue(map["viewed"]) ?? false
        let date = stringValue(map["date"]) ?? stringValue(map["create_date"])

        let contentValue = map["content"]
        let content = parseNotificationContent(contentValue)

        var author: PostAuthor?
        if case .map(let authorMap)? = map["author"] {
            author = parseNotificationAuthor(from: authorMap) ?? decodeMap(authorMap, as: PostAuthor.self)
        }
        if author == nil, case .map(let contentMap)? = contentValue,
           case .map(let contentAuthorMap)? = contentMap["author"] {
            author = parseNotificationAuthor(from: contentAuthorMap) ?? decodeMap(contentAuthorMap, as: PostAuthor.self)
        }

        return SocialNotification(
            id: id,
            author: author,
            action: action,
            content: content,
            viewed: viewed,
            date: date
        )
    }

    private func encodableToMap<T: Encodable>(_ payload: T) throws -> [String: MessagePackValue] {
        let data = try encoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw APIError.encodingError
        }

        var map: [String: MessagePackValue] = [:]
        for (k, v) in dict {
            map[k] = try MessagePack.fromJSONObject(v)
        }
        return map
    }

    private func generateRayID() -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let random = (0..<10).map { _ in chars.randomElement() ?? "a" }
        return "\(timestamp)\(String(random))"
    }

    private func describeMap(_ map: [String: MessagePackValue]) -> String {
        var copy: [String: Any] = [:]
        for (k, v) in map {
            if k == "password" {
                copy[k] = "***"
            } else {
                copy[k] = redactedJSONObject(from: v)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "<map>"
    }

    private func redactedJSONObject(from value: MessagePackValue) -> Any {
        switch value {
        case .binary(let data):
            return "<binary \(data.count) bytes>"
        case .string(let s):
            if s.count > 200 {
                let prefix = String(s.prefix(200))
                return "\(prefix)...(\(s.count) chars)"
            }
            return s
        case .array(let arr):
            return arr.map { redactedJSONObject(from: $0) }
        case .map(let map):
            var out: [String: Any] = [:]
            for (k, v) in map {
                out[k] = redactedJSONObject(from: v)
            }
            return out
        default:
            return MessagePack.toJSONObject(value)
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

    private func doubleValue(_ value: MessagePackValue?) -> Double? {
        switch value {
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        case .float(let f): return Double(f)
        case .string(let s): return Double(s.replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }

    private func stringValue(_ value: MessagePackValue?) -> String? {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .float(let f): return String(f)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    private func boolValue(_ value: MessagePackValue?) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .uint(let u): return u != 0
        case .string(let s):
            let v = s.lowercased()
            if v == "true" || v == "1" { return true }
            if v == "false" || v == "0" { return false }
            return nil
        default:
            return nil
        }
    }

    private func arrayValue(_ value: MessagePackValue?) -> [MessagePackValue]? {
        if case .array(let array)? = value {
            return array
        }
        return nil
    }

    private func parseIntArray(_ value: MessagePackValue?) -> [Int]? {
        guard case .array(let array)? = value else {
            return nil
        }

        return array.compactMap(intValue)
    }

    private func extractBinary(_ value: MessagePackValue?) -> Data? {
        switch value {
        case .binary(let d):
            return d
        case .map(let map):
            if case .binary(let d)? = map["buffer"] {
                return d
            }
            return nil
        default:
            return nil
        }
    }

    private func parseComments(from response: [String: MessagePackValue]) -> [PostComment]? {
        let candidates: [MessagePackValue?] = [
            response["comments"],
            response["data"],
            response["items"]
        ]

        for value in candidates {
            guard case .array(let array)? = value else { continue }
            var comments: [PostComment] = []

            for item in array {
                guard case .map(let map) = item,
                      let comment: PostComment = decodeMap(map, as: PostComment.self) else {
                    continue
                }
                comments.append(comment)
            }
            return comments
        }

        return nil
    }

    private func parseCreatedComment(from response: [String: MessagePackValue]) -> PostComment? {
        let keys = ["comment", "data", "item"]

        for key in keys {
            guard case .map(let map)? = response[key] else { continue }
            if let comment: PostComment = decodeMap(map, as: PostComment.self) {
                return comment
            }
        }

        // Some responses can return only `comment_id` or `id`.
        if let cid = intValue(response["comment_id"]) ?? intValue(response["id"]) {
            return PostComment(
                serverID: cid,
                text: "",
                createDate: ISO8601DateFormatter().string(from: Date()),
                author: PostCommentAuthor(id: currentUserID, name: currentUserName, username: currentUsername, avatarAura: nil)
            )
        }

        return nil
    }

    private func decodeMap<T: Decodable>(_ map: [String: MessagePackValue], as type: T.Type) -> T? {
        let object = MessagePack.toJSONObject(.map(map))
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? decoder.decode(T.self, from: data) else {
            return nil
        }
        return decoded
    }

    private func hexPrefix(_ data: Data, count: Int) -> String {
        let prefix = data.prefix(count)
        return prefix.map { String(format: "%02x", $0) }.joined()
    }
}

extension APIClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard session === self.session else { return } // stale session
        isConnected = true
        print("[WS] Connected to: \(webSocketTask.currentRequest?.url?.absoluteString ?? "unknown")")
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard session === self.session else { return } // stale session
        isConnected = false
        isSocketReady = false
        if let reason, let text = String(data: reason, encoding: .utf8) {
            print("[WS] Closed: \(closeCode.rawValue), reason: \(text)")
        } else {
            print("[WS] Closed: \(closeCode.rawValue)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard session === self.session else {
            print("[WS] Ignoring completion of a stale session: \(error.localizedDescription)")
            return
        }
        print("[WS] Task completed with error: \(error.localizedDescription)")
        if shouldIgnoreSocketFailure(error) {
            disconnect()
            return
        }
        notifySocketFailure(error)
    }
}

private extension APIClient {
    func shouldIgnoreSocketFailure(_ error: Error) -> Bool {
        // Avoid surfacing expected socket teardown during backgrounding.
        let isActive: Bool
        if Thread.isMainThread {
            isActive = UIApplication.shared.applicationState == .active
        } else {
            var state: UIApplication.State = .inactive
            DispatchQueue.main.sync {
                state = UIApplication.shared.applicationState
            }
            isActive = state == .active
        }

        if !isActive {
            return true
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .networkConnectionLost:
                return true
            default:
                break
            }
        }
        return false
    }

    func notifySocketFailure(_ error: Error) {
        let now = Date()
        let message = error.localizedDescription
        let urlString = socketStore.currentEndpoint().url
        lastSocketFailure = (message, urlString, now)
        isSocketSuspended = true
        socketFailureHandled = false
        disconnect()

        if let last = lastSocketFailureAt, now.timeIntervalSince(last) < 8 { return }
        lastSocketFailureAt = now

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: APIClient.socketFailureNotification,
                object: self,
                userInfo: ["message": message, "url": urlString]
            )
        }
    }
}

private extension APIClient {
    func startConnectTaskIfNeeded() -> (Task<Void, Error>, UUID) {
        connectLock.lock()
        defer { connectLock.unlock() }

        if let existing = connectTask, let existingID = connectTaskID {
            return (existing, existingID)
        }

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performConnect()
        }
        connectTask = task
        connectTaskID = taskID
        return (task, taskID)
    }

    func clearConnectTask(_ taskID: UUID) {
        connectLock.lock()
        if connectTaskID == taskID {
            connectTask = nil
            connectTaskID = nil
        }
        connectLock.unlock()
    }

    func performConnect() async throws {
        if isSocketReady { return }
        guard let wsURL else { throw APIError.invalidURL }

        do {
            try Task.checkCancellation()

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: wsURL)
            // Allow larger binary frames for original images (default is ~1MB).
            task.maximumMessageSize = 8 * 1024 * 1024

            self.session = session
            self.webSocketTask = task

            task.resume()

            try Task.checkCancellation()
            try await waitForOpen()

            try Task.checkCancellation()
            try await performHandshake()

            try Task.checkCancellation()
            startReceiveLoop()

            try Task.checkCancellation()
            // Socket-level auth is required after every fresh WS session.
            if let sKey = currentSKey {
                try await restoreAuthorization(sKey: sKey)
            }
        } catch {
            print("[WS][CONNECT] failed or cancelled: \(error.localizedDescription), cleaning up socket")
            disconnect()
            throw error
        }
    }
}
