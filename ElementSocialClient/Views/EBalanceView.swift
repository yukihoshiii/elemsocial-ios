import SwiftUI

private enum EBalanceTab: String, CaseIterable, Identifiable {
    case history
    case subscription
    case earning
    case referral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "История"
        case .subscription: return "Подписка"
        case .earning: return "Начисление"
        case .referral: return "Рефералы"
        }
    }
}

@MainActor
final class EBalanceViewModel: ObservableObject {
    @Published private(set) var transactions: [EBallTransaction] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var balanceText: String = "0.000"
    @Published private(set) var goldStatus = false
    @Published private(set) var goldHistory: [GoldHistoryItem] = []
    @Published private(set) var isGoldActionInFlight = false

    private var startIndex = 0

    var balanceValue: Double {
        let normalized = balanceText.replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0
    }

    func loadInitialIfNeeded() async {
        refreshBalanceSnapshot()
        refreshSubscriptionSnapshot()
        guard transactions.isEmpty else { return }
        await loadInitial()
    }

    func refreshBalanceSnapshot() {
        let raw = APIClient.shared.currentUserEBallsSnapshot() ?? "0"
        balanceText = Self.formatBalance(raw)
    }

    func updateBalance(_ newValue: Double) {
        balanceText = String(format: "%.3f", newValue)
    }

    func refreshSubscriptionSnapshot() {
        goldStatus = APIClient.shared.currentUserGoldStatusSnapshot()
        goldHistory = Self.sortedHistory(APIClient.shared.currentUserGoldHistorySnapshot())
    }

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await APIClient.shared.loadEBallHistory(startIndex: 0)
            transactions = result
            startIndex = result.count
            hasMore = !result.isEmpty
        } catch {
            hasMore = false
        }
    }

    func reloadHistory() async {
        transactions.removeAll()
        startIndex = 0
        hasMore = true
        await loadInitial()
    }

    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await APIClient.shared.loadEBallHistory(startIndex: startIndex)
            if result.isEmpty {
                hasMore = false
                return
            }
            transactions.append(contentsOf: result)
            startIndex += result.count
        } catch {
            hasMore = false
        }
    }

    func payGoldSubscription() async throws {
        guard !isGoldActionInFlight else { return }
        isGoldActionInFlight = true
        defer { isGoldActionInFlight = false }
        try await APIClient.shared.payGoldSubscription()
        refreshBalanceSnapshot()
        refreshSubscriptionSnapshot()
    }

    func activateGoldSubscription(code: String) async throws {
        guard !isGoldActionInFlight else { return }
        isGoldActionInFlight = true
        defer { isGoldActionInFlight = false }
        try await APIClient.shared.activateGoldSubscription(code: code)
        refreshSubscriptionSnapshot()
    }

    private static func formatBalance(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let value = Double(normalized) ?? 0
        return String(format: "%.3f", value)
    }

    private static func sortedHistory(_ history: [GoldHistoryItem]) -> [GoldHistoryItem] {
        history.sorted { lhs, rhs in
            let leftDate = EBalanceDateFormatter.shared.parseDate(lhs.date) ?? .distantPast
            let rightDate = EBalanceDateFormatter.shared.parseDate(rhs.date) ?? .distantPast
            return leftDate > rightDate
        }
    }
}

struct EBalanceView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @StateObject private var viewModel = EBalanceViewModel()
    @State private var selectedTab: EBalanceTab = .history
    @State private var activationCode: String = ""
    @State private var isActivatePromptPresented = false
    @State private var statusAlert: StatusAlert?

    init(openSubscription: Bool = false) {
        _selectedTab = State(initialValue: openSubscription ? .subscription : .history)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                balanceCard

                Picker("Раздел", selection: $selectedTab) {
                    ForEach(EBalanceTab.allCases) { tab in
                        Text(tabTitle(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)

                tabContent
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.tr("Кошелёк", "Wallet", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadInitialIfNeeded() }
        .alert(AppLang.key("balance.subscription.activate.title", code: selectedLanguageCode, fallback: "Введите ключ"), isPresented: $isActivatePromptPresented) {
            TextField(AppLang.key("balance.subscription.activate.title", code: selectedLanguageCode, fallback: "Введите ключ"), text: $activationCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(AppLang.key("activate", code: selectedLanguageCode, fallback: "Активировать")) {
                let code = activationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                activationCode = ""
                Task { await handleActivate(code: code) }
            }
            Button(AppLang.key("cancel", code: selectedLanguageCode, fallback: "Отмена"), role: .cancel) {
                activationCode = ""
            }
        } message: {
            Text(AppLang.key("balance.subscription.activate.description", code: selectedLanguageCode, fallback: "Ключ можно получить разными способами. Начиная от покупки, заканчивая просто подарком от кого-то."))
        }
        .alert(item: $statusAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 14) {
            Text(AppLang.key("balance.current", code: selectedLanguageCode, fallback: "Текущий баланс"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                EBalanceBadge(size: 54)
                Text(viewModel.balanceText)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
            }

            NavigationLink {
                EBalanceTransferView(
                    availableBalance: viewModel.balanceValue,
                    availableBalanceText: viewModel.balanceText,
                    onBalanceUpdate: { newValue in
                        viewModel.updateBalance(newValue)
                    },
                    onTransferCompleted: {
                        Task { await viewModel.reloadHistory() }
                    }
                )
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(AppLang.key("balance.actions.transfer", code: selectedLanguageCode, fallback: "Перевести"))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surfaceElevated)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .ebCardStyle(cornerRadius: 20)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .history:
            historySection
        case .subscription:
            subscriptionSection
        case .earning:
            earningSection
        case .referral:
            ReferralProgramView()
        }
    }

    private var historySection: some View {
        VStack(spacing: 12) {
            if viewModel.isLoading && viewModel.transactions.isEmpty {
                ProgressView()
                    .padding(.vertical, 30)
            } else if viewModel.transactions.isEmpty {
                Text("История пока пустая")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                ForEach(viewModel.transactions) { transaction in
                    EBalanceHistoryRow(transaction: transaction)
                        .onAppear {
                            guard transaction.id == viewModel.transactions.last?.id else { return }
                            Task { await viewModel.loadMoreIfNeeded() }
                        }
                }

                if viewModel.isLoadingMore {
                    ProgressView()
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            subscriptionHistory

            if !viewModel.goldStatus {
                NavigationLink {
                    SubscriptionScreen()
                } label: {
                    HStack(spacing: 10) {
                        Image("Star")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text("Перейти к покупке")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.surfaceElevated)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .ebCardStyle(cornerRadius: 20)
    }

    private var subscriptionOffer: some View {
        VStack(spacing: 12) {
            Image("SubscriptionLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(height: 64)

            Text(AppLang.key("gold_price", code: selectedLanguageCode, fallback: "1 месяц / 0.1 е-балл"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            HStack(spacing: 12) {
                Button(AppLang.key("activate", code: selectedLanguageCode, fallback: "Активировать")) {
                    isActivatePromptPresented = true
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.surfaceElevated)
                )

                Button(AppLang.key("pay", code: selectedLanguageCode, fallback: "Купить")) {
                    Task { await handlePay() }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.primary.opacity(0.2))
                )
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .disabled(viewModel.isGoldActionInFlight)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surfaceElevated)
        )
    }

    private var subscriptionHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLang.key("gold_history", code: selectedLanguageCode, fallback: "История активаций"))
                .font(.subheadline.weight(.semibold))

            if viewModel.goldHistory.isEmpty {
                Text(AppLang.key("ups", code: selectedLanguageCode, fallback: "Ой, а тут пусто"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(viewModel.goldHistory) { item in
                    EBalanceSubscriptionStatusRow(
                        status: item.status,
                        activatedText: activationText(for: item),
                        languageCode: selectedLanguageCode
                    )
                }
            }
        }
    }

    private var subscriptionBenefits: some View {
        VStack(spacing: 0) {
            ForEach(subscriptionBenefitItems.indices, id: \.self) { index in
                let item = subscriptionBenefitItems[index]
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                    Text(item.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)

                if index != subscriptionBenefitItems.count - 1 {
                    Divider()
                        .overlay(AppTheme.divider)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.surfaceElevated)
        )
    }

    private var earningSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            EBalanceEarningRow(title: "1 пост", amount: 0.005, systemImage: "doc.text")
            EBalanceEarningRow(title: "1 комментарий", amount: 0.003, systemImage: "text.bubble")
            EBalanceEarningRow(title: "1 трек", amount: 0.010, systemImage: "music.note")

            Text("Баллы начисляются автоматически за вашу активность на платформе. Чем больше вы участвуете в жизни сообщества, тем больше баллов получаете.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(18)
        .ebCardStyle(cornerRadius: 20)
    }

    private func tabTitle(_ tab: EBalanceTab) -> String {
        switch tab {
        case .history:
            return AppLang.key("balance.tabs.history", code: selectedLanguageCode, fallback: "История")
        case .subscription:
            return AppLang.key("balance.tabs.subscription", code: selectedLanguageCode, fallback: "Подписка")
        case .earning:
            return AppLang.key("balance.tabs.earning", code: selectedLanguageCode, fallback: "Начисление")
        case .referral:
            return AppLang.key("balance.tabs.referral", code: selectedLanguageCode, fallback: "Рефералы")
        }
    }

    private func activationText(for item: GoldHistoryItem) -> String {
        let locale = Locale(identifier: selectedLanguageCode)
        let dateText = EBalanceDateFormatter.shared.absoluteDate(from: item.date, locale: locale) ?? item.date
        let template = AppLang.key("balance.subscription.activated_on", code: selectedLanguageCode, fallback: "активировано {{date}}")
        return template.replacingOccurrences(of: "{{date}}", with: dateText)
    }

    private func handlePay() async {
        do {
            try await viewModel.payGoldSubscription()
            showStatusAlert(
                title: AppLang.key("success", code: selectedLanguageCode, fallback: "Получилось"),
                message: AppLang.key("balance.subscription.success", code: selectedLanguageCode, fallback: "Подписка активирована")
            )
        } catch {
            showStatusAlert(
                title: AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
                message: error.localizedDescription.isEmpty
                    ? AppLang.key("balance.subscription.error_unknown", code: selectedLanguageCode, fallback: "Точных причин нет")
                    : error.localizedDescription
            )
        }
    }

    private func handleActivate(code: String) async {
        guard !code.isEmpty else { return }
        do {
            try await viewModel.activateGoldSubscription(code: code)
            showStatusAlert(
                title: AppLang.key("success", code: selectedLanguageCode, fallback: "Получилось"),
                message: AppLang.key("balance.subscription.success", code: selectedLanguageCode, fallback: "Подписка активирована")
            )
        } catch {
            showStatusAlert(
                title: AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
                message: error.localizedDescription.isEmpty
                    ? AppLang.key("balance.subscription.error_unknown", code: selectedLanguageCode, fallback: "Точных причин нет")
                    : error.localizedDescription
            )
        }
    }

    private func showStatusAlert(title: String, message: String) {
        statusAlert = StatusAlert(title: title, message: message)
    }

    private var subscriptionBenefitItems: [BenefitItem] {
        [
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.limits.title", code: selectedLanguageCode, fallback: "Повышенные лимиты"),
                body: AppLang.key("balance.subscription.benefits.limits.body", code: selectedLanguageCode, fallback: "Больше действий: например, увеличенные лимиты на загрузку файлов и не только.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.badge.title", code: selectedLanguageCode, fallback: "Уникальный значок"),
                body: AppLang.key("balance.subscription.benefits.badge.body", code: selectedLanguageCode, fallback: "В профиле появится уникальный значок, и он будет виден в ваших постах.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.ads.title", code: selectedLanguageCode, fallback: "Без рекламы"),
                body: AppLang.key("balance.subscription.benefits.ads.body", code: selectedLanguageCode, fallback: "Для вас будет скрыта вся реклама.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.theme.title", code: selectedLanguageCode, fallback: "Уникальная тема"),
                body: AppLang.key("balance.subscription.benefits.theme.body", code: selectedLanguageCode, fallback: "Дополнительная золотая тема оформления.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.list.title", code: selectedLanguageCode, fallback: "Особый список"),
                body: AppLang.key("balance.subscription.benefits.list.body", code: selectedLanguageCode, fallback: "Ваш аккаунт будет добавлен в специальный список на главной странице.")
            )
        ]
    }
}

struct SubscriptionScreen: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @StateObject private var viewModel = EBalanceViewModel()
    @State private var activationCode: String = ""
    @State private var isActivatePromptPresented = false
    @State private var statusAlert: StatusAlert?
    @State private var selectedTab: SubscriptionTab = .benefits
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                subscriptionHeader
                subscriptionTabs
                subscriptionContentCard
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, viewModel.goldStatus ? 28 : 180)
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.goldStatus {
                subscriptionPurchaseCard
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
            }
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.key("balance.tabs.subscription", code: selectedLanguageCode, fallback: "Подписка"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadInitialIfNeeded() }
        .alert(AppLang.key("balance.subscription.activate.title", code: selectedLanguageCode, fallback: "Введите ключ"), isPresented: $isActivatePromptPresented) {
            TextField(AppLang.key("balance.subscription.activate.title", code: selectedLanguageCode, fallback: "Введите ключ"), text: $activationCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(AppLang.key("activate", code: selectedLanguageCode, fallback: "Активировать")) {
                let code = activationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                activationCode = ""
                Task { await handleActivate(code: code) }
            }
            Button(AppLang.key("cancel", code: selectedLanguageCode, fallback: "Отмена"), role: .cancel) {
                activationCode = ""
            }
        } message: {
            Text(AppLang.key("balance.subscription.activate.description", code: selectedLanguageCode, fallback: "Ключ можно получить разными способами. Начиная от покупки, заканчивая просто подарком от кого-то."))
        }
        .alert(item: $statusAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private enum SubscriptionTab: String, CaseIterable {
        case benefits
        case history
    }

    private var subscriptionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLang.tr("Подписка Gold", "Gold Subscription", code: selectedLanguageCode))
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Image("SubscriptionLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(height: 110)
                .frame(maxWidth: .infinity)

            Text(subscriptionStatusText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(goldAccent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .ebCardStyle(cornerRadius: 20)
    }

    private var subscriptionTabs: some View {
        Picker("", selection: $selectedTab) {
            Text(AppLang.tr("Преимущества", "Benefits", code: selectedLanguageCode))
                .tag(SubscriptionTab.benefits)
            Text(AppLang.tr("История активаций", "Activation history", code: selectedLanguageCode))
                .tag(SubscriptionTab.history)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 2)
    }

    private var subscriptionContentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedTab == .benefits {
                subscriptionBenefits
            } else {
                subscriptionHistory
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .ebCardStyle(cornerRadius: 18)
    }

    private var subscriptionPurchaseCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { await handlePay() }
            } label: {
                HStack(spacing: 10) {
                    Text(AppLang.tr("Купить за", "Buy for", code: selectedLanguageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    eballPill(text: "0.1")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(goldGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(AppLang.key("activate", code: selectedLanguageCode, fallback: "Активировать")) {
                isActivatePromptPresented = true
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.surface)
            )
        }
        .disabled(viewModel.isGoldActionInFlight)
        .padding(12)
        .ebCardStyle(cornerRadius: 18)
    }

    private var subscriptionHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLang.key("gold_history", code: selectedLanguageCode, fallback: "История активаций"))
                .font(.subheadline.weight(.semibold))

            if viewModel.goldHistory.isEmpty {
                Text(AppLang.key("ups", code: selectedLanguageCode, fallback: "Ой, а тут пусто"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(viewModel.goldHistory) { item in
                    EBalanceSubscriptionStatusRow(
                        status: item.status,
                        activatedText: activationText(for: item),
                        languageCode: selectedLanguageCode
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subscriptionBenefits: some View {
        VStack(spacing: 0) {
            ForEach(subscriptionBenefitItems.indices, id: \.self) { index in
                let item = subscriptionBenefitItems[index]
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(goldAccent)
                    Text(item.body)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)

                if index != subscriptionBenefitItems.count - 1 {
                    Divider()
                        .overlay(AppTheme.divider)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackground)
        )
    }

    private var subscriptionStatusText: String {
        if viewModel.goldStatus {
            return AppLang.tr("Приобретено", "Purchased", code: selectedLanguageCode)
        }
        return AppLang.key("gold_price", code: selectedLanguageCode, fallback: "1 месяц / 0.1 е-балл")
    }

    private var goldAccent: Color {
        Color(red: 242.0 / 255.0, green: 154.0 / 255.0, blue: 46.0 / 255.0)
    }

    private var goldGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 244.0 / 255.0, green: 170.0 / 255.0, blue: 63.0 / 255.0),
                Color(red: 242.0 / 255.0, green: 146.0 / 255.0, blue: 50.0 / 255.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func eballPill(text: String) -> some View {
        HStack(spacing: 6) {
            Text("E")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(AppTheme.primary)
                )
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.92 : 0.98))
        )
    }

    private var cardBackground: Color {
        AppTheme.postCard
    }

    private func activationText(for item: GoldHistoryItem) -> String {
        let locale = Locale(identifier: selectedLanguageCode)
        let dateText = EBalanceDateFormatter.shared.absoluteDate(from: item.date, locale: locale) ?? item.date
        let template = AppLang.key("balance.subscription.activated_on", code: selectedLanguageCode, fallback: "активировано {{date}}")
        return template.replacingOccurrences(of: "{{date}}", with: dateText)
    }

    private func handlePay() async {
        do {
            try await viewModel.payGoldSubscription()
            showStatusAlert(
                title: AppLang.key("success", code: selectedLanguageCode, fallback: "Получилось"),
                message: AppLang.key("balance.subscription.success", code: selectedLanguageCode, fallback: "Подписка активирована")
            )
        } catch {
            showStatusAlert(
                title: AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
                message: error.localizedDescription.isEmpty
                    ? AppLang.key("balance.subscription.error_unknown", code: selectedLanguageCode, fallback: "Точных причин нет")
                    : error.localizedDescription
            )
        }
    }

    private func handleActivate(code: String) async {
        guard !code.isEmpty else { return }
        do {
            try await viewModel.activateGoldSubscription(code: code)
            showStatusAlert(
                title: AppLang.key("success", code: selectedLanguageCode, fallback: "Получилось"),
                message: AppLang.key("balance.subscription.success", code: selectedLanguageCode, fallback: "Подписка активирована")
            )
        } catch {
            showStatusAlert(
                title: AppLang.key("error", code: selectedLanguageCode, fallback: "Ошибка"),
                message: error.localizedDescription.isEmpty
                    ? AppLang.key("balance.subscription.error_unknown", code: selectedLanguageCode, fallback: "Точных причин нет")
                    : error.localizedDescription
            )
        }
    }

    private func showStatusAlert(title: String, message: String) {
        statusAlert = StatusAlert(title: title, message: message)
    }

    private var subscriptionBenefitItems: [BenefitItem] {
        [
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.limits.title", code: selectedLanguageCode, fallback: "Повышенные лимиты"),
                body: AppLang.key("balance.subscription.benefits.limits.body", code: selectedLanguageCode, fallback: "Больше действий: например, увеличенные лимиты на загрузку файлов и не только.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.badge.title", code: selectedLanguageCode, fallback: "Уникальный значок"),
                body: AppLang.key("balance.subscription.benefits.badge.body", code: selectedLanguageCode, fallback: "В профиле появится уникальный значок, и он будет виден в ваших постах.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.ads.title", code: selectedLanguageCode, fallback: "Без рекламы"),
                body: AppLang.key("balance.subscription.benefits.ads.body", code: selectedLanguageCode, fallback: "Для вас будет скрыта вся реклама.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.theme.title", code: selectedLanguageCode, fallback: "Уникальная тема"),
                body: AppLang.key("balance.subscription.benefits.theme.body", code: selectedLanguageCode, fallback: "Дополнительная золотая тема оформления.")
            ),
            BenefitItem(
                title: AppLang.key("balance.subscription.benefits.list.title", code: selectedLanguageCode, fallback: "Особый список"),
                body: AppLang.key("balance.subscription.benefits.list.body", code: selectedLanguageCode, fallback: "Ваш аккаунт будет добавлен в специальный список на главной странице.")
            )
        ]
    }
}

private struct StatusAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct BenefitItem {
    let title: String
    let body: String
}

private struct EBalanceHistoryRow: View {
    let transaction: EBallTransaction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.subheadline.weight(.semibold))

                if let subtitleText {
                    Text(subtitleText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let message = transaction.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Text(amountText)
                        .font(.subheadline.weight(.semibold))
                    EBalanceBadge(size: 18)
                }
                .foregroundStyle(AppTheme.textPrimary)

                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .ebCardStyle(cornerRadius: 16)
    }

    private var leadingIcon: some View {
        Group {
            if transaction.type == "gift_pay" {
                ZStack {
                    Circle()
                        .fill(AppTheme.surfaceElevated)
                        .frame(width: 52, height: 52)

                    if let previewImage = giftPreviewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    } else if let previewURL = giftPreviewURL {
                        AsyncImage(url: previewURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "gift")
                            .foregroundStyle(AppTheme.primary)
                    }

                    HStack(spacing: -8) {
                        EBalanceAvatarView(author: transaction.sender, size: 20)
                        EBalanceAvatarView(author: transaction.giftRecipient, size: 20)
                    }
                    .offset(y: 16)
                }
            } else {
                HStack(spacing: 4) {
                    EBalanceAvatarView(author: transaction.sender, size: 24)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    EBalanceAvatarView(author: transaction.recipient, size: 24)
                }
            }
        }
    }

    private var titleText: String {
        if transaction.type == "gift_pay" {
            return transaction.isIncoming ? "Подарок получен" : "Подарок отправлен"
        }
        let user = transaction.isIncoming
            ? transaction.sender?.username
            : transaction.recipient?.username
        let prefix = transaction.isIncoming ? "Получено от" : "Отправлено"
        return "\(prefix) @\(user ?? "неизвестный")"
    }

    private var subtitleText: String? {
        if transaction.type == "gift_pay" {
            return transaction.gift?.name
        }
        return nil
    }

    private var amountText: String {
        let sign = transaction.isIncoming ? "+" : "-"
        let baseAmount = transaction.amount
        if transaction.isIncoming {
            return String(format: "%@%.3f", sign, baseAmount)
        }
        let total = baseAmount + transaction.fee
        return String(format: "%@%.3f", sign, total)
    }

    private var dateText: String {
        EBalanceDateFormatter.shared.relativeDate(from: transaction.date) ?? ""
    }

    private var giftPreviewURL: URL? {
        EBalanceImageURLBuilder.shared.url(from: transaction.gift?.image?.preview)
    }

    private var giftPreviewImage: UIImage? {
        guard let raw = transaction.gift?.image?.preview else { return nil }
        guard raw.hasPrefix("data:image") else { return nil }
        guard let base64Range = raw.range(of: "base64,") else { return nil }
        let encoded = String(raw[base64Range.upperBound...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return UIImage(data: data)
    }
}

private struct EBalanceSubscriptionStatusRow: View {
    let status: Int
    let activatedText: String
    let languageCode: String

    var body: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(statusBackground)
                )

            Text(activatedText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var statusText: String {
        if status == 1 {
            return AppLang.key("balance.subscription.status.active", code: languageCode, fallback: "Активна")
        }
        return AppLang.key("balance.subscription.status.inactive", code: languageCode, fallback: "Неактивна")
    }

    private var statusForeground: Color {
        status == 1 ? Color.green : Color.secondary
    }

    private var statusBackground: Color {
        status == 1 ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15)
    }
}

private struct EBalanceEarningRow: View {
    let title: String
    let amount: Double
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(AppTheme.surfaceElevated)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: systemImage)
                        .foregroundStyle(AppTheme.primary)
                )

            Text(title)
                .font(.subheadline.weight(.semibold))

            Spacer()

            HStack(spacing: 6) {
                Text(String(format: "%.3f", amount))
                    .font(.subheadline.weight(.semibold))
                EBalanceBadge(size: 18)
            }
        }
    }
}

private struct EBalanceBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.primary)
                .shadow(color: AppTheme.primary.opacity(0.35), radius: 6, x: 0, y: 3)
            Text("E")
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct EBalanceAvatarView: View {
    let author: PostAuthor?
    let size: CGFloat

    @State private var uiImage: UIImage?
    @State private var lastLoadedKey: String?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: avatarLoadKey) {
            await loadAvatarIfNeeded(for: avatarLoadKey)
        }
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(AppTheme.surfaceElevated)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    private var initials: String {
        let source = author?.name ?? author?.username ?? "?"
        return String(source.prefix(1)).uppercased()
    }

    private var avatarLoadKey: String {
        author?.avatarMedia?.imageLoadKey ?? ""
    }

    private func loadAvatarIfNeeded(for key: String) async {
        guard lastLoadedKey != key else { return }
        lastLoadedKey = key
        guard let media = author?.avatarMedia else {
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

struct EBalanceImageURLBuilder {
    static let shared = EBalanceImageURLBuilder()

    func url(path rawPath: String?, file rawFile: String?) -> URL? {
        guard let file = normalized(rawFile) else { return nil }
        let path = normalized(rawPath)?
            .replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        let normalizedFile = file
            .replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        let relative: String
        if normalizedFile.contains("/") {
            relative = normalizedFile
        } else if let path, !path.isEmpty {
            relative = "\(path)/\(normalizedFile)"
        } else {
            relative = normalizedFile
        }
        return URL(string: "https://elemsocial.com/files/\(relative)")
    }

    func url(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("data:") {
            return nil
        }
        guard let value = normalized(trimmed) else { return nil }
        if value.hasPrefix("files/") || value.hasPrefix("/files/") {
            let cleaned = value.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
            return URL(string: "https://elemsocial.com/\(cleaned)")
        }
        return URL(string: "https://elemsocial.com/files/\(value)")
    }

    private func normalized(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: "\\/", with: "/")
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct EBalanceDateFormatter {
    static let shared = EBalanceDateFormatter()

    private let isoFormatter: ISO8601DateFormatter
    private let fallbackFormatter: DateFormatter
    private let relativeFormatter: RelativeDateTimeFormatter

    init() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter = iso

        let fallback = DateFormatter()
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fallbackFormatter = fallback

        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        relativeFormatter = relative
    }

    func relativeDate(from raw: String?) -> String? {
        guard let raw, let date = parse(raw) else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    func parseDate(_ raw: String) -> Date? {
        parse(raw)
    }

    func absoluteDate(from raw: String?, locale: Locale) -> String? {
        guard let raw, let date = parse(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func parse(_ raw: String) -> Date? {
        if let date = isoFormatter.date(from: raw) { return date }
        if let date = fallbackFormatter.date(from: raw) { return date }
        return nil
    }
}

private struct EBalanceCardStyle: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.postCard)
            )
    }
}

private extension View {
    func ebCardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(EBalanceCardStyle(cornerRadius: cornerRadius))
    }
}
