import Foundation
import CryptoKit

final class ImageDiskCache {
    static let shared = ImageDiskCache()

    private let baseURL: URL
    private let ioQueue = DispatchQueue(label: "ImageDiskCache.IO", qos: .utility)

    private init() {
        baseURL = CachePaths.cacheDirectory.appendingPathComponent("images", isDirectory: true)
        CachePaths.ensureDirectory(baseURL)
    }

    func data(forKey key: String) -> Data? {
        let urls = fileURLs(forKey: key)
        if let data = try? Data(contentsOf: urls.primary) {
            return data
        }
        if let data = try? Data(contentsOf: urls.legacy) {
            ioQueue.async {
                CachePaths.writeData(data, to: urls.primary)
            }
            return data
        }
        return nil
    }

    func store(_ data: Data, forKey key: String) {
        let url = fileURLs(forKey: key).primary
        ioQueue.async {
            CachePaths.writeData(data, to: url)
        }
    }

    private func fileURLs(forKey key: String) -> (primary: URL, legacy: URL) {
        let digest = sha256(key)
        let bucket = bucketName(forKey: key)
        let bucketURL = baseURL.appendingPathComponent(bucket, isDirectory: true)
        CachePaths.ensureDirectory(bucketURL)
        let primary = bucketURL.appendingPathComponent(digest)
        let legacy = baseURL.appendingPathComponent(digest)
        return (primary, legacy)
    }

    private func bucketName(forKey key: String) -> String {
        if key.lowercased().hasPrefix("storage#") {
            return "storage"
        }
        if key.lowercased().hasPrefix("url|") {
            return "posts"
        }
        let pathPart = key.split(separator: "#", maxSplits: 1).first ?? ""
        let firstComponent = pathPart.split(separator: "/").first ?? ""
        let cleaned = firstComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned.isEmpty ? "posts" : cleaned
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
