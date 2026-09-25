import Foundation

@MainActor
final class MessengerPushCenter {
    static let shared = MessengerPushCenter()

    var handler: ((MessengerPushKind) -> Void)?

    private init() {}

    func deliver(_ kind: MessengerPushKind) {
        handler?(kind)
    }
}
