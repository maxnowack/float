import AppKit
import Foundation

@MainActor
protocol PiPControlling: AnyObject {
    var onPictureInPictureClosed: (() -> Void)? { get set }
    var onPlaybackCommand: ((Bool) -> Void)? { get set }
    var onSeekCommand: ((Double) -> Void)? { get set }

    func setContentView(_ view: NSView)
    func requestStart()
    func stop()
    func updateExpectedVideoSize(_ size: CGSize)
    func updatePlaybackState(_ isPlaying: Bool)
    func updatePlaybackProgress(elapsedSeconds: Double?, durationSeconds: Double?)
}

enum PiPControllerFactory {
    @MainActor
    static func makeController() -> PiPControlling {
        print("[Float PiP] using AVKit sample-buffer backend")
        return NativePiPController()
    }
}
