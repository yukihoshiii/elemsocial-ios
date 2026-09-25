import SwiftUI

/// Feed banner «Обновление {версия}» — web `Update.tsx` parity:
/// collapsible sections, hide button, toggle in advanced settings.
struct AppUpdateBanner: View {
    @AppStorage("show_new_update") private var isVisible: Bool = true
    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    @State private var isExpanded = false

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(AppTheme.primary)
                    Text(isEnglish ? "What's new" : "Обновление")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            AppChangelog.isBannerVisible = false
                            isVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.textSecondary)
                            .frame(width: 26, height: 26)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(AppChangelog.sections.enumerated()), id: \.offset) { index, section in
                        if isExpanded || index == 0 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(AppTheme.primary)
                                ForEach(section.changes, id: \.self) { change in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•")
                                        Text(change)
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded
                         ? AppLang.tr("Свернуть", "Collapse", code: selectedLanguageCode)
                         : AppLang.tr("Показать больше", "Show more", code: selectedLanguageCode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                }
            }
            .padding(14)
            .background(AppTheme.postCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}
