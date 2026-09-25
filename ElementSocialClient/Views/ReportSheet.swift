import SwiftUI

struct ReportContext: Identifiable {
    let id = UUID()
    let targetType: ReportTargetType
    let targetId: Int
    let title: String
    let subtitle: String?
    let text: String?
}

enum ReportTargetType: String {
    case post
    case comment
    case user
    case channel
    case music
}

struct ReportSheet: View {
    let context: ReportContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedReason: ReportReason?
    @State private var comment: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var suppressKeyboardDismiss = false

    private var reasons: [ReportReason] {
        switch context.targetType {
        case .music:
            return [
                ReportReason(key: "nonsense", title: "Бессмыслица"),
                ReportReason(key: "other", title: "Другое")
            ]
        default:
            return [
                ReportReason(key: "spam", title: "Спам"),
                ReportReason(key: "animal_cruelty", title: "Жестокое обращение с животными"),
                ReportReason(key: "child_porn", title: "Детская порнография"),
                ReportReason(key: "weapon_sales", title: "Продажа оружия"),
                ReportReason(key: "drug_sales", title: "Продажа наркотиков"),
                ReportReason(key: "personal_data_without_consent", title: "Личные данные без согласия"),
                ReportReason(key: "other", title: "Другое")
            ]
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ReportTargetPreview(context: context)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if selectedReason == nil {
                    reasonSelection
                } else if let chosenReason = selectedReason {
                    Section {
                        commentForm(for: chosenReason)
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentShape(Rectangle())
            .onTapGesture {
                dismissKeyboardIfAllowed()
            }
            .navigationTitle("Пожаловаться")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Назад") { dismiss() }
                }
            }
        }
        .alert("Сообщение", isPresented: Binding(
            get: { infoMessage != nil || errorMessage != nil },
            set: { newValue in
                if !newValue {
                    infoMessage = nil
                    errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                infoMessage = nil
                errorMessage = nil
            }
        } message: {
            Text(infoMessage ?? errorMessage ?? "")
        }
        .onChange(of: comment) { newValue in
            if newValue.count > 500 {
                comment = String(newValue.prefix(500))
            }
        }
    }

    private var reasonSelection: some View {
        Section {
            ForEach(reasons) { reason in
                Button {
                    selectedReason = reason
                } label: {
                    Text(reason.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Что именно вам кажется недопустимым в этом материале?")
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func commentForm(for reason: ReportReason) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Жалоба: \(reason.title)")
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)

            Text(reason.key == "other"
                 ? "Опишите проблему подробнее (обязательно):"
                 : "Дополнительное описание проблемы (необязательно):")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)

            TextEditor(text: $comment)
                .frame(minHeight: 96)
                .padding(10)
                .scrollContentBackground(.hidden)
                .highPriorityGesture(
                    TapGesture().onEnded {
                        suppressKeyboardDismiss = true
                    }
                )
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(cardStroke, lineWidth: 1)
                )

            Text("\(comment.count)/500 символов")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            HStack(spacing: 10) {
                Button("Назад") {
                    selectedReason = nil
                    comment = ""
                }
                .buttonStyle(.bordered)

                Button("Отправить") {
                    Task { await sendReport() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
        }
        .listRowBackground(colorScheme == .dark ? Color.clear : Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.clear
            }
            return UIColor(red: 242.0 / 255.0, green: 241.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0)
        }))
    }

    private var canSend: Bool {
        guard let selectedReason else { return false }
        if selectedReason.key == "other" {
            return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
        }
        return !isSubmitting
    }

    private func dismissKeyboardIfAllowed() {
        if suppressKeyboardDismiss {
            suppressKeyboardDismiss = false
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func sendReport() async {
        guard let chosenReason = selectedReason, !isSubmitting else { return }
        isSubmitting = true
        do {
            try await APIClient.shared.sendReport(
                targetType: context.targetType.rawValue,
                targetId: context.targetId,
                category: chosenReason.key,
                message: comment
            )
            infoMessage = "Жалоба отправлена"
            selectedReason = nil
            comment = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color(red: 0.059, green: 0.059, blue: 0.059)
        }
        return Color(red: 242.0 / 255.0, green: 241.0 / 255.0, blue: 246.0 / 255.0)
    }

    private var cardStroke: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.09)
        }
        return Color.white.opacity(0.9)
    }
}

private struct ReportReason: Identifiable {
    let id = UUID()
    let key: String
    let title: String
}

private struct ReportTargetPreview: View {
    let context: ReportContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            if let subtitle = context.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            if let text = context.text, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(AppTheme.textPrimary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color(red: 0.059, green: 0.059, blue: 0.059)
        }
        return Color(red: 242.0 / 255.0, green: 241.0 / 255.0, blue: 246.0 / 255.0)
    }

    private var cardStroke: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.09)
        }
        return Color.white.opacity(0.9)
    }
}
