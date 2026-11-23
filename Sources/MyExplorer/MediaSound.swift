// SPDX-License-Identifier: Apache-2.0
import AVFoundation

/// The sound state of the media players, kept from one video to the next and across launches:
/// a video closed with the sound off opens the next one with the sound off, and the other way round.
enum MediaSound {
    private static let mutedKey = "media.sound.muted"
    private static let volumeKey = "media.sound.volume"

    static func apply(to player: AVPlayer, defaults: UserDefaults = .standard) {
        player.isMuted = defaults.bool(forKey: mutedKey)
        if let volume = defaults.object(forKey: volumeKey) as? Double, volume.isFinite {
            player.volume = Float(min(1, max(0, volume)))
        }
    }

    /// Saves every change the person makes with the player's own controls. The caller keeps the
    /// observations for as long as the player is on screen.
    static func follow(_ player: AVPlayer, defaults: UserDefaults = .standard) -> [NSKeyValueObservation] {
        [player.observe(\.isMuted, options: [.new]) { player, _ in defaults.set(player.isMuted, forKey: mutedKey) },
         player.observe(\.volume, options: [.new]) { player, _ in defaults.set(Double(player.volume), forKey: volumeKey) }]
    }
}
