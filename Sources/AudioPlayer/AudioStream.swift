import UIKit

/// A playable internet-radio stream.
///
/// Artwork is optional; the player falls back to its configured image when `artwork` is `nil`.
public struct AudioStream: Equatable, @unchecked Sendable {
    /// Display name shown as Now Playing title.
    public let name: String
    /// Stream URL (MP3 / AAC / AAC+).
    public let url: URL
    /// Optional station artwork for Lock Screen / Control Center.
    public let artwork: UIImage?

    /// Creates a stream description.
    /// - Parameters:
    ///   - name: Display name of the station or stream.
    ///   - url: Audio stream URL.
    ///   - artwork: Optional artwork. Pass `nil` to use the player's fallback image.
    public init(name: String, url: URL, artwork: UIImage? = nil) {
        self.name = name
        self.url = url
        self.artwork = artwork
    }

    public static func == (lhs: AudioStream, rhs: AudioStream) -> Bool {
        lhs.name == rhs.name && lhs.url == rhs.url
    }
}
