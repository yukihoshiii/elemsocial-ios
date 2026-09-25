import SwiftUI

/// Chat info — web ChatMenu: profile block for DMs, members + invitations tabs for groups.
struct MessengerChatInfoSheet: View {
    @ObservedObject var viewModel: MessengerViewModel
    let chat: MessengerActiveChat
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    @State private var members: [MessengerGroupMember] = []
    @State private var isLoadingMembers = false
    @State private var profileRouteUsername: String?
    @State private var profileViewModel: ProfileViewModel?
    @State private var copiedLink = false

    private var isEnglish: Bool { selectedLanguageCode == "en" }
    private var isGroup: Bool { chat.type == 1 }
    private var isFavorites: Bool { viewModel.isFavoritesChat(chat.target) }
    private var displayName: String {
        isFavorites ? AppLang.key("chat_fav", code: selectedLanguageCode, fallback: isEnglish ? "Favorites" : "Избранное") : chat.name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    headerBlock

                    if !isGroup, let username = chat.username, !username.isEmpty {
                        Button {
                            openProfile(username)
                        } label: {
                            HStack {
                                Image(systemName: "at")
                                Text(isEnglish ? "Go to profile" : "Перейти в профиль")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .foregroundStyle(AppTheme.textPrimary)
                            .padding(14)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }

                    if !isGroup, let description = chat.description, !description.isEmpty {
                        descriptionBlock(description)
                    }

                    if isGroup {
                        groupLinkBlock
                        membersBlock
                    }
                }
                .padding(16)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLang.tr("Готово", "Done", code: selectedLanguageCode)) { dismiss() }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { profileRouteUsername != nil && profileViewModel != nil },
                set: { isPresented in
                    if !isPresented {
                        profileRouteUsername = nil
                        profileViewModel = nil
                    }
                }
            )) {
                if let username = profileRouteUsername, let vm = profileViewModel {
                    ProfileScreen(username: username, viewModel: vm, isMessengerProfile: true)
                        .environmentObject(ProfileComposeContext())
                }
            }
        }
        .task {
            if isGroup {
                isLoadingMembers = true
                members = await viewModel.loadGroupMembers(gid: chat.target.id)
                isLoadingMembers = false
            }
        }
    }

    // MARK: Blocks

    private var headerBlock: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if isFavorites {
                    MessengerSavesAvatarView(size: 96)
                } else {
                    MessengerAvatarView(media: chat.avatar, name: chat.name, size: 96)
                }
                if !isGroup && !isFavorites && chat.isOnline {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2.5))
                }
            }

            Text(displayName)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)

            ForEach(chat.icons, id: \.self) { icon in
                Text(icon)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(AppTheme.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AppTheme.primary.opacity(0.12)))
            }

            if let username = chat.username, !username.isEmpty {
                Text("@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func descriptionBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLang.key("description", code: selectedLanguageCode, fallback: isEnglish ? "Description" : "Описание"))
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Web Invitations tab: join link with regenerate for the owner.
    private var groupLinkBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLang.key("chat_link_info", code: selectedLanguageCode, fallback: isEnglish ? "Group link" : "Ссылка на группу"))
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: 8) {
                Text(chat.joinLink.map { "elemsocial.com/join/\($0)" } ?? (isEnglish ? "No link yet" : "Ссылки пока нет"))
                    .font(.footnote.monospaced())
                    .foregroundStyle(chat.joinLink == nil ? AppTheme.textSecondary : AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    copyLink()
                } label: {
                    Image(systemName: copiedLink ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(copiedLink ? Color.green : AppTheme.primary)
                }
                if chat.isOwner {
                    Button {
                        Task { await viewModel.regenerateGroupLink() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.primary)
                    }
                }
            }
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func copyLink() {
        guard let link = chat.joinLink else { return }
        UIPasteboard.general.string = "https://elemsocial.com/join/\(link)"
        copiedLink = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLink = false }
    }

    private var membersBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLang.key("members", code: selectedLanguageCode, fallback: isEnglish ? "Members" : "Участники"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.textSecondary)
                if !members.isEmpty {
                    Text("\(members.count)")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            if isLoadingMembers {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if members.isEmpty {
                Text(isEnglish ? "No members" : "Нет участников")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(members) { member in
                        HStack(spacing: 12) {
                            MessengerAvatarView(media: member.avatar, name: member.name, size: 38)
                            Text(member.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func openProfile(_ username: String) {
        let vm = ProfileViewModel()
        profileViewModel = vm
        profileRouteUsername = username
        Task {
            await vm.load(username: username, force: false)
        }
    }
}
