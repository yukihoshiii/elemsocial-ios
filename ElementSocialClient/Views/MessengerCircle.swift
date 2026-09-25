import SwiftUI
import AVFoundation

// MARK: - Video circle («кружок», web HandleVideoMessage)

struct MessageVideoCircleAttachment: View {
    let message: MessengerMessage
    @ObservedObject var viewModel: MessengerViewModel
    let timeText: String

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var localURL: URL?
    @State private var timeObserver: Any?
    @State private var exportURL: URL?

    private struct ExportPayload: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private let ringSize: CGFloat = 148
    private var content: MessengerMessageContent? { message.content }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            circleView
            footer
        }
        .contextMenu {
            if message.mid != nil {
                Button {
                    Task {
                        if let url = await viewModel.exportVideoCircle(for: message) {
                            await MainActor.run {
                                exportURL = url
                            }
                        }
                    }
                } label: {
                    Label("Скачать кружок", systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(item: Binding(
            get: { exportURL.map(ExportPayload.init) },
            set: { exportURL = $0?.url }
        )) { payload in
            ShareSheet(items: [payload.url])
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private var circleView: some View {
        ZStack {
            Group {
                if player != nil && (isPlaying || currentTime > 0) {
                    CirclePlayerLayer(player: player!)
                        .frame(width: ringSize - 8, height: ringSize - 8)
                        .clipShape(Circle())
                } else if let thumb = thumbnailImage {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: ringSize - 8, height: ringSize - 8)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.black.opacity(0.25))
                        .frame(width: ringSize - 8, height: ringSize - 8)
                }
            }

            if isPlaying {
                Circle()
                    .trim(from: 0, to: CGFloat(duration > 0 ? min(1, currentTime / duration) : 0))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: ringSize - 5, height: ringSize - 5)
            }

            centerControl
        }
        .frame(width: ringSize, height: ringSize)
        .contentShape(Circle())
        .onTapGesture { handleTap() }
    }

    @ViewBuilder
    private var centerControl: some View {
        if message.status == "not_sent" {
            Button {
                viewModel.cancelUpload(tempMid: message.tempMid ?? -1)
            } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.45)).frame(width: 52, height: 52)
                    CircularProgress(progress: (message.uploadProgress ?? 0) / 100, size: 48)
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
        } else if !hasLocalFile && !isPlaying {
            Button {
                download()
            } label: {
                ZStack {
                    Circle().fill(Color.black.opacity(0.45)).frame(width: 52, height: 52)
                    let p = viewModel.progressForAttachment(message)
                    if let p, p >= 0 && p < 1 {
                        CircularProgress(progress: p, size: 48)
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    } else if p == -1 {
                        Text("Ошибка").font(.system(size: 9)).foregroundStyle(.red)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
        } else if !isPlaying {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(14)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
    }

    private var thumbnailImage: UIImage? {
        guard let base64 = content?.thumbnailBase64 else { return nil }
        let clean = base64.contains(",") ? String(base64.split(separator: ",", maxSplits: 1).last ?? "") : base64
        guard let data = Data(base64Encoded: clean) else { return nil }
        return UIImage(data: data)
    }

    private var hasLocalFile: Bool {
        if let url = localURL ?? message.localFileURL {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(timeString(isPlaying ? currentTime : (content?.duration ?? 0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
            Text(timeText)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppTheme.surface.opacity(0.85)))
    }

    // MARK: Actions

    private func handleTap() {
        if message.status == "not_sent" { return }
        guard hasLocalFile else {
            download()
            return
        }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if player == nil, let url = localURL ?? message.localFileURL {
                localURL = url
                preparePlayer(url: url)
            }
            player?.play()
            isPlaying = true
        }
    }

    private func download() {
        Task {
            if let url = await viewModel.ensureAttachmentFileLoaded(for: message) {
                await MainActor.run {
                    localURL = url
                    preparePlayer(url: url)
                }
            }
        }
    }

    private func preparePlayer(url: URL) {
        let p = AVPlayer(url: url)
        let observer = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = CMTimeGetSeconds(time)

            // Duration may not be ready immediately after AVPlayer init.
            if duration <= 0, let item = p.currentItem,
               item.duration.isNumeric, item.duration.isValid {
                let d = CMTimeGetSeconds(item.duration)
                if d > 0 { duration = d }
            }

            if duration > 0 && currentTime >= duration - 0.05 {
                stopPlayback()
            }
        }

        if let fallback = content?.duration, fallback > 0 {
            duration = fallback
        }
        timeObserver = observer
        player = p
    }

    private func stopPlayback() {
        player?.pause()
        isPlaying = false
        currentTime = 0
        // Removing a time observer from within its own callback must not run
        // synchronously (AVFoundation deadlock pattern).
        if let observer = timeObserver, let player {
            DispatchQueue.main.async {
                player.removeTimeObserver(observer)
            }
        }
        timeObserver = nil
        player = nil
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// AVPlayerLayer wrapped for SwiftUI.
struct CirclePlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}
