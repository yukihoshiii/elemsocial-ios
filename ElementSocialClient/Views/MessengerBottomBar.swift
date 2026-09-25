import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Chat composer — the web BottomBar: attach menu, input with typing throttle,
/// emoji picker, voice/video-circle hold-to-record.
struct MessengerBottomBar: View {
    @ObservedObject var viewModel: MessengerViewModel
    let chatTarget: MessengerChatTarget
    let isGroup: Bool

    @AppStorage("app_language") private var selectedLanguageCode = "RU"
    @State private var selectedFiles: [OutgoingAttachment] = []
    @State private var filePreviews: [UIImage] = []
    @State private var isMediaPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var isActionPanelOpen = false
    @State private var isEmojiSheetPresented = false

    @StateObject private var recorder = ChatRecorderController()
    @State private var holdProgress: CGFloat = 0
    @State private var showVideoOverlay = false

    private var isEnglish: Bool { selectedLanguageCode == "en" }
    private var trimmedText: String { viewModel.composeText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContentToSend: Bool { !trimmedText.isEmpty || !selectedFiles.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if !selectedFiles.isEmpty {
                selectedFilesStrip
            }

            if let replyTo = viewModel.replyingToMessage ?? viewModel.editingMessage {
                replyPreview(replyTo, isEditing: viewModel.editingMessage != nil)
            }

            mainInputRow
        }
        .background(.ultraThinMaterial)
        .overlay {
            if recorder.isRecording && recorder.mode == .voice {
                recordingPanel
            }
        }
        .fullScreenCover(isPresented: $showVideoOverlay) {
            VideoCircleRecordingOverlay(recorder: recorder) {
                showVideoOverlay = false
            }
        }
        .sheet(isPresented: $isEmojiSheetPresented) {
            EmojiPickerSheet { emoji in
                viewModel.composeText.append(emoji)
            }
        }
        .photosPicker(
            isPresented: $isMediaPickerPresented,
            selection: $mediaItem,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: mediaItem) { item in
            guard let item else { return }
            handleMediaPick(item)
            mediaItem = nil
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                importFiles(urls: urls)
            }
        }
        .onAppear {
            recorder.onStart = {
                viewModel.notifyRecordingChange(videoCircle: recorder.mode == .videoCircle, stop: false)
            }
            recorder.onFinishVoice = { result in
                viewModel.notifyRecordingChange(videoCircle: false, stop: true)
                guard let result else { return }
                Task {
                    await viewModel.sendVoiceMessage(
                        url: result.url,
                        duration: result.duration,
                        waveform: result.waveform
                    )
                }
            }
            recorder.onFinishCircle = { result in
                viewModel.notifyRecordingChange(videoCircle: true, stop: true)
                guard let result else { return }
                Task {
                    await viewModel.sendVideoCircleMessage(
                        fileURL: result.url,
                        duration: result.duration,
                        thumbnailDataURL: result.thumbnailDataURL
                    )
                }
            }
        }
    }

    // MARK: Media picking

    @State private var mediaItem: PhotosPickerItem?

    private func handleMediaPick(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let types = item.supportedContentTypes
            let isVideo = types.contains { $0.conforms(to: .movie) }
            if let data = try? await item.loadTransferable(type: Data.self) {
                let (name, mime): (String, String)
                if isVideo {
                    name = "video.mov"
                    mime = "video/quicktime"
                } else if let type = types.first(where: { $0.conforms(to: .image) }),
                          let ext = type.preferredFilenameExtension {
                    name = "photo.\(ext)"
                    mime = type.preferredMIMEType ?? "image/jpeg"
                } else {
                    name = "photo.jpg"
                    mime = "image/jpeg"
                }
                selectedFiles.append(OutgoingAttachment(name: name, mimeType: mime, data: data))
                filePreviews.append(UIImage(data: data) ?? UIImage())
            }
        }
    }

    private func importFiles(urls: [URL]) {
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            let mime: String
            switch ext {
            case "mp4": mime = "video/mp4"
            case "mov": mime = "video/quicktime"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "png": mime = "image/png"
            case "gif": mime = "image/gif"
            case "pdf": mime = "application/pdf"
            default: mime = "application/octet-stream"
            }
            selectedFiles.append(OutgoingAttachment(name: url.lastPathComponent, mimeType: mime, data: data))
            if let image = UIImage(data: data), data.count < 8 * 1024 * 1024 {
                filePreviews.append(image)
            } else {
                filePreviews.append(UIImage())
            }
        }
    }

    // MARK: Selected files strip

    private var selectedFilesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(selectedFiles.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: 8) {
                        if file.mimeType.hasPrefix("image/"), index < filePreviews.count,
                           let image = UIImage(data: file.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 42, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AppTheme.surfaceElevated)
                                    .frame(width: 42, height: 42)
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppTheme.primary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                .font(.system(size: 9))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Button {
                            _ = withAnimation { selectedFiles.remove(at: index) }
                            if index < filePreviews.count { filePreviews.remove(at: index) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.surface))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // MARK: Reply / edit preview bar

    private func replyPreview(_ message: MessengerMessage, isEditing: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isEditing ? "pencil" : "arrowshape.turn.up.left.fill")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.primary)

            Rectangle()
                .fill(AppTheme.primary)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(isEditing
                     ? AppLang.key("editing_message", code: selectedLanguageCode, fallback: isEnglish ? "Editing" : "Редактирование")
                     : (message.author?.name ?? (message.isOutgoing ? "Вы" : "")))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.primary)
                Text(message.content?.replyPreviewText ?? "")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.cancelReplyOrEdit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Main input row

    private var mainInputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // Plus / attach
            BubbleButton(icon: "plus") {
                withAnimation { isActionPanelOpen.toggle() }
            }

            if isActionPanelOpen {
                actionPanelButtons
            }

            // Text field
            TextField(
                AppLang.key("chat_message_input", code: selectedLanguageCode, fallback: isEnglish ? "Message" : "Сообщение"),
                text: Binding(
                    get: { viewModel.composeText },
                    set: { newValue in
                        viewModel.composeText = newValue
                        if !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                            viewModel.notifyTyping()
                        }
                    }
                ),
                axis: .vertical
            )
            .lineLimit(1...5)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.cardStroke, lineWidth: 1))

            // Emoji
            BubbleButton(icon: "face.smiling") {
                isEmojiSheetPresented = true
            }

            // Send / record
            if hasContentToSend {
                Button {
                    sendTapped()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(AppTheme.primary))
                }
                .buttonStyle(BubblePressButtonStyle())
            } else {
                recordButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func sendTapped() {
        let files = selectedFiles
        selectedFiles.removeAll()
        filePreviews.removeAll()
        if !files.isEmpty {
            Task { await viewModel.sendFiles(files) }
        } else {
            Task { await viewModel.sendMessage() }
        }
    }

    private var actionPanelButtons: some View {
        HStack(spacing: 6) {
            BubbleButton(icon: "photo.on.rectangle.angled") {
                isMediaPickerPresented = true
                isActionPanelOpen = false
            }
            BubbleButton(icon: "doc") {
                isFileImporterPresented = true
                isActionPanelOpen = false
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    // MARK: Record button (hold to record, tap toggles voice/video mode)

    /// Web mobile parity: tap toggles voice/video mode; hold starts recording;
    /// releasing under 1 s discards; the recording panel controls the rest.
    private var recordButton: some View {
        Image(systemName: recorder.mode == .voice ? "mic.fill" : "video.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(AppTheme.primary))
            .scaleEffect(recorder.isRecording && recorder.mode == .voice ? 1.12 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: recorder.isRecording && recorder.mode == .voice)
            .onTapGesture {
                guard !recorder.isRecording else { return }
                // Tap = switch mode (site: click toggles voice/video).
                recorder.mode = recorder.mode == .voice ? .videoCircle : .voice
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 30) {
                guard !recorder.isRecording else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if recorder.mode == .voice {
                    recorder.startVoice()
                } else {
                    Task {
                        let ok = await recorder.startCircle()
                        await MainActor.run {
                            if ok {
                                // Mobile web auto-locks circle recording.
                                showVideoOverlay = true
                            } else {
                                viewModel.errorMessage = isEnglish
                                    ? "Camera access denied. Allow access in Settings."
                                    : "Доступ к камере запрещён. Разрешите доступ в настройках."
                                recorder.mode = .voice
                            }
                        }
                    }
                }
            } onPressingChanged: { pressing in
                // Finger lifted: a quick misfire (<1 s) is discarded, like the web.
                if !pressing && recorder.isRecording && recorder.mode == .voice && recorder.elapsed < 1 {
                    recorder.cancel()
                }
            }
    }

    // MARK: Voice recording panel (locked state UI)

    private var recordingPanel: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(recorder.elapsed % 2 == 0 ? 1 : 0.35)
                Text(String(format: "%d:%02d", recorder.elapsed / 60, recorder.elapsed % 60))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }

            Spacer()

            Button(AppLang.tr("Отмена", "Cancel", code: selectedLanguageCode)) {
                recorder.cancel()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.red)

            Button {
                recorder.stop()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(AppTheme.primary))
            }
            .buttonStyle(BubblePressButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Small circular icon button used across the composer.
struct BubbleButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(AppTheme.surfaceElevated))
                .overlay(Circle().stroke(AppTheme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(BubblePressButtonStyle())
    }
}

// MARK: - Video circle fullscreen recording overlay

struct VideoCircleRecordingOverlay: View {
    @ObservedObject var recorder: ChatRecorderController
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewHost(recorder: recorder)
                .frame(width: 260, height: 260)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .trim(from: 0, to: CGFloat(min(1, Double(recorder.elapsed) / ChatRecorderController.maxDuration)))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 264, height: 264)
                )

            VStack {
                Spacer()
                HStack(spacing: 24) {
                    Button {
                        recorder.cancel()
                        onClose()
                    } label: {
                        Text("Отмена")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }

                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 9, height: 9)
                            .opacity(recorder.elapsed % 2 == 0 ? 1 : 0.3)
                        Text(String(format: "%d:%02d", recorder.elapsed / 60, recorder.elapsed % 60))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                    }

                    Button {
                        recorder.stop()
                        onClose()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Color.white))
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onDisappear {
            if recorder.isRecording {
                recorder.stop()
            }
            recorder.shutdownCapture()
        }
    }
}

struct CameraPreviewHost: UIViewControllerRepresentable {
    let recorder: ChatRecorderController

    final class HostViewController: UIViewController {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }
    }

    func makeUIViewController(context: Context) -> HostViewController {
        let controller = HostViewController()
        DispatchQueue.main.async {
            let layer = recorder.makePreviewLayer()
            layer.frame = controller.view.bounds
            controller.view.layer.addSublayer(layer)
            controller.previewLayer = layer
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: HostViewController, context: Context) {}
}
