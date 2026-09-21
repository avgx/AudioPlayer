import AVFoundation
import Combine
import MediaPlayer
import Network
import OSLog
import UIKit

/// Internet-radio player for MP3 / AAC / AAC+ streams.
///
/// Features:
/// - Single source of truth for playback (`state`)
/// - Explicit `play` / `pause` / `stop` (no Combine binding to a station manager)
/// - Lock Screen next / previous via an optional `StreamList`
/// - ICY metadata through `AVPlayerItemMetadataOutput`
/// - Start timeout and automatic retry
/// - Buffering via `timeControlStatus`
/// - Network reachability (pause / restore)
/// - Sleep timer
/// - Now Playing (title = station, artist = track)
/// - Approximate traffic via access log
@MainActor
public final class AudioPlayer: NSObject, ObservableObject {

    // MARK: - State

    /// Playback state derived from AVPlayer and explicit commands.
    public enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    /// Current playback state.
    @Published public private(set) var state: State = .idle
    /// Track title parsed from ICY metadata, when available.
    @Published public private(set) var song: String?
    /// Artist parsed from ICY metadata, when available.
    @Published public private(set) var artist: String?
    /// Stream currently loaded or last requested.
    @Published public private(set) var currentStream: AudioStream?
    /// Last human-readable error, if any.
    @Published public private(set) var lastError: String?

    // MARK: - Private

    private weak var playlist: StreamList?

    private var player: AVPlayer?
    private var item: AVPlayerItem?

    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: NSKeyValueObservation?

    private var metadataOutput: AVPlayerItemMetadataOutput?
    private let metadataQueue = DispatchQueue(label: "audioplayer.metadata.queue")

    private var startTimeoutTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?

    private var currentRequestID = UUID()
    private var wantsPlayback = false

    private let monitor = NWPathMonitor()
    private let log = Logger(subsystem: "AudioPlayer", category: "playback")

    /// Image used when the stream has no artwork of its own.
    private var fallbackArtwork: UIImage?

    // MARK: - Init

    public override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        startNetworkMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Public API

    /// Starts or resumes the given stream.
    ///
    /// Reuses the existing player when the same URL is already loaded and paused.
    /// Restarts the item when the URL changes or the previous attempt failed.
    public func play(_ stream: AudioStream) {
        wantsPlayback = true
        lastError = nil

        if currentStream?.url == stream.url, state == .paused, player != nil {
            currentStream = stream
            refreshNowPlayingArtwork(stream.artwork)
            player?.play()
            log.info("Resuming \(stream.name, privacy: .public)")
            return
        }

        if currentStream?.url == stream.url, state == .playing || state == .loading {
            if stream.artwork != nil {
                currentStream = stream
                updateArtwork(stream.artwork)
            }
            log.debug("Already playing or loading \(stream.name, privacy: .public)")
            return
        }

        start(stream)
    }

    /// Pauses the current stream without clearing Now Playing.
    public func pause() {
        wantsPlayback = false
        retryTask?.cancel()
        player?.pause()
        log.info("Paused")
    }

    /// Stops playback, releases the player, and clears Now Playing.
    public func stop() {
        wantsPlayback = false
        player?.pause()
        reset()
        currentStream = nil
        setState(.idle)
        clearNowPlaying()
        log.info("Stopped")
    }

    /// Sets the fallback artwork used when a stream has no image.
    public func setFallbackArtwork(_ image: UIImage?) {
        fallbackArtwork = image
        if currentStream?.artwork == nil {
            refreshNowPlayingArtwork(nil)
        }
    }

    /// Replaces artwork on the current stream and refreshes Now Playing.
    public func updateArtwork(_ image: UIImage?) {
        guard let currentStream else { return }
        self.currentStream = AudioStream(
            name: currentStream.name,
            url: currentStream.url,
            artwork: image
        )
        refreshNowPlayingArtwork(image)
    }

    /// Attaches a playlist used by Lock Screen next / previous commands.
    public func attach(playlist: StreamList?) {
        self.playlist = playlist
    }

    /// Stops playback after the given number of seconds.
    public func sleep(after seconds: TimeInterval) {
        sleepTask?.cancel()
        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            stop()
        }
    }

    /// Cancels a pending sleep timer.
    public func cancelSleep() {
        sleepTask?.cancel()
        sleepTask = nil
    }

    /// Approximate indicated bitrate in bits per second from the access log.
    public func currentBitrate() -> Double? {
        player?.currentItem?.accessLog()?.events.last?.indicatedBitrate
    }

    /// Approximate number of bytes transferred from the access log.
    public func totalBytes() -> Int64? {
        player?.currentItem?.accessLog()?.events.last?.numberOfBytesTransferred
    }

    // MARK: - Core

    private func start(_ stream: AudioStream) {
        reset()

        let requestID = UUID()
        currentRequestID = requestID
        currentStream = stream

        setState(.loading)
        setupTimeout(requestID: requestID)

        log.info("Starting \(stream.name, privacy: .public) \(stream.url.absoluteString, privacy: .public)")

        let item = AVPlayerItem(url: stream.url)
        self.item = item

        setupMetadata(item)
        observeStatus(item, requestID: requestID)

        let player = AVPlayer(playerItem: item)
        self.player = player

        observeTimeControl(player)
        player.play()

        updateNowPlaying(station: stream.name, track: nil, artwork: stream.artwork)
    }

    private func restartCurrent() {
        guard let stream = currentStream else { return }
        start(stream)
    }

    // MARK: - Retry

    private func retry() {
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard wantsPlayback, currentStream != nil else { return }
            switch state {
            case .failed, .paused:
                log.info("Retrying current stream")
                restartCurrent()
            default:
                break
            }
        }
    }

    // MARK: - Observers

    private func observeStatus(_ item: AVPlayerItem, requestID: UUID) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.currentRequestID == requestID else { return }
                if item.status == .failed {
                    self.fail(self.mapError(item.error))
                }
            }
        }
    }

    private func observeTimeControl(_ player: AVPlayer) {
        timeObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            Task { @MainActor in
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    self.setState(.loading)
                case .playing:
                    self.setState(.playing)
                case .paused:
                    switch self.state {
                    case .failed, .idle:
                        break
                    default:
                        self.setState(.paused)
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Metadata

    private func setupMetadata(_ item: AVPlayerItem) {
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: metadataQueue)
        item.add(output)
        metadataOutput = output
    }

    private func processMetadata(identifier: String?, value: String?, data: Data?) {
        if identifier == "icy/StreamTitle", let value {
            parseICY(value)
            return
        }

        if identifier == AVMetadataIdentifier.commonIdentifierArtwork.rawValue,
           let data,
           let image = UIImage(data: data) {
            log.debug("Received ICY artwork \(image.size.width, format: .fixed)x\(image.size.height, format: .fixed)")
            updateArtwork(image)
        }
    }

    /// Parses an ICY title of the form "Artist - Track".
    private func parseICY(_ title: String) {
        let cleaned = title.replacingOccurrences(
            of: #"^.*?:\s*"#,
            with: "",
            options: .regularExpression
        )

        let parts = cleaned.split(separator: "-", maxSplits: 1)
        let artist = parts.first?.trimmingCharacters(in: .whitespaces)
        let song = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil

        self.artist = artist
        self.song = song

        let track = [artist, song].compactMap { $0 }.joined(separator: " - ")
        updateNowPlayingTrack(track)
    }

    // MARK: - Errors

    private func fail(_ message: String) {
        lastError = message
        setState(.failed(message))
        log.error("Playback failed: \(message, privacy: .public)")
        retry()
    }

    private func mapError(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "Unknown error" }
        switch error.code {
        case -1003: return "DNS error"
        case -1004: return "No connection"
        case -1009: return "The Internet connection appears to be offline"
        case -1202: return "SSL error"
        case -12660: return "Access denied"
        case -12938: return "Not found"
        default: return error.localizedDescription
        }
    }

    // MARK: - Network

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .unsatisfied {
                    self.player?.pause()
                    if self.state == .playing || self.state == .loading {
                        self.setState(.paused)
                        self.log.warning("Network lost, paused")
                    }
                } else if self.wantsPlayback, self.currentStream != nil {
                    switch self.state {
                    case .failed, .paused:
                        self.retry()
                    default:
                        break
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue.global())
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            log.error("Audio session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Remote Commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let stream = self.currentStream else { return }
                self.play(stream)
            }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let stream = self.playlist?.nextStream() else { return }
                self.play(stream)
            }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let stream = self.playlist?.previousStream() else { return }
                self.play(stream)
            }
            return .success
        }
    }

    // MARK: - State

    private func setState(_ new: State) {
        if state != new {
            log.debug("State \(String(describing: self.state), privacy: .public) → \(String(describing: new), privacy: .public)")
        }
        state = new
    }

    private func reset() {
        startTimeoutTask?.cancel()
        retryTask?.cancel()

        statusObserver?.invalidate()
        timeObserver?.invalidate()
        statusObserver = nil
        timeObserver = nil

        if let metadataOutput, let item {
            item.remove(metadataOutput)
        }
        metadataOutput = nil

        player = nil
        item = nil
        song = nil
        artist = nil
    }

    // MARK: - Timeout

    private func setupTimeout(requestID: UUID) {
        startTimeoutTask?.cancel()
        startTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            guard currentRequestID == requestID else { return }
            if case .loading = state {
                fail("Connection timeout")
            }
        }
    }

    // MARK: - Now Playing

    private func updateNowPlaying(station: String, track: String?, artwork: UIImage?) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = station
        info[MPMediaItemPropertyArtist] = track
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        applyArtwork(artwork, to: &info)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTrack(_ track: String?) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtist] = track
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlayingArtwork(_ artwork: UIImage?) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        applyArtwork(artwork, to: &info)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func applyArtwork(_ artwork: UIImage?, to info: inout [String: Any]) {
        if let artwork = artwork ?? fallbackArtwork, let cgImage = artwork.cgImage {
            info[MPMediaItemPropertyArtwork] = makeArtwork(cgImage: cgImage, size: artwork.size)
        }
    }

    nonisolated private func makeArtwork(cgImage: CGImage, size: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { size in
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

// MARK: - Metadata Delegate

extension AudioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    /// Receives timed metadata batches from AVFoundation and hops to the main actor.
    nonisolated public func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        for group in groups {
            for item in group.items {
                let identifier = item.identifier?.rawValue
                let stringValue = item.stringValue
                let dataValue = item.dataValue
                Task { @MainActor in
                    self.processMetadata(identifier: identifier, value: stringValue, data: dataValue)
                }
            }
        }
    }
}
