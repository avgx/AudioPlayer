import Foundation

/// A playlist the player can ask for the next or previous stream.
///
/// Used by Lock Screen / Control Center skip commands. The player does not own library state.
@MainActor
public protocol StreamList: AnyObject {
    /// Returns the next stream and updates the list's current selection, or `nil` if none.
    func nextStream() -> AudioStream?

    /// Returns the previous stream and updates the list's current selection, or `nil` if none.
    func previousStream() -> AudioStream?
}
