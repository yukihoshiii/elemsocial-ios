import SwiftUI
import PhotosUI
import Foundation

enum AppLang {
    static func tr(_ ru: String, _ en: String, code: String) -> String {
        LocalizationStore.shared.translate(ru: ru, en: en, code: code)
    }

    static func key(_ key: String, code: String, fallback: String) -> String {
        LocalizationStore.shared.string(forKey: key, code: code, fallback: fallback)
    }
}

enum CreatePostUIStyle: String, CaseIterable, Identifiable {
    case button
    case card
    case both

    var id: String { rawValue }
}

final class LocalizationStore {
    static let shared = LocalizationStore()

    private var cached: [String: [String: String]] = [:]
    private var ruKeyMap: [String: String] = [:]

    private init() {}

    func translate(ru: String, en: String, code: String) -> String {
        let normalized = normalize(code)
        if normalized == "ru" {
            return ru
        }

        loadLanguageIfNeeded("ru")
        loadLanguageIfNeeded(normalized)
        loadLanguageIfNeeded("en")

        if let key = ruKeyMap[ru],
           let translated = cached[normalized]?[key],
           !translated.isEmpty {
            return translated
        }

        if let key = ruKeyMap[ru],
           let translated = cached["en"]?[key],
           !translated.isEmpty {
            return translated
        }

#if DEBUG
        if ruKeyMap[ru] != nil, normalized != "en" {
            print("[i18n] Missing key for '\(ru)' in \(normalized.uppercased())")
        }
#endif

        if normalized == "en" {
            return en
        }

        return ru
    }

    func string(forKey key: String, code: String, fallback: String) -> String {
        let normalized = normalize(code)
        loadLanguageIfNeeded(normalized)
        loadLanguageIfNeeded("en")
        loadLanguageIfNeeded("ru")

        if let value = cached[normalized]?[key], !value.isEmpty {
            return value
        }
        if let value = cached["en"]?[key], !value.isEmpty {
            return value
        }
        if let value = cached["ru"]?[key], !value.isEmpty {
            return value
        }
#if DEBUG
        print("[i18n] Missing direct key '\(key)' for \(normalized.uppercased())")
#endif
        return fallback
    }

    func normalizeLanguageCodeForStorage(_ code: String) -> String {
        normalize(code)
    }

    private func loadLanguageIfNeeded(_ code: String) {
        if cached[code] != nil {
            return
        }

        let candidates: [(name: String, subdir: String?)] = [
            (code.uppercased(), nil),
            (code.lowercased(), nil),
            (code.uppercased(), "Localization"),
            (code.lowercased(), "Localization"),
            (code.uppercased(), "Resources/Localization"),
            (code.lowercased(), "Resources/Localization"),
        ]
        var resolvedURL: URL?
        for candidate in candidates {
            if let url = Bundle.main.url(
                forResource: candidate.name,
                withExtension: "json",
                subdirectory: candidate.subdir
            ) {
                resolvedURL = url
                break
            }
        }
        guard let url = resolvedURL else {
            cached[code] = [:]
            return
        }

        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cached[code] = [:]
            return
        }

        var flattened: [String: String] = [:]
        flatten(object, prefix: nil, into: &flattened)
        cached[code] = flattened

        if code == "ru" {
            var map: [String: String] = [:]
            for (key, value) in flattened where !value.isEmpty {
                map[value] = key
            }
            ruKeyMap = map
        }
    }

    private func flatten(_ object: [String: Any], prefix: String?, into result: inout [String: String]) {
        for (key, value) in object {
            let fullKey = prefix == nil ? key : "\(prefix!).\(key)"
            if let stringValue = value as? String {
                result[fullKey] = stringValue
            } else if let nested = value as? [String: Any] {
                flatten(nested, prefix: fullKey, into: &result)
            }
        }
    }

    private func normalize(_ code: String) -> String {
        switch code.lowercased() {
        case "uk": return "ua"
        case "be": return "by"
        case "kk": return "kz"
        case "za": return "yi"
        default: return code.lowercased()
        }
    }
}

enum SettingsDestination: Hashable {
    case editProfile
    case changeUsername
    case sessions
    case blockedUsers
    case changeEmail
    case changePassword
    case myStatus
    case language
    case theme
    case advanced
    case sockets
    case storage
    case deleteAccount
    case myReports
    case myAppeals
    case apps
    case epack
    case infoHub
}

struct SettingsRootView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    private let topBarBubbleHeight: CGFloat = 34
    private var isIOS26OrNewer: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 8) {
            List {
                Section(AppLang.tr("Профиль", "Profile", code: selectedLanguageCode)) {
                    let rows = [
                        SettingsRowModel(title: AppLang.tr("Редактировать профиль", "Edit profile", code: selectedLanguageCode), icon: "person.crop.circle", color: Color(red: 0.62, green: 0.42, blue: 0.96), destination: .editProfile)
                    ]
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        NavigationLink {
                            destinationView(row.destination)
                        } label: {
                            SettingsRowLabel(row: row)
                        }
                    }
                }

                Section(AppLang.tr("Аккаунт", "Account", code: selectedLanguageCode)) {
                    let rows = [
                        SettingsRowModel(title: AppLang.tr("Сменить уникальное имя", "Change unique name", code: selectedLanguageCode), icon: "at", color: Color(red: 0.31, green: 0.2, blue: 0.9), destination: .changeUsername)
                    ]
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        NavigationLink {
                            destinationView(row.destination)
                        } label: {
                            SettingsRowLabel(row: row)
                        }
                    }
                }

                Section(AppLang.tr("Конфиденциальность", "Privacy", code: selectedLanguageCode)) {
                    let rows = [
                        SettingsRowModel(title: AppLang.tr("Сессии", "Sessions", code: selectedLanguageCode), icon: "iphone", color: Color(red: 0.09, green: 0.95, blue: 0.09), destination: .sessions),
                        SettingsRowModel(title: AppLang.tr("Блокировки", "Blocked Users", code: selectedLanguageCode), icon: "nosign", color: Color(red: 0.98, green: 0.4, blue: 0.35), destination: .blockedUsers),
                        SettingsRowModel(title: AppLang.tr("Сменить почту", "Change email", code: selectedLanguageCode), icon: "envelope.fill", color: Color(red: 1, green: 0.34, blue: 0.35), destination: .changeEmail),
                        SettingsRowModel(title: AppLang.tr("Сменить пароль", "Change password", code: selectedLanguageCode), icon: "lock.fill", color: Color(red: 0.31, green: 0.2, blue: 0.9), destination: .changePassword)
                    ]
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        NavigationLink {
                            destinationView(row.destination)
                        } label: {
                            SettingsRowLabel(row: row)
                        }
                    }
                }

                Section(AppLang.tr("Модерация", "Moderation", code: selectedLanguageCode)) {
                    let rows = [
                        SettingsRowModel(title: AppLang.tr("Мои жалобы", "My reports", code: selectedLanguageCode), icon: "flag.fill", color: Color(red: 1.0, green: 0.60, blue: 0.0), destination: .myReports),
                        SettingsRowModel(title: AppLang.tr("Мои апелляции", "My appeals", code: selectedLanguageCode), icon: "paperplane.fill", color: Color(red: 0.38, green: 0.67, blue: 0.94), destination: .myAppeals)
                    ]
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        NavigationLink {
                            destinationView(row.destination)
                        } label: {
                            SettingsRowLabel(row: row)
                        }
                    }
                }

                Section(AppLang.tr("Другое", "Other", code: selectedLanguageCode)) {
                    let rows = [
                        SettingsRowModel(title: AppLang.tr("Мой статус", "My status", code: selectedLanguageCode), icon: "exclamationmark.triangle.fill", color: Color(red: 0.62, green: 0.42, blue: 0.96), destination: .myStatus),
                        SettingsRowModel(title: AppLang.tr("Язык", "Language", code: selectedLanguageCode), icon: "globe.europe.africa.fill", color: Color(red: 0.38, green: 0.53, blue: 0.93), destination: .language),
                        SettingsRowModel(title: AppLang.tr("Тема", "Theme", code: selectedLanguageCode), icon: "circle.lefthalf.filled", color: Color(red: 0.47, green: 0.39, blue: 0.95), destination: .theme),
                        SettingsRowModel(title: AppLang.tr("Продвинутые настройки", "Advanced settings", code: selectedLanguageCode), icon: "slider.horizontal.3", color: Color(red: 0.38, green: 0.67, blue: 0.94), destination: .advanced),
                        SettingsRowModel(title: AppLang.tr("Сокеты", "Sockets", code: selectedLanguageCode), icon: "bolt.horizontal.fill", color: Color(red: 0.38, green: 0.67, blue: 0.94), destination: .sockets),
                        SettingsRowModel(title: AppLang.tr("Приложения", "Apps", code: selectedLanguageCode), icon: "app.gift.fill", color: Color(red: 0.62, green: 0.42, blue: 0.96), destination: .apps),
                        SettingsRowModel(title: AppLang.tr("Открыть EPACK", "Open EPACK", code: selectedLanguageCode), icon: "archivebox.fill", color: Color(red: 0.47, green: 0.39, blue: 0.95), destination: .epack),
                        SettingsRowModel(title: AppLang.tr("Информация", "Info", code: selectedLanguageCode), icon: "info.circle.fill", color: Color(red: 0.38, green: 0.53, blue: 0.93), destination: .infoHub),
                        SettingsRowModel(title: AppLang.tr("Управление хранилищем", "Storage management", code: selectedLanguageCode), icon: "list.bullet.rectangle.fill", color: Color(red: 0.38, green: 0.67, blue: 0.94), destination: .storage),
                        SettingsRowModel(title: AppLang.tr("Удалить аккаунт", "Delete account", code: selectedLanguageCode), icon: "trash.fill", color: Color(red: 0.98, green: 0.35, blue: 0.35), destination: .deleteAccount)
                    ]
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        NavigationLink {
                            destinationView(row.destination)
                        } label: {
                            SettingsRowLabel(row: row)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .tint(AppTheme.primary)
        .navigationTitle(AppLang.tr("Настройки", "Settings", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func destinationView(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .editProfile:
            EditProfileView()
        case .changeUsername:
            ChangeUniqueNameView()
        case .sessions:
            SessionsView()
        case .blockedUsers:
            BlockedUsersView()
        case .changeEmail:
            ChangeEmailView()
        case .changePassword:
            ChangePasswordView()
        case .myStatus:
            MyStatusView()
        case .language:
            LanguageSettingsView()
        case .theme:
            ThemeSettingsView()
        case .advanced:
            AdvancedSettingsView()
        case .sockets:
            SocketSettingsView()
        case .storage:
            StorageManagementView()
        case .deleteAccount:
            DeleteAccountView()
        case .myReports:
            MyReportsView()
        case .myAppeals:
            MyAppealsView()
        case .apps:
            ThirdPartyAppsView()
        case .epack:
            EPACKViewerView()
        case .infoHub:
            InfoHubView()
        }
    }
}

private struct EditProfileView: View {
    @State private var displayName: String = ""
    @State private var description: String = ""
    @State private var originalName: String = ""
    @State private var originalDescription: String = ""
    @State private var coverMedia: MediaData?
    @State private var avatarMedia: MediaData?
    @State private var coverPreview: UIImage?
    @State private var avatarPreview: UIImage?
    @State private var coverItem: PhotosPickerItem?
    @State private var avatarItem: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var avatarData: Data?
    @State private var isSaving = false
    @State private var infoMessage: String?
    @State private var isLoading = false
    @State private var shouldDeleteCover = false
    @State private var shouldDeleteAvatar = false
    @FocusState private var isDisplayNameFocused: Bool
    @FocusState private var isDescriptionFocused: Bool
    @State private var links: [ProfileLink] = []
    @State private var showingAddLink = false
    @State private var editingLink: ProfileLink?

    private let accountStore = AccountStore()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 10) {
                        coverPreviewView
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        HStack(spacing: 10) {
                            PhotosPicker(selection: $coverItem, matching: .images) {
                                Text("Загрузить обложку")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            if coverPreview != nil {
                                Button(role: .destructive) {
                                    shouldDeleteCover = true
                                    coverPreview = nil
                                    coverData = nil
                                    coverItem = nil
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.red)
                                        .frame(width: 44, height: 40)
                                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        avatarPreviewView
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())

                        HStack(spacing: 10) {
                            PhotosPicker(selection: $avatarItem, matching: .images) {
                                Text("Загрузить аватар")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            if avatarPreview != nil {
                                Button(role: .destructive) {
                                    shouldDeleteAvatar = true
                                    avatarPreview = nil
                                    avatarData = nil
                                    avatarItem = nil
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.red)
                                        .frame(width: 44, height: 40)
                                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        TextField("Имя (ник)", text: $displayName)
                            .focused($isDisplayNameFocused)
                            .font(.body.weight(.medium))
                            .padding(12)
                            .settingsElevatedCard(cornerRadius: 14)

                        TextEditor(text: $description)
                            .focused($isDescriptionFocused)
                            .frame(minHeight: 110)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                            .padding(.trailing, 12)
                            .padding(.leading, 7)
                            .scrollContentBackground(.hidden)
                            .settingsElevatedCard(cornerRadius: 14)
                    }
                }
                .padding(12)
                .settingsCard(cornerRadius: 18)

                // MARK: Links Section
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Ссылки")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Button {
                            showingAddLink = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(AppTheme.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)

                    if links.isEmpty {
                        Text("Нет ссылок")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 10)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                                Button {
                                    editingLink = link
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "link")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(AppTheme.primary)
                                            .frame(width: 28, height: 28)
                                            .background(AppTheme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(link.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(AppTheme.textPrimary)
                                                .lineLimit(1)
                                            Text(link.url)
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if index < links.count - 1 {
                                    Divider().padding(.leading, 50)
                                }
                            }
                        }
                        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(12)
                .settingsCard(cornerRadius: 18)

                actionButton(title: isSaving ? "Сохраняем..." : "Сохранить", enabled: canSubmit) {
                    Task { await saveChanges() }
                }
            }
            .padding(12)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissKeyboard()
            }
        )
        .tint(AppTheme.primary)
        .navigationTitle("Редактировать профиль")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadProfile()
        }
        .onChange(of: coverItem) { _ in
            Task { await loadCoverItem() }
        }
        .onChange(of: avatarItem) { _ in
            Task { await loadAvatarItem() }
        }
        .alert("Профиль", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
        .sheet(isPresented: $showingAddLink) {
            AddEditLinkSheet(
                link: nil,
                onSave: { newTitle, newURL in
                    Task {
                        do {
                            let newID = try await APIClient.shared.addLink(title: newTitle, url: newURL)
                            await MainActor.run {
                                links.append(ProfileLink(id: newID, title: newTitle, url: newURL))
                            }
                        } catch {
                            await MainActor.run { infoMessage = error.localizedDescription }
                        }
                    }
                },
                onDelete: nil
            )
        }
        .sheet(item: $editingLink) { link in
            AddEditLinkSheet(
                link: link,
                onSave: { newTitle, newURL in
                    Task {
                        do {
                            try await APIClient.shared.editLink(linkID: link.id, title: newTitle, url: newURL)
                            await MainActor.run {
                                if let idx = links.firstIndex(where: { $0.id == link.id }) {
                                    links[idx] = ProfileLink(id: link.id, title: newTitle, url: newURL)
                                }
                            }
                        } catch {
                            await MainActor.run { infoMessage = error.localizedDescription }
                        }
                    }
                },
                onDelete: {
                    Task {
                        do {
                            try await APIClient.shared.deleteLink(linkID: link.id)
                            await MainActor.run {
                                links.removeAll { $0.id == link.id }
                            }
                        } catch {
                            await MainActor.run { infoMessage = error.localizedDescription }
                        }
                    }
                }
            )
        }
    }

    private var canSubmit: Bool {
        !isSaving && (!displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var coverPreviewView: some View {
        Group {
            if let coverPreview {
                Image(uiImage: coverPreview)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderCover
            }
        }
    }

    private var avatarPreviewView: some View {
        Group {
            if let avatarPreview {
                Image(uiImage: avatarPreview)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderAvatar
            }
        }
    }

    private var placeholderCover: some View {
        ZStack {
            if let placeholder = UIImage(named: "ProfileCoverPattern") {
                Image(uiImage: placeholder)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(AppTheme.surfaceElevated)
                Image(systemName: "photo")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var placeholderAvatar: some View {
        ZStack {
            Circle().fill(AppTheme.surfaceElevated)
            Image(systemName: "person.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func loadProfile() async {
        guard !isLoading else { return }
        guard let username = APIClient.shared.currentUsernameSnapshot(), !username.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let profile = try await APIClient.shared.loadProfile(username: username)
            displayName = profile.name
            description = profile.description ?? ""
            originalName = profile.name
            originalDescription = profile.description ?? ""
            coverMedia = profile.cover
            avatarMedia = profile.avatar
            links = profile.links
            if let cover = profile.cover {
                coverPreview = await loadRemoteImage(for: cover, lossless: true)
            }
            if let avatar = profile.avatar {
                avatarPreview = await loadRemoteImage(for: avatar, lossless: true)
            }
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func loadCoverItem() async {
        guard let coverItem else { return }
        do {
            if let data = try await coverItem.loadTransferable(type: Data.self) {
                coverData = data
                coverPreview = UIImage(data: data)
                shouldDeleteCover = false
            }
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func loadAvatarItem() async {
        guard let avatarItem else { return }
        do {
            if let data = try await avatarItem.loadTransferable(type: Data.self) {
                avatarData = data
                avatarPreview = UIImage(data: data)
                shouldDeleteAvatar = false
            }
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func loadRemoteImage(for media: MediaData, lossless: Bool) async -> UIImage? {
        if let cached = APIClient.shared.cachedMediaImageData(for: media, lossless: lossless),
           let image = UIImage(data: cached) {
            return image
        }
        if let data = await APIClient.shared.downloadMediaImage(media, lossless: lossless),
           let image = UIImage(data: data) {
            return image
        }
        return nil
    }

    private func saveChanges() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if trimmedName != originalName {
                try await APIClient.shared.updateProfileName(trimmedName)
                originalName = trimmedName
            }
            if trimmedDescription != originalDescription {
                try await APIClient.shared.updateProfileDescription(trimmedDescription)
                originalDescription = trimmedDescription
            }
            if shouldDeleteCover {
                try await APIClient.shared.deleteProfileCover()
                shouldDeleteCover = false
                coverMedia = nil
            } else if let coverData {
                try await APIClient.shared.uploadProfileCover(data: coverData)
                self.coverData = nil
            }
            if shouldDeleteAvatar {
                try await APIClient.shared.deleteProfileAvatar()
                shouldDeleteAvatar = false
                avatarMedia = nil
            } else if let avatarData {
                try await APIClient.shared.uploadProfileAvatar(data: avatarData)
                self.avatarData = nil
            }

            accountStore.updateCurrent(summary: APIClient.shared.currentAccountSummary())
            infoMessage = "Профиль обновлён"
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func dismissKeyboard() {
        isDisplayNameFocused = false
        isDescriptionFocused = false
    }
}

// MARK: - Add / Edit Link Sheet

private struct AddEditLinkSheet: View {
    let link: ProfileLink?
    let onSave: (String, String) -> Void
    let onDelete: (() -> Void)?

    @State private var titleText: String
    @State private var urlText: String
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    init(link: ProfileLink?, onSave: @escaping (String, String) -> Void, onDelete: (() -> Void)?) {
        self.link = link
        self.onSave = onSave
        self.onDelete = onDelete
        _titleText = State(initialValue: link?.title ?? "")
        _urlText = State(initialValue: link?.url ?? "")
    }

    private var isEditing: Bool { link != nil }
    private var canSave: Bool {
        !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Название")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 4)
                            TextField("Например: мой GitHub", text: $titleText)
                                .font(.body.weight(.medium))
                                .padding(12)
                                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ссылка")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 4)
                            TextField("https://...", text: $urlText)
                                .font(.body)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(12)
                                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(12)
                    .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Button {
                        guard canSave else { return }
                        isSaving = true
                        onSave(
                            titleText.trimmingCharacters(in: .whitespacesAndNewlines),
                            urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    } label: {
                        Text(isSaving ? "Сохраняем..." : (isEditing ? "Сохранить" : "Добавить"))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(canSave ? AppTheme.primary : AppTheme.textSecondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .disabled(!canSave)
                    .buttonStyle(.plain)

                    if isEditing, let onDelete {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Удалить ссылку")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(Color.red)
                        }
                        .buttonStyle(.plain)
                        .confirmationDialog("Удалить ссылку?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                            Button("Удалить", role: .destructive) {
                                onDelete()
                                dismiss()
                            }
                            Button("Отмена", role: .cancel) {}
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle(isEditing ? "Редактировать ссылку" : "Добавить ссылку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}


private struct SettingsRowLabel: View {
    let row: SettingsRowModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(.white)
                .background(row.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(row.title)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsRowModel {
    let title: String
    let icon: String
    let color: Color
    let destination: SettingsDestination
}

private struct SettingsSectionView: View {
    let title: String
    let rows: [SettingsRowModel]
    let onTap: (SettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 6)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    SettingsRowButton(row: row) {
                        onTap(row.destination)
                    }
                    if index < rows.count - 1 {
                        Divider()
                            .background(AppTheme.divider)
                            .padding(.leading, 62)
                    }
                }
            }
            .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
        }
    }
}

private struct SettingsRowButton: View {
    let row: SettingsRowModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(row.color)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: row.icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    )

                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StorageManagementView: View {
    @State private var categories: [StorageCategory] = StorageCategory.defaultCategories
    @State private var infoMessage: String?
    @Environment(\.colorScheme) private var colorScheme

    private var totalBytes: Int64 {
        categories.reduce(0) { $0 + $1.bytes }
    }
    
    private var categorySizeColor: Color {
        colorScheme == .dark ? .secondary : .black
    }
    
    private var settingsHeaderColor: Color {
        .secondary
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    StorageRingChart(categories: categories)
                        .frame(width: 170, height: 170)
                        .padding(.top, 6)
                    VStack(spacing: 6) {
                        Text("Использование памяти")
                            .font(.title3.weight(.bold))
                        Text("Element занимает \(formatBytes(totalBytes)) кэша на вашем устройстве")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    Button {
                        categories[index].selected.toggle()
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(category.color)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: category.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.95))
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(formatBytes(category.bytes))
                                    .font(.footnote)
                                    .foregroundStyle(categorySizeColor)
                            }

                            Spacer()

                            Image(systemName: category.selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(category.selected ? category.color : Color.secondary.opacity(0.6))
                        }
                    }
                }
            } header: {
                Text("Категории")
                    .foregroundStyle(settingsHeaderColor)
            } footer: {
                Text("Нажмите на категорию, чтобы выбрать или отменить выбор для очистки.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await clearSelectedCache() }
                } label: {
                    Text("Очистить кэш")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(categories.allSatisfy { !$0.selected || $0.bytes == 0 })

                Button(role: .destructive) {
                    Task { await clearAllCache() }
                } label: {
                    Text("Очистить весь кэш")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(totalBytes == 0)
            }
        }
        .listStyle(.insetGrouped)
        .tint(AppTheme.primary)
        .navigationTitle("Управление хранилищем")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStorageUsage()
        }
        .alert("Хранилище", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func refreshStorageUsage() async {
        let usage = await StorageUsageScanner.scanUsage()
        for index in categories.indices {
            categories[index].bytes = usage[categories[index].id] ?? 0
        }
    }

    private func clearSelectedCache() async {
        let selectedIDs = categories.filter(\.selected).map(\.id)
        guard !selectedIDs.isEmpty else { return }
        let clearedBytes = await StorageUsageScanner.clear(categories: selectedIDs)
        for index in categories.indices where selectedIDs.contains(categories[index].id) {
            categories[index].selected = false
        }
        await refreshStorageUsage()
        infoMessage = "Очищено: \(formatBytes(clearedBytes))"
    }

    private func clearAllCache() async {
        let allIDs = categories.map(\.id)
        let clearedBytes = await StorageUsageScanner.clear(categories: allIDs)
        for index in categories.indices {
            categories[index].selected = false
        }
        await refreshStorageUsage()
        infoMessage = "Полная очистка завершена: \(formatBytes(clearedBytes))"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 Б" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

private struct StorageRingChart: View {
    let categories: [StorageCategory]
    @Environment(\.colorScheme) private var colorScheme

    private var total: Double {
        max(1, Double(categories.reduce(0) { $0 + $1.bytes }))
    }

    var body: some View {
        ZStack {
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                let start = startFraction(index: index)
                let end = endFraction(index: index)
                Circle()
                    .trim(from: start, to: end)
                    .stroke(category.color, style: StrokeStyle(lineWidth: 18, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Circle()
                .fill(colorScheme == .dark ? Color.clear : Color.white)
                .frame(width: 88, height: 88)
                .overlay(
                    Circle().stroke(colorScheme == .dark ? Color.clear : AppTheme.cardStroke, lineWidth: 1)
                )
            Text(formatBytes(categories.reduce(0) { $0 + $1.bytes }))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
        }
    }

    private func startFraction(index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = categories[..<index].reduce(0) { $0 + $1.bytes }
        return CGFloat(Double(previous) / total)
    }

    private func endFraction(index: Int) -> CGFloat {
        let current = categories[...index].reduce(0) { $0 + $1.bytes }
        return CGFloat(Double(current) / total)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 Б" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

private struct StorageCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    var bytes: Int64
    var selected: Bool

    static let defaultCategories: [StorageCategory] = [
        .init(id: "avatars", title: "Аватары", icon: "person.circle.fill", color: Color(red: 0.98, green: 0.7, blue: 0.29), bytes: 0, selected: true),
        .init(id: "covers", title: "Обложки", icon: "doc.on.doc.fill", color: Color(red: 0.33, green: 0.76, blue: 0.55), bytes: 0, selected: true),
        .init(id: "posts", title: "Посты", icon: "square.fill", color: Color(red: 0.38, green: 0.53, blue: 0.93), bytes: 0, selected: true),
        .init(id: "comments", title: "Комментарии", icon: "bubble.left.fill", color: Color(red: 0.9, green: 0.3, blue: 0.8), bytes: 0, selected: true),
        .init(id: "music", title: "Музыка", icon: "music.note", color: Color(red: 0.99, green: 0.37, blue: 0.29), bytes: 0, selected: true),
        .init(id: "messenger", title: "Мессенджер", icon: "message.fill", color: Color(red: 0.47, green: 0.39, blue: 0.95), bytes: 0, selected: true)
    ]
}

private enum StorageUsageScanner {
    private static let categoryOrder: [String] = [
        "avatars",
        "covers",
        "comments",
        "music",
        "messenger",
        "posts"
    ]

    private static let categoryRules: [String: [String]] = [
        "avatars": ["images/avatars", "/avatars/"],
        "covers": ["images/covers", "/covers/"],
        "posts": [
            "images/posts",
            "elementsocialcache/images",
            "elementvideocache",
            "/posts/",
            "/profile_screens/",
            "/profiles/",
            "/notifications/"
        ],
        "comments": ["/comments/"],
        "music": ["/music/"],
        "messenger": ["messenger", "message", "chat"]
    ]

    static func scanUsage() async -> [String: Int64] {
        var result: [String: Int64] = [:]
        let files = allCacheFiles()
        for id in categoryOrder {
            result[id] = estimatedBytes(for: id, files: files)
        }
        // URLCache is shared network cache, относим к постам как к самому активному разделу.
        result["posts", default: 0] += Int64(URLCache.shared.currentDiskUsage)
        return result
    }

    static func clear(categories: [String]) async -> Int64 {
        let files = allCacheFiles()
        var bytesToClear: Int64 = 0
        let selected = Set(categories)
        let fm = FileManager.default
        var shouldClearNetworkCache = false
        for (url, size) in files {
            guard let categoryID = category(for: url), selected.contains(categoryID) else {
                continue
            }
            bytesToClear += size
            try? fm.removeItem(at: url)
            if categoryID == "avatars" || categoryID == "covers" || categoryID == "posts" || categoryID == "comments" {
                shouldClearNetworkCache = true
            }
        }

        if shouldClearNetworkCache || selected.contains("posts") {
            bytesToClear += Int64(URLCache.shared.currentDiskUsage)
            URLCache.shared.removeAllCachedResponses()
            APIClient.shared.clearImageMemoryCache()
        }

        return bytesToClear
    }

    private static func category(for url: URL) -> String? {
        let path = url.path.lowercased()
        for id in categoryOrder {
            guard let tokens = categoryRules[id] else { continue }
            if tokens.contains(where: { path.contains($0) }) { return id }
        }
        return nil
    }

    private static func estimatedBytes(for categoryID: String, files: [(URL, Int64)]) -> Int64 {
        guard let tokens = categoryRules[categoryID] else { return 0 }
        return files.reduce(0) { partial, file in
            let path = file.0.path.lowercased()
            return tokens.contains(where: { path.contains($0) }) ? partial + file.1 : partial
        }
    }

    private static func allCacheFiles() -> [(URL, Int64)] {
        let fm = FileManager.default
        let roots = [
            fm.temporaryDirectory,
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        var files: [(URL, Int64)] = []
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                if size > 0 {
                    files.append((url, size))
                }
            }
        }
        return files
    }
}

struct LanguageSettingsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    private let languages: [(code: String, flag: String, key: String, fallback: String)] = [
        ("en", "🇬🇧", "lang_en", "English"),
        ("isv", "🇨🇿", "lang_isv", "Interslavic"),
        ("ru", "🇷🇺", "lang_ru", "Russian"),
        ("ua", "🇺🇦", "lang_ua", "Ukrainian"),
        ("by", "🇧🇾", "lang_by", "Belarusian"),
        ("pl", "🇵🇱", "lang_pl", "Polish"),
        ("kz", "🇰🇿", "lang_kz", "Kazakh"),
        ("tr", "🇹🇷", "lang_tr", "Turkish"),
        ("bg", "🇧🇬", "lang_bg", "Bulgarian"),
        ("de", "🇩🇪", "lang_de", "German"),
        ("ja", "🇯🇵", "lang_ja", "Japanese"),
        ("zh", "🇨🇳", "lang_zh", "Chinese"),
        ("yi", "🇿🇦", "lang_yi", "Xhosa")
    ]

    var body: some View {
        List {
            Section {
                Text(AppLang.key("lang_warning", code: selectedLanguageCode, fallback: "ВНИМАНИЕ! Все языки, кроме русского и английского сделаны комьюнити, и они могут содержать ошибки."))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(languages, id: \.code) { item in
                    Button {
                        selectedLanguageCode = item.code
                    } label: {
                        HStack(spacing: 12) {
                            Text(item.flag)
                                .font(.system(size: 22))
                            Text(AppLang.key(item.key, code: selectedLanguageCode, fallback: item.fallback))
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            if LocalizationStore.shared.normalizeLanguageCodeForStorage(selectedLanguageCode) == item.code {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(AppTheme.primary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .tint(AppTheme.primary)
        .navigationTitle(tr("Язык", "Language"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let normalized = LocalizationStore.shared.normalizeLanguageCodeForStorage(selectedLanguageCode)
            if normalized != selectedLanguageCode {
                selectedLanguageCode = normalized
            }
        }
    }

    private func tr(_ ru: String, _ en: String) -> String {
        AppLang.tr(ru, en, code: selectedLanguageCode)
    }
}

struct ThemeSettingsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @AppStorage("selected_theme_mode") private var selectedThemeMode: String = AppThemeMode.system.rawValue
    @AppStorage("selected_accent_theme") private var selectedAccentTheme: String = AppAccentTheme.normal.rawValue
    @State private var hasGold = false

    private let themes: [(mode: AppThemeMode, icon: String)] = [
        (.system, "iphone"),
        (.light, "sun.max.fill"),
        (.dark, "moon.fill")
    ]

    var body: some View {
        List {
            Section {
                Text(tr("Выберите режим оформления приложения.", "Choose the app appearance mode."))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(themes, id: \.mode.id) { item in
                    Button {
                        selectedThemeMode = item.mode.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AppTheme.primary)
                            Text(themeTitle(item.mode))
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            if selectedThemeMode == item.mode.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(AppTheme.primary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }

            if hasGold {
                Section {
                    Picker(tr("Тема интерфейса", "Interface theme"), selection: $selectedAccentTheme) {
                        Text(tr("Обычная", "Standard"))
                            .tag(AppAccentTheme.normal.rawValue)
                        Text(tr("Золотая", "Gold"))
                            .tag(AppAccentTheme.gold.rawValue)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .listStyle(.insetGrouped)
        .tint(AppTheme.primary)
        .navigationTitle(tr("Тема", "Theme"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasGold = APIClient.shared.currentUserGoldStatusSnapshot()
            if !hasGold {
                selectedAccentTheme = AppAccentTheme.normal.rawValue
            }
        }
    }

    private func themeTitle(_ mode: AppThemeMode) -> String {
        switch mode {
        case .system:
            return tr("Системная", "System")
        case .light:
            return tr("Светлая", "Light")
        case .dark:
            return tr("Тёмная", "Dark")
        }
    }

    private func tr(_ ru: String, _ en: String) -> String {
        AppLang.tr(ru, en, code: selectedLanguageCode)
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("adv_show_online") private var showOnlineUsers = true
    @AppStorage("adv_double_tap_like") private var doubleTapLike = true
    @AppStorage("adv_auto_video") private var autoVideoDownload = false
    @AppStorage("adv_notifications_toast") private var notificationsToast = true
    @AppStorage("adv_notifications_sound") private var notificationsSound = true
    @AppStorage("adv_create_post_ui") private var createPostUIStyleRaw = CreatePostUIStyle.both.rawValue
    @AppStorage("show_new_update") private var showNewUpdate = true
    @State private var exports: [AccountExportItem] = []
    @State private var isExporting = false
    @State private var infoMessage: String?
    @State private var exportPayload: FileExportPayload?
    @State private var downloadingExports = Set<String>()
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    var body: some View {
        List {
            Section {
                Toggle(
                    AppLang.key(
                        "settings.advanced.show_online_users",
                        code: selectedLanguageCode,
                        fallback: "Показывать пользователей которые сейчас в сети"
                    ),
                    isOn: $showOnlineUsers
                )
                Toggle(
                    AppLang.key(
                        "settings.advanced.double_click_like",
                        code: selectedLanguageCode,
                        fallback: "Двойной клик по посту для лайка"
                    ),
                    isOn: $doubleTapLike
                )
                Toggle(
                    AppLang.tr("Показывать баннер обновлений", "Show update banner", code: selectedLanguageCode),
                    isOn: $showNewUpdate
                )
                Toggle(
                    AppLang.key(
                        "settings.advanced.auto_download_video",
                        code: selectedLanguageCode,
                        fallback: "Автоматическая загрузка видео"
                    ),
                    isOn: $autoVideoDownload
                )
                Toggle(
                    AppLang.key(
                        "settings.advanced.notifications_toast",
                        code: selectedLanguageCode,
                        fallback: "Всплывающие уведомления"
                    ),
                    isOn: $notificationsToast
                )
                Toggle(
                    AppLang.key(
                        "settings.advanced.notifications_sound",
                        code: selectedLanguageCode,
                        fallback: "Звук уведомлений"
                    ),
                    isOn: $notificationsSound
                )
            }

            Section(AppLang.tr("Создание поста", "Post creation", code: selectedLanguageCode)) {
                Picker(AppLang.tr("Показывать", "Show", code: selectedLanguageCode), selection: $createPostUIStyleRaw) {
                    Text(AppLang.tr("Кнопка", "Button", code: selectedLanguageCode))
                        .tag(CreatePostUIStyle.button.rawValue)
                    Text(AppLang.tr("Карточка", "Card", code: selectedLanguageCode))
                        .tag(CreatePostUIStyle.card.rawValue)
                    Text(AppLang.tr("Оба варианта", "Both", code: selectedLanguageCode))
                        .tag(CreatePostUIStyle.both.rawValue)
                }
                .pickerStyle(.segmented)
            }

            Section(AppLang.key("settings.advanced.export", code: selectedLanguageCode, fallback: "Экспорт данных аккаунта")) {
                Button(AppLang.key("settings.advanced.create_export", code: selectedLanguageCode, fallback: "Запросить экспорт")) {
                    Task { await requestExport() }
                }
                .disabled(isExporting)
            }

            Section(AppLang.key("settings.advanced.exports", code: selectedLanguageCode, fallback: "Экспорты")) {
                if exports.isEmpty {
                    Text("Ой, а тут пусто")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(exports) { item in
                        HStack(spacing: 12) {
                            Text(item.name)
                                .lineLimit(1)
                            Spacer()
                            if let size = item.size {
                                Text(formatSize(size))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if downloadingExports.contains(item.name) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    Task { await downloadAccountExport(item) }
                                } label: {
                                    Image(systemName: "arrow.down.to.line")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .tint(AppTheme.primary)
        .listStyle(.insetGrouped)
        .navigationTitle(
            AppLang.key("settings.advanced.title", code: selectedLanguageCode, fallback: "Продвинутые настройки")
        )
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshExports()
        }
        .alert("Экспорт", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
        .sheet(item: $exportPayload) { payload in
            FileExportSheet(url: payload.url) { _ in
                exportPayload = nil
            }
        }
    }

    private func requestExport() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let message = try await APIClient.shared.createAccountExport()
            infoMessage = message ?? "Экспорт поставлен в очередь."
            await refreshExports()
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func refreshExports() async {
        do {
            exports = try await APIClient.shared.loadAccountExports()
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func downloadAccountExport(_ item: AccountExportItem) async {
        let alreadyDownloading = await MainActor.run {
            downloadingExports.contains(item.name)
        }
        if alreadyDownloading { return }

        await MainActor.run {
            downloadingExports.insert(item.name)
        }
        defer {
            Task {
                await MainActor.run {
                    downloadingExports.remove(item.name)
                }
            }
        }

        let candidates = [
            "exports",
            "account/exports",
            "account/exports/files"
        ]

        for path in candidates {
            if let url = await APIClient.shared.downloadFile(path: path, file: item.name) {
                if let exportURL = prepareExportURL(from: url, filename: item.name) {
                    await MainActor.run {
                        exportPayload = FileExportPayload(url: exportURL)
                    }
                    return
                }
            }
        }

        await MainActor.run {
            infoMessage = "Не удалось скачать экспорт"
        }
    }

    private func prepareExportURL(from url: URL, filename: String) -> URL? {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("ElementExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let targetURL = exportDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            let unique = exportDir.appendingPathComponent("\(UUID().uuidString)_\(filename)")
            try? FileManager.default.removeItem(at: unique)
            do {
                try FileManager.default.copyItem(at: url, to: unique)
                return unique
            } catch {
                return nil
            }
        }

        try? FileManager.default.removeItem(at: targetURL)
        do {
            try FileManager.default.copyItem(at: url, to: targetURL)
            return targetURL
        } catch {
            return nil
        }
    }

    private func formatSize(_ size: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

struct SocketSettingsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var endpoints: [SocketEndpoint] = []
    @State private var selectedID: String = ""
    @State private var newSocketValue: String = ""
    @State private var errorMessage: String?
    @FocusState private var isNewSocketFocused: Bool

    private let store = SocketEndpointStore.shared
    
    private var settingsHeaderColor: Color {
        .secondary
    }

    var body: some View {
        List {
            Section {
                let current = endpoints.first(where: { $0.id == selectedID })
                Text(current?.url ?? store.currentEndpoint().url)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                    .textSelection(.enabled)
            } header: {
                Text(tr("Текущий сокет", "Current socket"))
                    .foregroundStyle(settingsHeaderColor)
            }

            Section {
                ForEach(endpoints) { endpoint in
                    Button {
                        select(endpoint)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(endpoint.url)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                                if endpoint.id == store.defaultID() {
                                    Text(tr("По умолчанию", "Default"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if endpoint.id == selectedID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.primary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteEndpoints)
            } header: {
                Text(tr("Список сокетов", "Socket list"))
                    .foregroundStyle(settingsHeaderColor)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("wss://ws.example.com/user_api", text: $newSocketValue)
                        .focused($isNewSocketFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.weight(.medium))

                    Button(tr("Добавить и выбрать", "Add and select")) {
                        addEndpoint()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 6)
            } header: {
                Text(tr("Добавить сокет", "Add socket"))
                    .foregroundStyle(settingsHeaderColor)
            }
        }
        .listStyle(.insetGrouped)
        .tint(AppTheme.primary)
        .navigationTitle(tr("Сокеты", "Sockets"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(tr("Готово", "Done")) {
                    dismiss()
                }
            }
        }
        .alert(tr("Ошибка", "Error"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        endpoints = store.loadEndpoints()
        selectedID = store.selectedID() ?? store.defaultID()
    }

    private func select(_ endpoint: SocketEndpoint) {
        APIClient.shared.applySocketEndpoint(endpoint)
        reload()
    }

    private func addEndpoint() {
        guard let endpoint = APIClient.shared.applySocketURLString(newSocketValue) else {
            errorMessage = tr("Некорректный адрес сокета", "Invalid socket address")
            return
        }
        newSocketValue = ""
        selectedID = endpoint.id
        reload()
    }

    private func deleteEndpoints(at offsets: IndexSet) {
        let removable = offsets.compactMap { index in
            endpoints.indices.contains(index) ? endpoints[index] : nil
        }
        removable.forEach { endpoint in
            store.removeEndpoint(id: endpoint.id)
        }
        reload()
    }

    private func tr(_ ru: String, _ en: String) -> String {
        AppLang.tr(ru, en, code: selectedLanguageCode)
    }
}

struct ChangeUniqueNameView: View {
    @AppStorage("local_profile_username") private var storedUsername: String = ""
    @State private var username: String = ""
    @State private var isSubmitting = false
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                LargeTopSymbol(assetName: "ChangeUsername", tint: AppTheme.primarySoft)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Сменить имя можно сколько угодно раз, но если его займёт кто-то другой вернуть уже не получится.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Section {
                TextField("Уникальное имя", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                actionButton(title: "Изменить", enabled: !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Task { await submit() }
                }
            }
        }
        .tint(AppTheme.primary)
        .navigationTitle("Сменить уникальное имя")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if username.isEmpty {
                username = storedUsername.isEmpty ? (APIClient.shared.currentUsernameSnapshot() ?? "") : storedUsername
            }
        }
        .alert("Имя", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            infoMessage = "Введите уникальное имя."
            return
        }
        do {
            try await APIClient.shared.updateUsername(trimmed)
            storedUsername = trimmed
            username = trimmed
            infoMessage = "Уникальное имя обновлено."
        } catch {
            infoMessage = error.localizedDescription
        }
    }
}

struct ChangeEmailView: View {
    @AppStorage("local_profile_email") private var storedEmail: String = ""
    @State private var email: String = ""
    @State private var isSubmitting = false
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                LargeTopSymbol(assetName: "ChangeEmail", tint: AppTheme.primarySoft)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Текущая: \(currentEmailLabel)")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Section {
                TextField("Новая почта", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                actionButton(title: "Изменить", enabled: isValidEmail(email)) {
                    Task { await submit() }
                }
            }
        }
        .tint(AppTheme.primary)
        .navigationTitle("Сменить почту")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if email.isEmpty {
                email = storedEmail.isEmpty ? (APIClient.shared.currentUserEmailSnapshot() ?? "") : storedEmail
            }
        }
        .alert("Почта", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func isValidEmail(_ value: String) -> Bool {
        value.contains("@") && value.contains(".")
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        guard isValidEmail(email) else {
            infoMessage = "Некорректная почта."
            return
        }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await APIClient.shared.updateEmail(trimmed)
            storedEmail = trimmed
            email = trimmed
            infoMessage = "Почта обновлена."
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private var currentEmailLabel: String {
        if !storedEmail.isEmpty {
            return storedEmail
        }
        return APIClient.shared.currentUserEmailSnapshot() ?? "не указана"
    }
}

struct ChangePasswordView: View {
    @AppStorage("local_profile_password") private var storedPassword: String = ""
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var isSubmitting = false
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                LargeTopSymbol(assetName: "ChangePassword", tint: AppTheme.primarySoft)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Запомните или запишите пароль, если вы его забудете, вы не сможете войти в аккаунт.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Section {
                SecureField("Старый пароль", text: $oldPassword)
                SecureField("Новый пароль", text: $newPassword)
                actionButton(title: "Изменить", enabled: oldPassword.count >= 3 && newPassword.count >= 6) {
                    Task { await submit() }
                }
            }
        }
        .tint(AppTheme.primary)
        .navigationTitle("Сменить пароль")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Пароль", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await APIClient.shared.updatePassword(oldPassword: oldPassword, newPassword: newPassword)
            storedPassword = ""
            oldPassword = ""
            newPassword = ""
            infoMessage = "Пароль обновлён."
        } catch {
            infoMessage = error.localizedDescription
        }
    }
}

struct MyStatusView: View {
    private var rows: [(String, Bool)] {
        let permissions = APIClient.shared.currentUserPermissionsSnapshot()
        return [
            ("Публикация постов", permissions?.posts ?? false),
            ("Публикация комментариев", permissions?.comments ?? false),
            ("Возможность начинать чат", permissions?.newChats ?? false),
            ("Публикация музыки", permissions?.musicUpload ?? false)
        ]
    }

    var body: some View {
        List {
            Section {
                LargeTopSymbol(symbol: "checkmark.circle", tint: AppTheme.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Ваш аккаунт свободен от ограничений!")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let title = row.0
                    let isAllowed = row.1
                    HStack {
                        Text(title)
                        Spacer()
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isAllowed ? AppTheme.primary : Color.secondary.opacity(0.55))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .tint(AppTheme.primary)
        .navigationTitle("Мой статус")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SessionsView: View {
    @State private var sessions: [APIClient.SessionInfo] = []
    @State private var infoMessage: String?
    @State private var selectedLifetime: Int = 60 * 60 * 24 * 30   // default 30 days
    @State private var isSavingLifetime = false
    @Environment(\.colorScheme) private var colorScheme

    private let lifetimeOptions: [(label: String, seconds: Int)] = [
        ("15 дней", 60 * 60 * 24 * 15),
        ("1 месяц", 60 * 60 * 24 * 30),
        ("3 месяца", 60 * 60 * 24 * 90),
        ("6 месяцев", 60 * 60 * 24 * 180),
        ("1 год", 60 * 60 * 24 * 365)
    ]

    private var settingsHeaderColor: Color {
        .secondary
    }

    var body: some View {
        List {
            Section {
                LargeTopSymbol(assetName: "Sessions", tint: AppTheme.primarySoft)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if let current = sessions.first(where: { $0.isCurrent }) {
                    sessionRow(
                        title: sessionTitle(for: current),
                        subtitle: sessionSubtitle(for: current),
                        icon: iconName(for: current),
                        removable: false,
                        onRemove: {}
                    )
                } else {
                    sessionRow(
                        title: "iPhone iOS",
                        subtitle: fallbackCurrentSubtitle(),
                        icon: "iphone",
                        removable: false,
                        onRemove: {}
                    )
                }
            } header: {
                Text("Текущая сессия")
                    .foregroundStyle(settingsHeaderColor)
            }

            Section {
                let otherSessions = sessions.filter { !$0.isCurrent }
                if otherSessions.isEmpty {
                    Text("Нет других активных сессий")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(otherSessions) { session in
                        sessionRow(
                            title: sessionTitle(for: session),
                            subtitle: sessionSubtitle(for: session),
                            icon: iconName(for: session),
                            removable: true
                        ) {
                            Task { await removeSession(session.id) }
                        }
                    }
                }
            } header: {
                Text("Все сессии")
                    .foregroundStyle(settingsHeaderColor)
            }

            Section {
                Picker("Срок хранения", selection: $selectedLifetime) {
                    ForEach(lifetimeOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .pickerStyle(.menu)
                .tint(AppTheme.primary)

                Button {
                    Task { await saveLifetime() }
                } label: {
                    HStack {
                        Text("Сохранить срок")
                        if isSavingLifetime {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSavingLifetime)
            } header: {
                Text("Время жизни неактивной сессии")
                    .foregroundStyle(settingsHeaderColor)
            } footer: {
                Text("Сессии, в которых нет активности дольше указанного времени, будут автоматически завершены.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .tint(AppTheme.primary)
        .navigationTitle("Сессии")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSessions()
        }
        .alert("Сессии", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func saveLifetime() async {
        isSavingLifetime = true
        defer { isSavingLifetime = false }
        do {
            try await APIClient.shared.updateInactiveSessionLifetime(seconds: selectedLifetime)
            infoMessage = "Настройка сохранена"
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func sessionRow(title: String, subtitle: String, icon: String, removable: Bool, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 28)
                .foregroundStyle(icon == "safari.fill" ? Color.blue : Color.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.medium))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if removable {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    private func removeSession(_ id: String) async {
        do {
            try await APIClient.shared.terminateSession(sessionID: id)
            await loadSessions()
            infoMessage = "Сессия удалена."
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func iconName(for session: APIClient.SessionInfo) -> String {
        let text = "\(session.title) \(session.subtitle)".lowercased()
        if text.contains("ios") || text.contains("iphone") {
            return "iphone"
        }
        if text.contains("mac") {
            return "laptopcomputer"
        }
        return "safari.fill"
    }

    private func sessionTitle(for session: APIClient.SessionInfo) -> String {
        if iconName(for: session) == "iphone" {
            return "iPhone iOS"
        }
        return session.title
    }

    private func sessionSubtitle(for session: APIClient.SessionInfo) -> String {
        if isElementIOSApp(subtitle: session.subtitle) {
            if iconName(for: session) == "iphone" && session.isCurrent {
                return "Element • iOS \(UIDevice.current.systemVersion) • \(appVersionText())"
            }
            return "Element • \(appVersionText())"
        }
        return session.subtitle
    }

    private func fallbackCurrentSubtitle() -> String {
        return "Element • iOS \(UIDevice.current.systemVersion) • \(appVersionText())"
    }

    private func isElementIOSApp(subtitle: String) -> Bool {
        let normalized = subtitle.lowercased()
        return normalized.contains("element ios") || normalized.contains("ios mvp")
    }

    private func appVersionText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        if version.isEmpty { return "" }
        return "v\(version)"
    }

    private func loadSessions() async {
        do {
            sessions = try await APIClient.shared.loadSessions()
        } catch {
            infoMessage = error.localizedDescription
        }
    }
}

struct BlockedUsersView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var blockedUsers: [BlockedUserItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            } else if blockedUsers.isEmpty {
                Text(AppLang.tr("Список пуст", "List is empty", code: selectedLanguageCode))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(blockedUsers) { item in
                    blockedUserRow(item: item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLang.tr("Блокировки", "Blocked Users", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(
            AppLang.tr("Уведомление", "Notice", code: selectedLanguageCode),
            isPresented: Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func blockedUserRow(item: BlockedUserItem) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                if let username = item.target.username {
                    ProfileRouteScreen(username: username)
                }
            } label: {
                HStack(spacing: 12) {
                    PostAuthorAvatarView(
                        media: item.target.avatarMedia,
                        fallbackText: item.target.name ?? item.target.username ?? "?",
                        size: 44
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.target.name ?? item.target.username ?? "—")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("@\(item.target.username ?? "")")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(formatBlockDate(item.createdAt))
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button {
                Task { await unblock(item: item) }
            } label: {
                Text(AppLang.tr("Разблокировать", "Unblock", code: selectedLanguageCode))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: 126)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            blockedUsers = try await APIClient.shared.loadBlockedUsers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unblock(item: BlockedUserItem) async {
        guard let username = item.target.username else { return }
        do {
            try await APIClient.shared.unblockUser(username: username)
            blockedUsers.removeAll { $0.id == item.id }
            infoMessage = AppLang.tr("Пользователь разблокирован", "User unblocked", code: selectedLanguageCode)
        } catch {
            infoMessage = error.localizedDescription
        }
    }

    private func formatBlockDate(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: date)
        }
        return raw
    }
}



struct DeleteAccountView: View {
    @State private var deletePosts = false
    @State private var isSubmitting = false
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                Text(deleteText)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Удалить все мои посты вместе с аккаунтом", isOn: $deletePosts)
            }

            Section {
                Button(role: .destructive) {
                    Task { await submitDeleteAccount() }
                } label: {
                    Text("Принять и удалить")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isSubmitting)
            }
        }
        .tint(AppTheme.primary)
        .navigationTitle("Удалить аккаунт")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Удаление аккаунта", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private var deleteText: String {
        """
        При удалении аккаунта, все ваши личные данные (имя аккаунта, почта, хэш пароля, сессии, чаты) будут удалены с базы данных Element'a в течении 14 дней.

        Если вы измените решение можно восстановить аккаунт в течении этих 14 дней, просто войдите в аккаунт до окончания этого срока, и удаление будет отменено. После 14 дней, аккаунт будет удалён без возможности восстановления.

        Ваши посты после удаления останутся не тронутыми, ваш аккаунт просто потеряет все личные данные, если вы хотите вы можете отдельно поставить отметку при удалении аккаунта и ваши посты будут удалены вместе с аккаунтом, а точнее перемещены в корзину, соответственно вы сможете восстановить их вместе с аккаунтом в течении 14 дней, после чего они будут удалены без возможности восстановления.

        Вы так же можете скачать архив с вашими данными во вкладке «Продвинутые настройки»
        """
    }

    private func submitDeleteAccount() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        infoMessage = deletePosts
            ? "Локально отмечено удаление аккаунта и постов."
            : "Локально отмечено удаление аккаунта."
    }
}

private struct LargeTopSymbol: View {
    let symbol: String?
    let assetName: String?
    let tint: Color

    init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.assetName = nil
        self.tint = tint
    }

    init(assetName: String, tint: Color) {
        self.symbol = nil
        self.assetName = assetName
        self.tint = tint
    }

    var body: some View {
        ZStack {
            if let assetName {
                Image(assetName)
                    .renderingMode(Image.TemplateRenderingMode.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 140)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 90, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white.opacity(0.8), tint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .frame(height: 132)
        .padding(.top, 2)
    }
}

private struct SessionAvatarBadge: View {
    @State private var image: UIImage?
    @State private var loadedKey = ""

    private var media: MediaData? {
        APIClient.shared.currentAuthorSnapshot().avatarMedia
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(AppTheme.surfaceElevated)
                Text("U")
                    .font(.headline.weight(.bold))
            }
        }
        .clipShape(Circle())
        .task(id: avatarKey) {
            await loadAvatar()
        }
    }

    private var avatarKey: String {
        media?.imageLoadKey ?? ""
    }

    private func loadAvatar() async {
        guard loadedKey != avatarKey else { return }
        loadedKey = avatarKey
        image = nil
        guard let media else { return }
        if let data = await APIClient.shared.downloadMediaImage(media, lossless: true),
           let loaded = UIImage(data: data) {
            image = loaded
        }
    }
}

private struct SettingsCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var cardBackground: Color {
        elevated ? AppTheme.surfaceElevated : AppTheme.postCard
    }
}

private extension View {
    func settingsCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(SettingsCardModifier(cornerRadius: cornerRadius, elevated: false))
    }

    func settingsElevatedCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(SettingsCardModifier(cornerRadius: cornerRadius, elevated: true))
    }

    func actionButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.primary)
        .disabled(!enabled)
    }
}
