import Foundation

struct LoadPostsResponse: Decodable {
    let status: String
    let message: String?
    let posts: [Post]?

    var isSuccess: Bool {
        status.lowercased() == "success"
    }
}
