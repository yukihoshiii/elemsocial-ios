import SwiftUI
import UIKit

private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

@MainActor
final class EBallHallViewModel: ObservableObject {
    @Published private(set) var users: [EBallHallUser] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await APIClient.shared.loadEBallHall()
            users = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EBallHallView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @StateObject private var viewModel = EBallHallViewModel()

    let onOpenProfile: (String?) -> Void

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.users.isEmpty {
                ProgressView()
                    .padding(.vertical, 40)
            } else {
                List {
                    Section {
                        podiumSection
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    Section {
                        if listUsers.isEmpty {
                            Text(AppLang.key("ups", code: selectedLanguageCode, fallback: "Ой, а тут пусто"))
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(listUsers) { user in
                                Button {
                                    onOpenProfile(user.username)
                                } label: {
                                    EBallHallRow(user: user)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(AppTheme.surfaceElevated)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.key("nav_hall", code: selectedLanguageCode, fallback: "Зал славы"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private var podiumSection: some View {
        let top = Array(viewModel.users.prefix(3))
        return VStack(spacing: 12) {
            Text(AppLang.key("nav_hall", code: selectedLanguageCode, fallback: "Зал славы"))
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)

            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 10) {
                    podiumBar(
                        user: top.count > 1 ? top[1] : nil,
                        rank: 2,
                        height: 170,
                        gradient: LinearGradient(
                            colors: [Color(hex: 0xB26FB5), Color(hex: 0x3F3462)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    podiumBar(
                        user: top.count > 0 ? top[0] : nil,
                        rank: 1,
                        height: 215,
                        gradient: LinearGradient(
                            colors: [Color(hex: 0xAC6CD8), Color(hex: 0x282949)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    podiumBar(
                        user: top.count > 2 ? top[2] : nil,
                        rank: 3,
                        height: 135,
                        gradient: LinearGradient(
                            colors: [Color(hex: 0x71D0F9), Color(hex: 0x3F3462)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .frame(height: 270)
            .padding(.top, 32)
        }
        .padding(12)
        .hallCardStyle(cornerRadius: 20)
    }

    private var listUsers: [EBallHallUser] {
        Array(viewModel.users.dropFirst(3))
    }

    @ViewBuilder
    private func podiumBar(
        user: EBallHallUser?,
        rank: Int,
        height: CGFloat,
        gradient: LinearGradient
    ) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(gradient)
                .frame(height: height)

            HStack(spacing: 6) {
                EBallHallBadge(size: 18, inverted: true)
                Text(user?.formattedEBalls ?? "--")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 1)
            }
            .padding(.bottom, 28)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                HallAvatarView(
                    media: user?.avatarMedia,
                    fallbackText: user?.name ?? "--",
                    size: 88
                )
                Text(user?.name ?? placeholderName(rank))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 1)
            }
            .offset(y: -56)
            .onTapGesture {
                guard let username = user?.username else { return }
                onOpenProfile(username)
            }
        }
        .frame(width: 108)
    }

    private func placeholderName(_ rank: Int) -> String {
        switch rank {
        case 1: return selectedLanguageCode == "en" ? "First place" : "Первое место"
        case 2: return selectedLanguageCode == "en" ? "Second place" : "Второе место"
        default: return selectedLanguageCode == "en" ? "Third place" : "Третье место"
        }
    }
}

private struct EBallHallRow: View {
    let user: EBallHallUser

    var body: some View {
        HStack(spacing: 12) {
            HallAvatarView(
                media: user.avatarMedia,
                fallbackText: user.name,
                size: 44
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(user.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("@\(user.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Text(user.formattedEBalls)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                EBallHallBadge(size: 14, inverted: false)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct EBallHallBadge: View {
    let size: CGFloat
    let inverted: Bool

    var body: some View {
        let fontSize = max(10, size * 0.65)
        return Text("E")
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(AppTheme.primary)
                    .shadow(color: AppTheme.primary.opacity(0.35), radius: 4, x: 0, y: 2)
            )
    }
}

private struct HallAvatarView: View {
    let media: MediaData?
    let fallbackText: String
    let size: CGFloat
    @State private var uiImage: UIImage?
    @State private var lastLoadedKey: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.surfaceElevated)
                .frame(width: size, height: size)

            Group {
                if let uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    initialsView
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        }
        .overlay(
            Circle()
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .task(id: avatarLoadKey) {
            await loadAvatarIfNeeded(for: avatarLoadKey)
        }
    }

    private var initialsView: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.textPrimary)
    }

    private var initials: String {
        String(fallbackText.prefix(1)).uppercased()
    }

    private var avatarLoadKey: String {
        media?.imageLoadKey ?? ""
    }

    private func loadAvatarIfNeeded(for key: String) async {
        guard lastLoadedKey != key else { return }
        lastLoadedKey = key
        guard let media else {
            uiImage = nil
            return
        }

        if let cachedData = APIClient.shared.cachedMediaImageData(for: media, lossless: true),
           let cachedImage = UIImage(data: cachedData) {
            uiImage = cachedImage
            return
        }

        uiImage = nil

        if let data = await APIClient.shared.downloadMediaImage(media, lossless: true),
           let image = UIImage(data: data) {
            uiImage = image
            return
        }

        if let path = media.path,
           let simple = media.simple,
           let data = await APIClient.shared.downloadImage(path: path, file: simple, simple: simple, lossless: false),
           let image = UIImage(data: data) {
            uiImage = image
        }
    }
}

private struct HallCardStyle: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.postCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 1)
                    )
            )
    }
}

private extension View {
    func hallCardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(HallCardStyle(cornerRadius: cornerRadius))
    }
}
