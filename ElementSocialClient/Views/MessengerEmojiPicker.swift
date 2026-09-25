import SwiftUI

/// Emoji picker backed by the bundled Apple emoji catalog (`Emoji.json`,
/// same source the site's EmojiPicker uses).
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    private struct EmojiCategory {
        let title: String
        let emojis: [String]
    }

    @State private var categories: [EmojiCategory] = []

    var body: some View {
        NavigationStack {
            Group {
                if categories.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                                Section(category.title) {
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 6) {
                                        ForEach(category.emojis, id: \.self) { emoji in
                                            Button {
                                                onPick(emoji)
                                            } label: {
                                                if let img = EmojiHelper.shared.image(for: emoji, pointSize: 28) {
                                                    Image(uiImage: img)
                                                        .resizable()
                                                        .frame(width: 28, height: 28)
                                                } else {
                                                    Text(emoji).font(.system(size: 24))
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .id(emoji)
                                        }
                                    }
                                }
                                .id("cat-\(index)")
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle(AppLang.tr("Эмодзи", "Emoji", code: selectedLanguageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLang.tr("Закрыть", "Close", code: selectedLanguageCode)) { dismiss() }
                }
            }
            .onAppear { loadCatalog() }
        }
    }

    private func loadCatalog() {
        guard categories.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "Emoji", withExtension: "json")
            ?? Bundle.main.url(forResource: "Emoji", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        let titles: [String: String] = [
            "smileys": "Смайлы",
            "people": "Люди",
            "animals": "Животные",
            "food": "Еда",
            "activities": "Активности",
            "travel": "Путешествия",
            "objects": "Объекты",
            "symbols": "Символы",
            "flags": "Флаги"
        ]

        var result: [EmojiCategory] = []
        for categoryMap in json {
            for (rawTitle, subList) in categoryMap {
                guard let items = subList as? [[String: Any]] else { continue }
                var emojis: [String] = []
                for item in items {
                    if let emoji = item["emoji"] as? String {
                        emojis.append(emoji)
                    }
                }
                guard !emojis.isEmpty else { continue }
                let title = titles[rawTitle.lowercased()] ?? rawTitle.capitalized
                result.append(EmojiCategory(title: title, emojis: emojis))
            }
        }
        categories = result
    }
}
