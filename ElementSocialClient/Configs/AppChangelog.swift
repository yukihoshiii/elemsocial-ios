import Foundation

/// Changelog shown in the feed banner — mirrors the web client's
/// `BaseConfig.update` (Configs/Base.jsx) + `Update.tsx` banner.
enum AppChangelog {
    struct Section {
        let title: String
        let changes: [String]
    }

    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    /// iOS-client changelog (kept in sync with the ported feature set).
    static let sections: [Section] = [
        Section(
            title: "Мессенджер",
            changes: [
                "Голосовые сообщения и видеокружки.",
                "Реакции, ответы и редактирование сообщений.",
                "Поиск по чату с переходом к сообщению.",
                "Группы: создание, участники, ссылки-приглашения.",
                "Индикаторы «печатает» и «записывает».",
                "Галочки прочтения и разделители дат.",
            ]
        ),
        Section(
            title: "Общие изменения",
            changes: [
                "Полноценная регистрация с капчей и подтверждением почты.",
                "Переключение между аккаунтами.",
                "Редактирование постов вместе с вложениями.",
                "Локальные уведомления о сообщениях и событиях.",
                "Чанковый кэш медиа с проверкой SHA-256.",
            ]
        ),
    ]

    // MARK: - Visibility flag (web: settingsStore.showNewUpdate)

    private static let flagKey = "show_new_update"

    static var isBannerVisible: Bool {
        get { UserDefaults.standard.object(forKey: flagKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: flagKey) }
    }
}
