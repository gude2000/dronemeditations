import Foundation
import MediaPlayer
import UIKit

/// Bridges DroneController state to MPNowPlayingInfoCenter (lock screen +
/// Control Center widget) and registers MPRemoteCommandCenter handlers so
/// the user can play / pause / stop from outside the app.
///
/// We don't have a "real" track length, so the lock-screen scrubber shows
/// session elapsed vs sessionDuration (when set; otherwise just elapsed).
@MainActor
final class NowPlayingBridge {
    private weak var controller: DroneController?
    private weak var vm: DroneViewModel?
    private var handlersRegistered = false

    init(controller: DroneController, vm: DroneViewModel) {
        self.controller = controller
        self.vm = vm
        registerRemoteCommands()
        refresh()
    }

    /// Push the current transport + preset state to MPNowPlayingInfoCenter.
    /// Call whenever play/pause/stop/preset/elapsed changes.
    func refresh() {
        guard let controller = controller else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = vm?.activePresetName ?? "Drone Meditations"
        info[MPMediaItemPropertyArtist] = "Drone Meditations"
        info[MPMediaItemPropertyAlbumTitle] = "Continuous Tone"
        info[MPMediaItemPropertyPlaybackDuration] =
            controller.sessionDuration > 0 ? controller.sessionDuration : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = controller.elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = (controller.state == .playing) ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = controller.sessionDuration == 0

        // App icon as artwork if we can load it from the bundle.
        if let img = UIImage(named: "AppIcon") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Wire play/pause/stop on the remote-command center so lock-screen
    /// transport buttons (and the EarPods button, AirPods squeeze, AirPlay
    /// remote, CarPlay) all route into our controller.
    private func registerRemoteCommands() {
        guard !handlersRegistered else { return }
        handlersRegistered = true

        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            guard let controller = self?.controller else { return .commandFailed }
            controller.play()
            self?.refresh()
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let controller = self?.controller else { return .commandFailed }
            controller.pause()
            self?.refresh()
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let controller = self?.controller else { return .commandFailed }
            if controller.state == .playing { controller.pause() } else { controller.play() }
            self?.refresh()
            return .success
        }
        cc.stopCommand.addTarget { [weak self] _ in
            guard let controller = self?.controller else { return .commandFailed }
            controller.stop()
            self?.refresh()
            return .success
        }

        // Skip forward/back aren't meaningful for a continuous drone — disable
        // them so the lock-screen UI doesn't show ghost buttons.
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false
        cc.seekForwardCommand.isEnabled = false
        cc.seekBackwardCommand.isEnabled = false
        cc.changePlaybackPositionCommand.isEnabled = false
    }
}
