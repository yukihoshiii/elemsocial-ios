import Foundation
import Photos

struct ImageSaveItem {
    let media: MediaData
    let estimatedBytes: Int?
}

enum PhotoLibrarySaver {
    static func saveImages(from items: [ImageSaveItem], apiClient: APIClient = .shared) async throws -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw APIError.serverError("Нет доступа к Фото")
        }

        var savedCount = 0
        for item in items {
            let media = item.media
            guard let path = media.path, let file = media.file else { continue }
            guard let data = await apiClient.downloadImage(
                path: path,
                file: file,
                simple: media.simple,
                lossless: true,
                maxLosslessBytes: item.estimatedBytes
            ) else {
                continue
            }
            try await saveImageData(data)
            savedCount += 1
        }

        guard savedCount > 0 else {
            throw APIError.serverError("Не удалось сохранить изображения")
        }
        return savedCount
    }

    private static func saveImageData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? APIError.serverError("Ошибка сохранения фото"))
                }
            }
        }
    }
}
