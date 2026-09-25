import Foundation
import UIKit

struct LoginRequest: Encodable {
    let type: String
    let action: String
    let email: String
    let password: String
    let deviceType: String
    let deviceName: String
    let clientName: String

    init(email: String, password: String) {
        self.type = "social"
        self.action = "auth/login"
        self.email = email
        self.password = password
        self.deviceType = "ios_app"
        
        let deviceModel = UIDevice.current.name
        self.deviceName = deviceModel.isEmpty ? "iPhone" : deviceModel
        
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        self.clientName = "Element iOS v\(version)"
    }

    enum CodingKeys: String, CodingKey {
        case type
        case action
        case email
        case password
        case deviceType = "device_type"
        case deviceName = "device_name"
        case clientName = "client_name"
    }
}
