import Foundation
import AVFoundation
import UIKit

/// Voice + video-circle recorder for the chat bottom bar.
/// Mirrors the web BottomBar recording flow: hold to record,
/// slide up to lock, 60 s hard limit for circles.
@MainActor
final class ChatRecorderController: NSObject, ObservableObject {

    enum Mode {
        case voice
        case videoCircle
    }

    struct VoiceResult {
        let url: URL
        let duration: Double
        let waveform: [Double]
    }

    struct CircleResult {
        let url: URL
        let duration: Double
        let thumbnailDataURL: String?
    }

    @Published private(set) var isRecording = false
    @Published var mode: Mode = .voice
    @Published private(set) var elapsed: Int = 0
    @Published private(set) var audioLevel: Double = 0

    var onFinishVoice: ((VoiceResult?) -> Void)?
    var onFinishCircle: ((CircleResult?) -> Void)?
    var onStart: (() -> Void)?

    private var audioRecorder: AVAudioRecorder?
    private var recordingFileURL: URL?
    private var tickTask: Task<Void, Never>?

    // Video capture
    private let captureSession = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var captureConfigured = false

    static let maxDuration: TimeInterval = 60

    // MARK: - Voice

    func startVoice() {
        guard !isRecording else { return }
        mode = .voice
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice_\(Int(Date().timeIntervalSince1970 * 1000)).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            audioRecorder = recorder
            recordingFileURL = url
            beginTracking()
            onStart?()
        } catch {
            finishVoice(success: false)
        }
    }

    func startCircle() async -> Bool {
        guard !isRecording else { return false }
        mode = .videoCircle
        guard await configureCaptureIfNeeded(), requestAccess() else { return false }

        movieOutput.maxRecordedDuration = CMTime(seconds: Self.maxDuration, preferredTimescale: 600)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("circle_\(Int(Date().timeIntervalSince1970 * 1000)).mov")
        recordingFileURL = url
        movieOutput.startRecording(to: url as URL, recordingDelegate: self)
        beginTracking()
        onStart?() // «записывает видео» — web sends start for circles too
        return true
    }

    func stop() {
        switch mode {
        case .voice:
            finishVoice(success: true)
        case .videoCircle:
            movieOutput.stopRecording()
        }
    }

    func cancel() {
        switch mode {
        case .voice:
            finishVoice(success: false)
        case .videoCircle:
            movieOutput.stopRecording()
            isCancelledByUser = true
        }
    }

    private var isCancelledByUser = false

    private func beginTracking() {
        isRecording = true
        elapsed = 0
        audioLevel = 0
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, self.isRecording, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.elapsed += 1

                if self.mode == .voice, let rec = self.audioRecorder {
                    rec.updateMeters()
                    let power = rec.averagePower(forChannel: 0)
                    self.audioLevel = Double(max(0, min(1, (power + 50) / 50)))
                }

                if Double(self.elapsed) >= Self.maxDuration {
                    self.stop()
                }
            }
        }
    }

    private func teardownTracking() {
        isRecording = false
        audioLevel = 0
        tickTask?.cancel()
        tickTask = nil
    }

    private func finishVoice(success: Bool) {
        guard let recorder = audioRecorder else { return }
        recorder.stop()
        audioRecorder = nil
        let url = recordingFileURL
        let seconds = elapsed
        teardownTracking()

        guard success, let url, seconds >= 1 else {
            try? FileManager.default.removeItem(at: url ?? URL(fileURLWithPath: "/dev/null"))
            onFinishVoice?(nil)
            return
        }

        let duration = AudioWaveformAnalyzer.duration(of: url) ?? Double(seconds)
        let waveform = AudioWaveformAnalyzer.generateWaveform(from: url) ?? Array(repeating: 0.08, count: 30)
        onFinishVoice?(VoiceResult(url: url, duration: duration, waveform: waveform))
    }

    // MARK: - Capture plumbing

    private func requestAccess() -> Bool {
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if camStatus == .denied || micStatus == .denied { return false }
        return true
    }

    private func configureCaptureIfNeeded() async -> Bool {
        if captureConfigured && !captureSession.inputs.isEmpty { return true }

        // Web getUserMedia({video, audio}) fails unless BOTH are granted.
        let granted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await AVCaptureDevice.requestAccess(for: .video) }
            group.addTask { await AVCaptureDevice.requestAccess(for: .audio) }
            return await group.reduce(true) { $0 && $1 }
        }
        guard granted else { return false }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: camera),
           captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }
        captureSession.commitConfiguration()
        captureConfigured = true

        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [captureSession] in
                captureSession.startRunning()
            }
        }
        return !captureSession.inputs.isEmpty
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [captureSession] in
                captureSession.startRunning()
            }
        }
        return layer
    }

    func shutdownCapture() {
        if captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [captureSession] in
                captureSession.stopRunning()
            }
        }
    }

    private func handleMovie(url: URL, error: Error?) {
        let cancelled = isCancelledByUser || elapsed < 1
        let seconds = elapsed
        teardownTracking()
        isCancelledByUser = false

        if error != nil || cancelled {
            try? FileManager.default.removeItem(at: url)
            onFinishCircle?(nil)
            return
        }

        Task { [weak self] in
            let mp4URL = await VideoCircleExporter.convertToMP4(source: url)
            let duration = await VideoCircleExporter.duration(of: mp4URL) ?? Double(seconds)
            let thumb = await VideoCircleExporter.thumbnailDataURL(for: mp4URL)
            await MainActor.run { [weak self] in
                self?.onFinishCircle?(CircleResult(url: mp4URL, duration: duration, thumbnailDataURL: thumb))
            }
        }
    }
}

extension ChatRecorderController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleMovie(url: outputFileURL, error: error)
        }
    }
}

// MARK: - Waveform analysis (web `generateWaveform` port)

enum AudioWaveformAnalyzer {
    /// 30 bars, noise gate 0.015, normalized to peak, floor 0.1.
    static func generateWaveform(from url: URL) -> [Double]? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return nil
        }

        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(totalFrames, 4_000_000)) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)

        let bars = 30
        let noiseGate = 0.015
        let blockSize = max(1, frameCount / bars)
        var peaks: [Double] = []

        for i in 0..<bars {
            var peak: Double = 0
            let start = i * blockSize
            let step = max(1, blockSize / 200)
            if start >= frameCount { peaks.append(0); continue }
            let end = min(start + blockSize, frameCount)
            var j = start
            while j < end {
                let v = abs(Double(channelData[j]))
                if v > peak { peak = v }
                j += step
            }
            peaks.append(peak < noiseGate ? 0 : peak)
        }

        let maxPeak = peaks.max() ?? 0.01
        let effectiveMax = Swift.max(maxPeak, 0.01)
        return peaks.map { $0 == 0 ? 0 : Swift.max(0.1, $0 / effectiveMax) }
    }

    static func duration(of url: URL) -> Double? {
        let file = try? AVAudioFile(forReading: url)
        guard let file else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

// MARK: - Video circle helpers

enum VideoCircleExporter {
    /// Re-muxes the QuickTime capture into an MP4 so browsers can play it too.
    static func convertToMP4(source: URL) async -> URL {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return source
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("circle_\(UUID().uuidString).mp4")
        export.outputURL = target
        export.outputFileType = .mp4
        await export.export()
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: source)
            return target
        }
        return source
    }

    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        let seconds = try? await asset.load(.duration)
        return seconds.map { CMTimeGetSeconds($0) }
    }

    /// Center-cropped square JPEG data URL (web: canvas.toDataURL('image/jpeg', 0.3)).
    static func thumbnailDataURL(for url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let croppedRect = CGRect(origin: origin, size: CGSize(width: side, height: side))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 150, height: 150), format: format)
        let square = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 150, height: 150).insetBy(dx: -origin.x * (150 / side), dy: -origin.y * (150 / side)))
        }
        _ = croppedRect
        guard let jpeg = square.jpegData(compressionQuality: 0.35) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}
