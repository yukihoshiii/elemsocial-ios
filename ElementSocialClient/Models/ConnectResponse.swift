import Foundation

struct ConnectResponse: Decodable {
    let status: String
    let message: String?
    let accountData: User?
}
