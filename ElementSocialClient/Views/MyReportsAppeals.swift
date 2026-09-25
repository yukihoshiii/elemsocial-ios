import SwiftUI

/// Web `MyReports.tsx` — list of the user's moderation reports.
struct MyReportsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var reports: [MyReportItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

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
            } else if reports.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(AppLang.tr("Вы не подавали жалоб", "You haven't filed any reports", code: selectedLanguageCode))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        Text(String(format: AppLang.tr("Ваши жалобы (%d)", "Your reports (%d)", code: selectedLanguageCode), reports.count))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(reports) { report in
                            reportCard(report)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.tr("Мои жалобы", "My reports", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = reports.isEmpty
        errorMessage = nil
        do {
            reports = try await APIClient.shared.loadMyReports()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func reportCard(_ report: MyReportItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(report.categoryLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(report.statusLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(report.statusColor))
            }

            if let target = report.targetText, !target.isEmpty {
                Text(target.count > 100 ? String(target.prefix(100)) + "…" : target)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(3)
            }
            if let username = report.targetUsername {
                Text("@\(username)")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.primary)
            }

            if let resolution = report.resolution, !resolution.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLang.tr("Решение модератора", "Moderator resolution", code: selectedLanguageCode))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(resolution)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textPrimary)
                    if let moderator = report.moderatorName {
                        Text("— \(moderator)")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
    }
}

private extension MyReportItem {
    var statusColor: Color {
        let rgb = statusColorRGB
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// Web `MyAppealsListModal` + `SubmitAppealModal` — list + submit form.
struct MyAppealsView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var appeals: [MyAppealItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var isSubmitPresented = false
    @State private var submitRestriction = "posts"
    @State private var submitReason = ""
    @State private var isSubmitting = false

    private let restrictions: [(id: String, label: String)] = [
        ("posts", "Публикация постов"),
        ("comments", "Комментирование"),
        ("chat", "Чаты"),
        ("music", "Музыка")
    ]

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
                            isSubmitPresented = true
                        } label: {
                            Label(AppLang.tr("Подать апелляцию", "Submit an appeal", code: selectedLanguageCode),
                                  systemImage: "paperplane.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        ForEach(appeals) { appeal in
                            appealCard(appeal)
                        }

                        if appeals.isEmpty {
                            Text(AppLang.tr("Апелляций пока нет", "No appeals yet", code: selectedLanguageCode))
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
        .navigationTitle(AppLang.tr("Мои апелляции", "My appeals", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $isSubmitPresented) {
            submitSheet
        }
    }

    private func load() async {
        isLoading = appeals.isEmpty
        errorMessage = nil
        do {
            appeals = try await APIClient.shared.loadMyAppeals()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func appealCard(_ appeal: MyAppealItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(appeal.restrictionLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(appeal.statusLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(appeal.status == "approved" ? .green : (appeal.status == "rejected" ? .red : .orange))
            }
            Text(appeal.reason)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(4)
            if let response = appeal.response, !response.isEmpty {
                Text(AppLang.tr("Ответ:", "Response:", code: selectedLanguageCode) + " \(response)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
    }

    private var submitSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker(AppLang.tr("Ограничение", "Restriction", code: selectedLanguageCode), selection: $submitRestriction) {
                    ForEach(restrictions, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $submitReason)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 120)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))

                HStack {
                    Spacer()
                    Text("\(submitReason.count)/2000")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .maxLength(2000, text: $submitReason)

                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text(AppLang.tr("Отправить", "Submit", code: selectedLanguageCode)).font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(submitReason.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)

                Spacer()
            }
            .padding(18)
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(AppLang.tr("Новая апелляция", "New appeal", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) { isSubmitPresented = false }
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            // Web gate: block a second appeal for the same restriction.
            if try await APIClient.shared.checkExistingAppeal(restrictionType: submitRestriction) {
                errorMessage = AppLang.tr(
                    "Апелляция по этому ограничению уже подана",
                    "An appeal for this restriction already exists",
                    code: selectedLanguageCode
                )
                return
            }
            try await APIClient.shared.submitAppeal(restrictionType: submitRestriction, reason: submitReason.trimmingCharacters(in: .whitespaces))
            isSubmitPresented = false
            submitReason = ""
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
