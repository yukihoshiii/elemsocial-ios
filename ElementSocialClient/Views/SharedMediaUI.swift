import SwiftUI
import UIKit
import AVKit

struct ImagePayloadItem: Identifiable {
    let id = UUID()
    let media: MediaData
    let estimatedBytes: Int?
}

struct SelectedImagePayload: Identifiable {
    let id = UUID()
    let items: [ImagePayloadItem]
    let startIndex: Int
}

func makeImagePayload(images: [PostImage], startIndex: Int) -> SelectedImagePayload? {
    guard !images.isEmpty else { return nil }
    let items = images.map { ImagePayloadItem(media: $0.imgData, estimatedBytes: $0.fileSize) }
    let clampedIndex = max(0, min(startIndex, items.count - 1))
    return SelectedImagePayload(items: items, startIndex: clampedIndex)
}

func makeCommentImagePayload(images: [PostCommentImage], startIndex: Int) -> SelectedImagePayload? {
    var items: [ImagePayloadItem] = []
    var mappedStartIndex = 0
    var didMapStart = false

    for (index, image) in images.enumerated() {
        guard let media = image.imgData else { continue }
        if index == startIndex {
            mappedStartIndex = items.count
            didMapStart = true
        }
        items.append(ImagePayloadItem(media: media, estimatedBytes: image.fileSize))
    }

    guard !items.isEmpty else { return nil }
    if !didMapStart {
        mappedStartIndex = max(0, min(startIndex, items.count - 1))
    }
    return SelectedImagePayload(items: items, startIndex: mappedStartIndex)
}

struct FullscreenImageViewer: View {
    let items: [ImagePayloadItem]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selected_language_code") private var selectedLanguageCode: String = "ru"
    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0

    init(items: [ImagePayloadItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()

                if items.isEmpty {
                    Text("Нет изображений")
                        .foregroundStyle(.white)
                } else {
                    NativeImagePager(items: items, currentIndex: $currentIndex, onDismiss: {})
                        .ignoresSafeArea()
                }

                if items.count > 1 {
                    Text("\(currentIndex + 1)/\(items.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 18)
                }
            }
            .scaleEffect(contentScale)
            .offset(y: dragOffset)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: dragOffset)
            .navigationTitle(selectedLanguageCode == "en" ? "Photo" : "Фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLang.tr("Готово", "Done", code: selectedLanguageCode)) { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let vertical = value.translation.height
                        let horizontal = value.translation.width
                        guard abs(vertical) > abs(horizontal) else { return }
                        dragOffset = max(0, vertical)
                    }
                    .onEnded { value in
                        let vertical = value.translation.height
                        let predicted = value.predictedEndTranslation.height
                        let shouldDismiss = vertical > 120 || predicted > 180
                        if shouldDismiss {
                            dismiss()
                        } else {
                            dragOffset = 0
                        }
                    }
            )
        }
    }

    private var contentScale: CGFloat {
        max(0.85, 1 - (dragOffset / 1200))
    }

    private var backgroundOpacity: Double {
        Double(max(0.2, 1 - (dragOffset / 500)))
    }
}

struct NativeImagePager: UIViewControllerRepresentable {
    let items: [ImagePayloadItem]
    @Binding var currentIndex: Int
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, onIndexChange: { index in
            currentIndex = index
        }, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pageController.view.backgroundColor = .black
        pageController.dataSource = context.coordinator
        pageController.delegate = context.coordinator

        if let initial = context.coordinator.viewController(at: currentIndex) {
            pageController.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pageController
    }

    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.items = items

        guard let current = uiViewController.viewControllers?.first as? ImageZoomViewController else { return }
        if current.index != currentIndex, let target = context.coordinator.viewController(at: currentIndex) {
            let direction: UIPageViewController.NavigationDirection = currentIndex > current.index ? .forward : .reverse
            uiViewController.setViewControllers([target], direction: direction, animated: false)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var items: [ImagePayloadItem]
        private let onIndexChange: (Int) -> Void
        private let onDismiss: () -> Void

        init(items: [ImagePayloadItem], onIndexChange: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
            self.items = items
            self.onIndexChange = onIndexChange
            self.onDismiss = onDismiss
        }

        func viewController(at index: Int) -> ImageZoomViewController? {
            guard index >= 0, index < items.count else { return nil }
            return ImageZoomViewController(item: items[index], index: index, onDismiss: onDismiss)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ImageZoomViewController else { return nil }
            return self.viewController(at: page.index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ImageZoomViewController else { return nil }
            return self.viewController(at: page.index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first as? ImageZoomViewController else { return }
            onIndexChange(current.index)
        }
    }
}

final class ImageZoomViewController: UIViewController, UIScrollViewDelegate {
    let item: ImagePayloadItem
    let index: Int
    private let onDismiss: () -> Void

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private var loadTask: Task<Void, Never>?

    init(item: ImagePayloadItem, index: Int, onDismiss: @escaping () -> Void) {
        self.item = item
        self.index = index
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureScrollView()
        configureErrorLabel()
        configureActivity()
        configureGestures()
        loadImage()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 3
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private func configureActivity() {
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        activityIndicator.startAnimating()
    }

    private func configureErrorLabel() {
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.text = "Не удалось загрузить изображение"
        errorLabel.textColor = .white
        errorLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func configureGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @objc private func handleDoubleTap() {
        let targetZoom: CGFloat = scrollView.zoomScale > 1.05 ? 1 : 2
        scrollView.setZoomScale(targetZoom, animated: true)
    }

    private func loadImage() {
        loadTask?.cancel()
        activityIndicator.startAnimating()
        errorLabel.isHidden = true

        let media = item.media
        let estimatedBytes = item.estimatedBytes
        loadTask = Task { [weak self] in
            guard let self else { return }

            let data = await APIClient.shared.downloadMediaImage(
                media,
                lossless: true,
                maxLosslessBytes: estimatedBytes
            )

            if let data, let image = UIImage(data: data) {
                await MainActor.run { self.showImage(image) }
            } else {
                await MainActor.run { self.showError() }
            }
        }
    }

    private func showImage(_ image: UIImage) {
        activityIndicator.stopAnimating()
        errorLabel.isHidden = true
        imageView.image = image
        scrollView.setZoomScale(1, animated: false)
    }

    private func showError() {
        activityIndicator.stopAnimating()
        errorLabel.isHidden = false
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}

struct VideoPlayerScreen: View {
    let video: PostVideo
    @State private var player: AVPlayer?
    @State private var playbackError: String?
    @State private var currentURLIndex = 0
    @State private var urlsToTry: [URL] = []
    @State private var statusObserver: NSKeyValueObservation?
    @State private var itemFailedObserver: NSObjectProtocol?
    @State private var attemptedLocalFallback = false

    var body: some View {
        Group {
            if let player {
                NativeVideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let playbackError {
                VStack(spacing: 8) {
                    Text("Видео не загрузилось")
                        .font(.headline)
                    Text(playbackError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task { await startPlaybackFlow() }
        .onDisappear { cleanupObservers() }
    }

    private func startPlaybackFlow() async {
        cleanupObservers()
        playbackError = nil
        attemptedLocalFallback = false

        if let fileID = video.fileId {
            do {
                let localURL = try await APIClient.shared.downloadStorageVideoFile(
                    fileID: fileID,
                    fileName: video.fileName ?? video.file ?? video.name
                )
                play(url: localURL, index: 0)
                return
            } catch {
                print("[VideoPlayer] Storage download failed for file_id=\(fileID): \(error.localizedDescription)")
            }
        }

        urlsToTry = mediaVideoURLs(video: video)
        if let resolved = await resolvePlayableURL() {
            play(url: resolved.url, index: resolved.index)
            return
        }

        if await playLocalFallbackIfPossible() {
            return
        }

        playbackError = "Не удалось открыть видео. Все URL вернули ошибку."
    }

    private func play(url: URL, index: Int) {
        cleanupObservers()
        currentURLIndex = index

        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer
        avPlayer.play()

        statusObserver = item.observe(\.status, options: [.new]) { _, _ in
            Task { @MainActor in
                guard let currentItem = player?.currentItem else { return }
                switch currentItem.status {
                case .readyToPlay:
                    playbackError = nil
                case .failed:
                    await tryNextURL()
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await tryNextURL()
            }
        }
    }

    @MainActor
    private func tryNextURL() async {
        let nextIndex = currentURLIndex + 1
        if nextIndex >= urlsToTry.count {
            if await playLocalFallbackIfPossible() {
                return
            }
            playbackError = "Видео не удалось воспроизвести. Перепробованы все URL."
            return
        }
        play(url: urlsToTry[nextIndex], index: nextIndex)
    }

    @MainActor
    private func playLocalFallbackIfPossible() async -> Bool {
        guard !attemptedLocalFallback else { return false }
        attemptedLocalFallback = true
        if let localURL = await resolveLocalFileURL() {
            play(url: localURL, index: 0)
            return true
        }
        return false
    }

    private func cleanupObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let itemFailedObserver {
            NotificationCenter.default.removeObserver(itemFailedObserver)
            self.itemFailedObserver = nil
        }
    }

    private func resolvePlayableURL() async -> (url: URL, index: Int)? {
        for (index, url) in urlsToTry.enumerated() {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 20
                request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200...299).contains(http.statusCode) || http.statusCode == 206 else { continue }

                let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let looksLikeVideoType = contentType.contains("video/") || contentType.contains("application/octet-stream")
                let containsFtyp = data.count >= 12 && String(data: data.subdata(in: 4..<12), encoding: .ascii)?.contains("ftyp") == true
                if looksLikeVideoType || containsFtyp {
                    return (url, index)
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func resolveLocalFileURL() async -> URL? {
        if let fileID = video.fileId {
            if let localURL = try? await APIClient.shared.downloadStorageVideoFile(
                fileID: fileID,
                fileName: video.fileName ?? video.file ?? video.name
            ) {
                return localURL
            }
        }

        let fileCandidates = [video.file, video.name, video.fileName, video.url, video.src]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("http://") && !$0.lowercased().hasPrefix("https://") }

        for file in fileCandidates {
            if let localURL = await APIClient.shared.downloadFile(path: "posts/videos", file: file) {
                return localURL
            }
            if let localURL = await APIClient.shared.downloadFile(path: "videos", file: file) {
                return localURL
            }
        }
        return nil
    }

    private func mediaVideoURLs(video: PostVideo) -> [URL] {
        var candidates: [URL] = []

        func appendCandidate(path rawPath: String?, file rawFile: String?) {
            guard var file = rawFile?.trimmingCharacters(in: .whitespacesAndNewlines), !file.isEmpty else { return }
            file = file.replacingOccurrences(of: "\\/", with: "/")
            file = file.replacingOccurrences(of: "\\", with: "/")
            if file.lowercased().hasPrefix("http://") || file.lowercased().hasPrefix("https://") {
                if let url = URL(string: file) { candidates.append(url) }
                return
            }

            let path = rawPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            var relative = file.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            relative = relative.replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
            if !relative.contains("/"), let path, !path.isEmpty {
                let cleanPath = path.replacingOccurrences(of: "^files/", with: "", options: .regularExpression)
                relative = "\(cleanPath)/\(relative)"
            }

            var components = URLComponents()
            components.scheme = "https"
            components.host = "elemsocial.com"
            components.path = "/files/\(relative)"
            if let url = components.url { candidates.append(url) }
        }

        appendCandidate(path: "posts/videos", file: video.url)
        appendCandidate(path: "posts/videos", file: video.src)
        appendCandidate(path: "posts/videos", file: video.file)
        appendCandidate(path: "posts/videos", file: video.name)
        appendCandidate(path: "posts/videos", file: video.fileName)
        appendCandidate(path: video.path, file: video.url)
        appendCandidate(path: video.path, file: video.src)
        appendCandidate(path: video.path, file: video.file)
        appendCandidate(path: video.path, file: video.name)
        appendCandidate(path: video.path, file: video.fileName)
        appendCandidate(path: "videos", file: video.url)
        appendCandidate(path: "videos", file: video.src)
        appendCandidate(path: "videos", file: video.file)
        appendCandidate(path: "videos", file: video.name)
        appendCandidate(path: "videos", file: video.fileName)
        appendCandidate(path: nil, file: video.url)
        appendCandidate(path: nil, file: video.src)
        appendCandidate(path: nil, file: video.file)
        appendCandidate(path: nil, file: video.name)
        appendCandidate(path: nil, file: video.fileName)

        var unique: [URL] = []
        var seen = Set<String>()
        for url in candidates where seen.insert(url.absoluteString).inserted {
            unique.append(url)
        }
        return unique
    }
}

struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = RotatingVideoPlayerController()
        controller.player = player
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.exitsFullScreenWhenPlaybackEnds = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

final class RotatingVideoPlayerController: AVPlayerViewController {
    override var shouldAutorotate: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}
