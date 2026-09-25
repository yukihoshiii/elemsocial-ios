import Foundation

struct LoadPostsRequest: Encodable {
    let type: String
    let action: String
    let payload: LoadPostsPayload
    let sKey: String?

    init(
        postsType: String = "last",
        startIndex: Int = 0,
        authorID: Int? = nil,
        authorType: Int? = nil,
        sKey: String? = nil
    ) {
        self.type = "social"
        self.action = "load_posts"
        self.payload = LoadPostsPayload(
            postsType: postsType,
            startIndex: startIndex,
            authorID: authorID,
            authorType: authorType
        )
        self.sKey = sKey
    }

    enum CodingKeys: String, CodingKey {
        case type
        case action
        case payload
        case sKey = "S_KEY"
    }
}

struct LoadPostsPayload: Encodable {
    let postsType: String
    let startIndex: Int
    let authorID: Int?
    let authorType: Int?

    enum CodingKeys: String, CodingKey {
        case postsType = "posts_type"
        case startIndex = "start_index"
        case authorID = "author_id"
        case authorType = "author_type"
    }
}
