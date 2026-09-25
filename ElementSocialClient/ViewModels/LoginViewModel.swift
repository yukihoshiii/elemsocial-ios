import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case success(LoginResponse)
        case error(String)
    }

    enum AuthMode {
        case login
        case register
    }

    @Published var username = ""
    @Published var password = ""
    @Published var state: State = .idle
    @Published var mode: AuthMode = .login

    // Registration fields (web Authorization.tsx «Reg» form).
    @Published var regName = ""
    @Published var regUsername = ""
    @Published var regEmail = ""
    @Published var regPassword = ""
    @Published var regReferralCode = ""
    @Published var regAccept = false
    @Published var captchaToken = ""

    // Email verification.
    @Published var pendingVerifyEmail: String?
    @Published var verificationCode = ""
    @Published var resendCooldown = 0

    private var resendCooldownTask: Task<Void, Never>?

    private let apiClient: APIClient
    private let tokenStore: AuthTokenStore
    private let accountStore: AccountStore

    init(apiClient: APIClient = .shared, tokenStore: AuthTokenStore = AuthTokenStore(), accountStore: AccountStore = AccountStore()) {
        self.apiClient = apiClient
        self.tokenStore = tokenStore
        self.accountStore = accountStore
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var canSubmitRegistration: Bool {
        !regName.trimmingCharacters(in: .whitespaces).isEmpty
            && !regUsername.trimmingCharacters(in: .whitespaces).isEmpty
            && !regEmail.trimmingCharacters(in: .whitespaces).isEmpty
            && regPassword.count >= 6
            && regAccept
            && !captchaToken.isEmpty
    }

    // MARK: Login

    func login() async {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedUsername.isEmpty, !trimmedPassword.isEmpty else {
            state = .error("Введите email и пароль")
            return
        }

        state = .loading

        do {
            let response = try await apiClient.login(username: trimmedUsername, password: trimmedPassword)
            finishAuth(response, fallbackEmail: trimmedUsername)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: Registration

    func register() async {
        guard canSubmitRegistration else {
            state = .error("Заполните все поля, примите правила и пройдите капчу")
            return
        }

        state = .loading
        do {
            let response = try await apiClient.registerAccount(
                name: regName.trimmingCharacters(in: .whitespaces),
                username: regUsername.trimmingCharacters(in: .whitespaces),
                email: regEmail.trimmingCharacters(in: .whitespaces),
                password: regPassword,
                referralCode: regReferralCode.trimmingCharacters(in: .whitespaces),
                accept: regAccept,
                captchaToken: captchaToken
            )
            finishAuth(response, fallbackEmail: regEmail)
        } catch {
            state = .error(error.localizedDescription)
            // Captcha is single-use — force a fresh challenge after a failure.
            captchaToken = ""
        }
    }

    // MARK: Email verification

    func verifyEmailCode() async {
        guard let email = pendingVerifyEmail, !verificationCode.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .error("Введите код из письма")
            return
        }
        state = .loading
        do {
            let response = try await apiClient.verifyEmail(email: email, code: verificationCode)
            finishAuth(response, fallbackEmail: email)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func resendVerificationCode() async {
        guard let email = pendingVerifyEmail, resendCooldown <= 0 else { return }
        do {
            try await apiClient.resendEmailVerification(email: email)
            startResendCooldown()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func startResendCooldown() {
        resendCooldown = 120
        resendCooldownTask?.cancel()
        resendCooldownTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.resendCooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.resendCooldown = max(0, self.resendCooldown - 1)
            }
        }
    }

    /// Shared tail of every auth flow (login / register / verify):
    /// verify_email → switch to the code screen; success → persist session.
    private func finishAuth(_ response: LoginResponse, fallbackEmail: String) {
        if response.needsEmailVerification {
            pendingVerifyEmail = response.email ?? fallbackEmail
            verificationCode = ""
            state = .idle
            return
        }

        if response.status.lowercased() == "error" {
            state = .error(response.message ?? "Ошибка авторизации")
            return
        }

        if let sKey = response.sKey {
            tokenStore.save(sessionKey: sKey)
            print("[AUTH] S_KEY saved")
            let summary = apiClient.currentAccountSummary()
            let stored = accountStore.addOrUpdate(sKey: sKey, summary: summary)
            accountStore.setCurrentAccount(id: stored.id)
        }

        pendingVerifyEmail = nil
        state = .success(response)
    }
}

@MainActor
final class AppSessionViewModel: ObservableObject {
    enum State {
        case checking
        case unauthenticated
        case authenticated
    }

    @Published private(set) var state: State = .checking
    private var isBootstrapping = false

    private let apiClient: APIClient
    private let tokenStore: AuthTokenStore
    private let accountStore: AccountStore

    init(apiClient: APIClient = .shared, tokenStore: AuthTokenStore = AuthTokenStore(), accountStore: AccountStore = AccountStore()) {
        self.apiClient = apiClient
        self.tokenStore = tokenStore
        self.accountStore = accountStore
    }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        let wasAuthenticated = state == .authenticated
        guard let sKey = tokenStore.load(), !sKey.isEmpty else {
            state = .unauthenticated
            return
        }

        let restored = await apiClient.restoreSession(sKey: sKey)
        if restored {
            let summary = apiClient.currentAccountSummary()
            if let currentID = accountStore.currentAccountID() {
                accountStore.updateCurrent(summary: summary)
                accountStore.setCurrentAccount(id: currentID)
            } else {
                let stored = accountStore.addOrUpdate(sKey: sKey, summary: summary)
                accountStore.setCurrentAccount(id: stored.id)
            }
            state = .authenticated
        } else {
            if apiClient.isSocketSuspendedSnapshot() {
                if !wasAuthenticated {
                    state = .checking
                }
            } else {
                tokenStore.clear()
                state = .unauthenticated
            }
        }
    }

    func markAuthenticated() {
        state = .authenticated
    }

    func logout() {
        tokenStore.clear()
        apiClient.clearSessionForLogout()
        if let currentID = accountStore.currentAccountID() {
            accountStore.removeAccount(id: currentID)
        }
        state = .unauthenticated
    }
}
