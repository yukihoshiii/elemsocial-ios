import UIKit
import SwiftUI

enum EmojiTextSegment {
    case text(String)
    case attributed(AttributedString)
    case emoji(UIImage)
}

final class EmojiHelper {
    static let shared = EmojiHelper()

    private let cache = NSCache<NSString, UIImage>()
    private var emojiToUnified: [String: String] = [:]
    private var isLoaded = false

    private init() {
        loadEmojiMappings()
    }

    private func loadEmojiMappings() {
        guard let url = Bundle.main.url(forResource: "Emoji", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.main.url(forResource: "Emoji", withExtension: "json")
            ?? Bundle.main.url(forResource: "Emoji.json", withExtension: nil) else {
            return
        }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        for categoryMap in json {
            for (_, subList) in categoryMap {
                guard let items = subList as? [[String: Any]] else { continue }
                for item in items {
                    if let emoji = item["emoji"] as? String, let unified = item["unified"] as? String {
                        emojiToUnified[emoji] = unified.lowercased()
                    }
                }
            }
        }
        isLoaded = true
    }

    func unified(for emoji: String) -> String {
        if let direct = emojiToUnified[emoji] {
            return direct
        }

        let hex = emoji.unicodeScalars
            .map { String(format: "%x", $0.value) }
            .joined(separator: "-")
        return hex.lowercased()
    }

    func image(for emoji: String, pointSize: CGFloat = 18) -> UIImage? {
        let cacheKey = "\(emoji)_\(Int(pointSize))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let unifiedCode = unified(for: emoji)

        let candidates = [
            unifiedCode,
            unifiedCode.replacingOccurrences(of: "-fe0f", with: ""),
            unifiedCode.replacingOccurrences(of: "-fe0e", with: ""),
            "\(unifiedCode)-fe0f",
            "emoji_\(unifiedCode)"
        ]

        var loadedRaw: UIImage? = nil
        let bundlePath = Bundle.main.bundlePath

        let subdirCandidates = [
            "Emoji/Apple",
            "Resources/Emoji/Apple",
            "Apple"
        ]

        for code in candidates {
            // Try Assets catalog first
            if let img = UIImage(named: code) ?? UIImage(named: "emoji_\(code)") {
                loadedRaw = img
                break
            }

            // Try Bundle subdirectories (folder reference copies to bundle root)
            for subdir in subdirCandidates {
                let path = "\(bundlePath)/\(subdir)/\(code).png"
                if FileManager.default.fileExists(atPath: path), let img = UIImage(contentsOfFile: path) {
                    loadedRaw = img
                    break
                }
            }
            if loadedRaw != nil { break }

            // Bundle.main.url approach
            if let imageURL = Bundle.main.url(forResource: code, withExtension: "png", subdirectory: "Emoji/Apple")
                ?? Bundle.main.url(forResource: code, withExtension: "png", subdirectory: "Resources/Emoji/Apple")
                ?? Bundle.main.url(forResource: code, withExtension: "png") {
                if let img = UIImage(contentsOfFile: imageURL.path) {
                    loadedRaw = img
                    break
                }
            }
        }

        guard let raw = loadedRaw else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize), format: format)
        let scaled = renderer.image { _ in
            raw.draw(in: CGRect(x: 0, y: 0, width: pointSize, height: pointSize))
        }

        cache.setObject(scaled, forKey: cacheKey)
        return scaled
    }

    func parseSegments(from string: String, pointSize: CGFloat = 18) -> [EmojiTextSegment] {
        guard !string.isEmpty else { return [] }

        var segments: [EmojiTextSegment] = []
        var currentText = ""

        for character in string {
            let sub = String(character)
            // Quick filter: must contain at least one emoji or high unicode scalar
            let isEmojiCandidate = character.unicodeScalars.contains { scalar in
                scalar.properties.isEmoji && (
                    scalar.value > 0x2000 || // Avoid plain ASCII emoji-capable chars (*, #, 0-9)
                    character.unicodeScalars.count > 1  // Multi-scalar = definitely emoji sequence
                )
            }

            if isEmojiCandidate, let emojiImg = image(for: sub, pointSize: pointSize) {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                segments.append(.emoji(emojiImg))
            } else {
                currentText.append(character)
            }
        }

        if !currentText.isEmpty {
            segments.append(.text(currentText))
        }

        return segments
    }

    func renderText(from string: String, pointSize: CGFloat = 18) -> Text {
        let segments = parseSegments(from: string, pointSize: pointSize)
        guard !segments.isEmpty else { return Text(string) }

        var combined = Text("")
        for segment in segments {
            switch segment {
            case .text(let str):
                combined = combined + Text(str)
            case .attributed(let attr):
                combined = combined + Text(attr)
            case .emoji(let image):
                combined = combined + Text(Image(uiImage: image))
            }
        }
        return combined
    }
}

struct EmojiText: View {
    let text: String
    var pointSize: CGFloat = 15

    var body: some View {
        EmojiHelper.shared.renderText(from: text, pointSize: pointSize)
    }
}
