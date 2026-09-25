import SwiftUI

/// Web `JoinGroup.tsx` parity: paste a `/join/:code` link or bare code,
/// preview the group, confirm, land in the chat.
struct JoinGroupSheet: View {
    @ObservedObject var viewModel: MessengerViewModel
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    @State private var linkInput = ""

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                switch viewModel.joinGroupState {
                case .none:
                    inputForm
                case .loading:
                    ProgressView(AppLang.tr("Загружаем группу...", "Loading group...", code: selectedLanguageCode))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .preview(let group):
                    previewBlock(group)
                case .joined(let target):
                    joinedBlock(target)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(AppLang.tr("Вступить в группу", "Join group", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) { dismiss() }
                }
            }
        }
    }

    // MARK: Step 1 — input

    private var inputForm: some View {
        VStack(spacing: 14) {
            Image(systemName: "link")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.primary)
                .padding(.top, 20)

            Text(isEnglish
                 ? "Paste an invite link (elemsocial.com/join/…) or just the code."
                 : "Вставьте ссылку-приглашение (elemsocial.com/join/…) или только код.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)

            TextField("elemsocial.com/join/…", text: $linkInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(14)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
                .onSubmit { submit() }

            Button {
                submit()
            } label: {
                Text(AppLang.tr("Найти группу", "Find group", code: selectedLanguageCode))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(linkInput.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()
        }
    }

    private func submit() {
        viewModel.beginJoinGroup(rawInput: linkInput)
    }

    // MARK: Step 2 — preview

    private func previewBlock(_ group: MessengerActiveChat) -> some View {
        VStack(spacing: 16) {
            MessengerAvatarView(media: group.avatar, name: group.name, size: 88)
                .padding(.top, 24)

            Text(group.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)

            if let members = group.membersCount {
                Text("\(members) \(membersLabel(members))")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            if let description = group.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }

            Button {
                Task { await viewModel.confirmJoinGroup() }
            } label: {
                Group {
                    if viewModel.isJoiningGroup {
                        ProgressView().tint(.white)
                    } else {
                        Text(AppLang.key("join", code: selectedLanguageCode, fallback: isEnglish ? "Join" : "Вступить"))
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(viewModel.isJoiningGroup)

            Button(AppLang.tr("Отмена", "Cancel", code: selectedLanguageCode)) {
                viewModel.joinGroupState = nil
                linkInput = ""
            }
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)

            Spacer()
        }
    }

    // MARK: Step 3 — joined

    private func joinedBlock(_ target: MessengerChatTarget) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .padding(.top, 40)

            Text(isEnglish ? "You joined the group" : "Вы вступили в группу")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)

            Button {
                if let target = viewModel.finishJoinGroup() {
                    dismiss()
                    Task { await openChat(target: target) }
                }
            } label: {
                Text(AppLang.tr("Открыть чат", "Open chat", code: selectedLanguageCode))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(AppLang.tr("Позже", "Later", code: selectedLanguageCode)) {
                _ = viewModel.finishJoinGroup()
                dismiss()
            }
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)

            Spacer()
        }
    }

    private func openChat(target: MessengerChatTarget) async {
        if let summary = viewModel.chats.first(where: { $0.target == target }) {
            await viewModel.openChat(summary)
        }
    }

    private func membersLabel(_ n: Int) -> String {
        if isEnglish { return n == 1 ? "member" : "members" }
        let mod100 = n % 100
        let mod10 = n % 10
        if mod100 > 10 && mod100 < 20 { return "участников" }
        if mod10 > 1 && mod10 < 5 { return "участника" }
        if mod10 == 1 { return "участник" }
        return "участников"
    }
}
