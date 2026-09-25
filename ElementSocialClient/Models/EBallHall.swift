import Foundation

struct EBallHallUser: Identifiable {
    let id: Int
    let name: String
    let username: String
    let avatar: PostAuthorAvatar?
    let eballs: Double

    var avatarMedia: MediaData? {
        guard let avatar else { return nil }
        return MediaData(
            file: avatar.file,
            path: avatar.path,
            preview: nil,
            simple: avatar.simple,
            aura: avatar.aura,
            storageFileID: avatar.storageFileID
        )
    }

    var formattedEBalls: String {
        String(format: "%.3f", eballs)
    }
}
