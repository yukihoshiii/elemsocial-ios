import SwiftUI
import UIKit

@main
struct ElementSocialClientApp: App {
    @StateObject private var sessionViewModel = AppSessionViewModel()
    @AppStorage("selected_theme_mode") private var selectedThemeMode: String = AppThemeMode.system.rawValue
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @AppStorage("selected_accent_theme") private var selectedAccentTheme: String = AppAccentTheme.normal.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var socketFailureMessage: String = ""
    @State private var socketFailureURL: String = ""
    @State private var isSocketFailurePresented = false
    @State private var isSocketSettingsPresented = false
    @State private var socketFailureTask: Task<Void, Never>?
    @State private var connectAppID: Int?
    
    init() {
        // Slightly slower deceleration for smoother scroll feel.
        UIScrollView.appearance().decelerationRate = .init(rawValue: 0.9985)
        AppTheme.applyUIKitTabBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppTheme.backgroundGradient
                    .ignoresSafeArea()

                Group {
                    switch sessionViewModel.state {
                    case .checking:
                        if isSocketFailurePresented || APIClient.shared.isSocketSuspendedSnapshot() {
                            SocketFailureRootScreen(
                                title: AppLang.tr("Проблема с сокетом", "Socket issue", code: selectedLanguageCode),
                                message: socketFailureMessage,
                                url: socketFailureURL,
                                primaryTitle: AppLang.tr("Сменить сокет", "Change socket", code: selectedLanguageCode),
                                secondaryTitle: AppLang.tr("Повторить", "Retry", code: selectedLanguageCode),
                                onChangeSocket: { isSocketSettingsPresented = true },
                                onRetry: {
                                    APIClient.shared.resumeSocket()
                                    Task { await sessionViewModel.bootstrap() }
                                    isSocketFailurePresented = false
                                }
                            )
                        } else {
                            ProgressView("Восстановление сессии...")
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    case .unauthenticated:
                        LoginView(viewModel: LoginViewModel()) {
                            sessionViewModel.markAuthenticated()
                        }
                    case .authenticated:
                        NavigationStack {
                            PostsView(viewModel: PostsViewModel()) {
                                sessionViewModel.logout()
                            }
                        }
                    }
                }
            }
            .tint(AppTheme.primary)
            .preferredColorScheme(currentColorScheme)
            .onChange(of: selectedThemeMode) { _ in
                AppTheme.applyUIKitTabBarAppearance()
            }
            .onChange(of: selectedAccentTheme) { _ in
                AppTheme.applyUIKitTabBarAppearance()
            }
            .onAppear {
                if case .checking = sessionViewModel.state,
                   APIClient.shared.hasUnhandledSocketFailure(),
                   let last = APIClient.shared.lastSocketFailureSnapshot() {
                    scheduleSocketFailurePresentation(message: last.message, url: last.url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: APIClient.socketFailureNotification)) { notification in
                guard case .checking = sessionViewModel.state else { return }
                let message = notification.userInfo?["message"] as? String ?? ""
                let url = notification.userInfo?["url"] as? String ?? ""
                scheduleSocketFailurePresentation(message: message, url: url)
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    cancelSocketFailurePresentation()
                    APIClient.shared.resumeSocket()
                    Task { await sessionViewModel.bootstrap() }
                case .background:
                    if MusicPlayerViewModel.shared.shouldKeepSocketAliveInBackground {
                        break
                    } else {
                        APIClient.shared.disconnect()
                    }
                default:
                    break
                }
            }
            .task {
                if case .checking = sessionViewModel.state {
                    await sessionViewModel.bootstrap()
                }
            }
            .onOpenURL { url in
                handleJoinLinkURL(url)
            }
            .onChange(of: sessionViewModel.state) { state in
                if case .authenticated = state {
                    PushNotificationsService.shared.requestPermissionIfNeeded()
                }
            }
            .sheet(isPresented: $isSocketSettingsPresented) {
                NavigationStack {
                    SocketSettingsView()
                        .navigationTitle(AppLang.tr("Сокеты", "Sockets", code: selectedLanguageCode))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(item: Binding(
                get: { connectAppID.map(ConnectAppTarget.init) },
                set: { connectAppID = $0?.id }
            )) { target in
                NavigationStack {
                    ConnectAppScreen(appID: target.id, onClose: { connectAppID = nil })
                }
            }
        }
    }

    private var currentColorScheme: ColorScheme? {
        AppThemeMode(rawValue: selectedThemeMode)?.colorScheme
    }

    /// elemsocial.com/join/:code and elemsocial.com/connect_app/:id
    private func handleJoinLinkURL(_ url: URL) {
        guard let host = url.host?.lowercased(), host.contains("elemsocial") else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return }

        if parts[0].lowercased() == "join" {
            let code = parts[1]
            guard !code.isEmpty else { return }
            MessengerViewModel.storePendingJoinLink(code)
            NotificationCenter.default.post(
                name: MessengerViewModel.openJoinLinkNotification,
                object: nil,
                userInfo: ["code": code]
            )
            return
        }

        if parts[0].lowercased() == "connect_app",
           let appID = Int(parts[1]) {
            connectAppID = appID
        }
    }

    private func scheduleSocketFailurePresentation(message: String, url: String) {
        cancelSocketFailurePresentation()
        socketFailureTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard case .checking = sessionViewModel.state else { return }
            guard APIClient.shared.isSocketSuspendedSnapshot() else { return }
            await MainActor.run {
                socketFailureMessage = message
                socketFailureURL = url
                isSocketFailurePresented = true
                APIClient.shared.markSocketFailureHandled()
            }
        }
    }

    private func cancelSocketFailurePresentation() {
        socketFailureTask?.cancel()
        socketFailureTask = nil
    }
}

private struct SocketFailureRootScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String
    let url: String
    let primaryTitle: String
    let secondaryTitle: String
    let onChangeSocket: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            AppTheme.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text([message, url].filter { !$0.isEmpty }.joined(separator: "\n"))
                    .font(.body)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(secondaryTitle, action: onRetry)
                        .buttonStyle(.bordered)

                    Button(primaryTitle, action: onChangeSocket)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(cardStroke, lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
    }

    private var cardBackground: Color {
        AppTheme.postCard
    }

    private var cardStroke: Color {
        AppTheme.cardStroke
    }
}

enum AppThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppAccentTheme: String, CaseIterable, Identifiable {
    case normal
    case gold

    var id: String { rawValue }
}

enum AppTheme {
    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }

    private static let purplePrimary = Color(red: 153.0 / 255.0, green: 90.0 / 255.0, blue: 246.0 / 255.0)
    private static let purplePrimarySoft = Color(red: 181.0 / 255.0, green: 132.0 / 255.0, blue: 250.0 / 255.0)
    private static let goldPrimary = Color(red: 212.0 / 255.0, green: 175.0 / 255.0, blue: 55.0 / 255.0)
    private static let goldPrimarySoft = Color(red: 236.0 / 255.0, green: 205.0 / 255.0, blue: 104.0 / 255.0)

    private static var accentTheme: AppAccentTheme {
        let raw = UserDefaults.standard.string(forKey: "selected_accent_theme")
        return AppAccentTheme(rawValue: raw ?? AppAccentTheme.normal.rawValue) ?? .normal
    }

    static var primary: Color {
        accentTheme == .gold ? goldPrimary : purplePrimary
    }

    static var primarySoft: Color {
        accentTheme == .gold ? goldPrimarySoft : purplePrimarySoft
    }
    /// Feed post cards and primary elevated surfaces matching post chrome.
    static let postCard = dynamicColor(
        light: UIColor(red: 254.0 / 255.0, green: 254.0 / 255.0, blue: 254.0 / 255.0, alpha: 1.0),
        dark: UIColor(red: 15.0 / 255.0, green: 15.0 / 255.0, blue: 15.0 / 255.0, alpha: 1.0)
    )
    /// Secondary panels, chips, list row chrome (not main post cards).
    static let surface = dynamicColor(
        light: UIColor(red: 243.0 / 255.0, green: 242.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0),
        dark: UIColor(red: 35.0 / 255.0, green: 35.0 / 255.0, blue: 35.0 / 255.0, alpha: 1.0)
    )
    /// Background behind icons in bordered / secondary buttons.
    static let surfaceElevated = dynamicColor(
        light: UIColor(red: 244.0 / 255.0, green: 243.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0),
        dark: UIColor(red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 32.0 / 255.0, alpha: 1.0)
    )
    /// Icons on secondary / neutral buttons (not accent).
    static let controlIcon = dynamicColor(
        light: UIColor(red: 139.0 / 255.0, green: 134.0 / 255.0, blue: 147.0 / 255.0, alpha: 1.0),
        dark: UIColor(red: 188.0 / 255.0, green: 188.0 / 255.0, blue: 188.0 / 255.0, alpha: 1.0)
    )
    static let textPrimary = dynamicColor(light: .label, dark: .white)
    static let textSecondary = dynamicColor(light: .secondaryLabel, dark: UIColor.white.withAlphaComponent(0.74))
    static let divider = dynamicColor(
        light: UIColor.black.withAlphaComponent(0.10),
        dark: UIColor.white.withAlphaComponent(0.08)
    )
    static let cardStroke = dynamicColor(
        light: UIColor.black.withAlphaComponent(0.06),
        dark: UIColor.white.withAlphaComponent(0.10)
    )
    static let backgroundGradient = LinearGradient(
        colors: [
            dynamicColor(
                light: UIColor(red: 242.0 / 255.0, green: 241.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0),
                dark: UIColor.black
            ),
            dynamicColor(
                light: UIColor(red: 242.0 / 255.0, green: 241.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0),
                dark: UIColor.black
            ),
            dynamicColor(
                light: UIColor(red: 242.0 / 255.0, green: 241.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0),
                dark: UIColor.black
            )
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Matches in-app palette so the system tab bar (e.g. iOS 26 native `TabView`) does not use default greys.
    static func applyUIKitTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 35.0 / 255.0, green: 35.0 / 255.0, blue: 35.0 / 255.0, alpha: 1.0)
                : UIColor(red: 243.0 / 255.0, green: 242.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0)
        }

        let item = UITabBarItemAppearance()
        let muted = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 188.0 / 255.0, green: 188.0 / 255.0, blue: 188.0 / 255.0, alpha: 1.0)
                : UIColor(red: 139.0 / 255.0, green: 134.0 / 255.0, blue: 147.0 / 255.0, alpha: 1.0)
        }
        item.normal.iconColor = muted
        item.normal.titleTextAttributes = [.foregroundColor: muted]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}


private struct ConnectAppTarget: Identifiable {
    let id: Int
}
