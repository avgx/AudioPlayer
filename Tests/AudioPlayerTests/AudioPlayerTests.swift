import Testing
import UIKit
@testable import AudioPlayer

@Test func audioStreamEqualityIgnoresArtwork() {
    let url = URL(string: "https://example.com/stream.mp3")!
    let left = AudioStream(name: "Jazz", url: url, artwork: UIImage())
    let right = AudioStream(name: "Jazz", url: url, artwork: nil)
    #expect(left == right)
}

@Test func audioStreamInequalityUsesNameAndURL() {
    let left = AudioStream(name: "Jazz", url: URL(string: "https://example.com/a.mp3")!)
    let right = AudioStream(name: "Jazz", url: URL(string: "https://example.com/b.mp3")!)
    #expect(left != right)
}

@MainActor
@Test func playerStartsIdle() {
    let player = AudioPlayer()
    #expect(player.state == .idle)
    #expect(player.currentStream == nil)
    #expect(player.lastError == nil)
}

@MainActor
@Test func stopClearsCurrentStream() {
    let player = AudioPlayer()
    player.stop()
    #expect(player.state == .idle)
    #expect(player.currentStream == nil)
}
