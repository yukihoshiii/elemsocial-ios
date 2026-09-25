import SwiftUI
import AVFoundation
import AVKit

// MARK: - Image attachment (web HandleMessageImage)

struct MessageImageAttachment: View {
    let message: MessengerMessage
    @ObservedObject var viewModel: MessengerViewModel

    @State private var imageData: Data?
    @State private var isViewerPresented = false

    var body: some View {
        Group {
            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: 220, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { isViewerPresented = true }
            } else {
                placeholder
            }
        }
        .overlay(alignment: .center) {
            overlayControls
        }
        .task(id: message.mid) {
            await loadIfAvailable()
        }
        .sheet(isPresented: $isViewerPresented) {
            if let image = currentImage {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        NativeChatImageZoom(image: image)
                            .ignoresSafeArea()
                    }
                    .navigationTitle(message.content?.fileName ?? "Фото")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private var currentImage: UIImage? {
        if let data = message.localImageData ?? imageData {
            return UIImage(data: data)
        }
        if let base64 = message.content?.previewBase64 {
            let clean = base64.contains(",") ? String(base64.split(separator: ",", maxSplits: 1).last ?? "") : base64
            if let data = Data(base64Encoded: clean) {
                return UIImage(data: data)
            }
        }
        return nil
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.surface)
                .frame(width: 180, height: 180)
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var overlayControls: some View {
        // Uploading state
        if message.status == "not_sent" {
            uploadRing
        } else if currentImage == nil || isPlaceholderOnly {
            downloadControl
        }
    }

    private var isPlaceholderOnly: Bool {
        message.localImageData == nil && imageData == nil && hasEncryptedFile
    }

    private var hasEncryptedFile: Bool {
        guard let content = message.content else { return false }
        return content.fileMap != nil && content.encryptedKey != nil && content.encryptedIV != nil
    }

    private var uploadRing: some View {
        Button {
            viewModel.cancelUpload(tempMid: message.tempMid ?? -1)
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.45)).frame(width: 44, height: 44)
                CircularProgress(progress: (message.uploadProgress ?? 0) / 100, size: 40)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var downloadControl: some View {
        if hasEncryptedFile, message.mid != nil {
            let progress = viewModel.progressForAttachment(message)
            let isProgressing = progress != nil && progress! >= 0 && progress! < 1

            ZStack {
                Button {
                    Task { _ = await viewModel.ensureImageLoaded(for: message) }
                } label: {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.45)).frame(width: 46, height: 46)
                        if isProgressing {
                            CircularProgress(progress: progress!, size: 42)
                        } else if progress == -1 {
                            Text("Ошибка").font(.system(size: 9)).foregroundStyle(.red)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isProgressing)

                if isProgressing {
                    Button {
                        viewModel.cancelAttachmentDownload(mid: message.mid)
                    } label: {
                        ZStack {
                            Circle().fill(Color.black.opacity(0.45)).frame(width: 46, height: 46)
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadIfAvailable() async {
        guard message.localImageData == nil else { return }
        if let mid = message.mid,
           let cached = MessengerFileDownloader.shared.cachedImageData(mid: mid) {
            imageData = cached
            return
        }
        // Only auto-fetch recent images to avoid burst downloads on scroll.
        guard let mid = message.mid, hasEncryptedFile else { return }
        let recentIDs = viewModel.messages.suffix(6).compactMap(\.mid)
        guard recentIDs.contains(mid) else { return }
        if let data = await viewModel.ensureImageLoaded(for: message) {
            imageData = data
        }
    }
}

/// Thin circular progress ring.
struct CircularProgress: View {
    let progress: Double
    var size: CGFloat = 40
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth))
            Circle()
                .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: progress)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - File attachment (web HandleMessage file block)

struct MessageFileAttachment: View {
    let message: MessengerMessage
    @ObservedObject var viewModel: MessengerViewModel
    var videoFallback = false

    @AppStorage("app_language") private var selectedLanguageCode = "RU"
    @State private var shareURL: URL?

    private var content: MessengerMessageContent? { message.content }
    private var isMine: Bool { message.isOutgoing }

    var body: some View {
        Button {
            openOrDownload()
        } label: {
            HStack(spacing: 10) {
                iconView

                VStack(alignment: .leading, spacing: 2) {
                    Text(content?.fileName ?? (videoFallback ? "Видео" : AppLang.tr("Документ", "Document", code: selectedLanguageCode)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isMine ? .white : AppTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let size = content?.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(isMine ? .white.opacity(0.75) : AppTheme.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                statusIcon
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isMine ? Color.white.opacity(0.14) : AppTheme.surface.opacity(0.7))
            )
        }
        .buttonStyle(.plain)
        .sheet(item: Binding(
            get: { shareURL.map { SharePayload(url: $0) } },
            set: { shareURL = $0?.url }
        )) { payload in
            ShareSheet(items: [payload.url])
        }
    }

    private struct SharePayload: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var iconView: some View {
        ZStack {
            Circle().fill(isMine ? Color.white.opacity(0.2) : AppTheme.primary.opacity(0.15))
                .frame(width: 38, height: 38)
            if message.status == "not_sent" {
                CircularProgress(progress: (message.uploadProgress ?? 0) / 100, size: 34).tint(.white)
            } else if videoFallback {
                Image(systemName: "video.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isMine ? .white : AppTheme.primary)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isMine ? .white : AppTheme.primary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let progress = viewModel.progressForAttachment(message)
        if progress != nil && progress != 1 && message.status != "not_sent" && !alreadyCached {
            if progress == -1 {
                Text("Ошибка").font(.caption2).foregroundStyle(.red)
            } else {
                CircularProgress(progress: progress!, size: 22)
                    .tint(isMine ? .white : AppTheme.primary)
            }
        } else if alreadyDownloaded {
            Image(systemName: "square.and.arrow.up")
                .font(.caption)
                .foregroundStyle(isMine ? .white.opacity(0.8) : AppTheme.textSecondary)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(isMine ? .white.opacity(0.8) : AppTheme.textSecondary)
        }
    }

    private var alreadyCached: Bool {
        guard let mid = message.mid else { return false }
        return MessengerFileDownloader.shared.cachedFileURL(mid: mid) != nil
    }

    private var alreadyDownloaded: Bool {
        message.localFileURL != nil && FileManager.default.fileExists(atPath: message.localFileURL!.path)
    }

    private func openOrDownload() {
        Task {
            if message.status == "not_sent" { return }
            if let url = await viewModel.ensureAttachmentFileLoaded(for: message) {
                await MainActor.run { shareURL = url }
            }
        }
    }
}

// MARK: - Voice attachment (web HandleVoiceMessage)

final class VoicePlaybackManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlaybackManager()

    @Published var playingID: String?
    @Published var currentTime: Double = 0
    @Published var rate: Float = 1

    private var player: AVAudioPlayer?
    private(set) var currentMessageKey: String?
    var onFinished: (() -> Void)?
    var onListened: ((String) -> Void)?

    func toggle(key: String, url: URL) {
        // Pause
        if playingID == key {
            player?.pause()
            playingID = nil
            return
        }
        // Resume the same paused player (web <audio> parity) — position kept.
        if currentMessageKey == key, let existing = player {
            existing.play()
            playingID = key
            trackProgress()
            return
        }
        // Different message — stop current, start fresh.
        if playingID != nil || player != nil {
            stop()
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.enableRate = true
            p.rate = rate
            p.play()
            player = p
            currentMessageKey = key
            playingID = key
            currentTime = 0
            onListened?(key)
            trackProgress()
        } catch {
            playingID = nil
        }
    }

    private func trackProgress() {
        Task { [weak self] in
            while let self, self.player != nil, self.playingID != nil {
                self.currentTime = self.player?.currentTime ?? 0
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func seek(to fraction: Double, duration: Double) {
        guard let player else { return }
        player.currentTime = fraction * duration
        currentTime = player.currentTime
    }

    func cycleRate() {
        let rates: [Float] = [1, 1.5, 2]
        let idx = rates.firstIndex(of: rate) ?? 0
        rate = rates[(idx + 1) % rates.count]
        player?.enableRate = true
        player?.rate = rate
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        currentTime = 0
        currentMessageKey = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.playingID = nil
            self?.currentTime = 0
            self?.onFinished?()
        }
    }
}

struct MessageVoiceAttachment: View {
    let message: MessengerMessage
    @ObservedObject var viewModel: MessengerViewModel

    @StateObject private var playback = VoicePlaybackManager.shared
    @State private var localURL: URL?
    @State private var loadFailed = false

    private var key: String { message.mid.map { "v-\($0)" } ?? ("vt-\(message.tempMid ?? 0)-\(message.id)") }
    private var duration: Double { message.content?.duration ?? 0 }
    private var waveform: [Double] {
        message.content?.waveform ?? Array(repeating: 0.08, count: 30)
    }

    var body: some View {
        HStack(spacing: 10) {
            leftButton

            VStack(alignment: .leading, spacing: 4) {
                WaveformBars(
                    bars: waveform,
                    progress: progressFraction,
                    activeColor: message.isOutgoing ? .white : AppTheme.primary,
                    inactiveColor: message.isOutgoing ? Color.white.opacity(0.35) : AppTheme.cardStroke
                )
                .frame(height: 26)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        guard localURL != nil else { return }
                        let width = max(1, UIScreen.main.bounds.width * 0.5)
                        let fraction = Double(max(0, min(1, value.location.x / width)))
                        playback.seek(to: fraction, duration: effectiveDuration)
                    }
                )

                HStack(spacing: 8) {
                    Text(timeString(playback.playingID == key ? playback.currentTime : effectiveDuration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(message.isOutgoing ? .white.opacity(0.8) : AppTheme.textSecondary)

                    if localURL != nil {
                        Button {
                            playback.cycleRate()
                        } label: {
                            Text(String(format: "%g×", playback.rate))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(message.isOutgoing ? .white : AppTheme.primary)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if !message.isListened && !message.isOutgoing {
                Circle().fill(AppTheme.primary).frame(width: 8, height: 8).offset(x: -3, y: -3)
            }
        }
        .task(id: message.id) {
            await loadIfNeeded()
        }
    }

    private var effectiveDuration: Double {
        duration > 0 ? duration : (localDuration ?? 0)
    }

    @State private var localDuration: Double?

    private var progressFraction: Double {
        guard playback.playingID == key, effectiveDuration > 0 else { return 0 }
        return playback.currentTime / effectiveDuration
    }

    private var leftButton: some View {
        ZStack {
            Button {
                handleTap()
            } label: {
                ZStack {
                    Circle()
                        .fill(message.isOutgoing ? Color.white.opacity(0.18) : AppTheme.primary.opacity(0.14))
                        .frame(width: 40, height: 40)

                    if message.status != "not_sent" {
                        if playback.playingID == key {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(message.isOutgoing ? .white : AppTheme.primary)
                        } else if localURL != nil {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(message.isOutgoing ? .white : AppTheme.primary)
                        } else if loadFailed {
                            Text("Ошибка").font(.system(size: 8)).foregroundStyle(.red)
                        } else {
                            let p = viewModel.progressForAttachment(message)
                            if p == -1 {
                                Text("Ошибка").font(.system(size: 8)).foregroundStyle(.red)
                            } else if !(p != nil && p! >= 0 && p! < 1) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(message.isOutgoing ? .white : AppTheme.primary)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(message.status == "not_sent" || isProgressing)

            // Cancel controls live OUTSIDE the main button (nested buttons
            // in SwiftUI fire both actions).
            if message.status == "not_sent" {
                cancelButton {
                    viewModel.cancelUpload(tempMid: message.tempMid ?? -1)
                }
            } else if isProgressing {
                cancelButton {
                    viewModel.cancelAttachmentDownload(mid: message.mid)
                }
            }
        }
    }

    private var isProgressing: Bool {
        guard message.status != "not_sent", localURL == nil, !loadFailed else { return false }
        if let p = viewModel.progressForAttachment(message) {
            return p >= 0 && p < 1
        }
        return false
    }

    private func cancelButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(0.45)).frame(width: 40, height: 40)
                CircularProgress(progress: message.status == "not_sent"
                                 ? (message.uploadProgress ?? 0) / 100
                                 : (viewModel.progressForAttachment(message) ?? 0),
                                 size: 36)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func handleTap() {
        if message.status == "not_sent" { return }
        guard let url = localURL else {
            Task {
                if let loaded = await viewModel.ensureAttachmentFileLoaded(for: message) {
                    localURL = loaded
                    play(url: loaded)
                } else {
                    loadFailed = true
                }
            }
            return
        }
        if playback.playingID == key {
            playback.toggle(key: key, url: url)
        } else {
            play(url: url)
        }
    }

    private func play(url: URL) {
        playback.onListened = { [weak viewModel] listenedKey in
            guard let viewModel, listenedKey == key else { return }
            viewModel.markListened(message)
        }
        playback.toggle(key: key, url: url)
    }

    private func loadIfNeeded() async {
        guard localURL == nil else { return }
        if let local = message.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            localURL = local
            localDuration = AudioWaveformAnalyzer.duration(of: local)
            return
        }
        if let mid = message.mid,
           let cached = MessengerFileDownloader.shared.cachedFileURL(mid: mid) {
            localURL = cached
            localDuration = AudioWaveformAnalyzer.duration(of: cached)
            return
        }
        // Do not auto-download voice messages — user taps to fetch (site behavior).
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Waveform bar chart with played-progress fill (web Waveform component).
struct WaveformBars: View {
    let bars: [Double]
    let progress: Double
    let activeColor: Color
    let inactiveColor: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(1, bars.count)
            let slot = geo.size.width / CGFloat(count)
            let barWidth = max(2, slot * 0.62)
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                    let height = max(3, CGFloat(value.clamped01()) * geo.size.height)
                    let filled = Double(index) / Double(count) <= progress
                    Capsule()
                        .fill(filled ? activeColor : inactiveColor)
                        .frame(width: barWidth, height: height)
                        .frame(width: slot, height: geo.size.height, alignment: .center)
                }
            }
        }
    }
}

extension Double {
    func clamped01() -> Double {
        max(0, min(1, self))
    }
}
