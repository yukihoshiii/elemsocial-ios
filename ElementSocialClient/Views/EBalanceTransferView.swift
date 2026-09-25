import SwiftUI

struct EBalanceTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recipientInput: String = ""
    @State private var amountInput: String = ""
    @State private var messageInput: String = ""
    @State private var users: [PostAuthor] = []
    @State private var selectedUser: PostAuthor?
    @State private var isSearching = false
    @State private var isSending = false
    @State private var isCompleted = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    let availableBalance: Double
    let availableBalanceText: String
    let onBalanceUpdate: (Double) -> Void
    let onTransferCompleted: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerImage

                if isCompleted {
                    completedCard
                } else {
                    availableBalanceCard
                    formCard
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Перевод")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: recipientInput) { _ in
            guard selectedUser == nil else { return }
            scheduleSearch()
        }
    }

    private var headerImage: some View {
        Image("EBalanceTransferHero")
            .resizable()
            .scaledToFit()
        .frame(maxWidth: 260)
        .padding(.vertical, 8)
    }

    private var availableBalanceCard: some View {
        HStack(spacing: 12) {
            Text("Доступные E-Баллы для перевода")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            Spacer()

            HStack(spacing: 6) {
                Text(availableBalanceText)
                    .font(.subheadline.weight(.semibold))
                EBalanceTransferBadge(size: 20)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.surfaceElevated)
            )
        }
        .padding(14)
        .transferCardStyle(cornerRadius: 16)
    }

    private var formCard: some View {
        VStack(spacing: 12) {
            if let selectedUser {
                selectedUserRow(selectedUser)
            } else {
                TextField("Получатель (@username)", text: $recipientInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(12)
                    .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if !recipientInput.isEmpty && !recipientInput.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") {
                    Text("Ник должен начинаться с @")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isSearching {
                    ProgressView()
                        .padding(.vertical, 4)
                } else if !users.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(users, id: \.username) { user in
                            Button {
                                selectUser(user)
                            } label: {
                                userRow(user)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            TextField("Сумма перевода", text: $amountInput)
                .keyboardType(.decimalPad)
                .padding(12)
                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if shouldShowDetails {
                transferDetails
            }

            TextField("Сообщение (по желанию)", text: $messageInput, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .padding(12)
                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await sendTransfer() }
            } label: {
                Text(isSending ? "Отправляем..." : "Отправить")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSend ? AppTheme.primarySoft : AppTheme.surfaceElevated)
                    )
                    .foregroundStyle(canSend ? .white : AppTheme.textSecondary)
            }
            .disabled(!canSend || isSending)
            .buttonStyle(.plain)
        }
        .padding(16)
        .transferCardStyle(cornerRadius: 18)
    }

    private var completedCard: some View {
        VStack(spacing: 12) {
            Text("Перевод отправлен")
                .font(.title3.weight(.bold))
            Text("Данные обновятся в истории")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Готово") {
                dismiss()
            }
            .font(.headline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.primarySoft)
            )
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(18)
        .transferCardStyle(cornerRadius: 18)
    }

    private func selectedUserRow(_ user: PostAuthor) -> some View {
        HStack(spacing: 10) {
            TransferAvatarView(author: user, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name ?? user.username ?? "")
                    .font(.subheadline.weight(.semibold))
                if let username = user.username {
                    Text("@\(username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                selectedUser = nil
                recipientInput = ""
                users = []
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func userRow(_ user: PostAuthor) -> some View {
        HStack(spacing: 10) {
            TransferAvatarView(author: user, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name ?? user.username ?? "")
                    .font(.subheadline.weight(.semibold))
                if let username = user.username {
                    Text("@\(username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var transferDetails: some View {
        VStack(spacing: 6) {
            detailRow(title: "Сумма перевода", value: amountNumber, highlight: false)
            detailRow(title: "Комиссия (10%)", value: fee, highlight: false)
            detailRow(title: "После перевода", value: balanceAfter, highlight: balanceAfter < 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(12)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailRow(title: String, value: Double, highlight: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 4) {
                Text(String(format: "%.3f", value))
                    .foregroundStyle(highlight ? .red : AppTheme.textPrimary)
                EBalanceTransferBadge(size: 16)
            }
        }
    }

    private var recipientQuery: String {
        let trimmed = recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else { return "" }
        return String(trimmed.dropFirst())
    }

    private var amountNumber: Double {
        let normalized = amountInput.replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0
    }

    private var fee: Double {
        amountNumber * 0.1
    }

    private var balanceAfter: Double {
        availableBalance - (amountNumber + fee)
    }

    private var shouldShowDetails: Bool {
        selectedUser != nil && amountNumber > 0
    }

    private var canSend: Bool {
        selectedUser != nil && amountNumber > 0 && balanceAfter >= 0
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = recipientQuery
        guard !query.isEmpty else {
            users = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await performSearch(query)
        }
    }

    @MainActor
    private func performSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }

        do {
            users = try await APIClient.shared.searchUsers(query: query)
        } catch {
            users = []
        }
    }

    private func selectUser(_ user: PostAuthor) {
        selectedUser = user
        recipientInput = "@\(user.username ?? "")"
        users = []
    }

    @MainActor
    private func sendTransfer() async {
        errorMessage = nil
        guard let selectedUser, let recipientID = selectedUser.id else { return }
        guard canSend else { return }

        isSending = true
        defer { isSending = false }

        do {
            try await APIClient.shared.sendEBall(recipientID: recipientID, amount: amountNumber, message: messageInput)
            let newBalance = max(0, balanceAfter)
            APIClient.shared.updateCurrentUserEBalls(newBalance)
            onBalanceUpdate(newBalance)
            onTransferCompleted()
            isCompleted = true
        } catch {
            errorMessage = (error as? APIError)?.localizedDescription ?? "Не удалось отправить перевод"
        }
    }
}

private struct EBalanceTransferBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.primary)
                .shadow(color: AppTheme.primary.opacity(0.35), radius: 4, x: 0, y: 2)
            Text("E")
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct TransferAvatarView: View {
    let author: PostAuthor?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = avatarURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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

    private var avatarURL: URL? {
        guard let avatar = author?.avatar else { return nil }
        let file = avatar.simple ?? avatar.file
        return EBalanceImageURLBuilder.shared.url(path: avatar.path, file: file)
    }
}

private struct EBalanceTransferCardStyle: ViewModifier {
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
    func transferCardStyle(cornerRadius: CGFloat = 16) -> some View {
        modifier(EBalanceTransferCardStyle(cornerRadius: cornerRadius))
    }
}
