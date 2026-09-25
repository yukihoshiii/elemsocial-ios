import Foundation

struct LoginResponse: Decodable {
    let status: String
    let sKey: String?
    let message: String?
    let email: String?
    let accountData: User?

    enum CodingKeys: String, CodingKey {
        case status
        case sKey = "S_KEY"
        case message
        case email
        case accountData
    }

    var isSuccess: Bool {
        status.lowercased() == "success"
    }

    var needsEmailVerification: Bool {
        status.lowercased() == "verify_email"
    }
}
