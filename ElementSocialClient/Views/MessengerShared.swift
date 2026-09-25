import SwiftUI
import ImageIO

// MARK: - Avatars

struct MessengerAvatarView: View {
    let media: MediaData?
    let name: String
    let size: CGFloat
    @State private var uiImage: UIImage?
    @State private var lastLoadedKey: String?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(AppTheme.primary.opacity(0.18))
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: media?.imageLoadKey) {
            await loadAvatarIfNeeded()
        }
    }

    private func loadAvatarIfNeeded() async {
        let key = media?.imageLoadKey ?? ""
        guard lastLoadedKey != key else { return }
        lastLoadedKey = key
        guard let media else {
            uiImage = nil
            return
        }

        if let cachedData = APIClient.shared.cachedMediaImageData(for: media, lossless: true),
           let cachedImage = UIImage(data: cachedData) {
            uiImage = cachedImage
            return
        }

        uiImage = nil

        if let data = await APIClient.shared.downloadMediaImage(media, lossless: true),
           let image = UIImage(data: data) {
            uiImage = image
        }
    }
}

struct MessengerSavesAvatarView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.primary)
            Image(systemName: "bookmark.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.42, height: size * 0.42)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Date parsing (shared with chat screen)

func parseMessengerDisplayDate(_ raw: String) -> Date {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = Double(trimmed) {
        let seconds = value > 9_999_999_999 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: trimmed) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: trimmed) ?? Date()
}

// MARK: - Fullscreen zoomable image (used by image attachments)

struct NativeChatImageZoom: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> ChatImageZoomViewController {
        ChatImageZoomViewController(image: image)
    }

    func updateUIViewController(_ uiViewController: ChatImageZoomViewController, context: Context) {
        uiViewController.update(image: image)
    }
}

final class ChatImageZoomViewController: UIViewController, UIScrollViewDelegate {
    private var currentImage: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage) {
        self.currentImage = image
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black

        imageView.contentMode = .scaleAspectFit
        imageView.image = currentImage

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
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

    func update(image: UIImage) {
        currentImage = image
        imageView.image = image
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }

    private func centerImageView() {
        let boundsSize = scrollView.bounds.size
        var frameToCenter = imageView.frame
        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
        } else {
            frameToCenter.origin.x = 0
        }
        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
        } else {
            frameToCenter.origin.y = 0
        }
        imageView.frame = frameToCenter
    }
}
