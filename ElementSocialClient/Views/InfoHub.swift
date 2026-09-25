import SwiftUI

/// Info hub — web `/info` routes parity: Rules (static), Updates (Updates.json).
struct InfoHubView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    var body: some View {
        List {
            NavigationLink {
                InfoRulesView()
            } label: {
                Label(AppLang.tr("Правила", "Rules", code: selectedLanguageCode), systemImage: "checkmark.shield.fill")
                    .foregroundStyle(AppTheme.primary)
            }
            NavigationLink {
                InfoUpdatesView()
            } label: {
                Label(AppLang.tr("Обновления", "Updates", code: selectedLanguageCode), systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(AppTheme.primary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLang.tr("Информация", "Info", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Web `/info/rules` — community rules & privacy summary.
struct InfoRulesView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    private let sections: [(title: String, items: [String])] = [
        ("Общие положения", [
            "Регистрируясь в Element, вы соглашаетесь с настоящими правилами.",
            "Незнание правил не освобождает от ответственности.",
            "Администрация оставляет за собой право изменять правила; актуальная версия всегда доступна на сайте.",
        ]),
        ("Контент и поведение", [
            "Запрещён спам, флуд и реклама без согласия администрации.",
            "Запрещены оскорбления, травля (буллинг) и разжигание ненависти.",
            "Запрещена публикация контента 18+ вне отведённых для этого мест, шок-контента и призывов к насилию.",
            "Запрещены распространение наркотиков, мошенничество и экстремизм в любой форме.",
            "Уважайте частную жизнь других пользователей: не публикуйте персональные данные без согласия.",
        ]),
        ("Аккаунты", [
            "Один пользователь может владеть несколькими аккаунтами, если они не используются для обхода ограничений.",
            "Передача аккаунта третьим лицам не освобождает от ответственности за его действия.",
            "Использование уязвимостей сайта и сторонних скриптов накрутки запрещено.",
        ]),
        ("Модерация и наказания", [
            "Модерация вправе выдать предупреждение, ограничить (мут/бан) или удалить контент при нарушении правил.",
            "Вы можете подать апелляцию в разделе «Настройки → Мои апелляции».",
            "Сроки ограничений зависят от тяжести и повторности нарушений.",
        ]),
        ("Конфиденциальность", [
            "Мы храним минимально необходимый объём данных (email, контент, служебные логи сессий).",
            "Пароли хранятся в виде хэша; переписка в мессенджере защищена сквозным шифрованием по ключевой фразе.",
            "Вы можете запросить экспорт или удаление аккаунта в настройках.",
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(AppLang.tr("Правила сообщества", "Community rules", code: selectedLanguageCode))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)

                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppTheme.primary)
                        ForEach(section.items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(AppTheme.textSecondary)
                                Text(item)
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
                }
            }
            .padding(14)
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.tr("Правила", "Rules", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Web `/info/updates` — renders the bundled Updates.json (same file as web).
struct InfoUpdatesView: View {
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"

    private struct UpdateSection: Decodable {
        let title: String
        let changes: [String]
    }

    private struct UpdateEntry: Decodable {
        let type: String
        let version: String
        let date: String
        let content: [UpdateSection]?
    }

    @State private var entries: [UpdateEntry] = []

    var body: some View {
        Group {
            if entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            updateCard(entry)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(AppLang.tr("Обновления", "Updates", code: selectedLanguageCode))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private func load() {
        guard entries.isEmpty,
              let url = Bundle.main.url(forResource: "Updates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([UpdateEntry].self, from: data) else { return }
        entries = decoded
    }

    private func updateCard(_ entry: UpdateEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(entry.type == "beta" ? "Beta" : AppLang.tr("Обновление", "Update", code: selectedLanguageCode)) \(entry.version)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(formattedDate(entry.date))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            ForEach(entry.content ?? [], id: \.title) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.primary)
                    ForEach(section.changes, id: \.self) { change in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                            Text(change).font(.caption).foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
    }

    private func formattedDate(_ raw: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: raw) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "d MMMM yyyy"
            return formatter.string(from: date)
        }
        return raw
    }
}
