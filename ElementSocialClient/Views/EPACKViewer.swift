import SwiftUI
import UniformTypeIdentifiers

/// Web `/epack` (ViewEPACK) — opens `.epack` post archive files.
/// Format: plain JSON, versions 1.4 / 1.9.2 / 1.9.4 / 2.1.
struct EPACKViewerView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    @State private var parsedPost: EPACKPost?
    @State private var parseError: String?
    @State private var isImporterPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let parsedPost {
                    EPACKPostCard(post: parsedPost)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(AppTheme.primary)
                        Text(AppLang.tr("Откройте файл формата «epack»", "Open an “epack” file", code: selectedLanguageCode))
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)

                        Button {
                            isImporterPresented = true
                        } label: {
                            Label(AppLang.key("select_file", code: selectedLanguageCode, fallback: AppLang.tr("Выбрать файл", "Select file", code: selectedLanguageCode)),
                                  systemImage: "folder")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 30)

                        Text(AppLang.tr("EPACK — архив поста со вложениями и комментариями, сохранённый с сайта.", "EPACK is a post archive with attachments and comments saved from the site.", code: selectedLanguageCode))
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 40)
                }

                if let parseError {
                    Text(parseError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(14)
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("EPACK")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data, .json, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                open(url: url)
            }
        }
    }

    private func open(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        guard url.pathExtension.lowercased() == "epack" else {
            parseError = AppLang.tr("Файл должен быть формата «epack»", "The file must be an “epack” file", code: selectedLanguageCode)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            parsedPost = try EPACKParser.parse(data)
            parseError = nil
        } catch {
            parseError = AppLang.tr("Ой, что-то пошло не так...", "Oops, something went wrong...", code: selectedLanguageCode)
        }
    }
}

// MARK: - Parser (web Utils/parsers.ts)

struct EPACKComment: Identifiable {
    let id: UUID
    let authorName: String
    let authorUsername: String?
    let avatarBase64: String?
    let date: String
    let text: String
}

struct EPACKPost {
    let authorName: String
    let authorUsername: String?
    let avatarBase64: String?
    let date: String
    let text: String
    let contentType: String?      // "image" | "file" | nil
    let contentFileName: String?
    let contentFileSize: Int?
    let contentBase64: String?    // image bytes or file bytes
    let likesCount: Int
    let dislikesCount: Int
    let commentsCount: Int
    let comments: [EPACKComment]
}

enum EPACKParser {
    /// The JSON root IS the post (web parsers.ts) — `E_VER` sits next to the
    /// post fields, there is no wrapper object.
    static func parse(_ data: Data) throws -> EPACKPost {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }

        let version = object["E_VER"] as? String ?? ""

        switch version {
        case "1.4":
            return try parseLegacy(object, contentKeys: ("Type", "Name", "Size", nil))
        case "1.9.2", "1.9.4":
            return try parseLegacy(object, contentKeys: ("Type", "orig_name", "Size", "file_size"))
        case "2.1":
            return try parseModern(object)
        default:
            throw APIError.serverError("Неподдерживаемая версия EPACK: \(version)")
        }
    }

    /// 1.4 / 1.9.x — PascalCase schema. Content base64 lives in
    /// `Content.File` OR `Content.Image` (1.4) / `ImageB64 || FileB64` (1.9.x).
    private static func parseLegacy(
        _ object: [String: Any],
        contentKeys: (type: String, name: String, size: String, sizeAlt: String?)
    ) throws -> EPACKPost {
        // Root is the post itself.
        let post = object

        let content = post["Content"] as? [String: Any] ?? [:]
        let contentType = content[contentKeys.type] as? String
        let fileName = content[contentKeys.name] as? String
        var fileSize: Int?
        if let n = content[contentKeys.size] as? NSNumber { fileSize = n.intValue }
        if let alt = contentKeys.sizeAlt, let n = content[alt] as? NSNumber { fileSize = n.intValue }

        // Web: `Content.File || Content.Image` (1.4), `ImageB64 || FileB64` (1.9.x)
        // — regardless of the declared type.
        var base64: String?
        for key in ["File", "Image", "FileB64", "ImageB64"] {
            if let b64 = content[key] as? String {
                base64 = b64
                break
            }
        }

        let comments = (post["Comments"] as? [[String: Any]] ?? []).map { raw in
            EPACKComment(
                id: UUID(),
                authorName: raw["Name"] as? String ?? "...",
                authorUsername: raw["Username"] as? String,
                avatarBase64: raw["Avatar"] as? String,
                date: raw["Date"] as? String ?? "",
                text: raw["Text"] as? String ?? ""
            )
        }

        // Web 1.4 leaves comments count null (hidden); only use the explicit field.
        let commentsCount = (post["CommentsCount"] as? NSNumber)?.intValue

        return EPACKPost(
            authorName: post["Name"] as? String ?? "...",
            authorUsername: post["Username"] as? String,
            avatarBase64: post["Avatar"] as? String,
            date: post["Date"] as? String ?? "",
            text: post["Text"] as? String ?? "",
            contentType: contentType,
            contentFileName: fileName,
            contentFileSize: fileSize,
            contentBase64: base64,
            likesCount: (post["LikesCount"] as? NSNumber)?.intValue ?? 0,
            dislikesCount: (post["DislikesCount"] as? NSNumber)?.intValue ?? 0,
            commentsCount: commentsCount ?? -1, // -1 = hide counter
            comments: comments
        )
    }

    /// 2.1 — snake_case schema (root is the post).
    private static func parseModern(_ object: [String: Any]) throws -> EPACKPost {
        let post = object
        let author = post["author_data"] as? [String: Any] ?? [:]
        let content = post["content"] as? [String: Any] ?? [:]

        let comments = (post["comments"] as? [[String: Any]] ?? []).map { raw in
            let commentAuthor = raw["author_data"] as? [String: Any] ?? [:]
            return EPACKComment(
                id: UUID(),
                authorName: commentAuthor["name"] as? String ?? "...",
                authorUsername: commentAuthor["username"] as? String,
                avatarBase64: commentAuthor["avatar"] as? String,
                date: raw["date"] as? String ?? "",
                text: raw["text"] as? String ?? ""
            )
        }

        var fileSize: Int?
        if let n = content["file_size"] as? NSNumber { fileSize = n.intValue }
        if let n = content["size"] as? NSNumber { fileSize = n.intValue }

        return EPACKPost(
            authorName: author["name"] as? String ?? "...",
            authorUsername: author["username"] as? String,
            avatarBase64: author["avatar"] as? String,
            date: post["date"] as? String ?? "",
            text: post["text"] as? String ?? "",
            contentType: content["type"] as? String,
            contentFileName: content["orig_name"] as? String,
            contentFileSize: fileSize,
            contentBase64: content["file"] as? String,
            likesCount: (post["likes_count"] as? NSNumber)?.intValue ?? 0,
            dislikesCount: (post["dislikes_count"] as? NSNumber)?.intValue ?? 0,
            commentsCount: (post["comments_count"] as? NSNumber)?.intValue ?? -1,
            comments: comments
        )
    }
}

// MARK: - Render

private struct EPACKPostCard: View {
    let post: EPACKPost
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var shareURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if let username = post.authorUsername {
                        Text("@\(username)")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
            }

            Text(post.text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)

            attachment

            HStack(spacing: 16) {
                Label("\(post.likesCount)", systemImage: "hand.thumbsup.fill")
                Label("\(post.dislikesCount)", systemImage: "hand.thumbsdown.fill")
                if post.commentsCount >= 0 {
                    Label("\(post.commentsCount)", systemImage: "bubble.right")
                }
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(14)
        .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
        .sheet(item: Binding(
            get: { shareURL.map(EPACKSharePayload.init) },
            set: { shareURL = $0?.url }
        )) { payload in
            ShareSheet(items: [payload.url])
        }
    }

    private struct EPACKSharePayload: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @ViewBuilder
    private var avatar: some View {
        if let base64 = post.avatarBase64?.split(separator: ",").last,
           let data = Data(base64Encoded: String(base64)),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(AppTheme.primary.opacity(0.18))
                Text(String(post.authorName.prefix(1)).uppercased())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
            }
            .frame(width: 42, height: 42)
        }
    }

    @ViewBuilder
    private var attachment: some View {
        if let base64 = post.contentBase64 {
            if post.contentType?.lowercased() == "image",
               let data = Data(base64Encoded: base64.contains(",") ? String(base64.split(separator: ",", maxSplits: 1).last ?? "") : base64),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Button {
                    saveFile()
                } label: {
                    HStack {
                        Image(systemName: "doc.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.contentFileName ?? "file")
                                .font(.footnote.weight(.semibold))
                            if let size = post.contentFileSize {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    .font(.caption2)
                            }
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.down")
                    }
                    .padding(10)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func saveFile() {
        guard let base64 = post.contentBase64 else { return }
        let clean = base64.contains(",") ? String(base64.split(separator: ",", maxSplits: 1).last ?? "") : base64
        guard let data = Data(base64Encoded: clean) else { return }
        let name = post.contentFileName ?? "epack_file"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        shareURL = url
    }
}
