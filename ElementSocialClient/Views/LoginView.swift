import SwiftUI

struct LoginView: View {
    @StateObject var viewModel: LoginViewModel
    let onLoginSuccess: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSocketSettingsPresented = false

    var body: some View {
        ZStack {
            AppTheme.backgroundGradient
                .ignoresSafeArea()

            Group {
                if viewModel.pendingVerifyEmail != nil {
                    verifyEmailScreen
                } else {
                    VStack(spacing: 18) {
                        Spacer(minLength: 14)
                        ElementLogo()
                            .frame(width: 140, height: 140)

                        Picker("", selection: $viewModel.mode) {
                            Text("Вход").tag(LoginViewModel.AuthMode.login)
                            Text("Регистрация").tag(LoginViewModel.AuthMode.register)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 30)

                        switch viewModel.mode {
                        case .login:
                            loginForm
                        case .register:
                            registerForm
                        }

                        Button("Сокеты") {
                            isSocketSettingsPresented = true
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.top, 2)

                        statusView
                            .padding(.top, 4)

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 420)
                }
            }
        }
        .sheet(isPresented: $isSocketSettingsPresented) {
            NavigationStack {
                SocketSettingsView()
            }
        }
        .onChange(of: viewModel.mode) { _ in
            viewModel.state = .idle
        }
    }

    // MARK: - Login form

    private var loginForm: some View {
        VStack(spacing: 12) {
            authField("Почта", text: $viewModel.username, isSecure: false)
            authField("Пароль", text: $viewModel.password, isSecure: true)

            primaryButton(title: viewModel.isLoading ? "Входим..." : "Войти") {
                Task {
                    await viewModel.login()
                    if case .success = viewModel.state {
                        onLoginSuccess()
                    }
                }
            }
        }
    }

    // MARK: - Registration form (web «Reg» parity)

    private var registerForm: some View {
        ScrollView {
            VStack(spacing: 12) {
                authField("Имя", text: $viewModel.regName, isSecure: false)
                authField("Уникальное имя", text: $viewModel.regUsername, isSecure: false)
                    .textInputAutocapitalization(.never)
                authField("Почта", text: $viewModel.regEmail, isSecure: false)
                authField("Реферальный код (необязательно)", text: $viewModel.regReferralCode, isSecure: false)
                    .textInputAutocapitalization(.never)
                authField("Пароль", text: $viewModel.regPassword, isSecure: true)

                HCaptchaView(
                    siteKey: HCaptchaView.elementSiteKey,
                    token: $viewModel.captchaToken,
                    isSolved: Binding(
                        get: { !viewModel.captchaToken.isEmpty },
                        set: { if !$0 { viewModel.captchaToken = "" } }
                    )
                )
                .frame(height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Toggle(isOn: $viewModel.regAccept) {
                    Text("Я принимаю правила сообщества")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .tint(AppTheme.primary)

                primaryButton(title: viewModel.isLoading ? "Создаём..." : "Создать аккаунт") {
                    Task {
                        await viewModel.register()
                        if case .success = viewModel.state {
                            onLoginSuccess()
                        }
                    }
                }
                .disabled(!viewModel.canSubmitRegistration)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Email verification screen

    private var verifyEmailScreen: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 30)

            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 46))
                .foregroundStyle(AppTheme.primary)

            Text("Подтвердите почту")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            VStack(spacing: 4) {
                Text("Мы отправили код на")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
                Text(viewModel.pendingVerifyEmail ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }

            authField("Код из письма", text: $viewModel.verificationCode, isSecure: false)
                .multilineTextAlignment(.center)

            primaryButton(title: viewModel.isLoading ? "Проверяем..." : "Подтвердить") {
                Task {
                    await viewModel.verifyEmailCode()
                    if case .success = viewModel.state {
                        onLoginSuccess()
                    }
                }
            }

            Button {
                Task { await viewModel.resendVerificationCode() }
            } label: {
                Text(viewModel.resendCooldown > 0
                     ? "Отправить снова (\(viewModel.resendCooldown)с)"
                     : "Отправить снова")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.resendCooldown > 0 ? AppTheme.textSecondary : AppTheme.primary)
            }
            .disabled(viewModel.resendCooldown > 0 || viewModel.isLoading)

            Button("Вернуться ко входу") {
                viewModel.pendingVerifyEmail = nil
                viewModel.state = .idle
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.top, 4)

            statusView
                .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: 420)
    }

    // MARK: - Shared pieces

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if viewModel.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [AppTheme.primary, AppTheme.primarySoft],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .foregroundStyle(.white)
        }
        .disabled(viewModel.isLoading)
    }

    @ViewBuilder
    private func authField(_ title: String, text: Binding<String>, isSecure: Bool) -> some View {
        Group {
            if isSecure {
                SecureField(title, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(title, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(title.contains("Почт") ? .emailAddress : .default)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(fieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(fieldStroke, lineWidth: 1)
        )
        .foregroundStyle(AppTheme.textPrimary)
    }

    private var fieldBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color(red: 0.95, green: 0.95, blue: 0.97)
    }

    private var fieldStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .loading:
            Text("Отправляем запрос...")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("Ошибка")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .success:
            Text("Успешно")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

private struct ElementLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(logoFill)
                .overlay(Circle().stroke(logoStroke, lineWidth: 2))
                .shadow(color: logoShadow, radius: 10, x: 0, y: 6)
                .frame(width: 120, height: 120)
                .offset(x: -10, y: 6)

            Circle()
                .fill(logoFill)
                .overlay(Circle().stroke(logoStroke, lineWidth: 2))
                .shadow(color: logoShadow, radius: 10, x: 0, y: 6)
                .frame(width: 78, height: 78)
                .offset(x: 28, y: -28)
        }
    }

    private var logoFill: Color {
        colorScheme == .dark
            ? Color(red: 0.40, green: 0.39, blue: 0.45)
            : Color(red: 0.63, green: 0.62, blue: 0.68)
    }

    private var logoStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }

    private var logoShadow: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.45)
            : Color.black.opacity(0.12)
    }
}
