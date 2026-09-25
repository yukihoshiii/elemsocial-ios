import SwiftUI

// MARK: - Call event card (web CallEventCard)

/// Message type `call` — the decrypted payload carries
/// `call: {call_type, missed, is_group, duration}`. The server keeps the raw
/// JSON in `decrypted.call`, which our parser stores inside `fileName`/`text`
/// fallbacks; we render from a best-effort reconstruction.
struct CallEventCard: View {
    let decrypted: MessengerMessageContent?

    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isMissed ? Color.red : AppTheme.primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill((isMissed ? Color.red : AppTheme.primary).opacity(0.14)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                    if isGroup {
                        badge("Группа")
                    }
                    if isVideo {
                        badge("Видео")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.surface.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isMissed ? Color.red.opacity(0.35) : AppTheme.cardStroke, lineWidth: 1)
        )
    }

    private var callInfo: (missed: Bool, video: Bool, group: Bool, duration: Double) {
        if let info = decrypted?.call {
            return (info.isMissed, info.isVideo, info.isGroup, info.duration)
        }
        return (false, false, false, 0)
    }

    private var isMissed: Bool { callInfo.missed }
    private var isVideo: Bool { callInfo.video }
    private var isGroup: Bool { callInfo.group }

    private var iconName: String {
        if isMissed { return "phone.down.fill" }
        return isVideo ? "video.fill" : "phone.fill"
    }

    private var title: String {
        let isEnglish = selectedLanguageCode == "en"
        if isMissed {
            return isGroup ? (isEnglish ? "Missed group call" : "Пропущенный групповой звонок")
                           : (isEnglish ? "Missed call" : "Пропущенный звонок")
        }
        if isVideo {
            return isGroup ? (isEnglish ? "Group video call" : "Групповой видеозвонок")
                           : (isEnglish ? "Video call" : "Видеозвонок")
        }
        return isGroup ? (isEnglish ? "Group audio call" : "Групповой аудиозвонок")
                       : (isEnglish ? "Audio call" : "Аудиозвонок")
    }

    private var subtitle: String {
        let isEnglish = selectedLanguageCode == "en"
        let duration = callInfo.duration
        if isMissed {
            return isEnglish ? "No answer" : "Без ответа"
        }
        guard duration > 0 else {
            return isEnglish ? "—" : "—"
        }
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(AppTheme.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(AppTheme.primary.opacity(0.12)))
    }
}
