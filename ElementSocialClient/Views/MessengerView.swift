import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Root

struct MessengerRootView: View {
    @Binding var isChatActive: Bool
    @StateObject private var viewModel = MessengerViewModel()
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    @State private var isCreateGroupPresented = false
    @State private var isDeleteAllConfirmPresented = false
    @State private var isJoinGroupPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.isKeywordReady {
                    keywordGate
                } else {
                    chatsScreen
                }
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationDestination(isPresented: $isChatActive) {
                if let chat = viewModel.activeChat {
                    MessengerChatScreen(viewModel: viewModel, chat: chat)
                }
            }
        }
        .task {
            await viewModel.bootstrap()
            // Deep link captured before the messenger tab existed.
            if let pending = MessengerViewModel.takePendingJoinLink(), viewModel.isKeywordReady {
                isJoinGroupPresented = true
                viewModel.beginJoinGroup(rawInput: pending)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MessengerViewModel.openJoinLinkNotification)) { notification in
            guard viewModel.isKeywordReady else { return }
            isJoinGroupPresented = true
            if let code = notification.userInfo?["code"] as? String {
                viewModel.beginJoinGroup(rawInput: code)
            }
        }
        .onChange(of: viewModel.activeChat) { newValue in
            isChatActive = (newValue != nil)
        }
        .onChange(of: isChatActive) { newValue in
            if !newValue && viewModel.activeChat != nil {
                viewModel.closeChat()
            }
        }
        .sheet(isPresented: $isCreateGroupPresented) {
            CreateGroupSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isJoinGroupPresented, onDismiss: {
            viewModel.joinGroupState = nil
        }) {
            JoinGroupSheet(viewModel: viewModel, isPresented: $isJoinGroupPresented)
        }
        .alert(
            isEnglish ? "Delete all chats" : "Удалить все чаты",
            isPresented: $isDeleteAllConfirmPresented
        ) {
            Button(isEnglish ? "Yes" : "Да", role: .destructive) {
                Task { await viewModel.deleteAllChats() }
            }
            Button(AppLang.tr("Отмена", "Cancel", code: selectedLanguageCode), role: .cancel) {}
        } message: {
            Text(isEnglish
                 ? "This will irreversibly delete all your chats. Your messages will remain visible to other users."
                 : "Нажимая «Да» вы безвозвратно удалите все свои чаты, при этом ваши сообщения у других пользователей останутся.")
        }
        .alert(
            isEnglish ? "Error" : "Ошибка",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: Keyword gate (web: Chat-SelectKeyWord)

    private var keywordGate: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(AppTheme.primary)

            Text(AppLang.key("chat_keyword", code: selectedLanguageCode, fallback: isEnglish ? "Encryption key" : "Ключевая фраза"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(isEnglish
                 ? "Enter the same passphrase you use on the website to decrypt messages."
                 : "Введите ту же ключевую фразу, что и на сайте, чтобы расшифровывать сообщения.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            SecureField(isEnglish ? "Passphrase" : "Ключевая фраза", text: $viewModel.passphrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))

            Button {
                Task { await viewModel.submitKeyword() }
            } label: {
                Group {
                    if viewModel.isLoadingChats {
                        ProgressView().tint(.white)
                    } else {
                        Text(AppLang.key("chat_select_keyword", code: selectedLanguageCode, fallback: isEnglish ? "Continue" : "Продолжить"))
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(viewModel.passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoadingChats)

            Button {
                isDeleteAllConfirmPresented = true
            } label: {
                Text(AppLang.key("chat_delete_all", code: selectedLanguageCode, fallback: isEnglish ? "Delete all chats" : "Удалить все чаты"))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Chats list (web: Chats.tsx)

    private var chatsScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppLang.key("chats_title", code: selectedLanguageCode, fallback: isEnglish ? "Chats" : "Чаты"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button {
                    isJoinGroupPresented = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(AppTheme.surfaceElevated))
                        .overlay(Circle().stroke(AppTheme.cardStroke, lineWidth: 1))
                }
                .buttonStyle(BubblePressButtonStyle())
                Button {
                    isCreateGroupPresented = true
                } label: {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(AppTheme.surfaceElevated))
                        .overlay(Circle().stroke(AppTheme.cardStroke, lineWidth: 1))
                }
                .buttonStyle(BubblePressButtonStyle())
                Button {
                    Task { await viewModel.reloadChats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(AppTheme.surfaceElevated))
                        .overlay(Circle().stroke(AppTheme.cardStroke, lineWidth: 1))
                }
                .buttonStyle(BubblePressButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if viewModel.isLoadingChats, viewModel.chats.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.chats.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "message")
                        .font(.system(size: 40))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(AppLang.key("chats_null", code: selectedLanguageCode, fallback: isEnglish ? "No chats yet" : "Чатов пока нет"))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.chats) { chat in
                            Button {
                                Task { await viewModel.openChat(chat) }
                            } label: {
                                ChatsListRow(chat: chat, viewModel: viewModel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .refreshable { await viewModel.reloadChats() }
            }
        }
    }
}

// MARK: - Row

struct ChatsListRow: View {
    let chat: MessengerChatSummary
    @ObservedObject var viewModel: MessengerViewModel
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    private var displayName: String {
        viewModel.isFavoritesChat(chat.target)
            ? AppLang.key("chat_fav", code: selectedLanguageCode, fallback: isEnglish ? "Favorites" : "Избранное")
            : chat.name
    }

    var body: some View {
        HStack(spacing: 12) {
            if viewModel.isFavoritesChat(chat.target) {
                MessengerSavesAvatarView(size: 52)
            } else {
                MessengerAvatarView(media: chat.avatar, name: chat.name, size: 52)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !chat.lastMessageDate.isEmpty {
                        Text(messengerRelativeTime(chat.lastMessageDate))
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Text(chat.lastMessage.isEmpty ? (isEnglish ? "No messages" : "Нет сообщений") : chat.lastMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if chat.unreadCount > 0 {
                Text(chat.unreadCount > 99 ? "99+" : "\(chat.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AppTheme.primary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Create group sheet (web: CreateGroup modal)

struct CreateGroupSheet: View {
    @ObservedObject var viewModel: MessengerViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    @State private var name = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarPreview: UIImage?
    @State private var avatarData: Data?
    @State private var isCreating = false

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        if let avatarPreview {
                            Image(uiImage: avatarPreview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())
                        } else {
                            ZStack {
                                Circle().fill(AppTheme.surface)
                                Image(systemName: "camera.fill")
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .frame(width: 96, height: 96)
                        }
                        Circle()
                            .fill(AppTheme.primary)
                            .frame(width: 28, height: 28)
                            .overlay(Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                    }
                }

                TextField(isEnglish ? "Group name" : "Название группы", text: $name)
                    .maxLength(30, text: $name)
                    .padding(14)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task {
                        isCreating = true
                        let success = await viewModel.createGroup(name: name.trimmingCharacters(in: .whitespaces), avatarData: avatarData)
                        isCreating = false
                        if success { dismiss() }
                    }
                } label: {
                    Group {
                        if isCreating {
                            ProgressView().tint(.white)
                        } else {
                            Text(AppLang.tr("Создать", "Create", code: selectedLanguageCode)).font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)

                Spacer()
            }
            .padding(20)
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(AppLang.key("chat_create_group", code: selectedLanguageCode, fallback: isEnglish ? "Create group" : "Создание группы"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) { dismiss() }
                }
            }
            .onChange(of: avatarItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        avatarData = image.jpegData(compressionQuality: 0.9)
                        avatarPreview = image
                    }
                }
                avatarItem = nil
            }
        }
    }
}
