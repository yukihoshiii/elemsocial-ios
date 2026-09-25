import AVFoundation

final class NotificationSoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = NotificationSoundPlayer()

    private let session = AVAudioSession.sharedInstance()
    private var sessionConfigured = false
    private var player: AVAudioPlayer?

    private override init() {
        super.init()
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        do {
            try session.setCategory(.ambient, options: [.duckOthers])
            sessionConfigured = true
        } catch {
            #if DEBUG
            print("[Sound] Failed to configure audio session: \(error.localizedDescription)")
            #endif
        }
    }

    func playNotificationSound() {
        DispatchQueue.main.async {
            self.configureSessionIfNeeded()
            do {
                try self.session.setActive(true, options: [.notifyOthersOnDeactivation])
            } catch {
                #if DEBUG
                print("[Sound] Failed to activate audio session: \(error.localizedDescription)")
                #endif
            }

            if self.player == nil {
                self.player = self.makePlayer()
            }

            guard let player = self.player else { return }
            if player.isPlaying {
                player.stop()
            }
            player.currentTime = 0
            player.prepareToPlay()
            if !player.play() {
                self.player = self.makePlayer()
                self.player?.play()
            }
        }
    }

    private func makePlayer() -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: "Notification", withExtension: "mp3") else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.5
            player.delegate = self
            return player
        } catch {
            #if DEBUG
            print("[Sound] Failed to initialize notification player: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        #if DEBUG
        print("[Sound] Decode error: \(error?.localizedDescription ?? "unknown")")
        #endif
        self.player = nil
        deactivateSessionIfPossible()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        deactivateSessionIfPossible()
    }

    private func deactivateSessionIfPossible() {
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            #if DEBUG
            print("[Sound] Failed to deactivate audio session: \(error.localizedDescription)")
            #endif
        }
    }
}
