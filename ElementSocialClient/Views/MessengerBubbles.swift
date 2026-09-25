import SwiftUI
import AVFoundation

/// Quick reactions — same set as the web `QUICK_REACTIONS`.
let messengerQuickReactions: [(emoji: String, unified: String)] = [
    ("❤️", "2764-FE0F"),
    ("👍", "1F44D"),
    ("👎", "1F44E"),
    ("🔥", "1F525"),
    ("😂", "1F602"),
    ("😮", "1F62E"),
    ("😢", "1F622"),
    ("🎉", "1F389")
]

// MARK: - Row

struct MessageRow: View {
    let message: MessengerMessage
    let hasTail: Bool
    let showAvatar: Bool
    let isGroupChat: Bool
    @ObservedObject var viewModel: MessengerViewModel
    let highlightMid: Int?
    let onLongPress: () -> Void

    @AppStorage("app_language") private var selectedLanguageCode = "RU"
    @Environment(\.colorScheme) private var colorScheme

    private var isEnglish: Bool { selectedLanguageCode == "en" }

    private var isMine: Bool { message.isOutgoing }
    /// In groups everything is left-aligned; in DMs own messages go right.
    private var rightAligned: Bool { !isGroupChat && isMine }
    private var type: String { message.content?.type ?? "text" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isGroupChat {
                avatarSlot
            }

            if rightAligned {
                Spacer(minLength: 40)
            }

            bubble

            if !rightAligned && !isGroupChat {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: isGroupChat ? .leading : (rightAligned ? .trailing : .leading))
    }

    @ViewBuilder
    private var avatarSlot: some View {
        ZStack {
            if isMine {
                MessengerAvatarView(media: APIClient.shared.currentUserAvatarSnapshotMedia(), name: "Вы", size: 30)
                    .opacity(showAvatar ? 1 : 0)
            } else {
                MessengerAvatarView(
                    media: message.author?.avatar,
                    name: message.author?.name ?? "",
                    size: 30
                )
                .opacity(showAvatar ? 1 : 0)
            }
        }
        .frame(width: 30)
    }

    private var bubbleBackground: Color {
        if isMine && !isGroupChat { return AppTheme.primary }
        return colorScheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color.white
    }

    private var bubbleForeground: Color {
        isMine && !isGroupChat ? .white : AppTheme.textPrimary
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            replyBlock

            if isGroupChat {
                Text(isMine ? "Вы" : (message.author?.name ?? ""))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.primary)
            }

            attachmentView

            if type != "video" && type != "call" {
                textAndStatusRow
            } else if type == "video" && !(message.content?.isVideoCircle ?? false) {
                // plain video file keeps the caption visible
                textAndStatusRow
            }

            reactionBar
        }
        .padding(.horizontal, contentInsets.horizontal)
        .padding(.vertical, contentInsets.vertical)
        .background(
            RoundedRectangle(cornerRadius: hasTail ? 16 : 10, style: .continuous)
                .fill(bubbleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: hasTail ? 16 : 10, style: .continuous)
                .stroke(isMine && !isGroupChat ? Color.clear : AppTheme.cardStroke, lineWidth: 1)
        )
        .overlay {
            if let highlightMid, message.mid == highlightMid {
                RoundedRectangle(cornerRadius: hasTail ? 16 : 10, style: .continuous)
                    .stroke(AppTheme.primary, lineWidth: 2)
                    .background(AppTheme.primary.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: hasTail ? 16 : 10, style: .continuous)))
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress()
        }
    }

    private var contentInsets: (horizontal: CGFloat, vertical: CGFloat) {
        switch type {
        case "image": return (4, 4)
        case "video" where message.content?.isVideoCircle == true: return (6, 6)
        default: return (12, 8)
        }
    }

    // MARK: Reply block

    @ViewBuilder
    private var replyBlock: some View {
        if let replyTo = message.content?.replyTo {
            Button {
                if let mid = replyTo.mid {
                    Task { await viewModel.jumpToMessage(mid: mid, startIndex: nil) }
                }
            } label: {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bubbleForeground.opacity(0.55))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(replyTo.author ?? "")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.primary)
                        HStack(spacing: 3) {
                            if replyTo.type == "voice" {
                                Image(systemName: "mic.fill").font(.system(size: 9))
                                replyText(AppLang.tr("Голосовое сообщение", "Voice message", code: selectedLanguageCode))
                            } else if replyTo.type == "video" {
                                Image(systemName: "video.fill").font(.system(size: 9))
                                replyText(AppLang.tr("Видео сообщение", "Video message", code: selectedLanguageCode))
                            } else if replyTo.type == "image" {
                                Image(systemName: "photo.fill").font(.system(size: 9))
                                replyText(AppLang.tr("Фото", "Image", code: selectedLanguageCode))
                            } else {
                                Text(replyTo.text ?? "")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(bubbleForeground.opacity(0.75))
                        .lineLimit(1)
                    }
                    .padding(.leading, 7)
                    Spacer(minLength: 0)
                }                .padding(5)
                .background(Color.black.opacity(0.07))
                .cornerRadius(7)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Attachments dispatch

    private var replyTo: MessengerReplyTo? { message.content?.replyTo }

    private func replyText(_ fallback: String) -> Text {
        let text = replyTo?.text ?? ""
        return Text(text.isEmpty ? fallback : text)
    }

    @ViewBuilder
    private var attachmentView: some View {
        switch type {
        case "image":
            MessageImageAttachment(message: message, viewModel: viewModel)
        case "file":
            MessageFileAttachment(message: message, viewModel: viewModel)
        case "voice":
            MessageVoiceAttachment(message: message, viewModel: viewModel)
        case "video":
            if message.content?.isVideoCircle == true {
                MessageVideoCircleAttachment(message: message, viewModel: viewModel, timeText: messengerMessageTime(message.date))
            } else {
                MessageFileAttachment(message: message, viewModel: viewModel, videoFallback: true)
            }
        case "call":
            CallEventCard(decrypted: message.content)
        default:
            EmptyView()
        }
    }

    // MARK: Text + status row

    private var textAndStatusRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if let content = message.content, !content.text.isEmpty {
                Text(content.text)
                    .font(.subheadline)
                    .foregroundStyle(content.isError ? .red : bubbleForeground)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)

            statusCluster
        }
    }

    private var statusCluster: some View {
        HStack(spacing: 4) {
            if message.content?.isEdited == true {
                Text(AppLang.key("edited", code: selectedLanguageCode, fallback: isEnglish ? "edited" : "изменено"))
                    .font(.system(size: 9))
                    .foregroundStyle(bubbleForeground.opacity(0.6))
            }
            Text(messengerMessageTime(message.date))
                .font(.caption2)
                .foregroundStyle(bubbleForeground.opacity(0.65))

            if isMine {
                if message.status == "not_sent" {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(bubbleForeground.opacity(0.65))
                } else if message.isRead {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(bubbleForeground.opacity(0.85))
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(bubbleForeground.opacity(0.65))
                }
            }
        }
    }

    // MARK: Reactions bar (web ReactionBar)

    @ViewBuilder
    private var reactionBar: some View {
        if !message.reactions.isEmpty {
            HStack(spacing: 5) {
                ForEach(message.reactions.sorted(by: { $0.value.count > $1.value.count }), id: \.key) { emoji, users in
                    Button {
                        Task { await viewModel.toggleReaction(message, emoji: emoji) }
                    } label: {
                        HStack(spacing: 4) {
                            EmojiHelper.shared.image(for: emoji, pointSize: 16)
                                .map(Image.init(uiImage:))?
                                .resizable()
                                .frame(width: 16, height: 16)
                            if users.count > 1 {
                                Text("\(users.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                users.contains(where: { $0.uid == (APIClient.shared.currentUserIDSnapshot() ?? -1) })
                                    ? AppTheme.primary.opacity(0.22)
                                    : AppTheme.surfaceElevated
                            )
                        )
                        .overlay(Capsule().stroke(AppTheme.cardStroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Context menu overlay (web ContextMenu with quick-reactions header)

struct MessageContextMenuOverlay: View {
    let message: MessengerMessage
    @ObservedObject var viewModel: MessengerViewModel
    let onDismiss: () -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @AppStorage("app_language") private var selectedLanguageCode = "RU"

    private var canEdit: Bool {
        message.isOutgoing && message.content?.type == "text" && message.status != "not_sent"
    }
    private var canDelete: Bool {
        message.isOutgoing && message.status != "not_sent"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 10) {
                // Quick reactions header
                HStack(spacing: 6) {
                    ForEach(messengerQuickReactions, id: \.unified) { item in
                        Button {
                            Task {
                                await viewModel.toggleReaction(message, emoji: item.emoji)
                            }
                            onDismiss()
                        } label: {
                            if let img = EmojiHelper.shared.image(for: item.emoji, pointSize: 26) {
                                Image(uiImage: img)
                                    .resizable()
                                    .frame(width: 26, height: 26)
                            } else {
                                Text(item.emoji).font(.system(size: 22))
                            }
                        }
                        .buttonStyle(BubblePressButtonStyle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))

                VStack(spacing: 2) {
                    menuButton(icon: "arrowshape.turn.up.left.fill", title: AppLang.key("reply", code: selectedLanguageCode, fallback: "Ответить")) {
                        onReply()
                    }
                    if canEdit {
                        menuButton(icon: "pencil", title: AppLang.key("edit", code: selectedLanguageCode, fallback: "Редактировать")) {
                            onEdit()
                        }
                    }
                    if canDelete {
                        menuButton(icon: "trash.fill", title: AppLang.key("delete", code: selectedLanguageCode, fallback: "Удалить"), destructive: true) {
                            onDelete()
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            }
            .padding(.horizontal, 60)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func menuButton(icon: String, title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(destructive ? Color.red : AppTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
