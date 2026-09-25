import SwiftUI
import PhotosUI

/// Web `Pages/Apps/index.tsx` — list + add/edit of third-party apps.
struct ThirdPartyAppsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var apps: [ThirdPartyApp] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var editTarget: ThirdPartyApp?
    @State private var isCreatePresented = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    Button(AppLang.tr("Повторить", "Retry", code: selectedLanguageCode)) {
                        Task { await load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        Button {
                            isCreatePresented = true
                        } label: {
                            Label(AppLang.tr("Добавить приложение", "Add app", code: selectedLanguageCode), systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        ForEach(apps) { app in
                            appTile(app)
                        }

                        if apps.isEmpty {
                            Text(AppLang.tr("Приложений пока нет", "No apps yet", code: selectedLanguageCode))
                                .font(.footnote)
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.vertical, 30)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.tr("Приложения", "Apps", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editTarget) { app in
            AppEditSheet(app: app) {
                Task { await load() }
            }
        }
        .sheet(isPresented: $isCreatePresented) {
            AppEditSheet(app: nil) {
                Task { await load() }
            }
        }
    }

    private func load() async {
        isLoading = apps.isEmpty
        errorMessage = nil
        do {
            apps = try await APIClient.shared.loadApps()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func appTile(_ app: ThirdPartyApp) -> some View {
        Button {
            editTarget = app
        } label: {
            HStack(spacing: 12) {
                appIcon(app)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    if let description = app.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(12)
            .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func appIcon(_ app: ThirdPartyApp) -> some View {
        if let base64 = app.iconBase64?.split(separator: ",").last,
           let data = Data(base64Encoded: String(base64)),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.primary.opacity(0.14))
                Image(systemName: "app.gift.fill")
                    .foregroundStyle(AppTheme.primary)
            }
            .frame(width: 44, height: 44)
        }
    }
}

/// Create (app == nil) / edit sheet. Shows api_key + connect URL for existing apps.
struct AppEditSheet: View {
    let app: ThirdPartyApp?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    @State private var name: String
    @State private var appDescription: String
    @State private var url: String
    @State private var iconItem: PhotosPickerItem?
    @State private var iconImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var copiedKey = false

    init(app: ThirdPartyApp?, onSaved: @escaping () -> Void) {
        self.app = app
        self.onSaved = onSaved
        _name = State(initialValue: app?.name ?? "")
        _appDescription = State(initialValue: app?.description ?? "")
        _url = State(initialValue: app?.url ?? "")
    }

    private var isEnglish: Bool { selectedLanguageCode == "en" }
    private var isCreate: Bool { app == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        PhotosPicker(selection: $iconItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                if let iconImage {
                                    Image(uiImage: iconImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(AppTheme.primary.opacity(0.14))
                                        Image(systemName: "app.gift.fill")
                                            .font(.title3)
                                            .foregroundStyle(AppTheme.primary)
                                    }
                                    .frame(width: 64, height: 64)
                                }
                                Circle()
                                    .fill(AppTheme.primary)
                                    .frame(width: 22, height: 22)
                                    .overlay(Image(systemName: "camera.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                            }
                        }

                        field(title: AppLang.tr("Название", "Name", code: selectedLanguageCode), text: $name, limit: 50)
                    }

                    field(title: AppLang.tr("Описание", "Description", code: selectedLanguageCode), text: $appDescription, limit: 150)
                    field(title: AppLang.tr("Описание", "Description", code: selectedLanguageCode), text: $appDescription, limit: 150)
                    if !isCreate {
                        field(title: "URL", text: $url, limit: 300)
                    }

                    if let app, let apiKey = app.apiKey {
                        copyBlock(title: "API Key", value: apiKey, key: "api")
                        copyBlock(title: AppLang.tr("Ссылка подключения", "Connect URL", code: selectedLanguageCode),
                                  value: "https://elemsocial.com/connect_app/\(app.id)", key: "url")
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text(isCreate ? AppLang.tr("Создать", "Create", code: selectedLanguageCode) : AppLang.tr("Сохранить", "Save", code: selectedLanguageCode))
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)

                    Spacer()
                }
                .padding(18)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(isCreate ? AppLang.tr("Новое приложение", "New app", code: selectedLanguageCode) : app?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) { dismiss() }
                }
            }
            .onChange(of: iconItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        iconImage = UIImage(data: data)
                    }
                }
                iconItem = nil
            }
        }
    }

    private func field(title: String, text: Binding<String>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(title == "URL" ? .URL : .default)
                .padding(12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .maxLength(limit, text: text)
        }
    }

    private func copyBlock(title: String, value: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
            HStack {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                    copiedKey = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedKey = false }
                } label: {
                    Image(systemName: copiedKey ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                        .foregroundStyle(copiedKey ? Color.green : AppTheme.primary)
                }
            }
            .padding(10)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            // Web uploads the icon as a data-URL base64 string.
            var iconBase64: String?
            if let iconImage, let jpeg = iconImage.jpegData(compressionQuality: 0.8) {
                iconBase64 = "data:image/jpeg;base64," + jpeg.base64EncodedString()
            }
            if let app {
                try await APIClient.shared.editApp(
                    appID: app.id,
                    name: name.trimmingCharacters(in: .whitespaces),
                    description: appDescription.trimmingCharacters(in: .whitespaces),
                    url: url.trimmingCharacters(in: .whitespaces),
                    iconBase64: iconImage != nil ? iconBase64 : nil
                )
            } else {
                try await APIClient.shared.addApp(
                    name: name.trimmingCharacters(in: .whitespaces),
                    description: appDescription.trimmingCharacters(in: .whitespaces),
                    iconBase64: iconBase64
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Web `ConnectApp.tsx` — confirm screen for elemsocial.com/connect_app/:id.
struct ConnectAppScreen: View {
    let appID: Int
    let onClose: () -> Void
    @State private var app: ThirdPartyApp?
    @State private var isLoading = true
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var connectedURL: URL?

    var body: some View {
        VStack(spacing: 18) {
            if isLoading {
                ProgressView().padding(.vertical, 50)
            } else if let app {
                HStack(spacing: 16) {
                    MessengerAvatarView(media: APIClient.shared.currentUserAvatarSnapshotMedia(), name: "Вы", size: 64)
                    Image(systemName: "link")
                        .foregroundStyle(AppTheme.textSecondary)
                    connectAppIcon(app)
                }
                .padding(.top, 24)

                Text(String(format: AppLang.tr("Подключить приложение %@?", "Connect %@?", code: selectedLanguageCode), app.name))
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let description = app.description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if let connectedURL {
                    Button(AppLang.tr("Открыть приложение", "Open app", code: selectedLanguageCode)) {
                        UIApplication.shared.open(connectedURL)
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { await connect() }
                    } label: {
                        Group {
                            if isConnecting {
                                ProgressView().tint(.white)
                            } else {
                                Text(AppLang.key("connect", code: selectedLanguageCode, fallback: AppLang.tr("Подключить", "Connect", code: selectedLanguageCode)))
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 24)
                    .disabled(isConnecting)
                }

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                Button(AppLang.key("close", code: selectedLanguageCode, fallback: AppLang.tr("Закрыть", "Close", code: selectedLanguageCode))) {
                    onClose()
                }
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)

                Spacer()
            } else {
                Text(errorMessage ?? "Такого приложения нет")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) { onClose() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.tr("Подключение приложения", "App connection", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    @ViewBuilder
    private func connectAppIcon(_ app: ThirdPartyApp) -> some View {
        if let base64 = app.iconBase64?.split(separator: ",").last,
           let data = Data(base64Encoded: String(base64)),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.primary.opacity(0.14))
                Image(systemName: "app.gift.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.primary)
            }
            .frame(width: 64, height: 64)
        }
    }

    private func load() async {
        do {
            app = try await APIClient.shared.loadApp(appID: appID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let key = try await APIClient.shared.connectApp(appID: appID)
            // Web: location.href = appData.url + res.connect_key (raw concat).
            if let urlString = app?.url, !urlString.isEmpty,
               let final = URL(string: urlString + key) {
                connectedURL = final
                _ = try? await UIApplication.shared.open(final)
                return
            }
            errorMessage = "Не удалось открыть ссылку приложения"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
