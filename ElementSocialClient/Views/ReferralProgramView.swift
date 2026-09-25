import SwiftUI

/// Web `ReferralProgram.tsx` parity: code + invite link, stats, history.
struct ReferralProgramView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    @State private var dashboard: ReferralDashboard?
    @State private var history: [ReferralHistoryEntry] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var startIndex = 0
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var copiedField: String?

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .padding(.vertical, 40)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button(AppLang.tr("Повторить", "Retry", code: selectedLanguageCode)) {
                        Task { await load() }
                    }
                }
                .padding(.vertical, 30)
            } else if let dashboard {
                dashboardBlock(dashboard)
                historyBlock
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = dashboard == nil
        errorMessage = nil
        do {
            dashboard = try await APIClient.shared.loadReferralDashboard()
            startIndex = 0
            history = try await APIClient.shared.loadReferralHistory(startIndex: 0)
            hasMore = history.count >= 25
            startIndex = history.count
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        do {
            let rows = try await APIClient.shared.loadReferralHistory(startIndex: startIndex)
            history += rows
            startIndex += rows.count
            hasMore = rows.count >= 25
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    // MARK: Dashboard

    private func dashboardBlock(_ dashboard: ReferralDashboard) -> some View {
        VStack(spacing: 12) {
            if let code = dashboard.refCode {
                copyRow(title: AppLang.tr("Код", "Code", code: selectedLanguageCode), value: code, key: "code")
            }
            if let link = dashboard.inviteLink {
                copyRow(title: AppLang.tr("Ссылка", "Link", code: selectedLanguageCode), value: link, key: "link")
            }

            VStack(spacing: 0) {
                statRow(AppLang.tr("Приглашено", "Invited", code: selectedLanguageCode), "\(dashboard.totalInvited)")
                statRow(AppLang.tr("С наградой", "Rewarded", code: selectedLanguageCode), "\(dashboard.rewarded)")
                statRow(AppLang.tr("Ожидают", "Pending", code: selectedLanguageCode), "\(dashboard.pending)")
                statRow(AppLang.tr("Всего заработано", "Total earned", code: selectedLanguageCode), String(format: "E %.3f", dashboard.totalEarned))
            }
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let invitedBy = dashboard.invitedByUsername {
                let isNumeric = invitedBy.allSatisfy { $0.isNumber }
                Text(isNumeric
                     ? String(format: AppLang.tr("Вас пригласил: ID %@", "Invited by: ID %@", code: selectedLanguageCode), invitedBy)
                     : String(format: AppLang.tr("Вас пригласил: @%@", "Invited by: @%@", code: selectedLanguageCode), invitedBy))
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(14)
        .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
    }

    private func copyRow(title: String, value: String, key: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                Text(value)
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = value
                copiedField = key
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedField == key { copiedField = nil }
                }
            } label: {
                Image(systemName: copiedField == key ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(copiedField == key ? Color.green : AppTheme.primary)
            }
        }
        .padding(10)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: History

    @ViewBuilder
    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLang.tr("История приглашений", "Invite history", code: selectedLanguageCode))
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 4)

            if history.isEmpty {
                Text(AppLang.tr("Пока никого не приглашено", "No invites yet", code: selectedLanguageCode))
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(history) { entry in
                    HStack(spacing: 10) {
                        MessengerAvatarView(media: entry.invitedAvatar, name: entry.invitedName ?? "?", size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.invitedUsername.map { "@\($0)" } ?? (entry.invitedName ?? "ID \(entry.id)"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.textPrimary)
                                .lineLimit(1)
                            Text(referralStatusLabel(entry.status))
                                .font(.caption2)
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        if let reward = entry.rewardAmount {
                            Text(String(format: "E %.3f", reward))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.primary)
                        }
                    }
                    .padding(10)
                    .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if hasMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Group {
                            if isLoadingMore {
                                ProgressView()
                            } else {
                                Text(AppLang.key("search_show_more", code: selectedLanguageCode, fallback: AppLang.tr("Показать ещё", "Show more", code: selectedLanguageCode)))
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.primary)
                }
            }
        }
    }

    private func referralStatusLabel(_ status: String) -> String {
        switch status {
        case "rewarded": return AppLang.tr("Награждён", "Rewarded", code: selectedLanguageCode)
        case "pending_email": return AppLang.tr("Ожидает email", "Awaiting email", code: selectedLanguageCode)
        case "pending_activity": return AppLang.tr("Ожидает активности", "Awaiting activity", code: selectedLanguageCode)
        case "rejected": return AppLang.tr("Отклонён", "Rejected", code: selectedLanguageCode)
        default: return status
        }
    }
}
