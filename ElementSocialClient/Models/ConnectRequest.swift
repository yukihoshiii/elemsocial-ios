import Foundation

struct ConnectRequest: Encodable {
    let type: String
    let action: String
    let sKey: String

    init(sKey: String) {
        self.type = "authorization"
        self.action = "connect"
        self.sKey = sKey
    }

    enum CodingKeys: String, CodingKey {
        case type
        case action
        case sKey = "S_KEY"
    }
}
