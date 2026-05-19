//
//  AVPlayerManager.swift
//  FloatNative
//
//  Advanced video player manager with background audio and PIP support
//  Created by Claude on 2025-10-08.
//

import AVKit
import AVFoundation
import Combine
import SwiftUI
import MediaPlayer
import MediaAccessibility

// MARK: - Player State

enum PlayerState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case failed(Error)

    static func == (lhs: PlayerState, rhs: PlayerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.loading, .loading),
             (.playing, .playing),
             (.paused, .paused),
             (.buffering, .buffering):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
}

// MARK: - AVPlayer Manager

@MainActor
class AVPlayerManager: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = AVPlayerManager()

    // MARK: - Published Properties

    @Published private(set) var player: AVPlayer?
    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var availableQualities: [QualityVariant] = []
    @Published private(set) var currentQuality: QualityVariant?

    // Captions (GH #11). The synthetic-master HLS path didn't survive
    // AVPlayer's parser, so we render captions ourselves as a SwiftUI
    // overlay driven by currentTime + cues. The CC button in the player
    // chrome toggles `captionsEnabled`.
    @Published private(set) var captionCues: [VTTCue] = []
    @Published var captionsEnabled: Bool = false

    /// Cached system caption preference. We seed `captionsEnabled` from
    /// this when loading a video that has captions, so users with system
    /// captions on don't have to tap the in-app CC button on every video.
    static var systemCaptionsEnabled: Bool {
        MACaptionAppearanceGetDisplayType(.user) != .automatic
    }

    // MARK: - PIP State (managed by CustomVideoPlayer)

    @Published var isPIPActive = false // True only while PiP window is actively displayed
    @Published var isPIPSupported = true // AVPlayerViewController always supports PiP if device supports it

    // Track if we have a PiP session that can be restored (true even when paused)
    // This stays true as long as playerViewController/delegate are stored for restoration
    @Published var hasPIPSession = false

    // Keep playerViewController and its delegate alive during PiP
    // This prevents the delegate from being deallocated when the view is popped
    var playerViewController: AVPlayerViewController?
    var playerViewControllerDelegate: NSObject? // Stores the Coordinator

    /// True while AVPlayerViewController is mid-transition into or out of its
    /// own native fullscreen presentation. Used by VideoPlayerView.onDisappear
    /// to skip the singleton-player teardown: during fullscreen the host
    /// SwiftUI view sometimes fires .onDisappear, but the player is still
    /// being shown by AVPlayerViewController's modal — resetting it would
    /// black the screen with a PlayerRemoteXPC -12860 error.
    var isInFullScreenTransition: Bool = false

    // MARK: - Current Video Info

    private(set) var currentVideoId: String?
    private(set) var currentVideoTitle: String?
    @Published var currentPost: BlogPost?
    @Published var shouldRestoreVideoPlayer: Bool = false
    private(set) var isLiveStream: Bool = false

    // MARK: - Observers

    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var itemObserver: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var progressTimer: DispatchSourceTimer?
    private var backgroundObserver: NSObjectProtocol?
    private var videoEndObserver: NSObjectProtocol?

    // MARK: - Buffer State

    @Published private(set) var isBuffering = false
    @Published private(set) var bufferProgress: Double = 0
    private var lastBufferUpdate: TimeInterval = 0

    // MARK: - Audio Session

    private let audioSession = AVAudioSession.sharedInstance()

    // MARK: - Persisted Playback Rate

    /// UserDefaults-backed playback rate that sticks across videos and app
    /// launches. Mirrors what YouTube / the official Floatplane app do.
    private static let playbackRateKey = "playbackRate"
    static let availablePlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var persistedPlaybackRate: Float {
        get {
            let raw = UserDefaults.standard.float(forKey: Self.playbackRateKey)
            return raw > 0 ? raw : 1.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.playbackRateKey)
            objectWillChange.send()
        }
    }

    private var rateObservation: NSKeyValueObservation?

    // MARK: - Initialization

    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommandCenter()
        setupBackgroundObserver()
    }

    // MARK: - Audio Session Setup

    private func setupAudioSession() {
        do {
            // Configure audio session for background playback (needed for
            // PiP and AirPlay to behave correctly).
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            print("⚠️ Failed to setup audio session: \(error)")
        }
    }

    // MARK: - Remote Command Center (Lock Screen Controls)

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        // Skip forward
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(by: 15)
            return .success
        }

        // Skip backward
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(by: -15)
            return .success
        }

        // Seek command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    // MARK: - Background & Lifecycle Observers

    private func setupBackgroundObserver() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.saveProgress()
            }
        }
    }

    private func setupVideoEndObserver() {
        guard let playerItem = player?.currentItem else { return }

        videoEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.saveProgress()
            }
        }
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = currentVideoTitle ?? "Floatplane Video"
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player?.rate ?? 0

        // TODO: Add artwork from thumbnail
        // if let thumbnail = currentThumbnail {
        //     nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(...)
        // }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Load Video

    func loadVideo(
        videoId: String,
        title: String,
        post: BlogPost? = nil,
        startTime: Double = 0,
        qualities: [QualityVariant],
        isLive: Bool = false,
        // Caption cues parsed from Floatplane's WebVTT (GH #11). Stored on
        // the manager so CaptionsOverlayView can render the active cue based
        // on currentTime. Empty for videos without captions.
        captionCues: [VTTCue] = []
    ) async throws {
        self.currentVideoId = videoId
        self.currentVideoTitle = title
        self.currentPost = post
        self.availableQualities = qualities
        self.playerState = .loading
        self.isLiveStream = isLive
        self.captionCues = captionCues
        // Auto-enable when the user has system captions on AND the post
        // ships a caption track. Otherwise leave the in-app toggle off.
        self.captionsEnabled = !captionCues.isEmpty && Self.systemCaptionsEnabled

        // Use highest quality by default
        guard let quality = qualities.first else {
            throw FloatplaneAPIError.invalidResponse
        }

        self.currentQuality = quality

        print("🎬 [AVPlayerManager] Loading video: \(title) (Live: \(isLive)) cues: \(captionCues.count)")
        try await loadStream(url: quality.url, startTime: startTime, isLive: isLive)
    }

    private let resourceLoader = VideoResourceLoader()

    /// Load stream from URL
    private func loadStream(url: String, startTime: Double = 0, isLive: Bool) async throws {
        // Clean up old player
        cleanupPlayer()

        // Re-activate the audio session in case it was deactivated by a
        // previous reset() (GH #40). setupAudioSession() only runs once at
        // init, so without this a video loaded after a reset would play
        // silent on background routes.
        try? audioSession.setActive(true)

        let asset: AVURLAsset

        if isLive {
            // Bypass VideoResourceLoader for Live Streams
            // Use the original URL directly so AVPlayer handles HLS natively
            guard let streamURL = URL(string: url) else {
                throw FloatplaneAPIError.invalidURL
            }
            print("📡 [AVPlayerManager] Loading LIVE stream directly: \(streamURL)")

            // Create asset without custom resource loader
            asset = AVURLAsset(url: streamURL)
            // No resourceLoader delegate set for live streams
        } else {
            // Convert HTTP/HTTPS to custom scheme to force interception via VideoResourceLoader.
            // This is what gives DPoP + key-rewrite a hook into the HLS pipeline. Captions
            // no longer ride this path — they're rendered as a SwiftUI overlay (GH #11).
            guard var components = URLComponents(string: url) else {
                throw FloatplaneAPIError.invalidURL
            }
            components.scheme = "floatnative" // Must match VideoResourceLoader.customScheme
            guard let streamURL = components.url else {
                throw FloatplaneAPIError.invalidURL
            }
            print("📼 [AVPlayerManager] Loading VOD stream with interception: \(streamURL)")

            // Create new player with Interceptor
            // We do NOT pass headers here because the ResourceLoader will handle the request.
            asset = AVURLAsset(url: streamURL)
            asset.resourceLoader.setDelegate(resourceLoader, queue: DispatchQueue.global(qos: .userInitiated))
        }

        let playerItem = AVPlayerItem(asset: asset)

        // Configure buffer limits for tvOS to prevent memory issues during long playback
        #if os(tvOS)
        // Limit buffer to 30 seconds ahead to reduce memory pressure on tvOS
        playerItem.preferredForwardBufferDuration = 30
        #else
        // iOS can handle larger buffers
        playerItem.preferredForwardBufferDuration = 60
        #endif


        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.allowsExternalPlayback = true
        newPlayer.appliesMediaSelectionCriteriaAutomatically = true

        // Configure player to minimize stalling while respecting buffer limits
        if #available(iOS 10.0, tvOS 10.0, *) {
            newPlayer.automaticallyWaitsToMinimizeStalling = true
        }

        self.player = newPlayer

        // Apply the user's preferred playback speed before the first play()
        // so they don't see a 1.0× flash. defaultRate is iOS/tvOS 16+; our
        // deployment target is 18+.
        newPlayer.defaultRate = persistedPlaybackRate

        // Persist any future rate changes the user makes via the
        // AVPlayerViewController chrome (iOS) or the transport bar menu
        // (tvOS). Only persist while playing — rate goes to 0 on pause,
        // we don't want to lose the user's selection. Also push the new
        // rate into defaultRate so a subsequent pause → play resumes at
        // the chosen speed instead of snapping back to 1.0×.
        rateObservation = newPlayer.observe(\.rate, options: [.new]) { [weak self] player, change in
            guard let newRate = change.newValue, newRate > 0 else { return }
            self?.persistedPlaybackRate = newRate
            if abs(player.defaultRate - newRate) > 0.01 {
                player.defaultRate = newRate
            }
        }

        // Add observers for detailed logging
        addDebugObservers(to: playerItem)

        // Observe player status
        observePlayer()

        // Setup video end observer
        setupVideoEndObserver()

        // Seek to start time if specified
        if startTime > 0 && !isLive {
            seek(to: startTime)
        }

        // Update state
        playerState = .paused
    }
    
    private func addDebugObservers(to item: AVPlayerItem) {
        NotificationCenter.default.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { notification in
            guard let playerItem = notification.object as? AVPlayerItem,
                  let errorLog = playerItem.errorLog()?.events.last else { return }
            print("🚨 [AVPlayer] Error Log: \(errorLog.errorDomain) \(errorLog.errorStatusCode) — \(errorLog.errorComment ?? "(no comment)") @ \(errorLog.uri ?? "?")")
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main) { notification in
            guard let playerItem = notification.object as? AVPlayerItem,
                  let accessLog = playerItem.accessLog()?.events.last else { return }
            print("ℹ️ [AVPlayer] Access Log: URI: \(accessLog.uri ?? "") | Bitrate: \(accessLog.indicatedBitrate)")
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { notification in
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                print("❌ [AVPlayer] Failed to play to end: \(error.localizedDescription)")
            }
        }

        // Playback-stall notification — fires when AVPlayer ran out of buffered
        // data. Worth knowing for the GH #11 tvOS stall: if we never see this,
        // playback never started buffering, which points at HLS-parsing trouble
        // (vs. network) and the master/variant playlists are the prime suspects.
        NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            print("⏸ [AVPlayer] Playback stalled")
        }

        // Track status transitions: .unknown → .readyToPlay / .failed. A .failed
        // status without a corresponding errorLog entry is rare but means the
        // item itself rejected the asset (e.g. malformed master playlist).
        item.publisher(for: \.status)
            .sink { status in
                let label: String = switch status {
                case .unknown: "unknown"
                case .readyToPlay: "readyToPlay"
                case .failed: "failed"
                @unknown default: "@unknown"
                }
                print("🎞 [AVPlayer] PlayerItem.status → \(label)")
                if status == .failed, let err = item.error as NSError? {
                    print("   error domain=\(err.domain) code=\(err.code) desc=\(err.localizedDescription)")
                    if let underlying = err.userInfo[NSUnderlyingErrorKey] as? NSError {
                        print("   underlying domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Change Quality

    func changeQuality(_ quality: QualityVariant) async throws {
        guard let player = player else { return }

        let currentTime = player.currentTime().seconds
        self.currentQuality = quality

        try await loadStream(url: quality.url, startTime: currentTime, isLive: isLiveStream)

        if isPlaying {
            play()
        }
    }

    // MARK: - Picture in Picture
    // PiP is now handled by CustomVideoPlayer (AVPlayerViewController)
    // which has native PiP support built-in

    // MARK: - Player Observation

    private func observePlayer() {
        guard let player = player else { return }

        // Time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                // Update without animation to avoid AttributeGraph cycles
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self?.currentTime = time.seconds
                }
                self?.updateNowPlayingInfo()
            }
        }

        // Duration observer
        player.currentItem?.publisher(for: \.duration)
            .sink { [weak self] duration in
                Task { @MainActor in
                    if duration.isNumeric {
                        self?.duration = duration.seconds
                        self?.updateNowPlayingInfo()
                    }
                }
            }
            .store(in: &cancellables)

        // Status observer
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                Task { @MainActor in
                    switch status {
                    case .playing:
                        self?.isPlaying = true
                        self?.playerState = .playing
                    case .paused:
                        self?.isPlaying = false
                        if self?.playerState == .playing {
                            self?.playerState = .paused
                        }
                    case .waitingToPlayAtSpecifiedRate:
                        self?.playerState = .buffering
                    @unknown default:
                        break
                    }
                    self?.updateNowPlayingInfo()
                }
            }
            .store(in: &cancellables)

        // Item status observer
        player.currentItem?.publisher(for: \.status)
            .sink { [weak self] status in
                Task { @MainActor in
                    switch status {
                    case .failed:
                        if let error = player.currentItem?.error {
                            self?.playerState = .failed(error)
                        }
                    case .readyToPlay:
                        if self?.playerState == .loading {
                            self?.playerState = .paused
                        }
                    default:
                        break
                    }
                }
            }
            .store(in: &cancellables)

        // Buffer empty observer - critical for detecting stalling
        player.currentItem?.publisher(for: \.isPlaybackBufferEmpty)
            .sink { [weak self] isEmpty in
                Task { @MainActor in
                    if isEmpty {

                        self?.isBuffering = true
                        self?.playerState = .buffering
                    }
                }
            }
            .store(in: &cancellables)

        // Buffer likely to keep up observer
        player.currentItem?.publisher(for: \.isPlaybackLikelyToKeepUp)
            .sink { [weak self] likelyToKeepUp in
                Task { @MainActor in
                    if likelyToKeepUp {

                        self?.isBuffering = false
                        if self?.isPlaying == true {
                            self?.playerState = .playing
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Buffer full observer
        player.currentItem?.publisher(for: \.isPlaybackBufferFull)
            .sink { [weak self] isFull in
                Task { @MainActor in
                    // Log removed as per instruction
                }
            }
            .store(in: &cancellables)

        // Loaded time ranges observer - track buffer progress
        player.currentItem?.publisher(for: \.loadedTimeRanges)
            .sink { [weak self] timeRanges in
                Task { @MainActor in
                    guard let self = self,
                          let currentTime = self.player?.currentTime(),
                          let timeRange = timeRanges.first?.timeRangeValue else {
                        return
                    }

                    // Throttle updates to once every 2 seconds to prevent excessive view redraws
                    // This is critical for tvOS performance where view updates are expensive
                    let now = Date().timeIntervalSince1970
                    guard now - self.lastBufferUpdate > 2.0 else { return }

                    let bufferEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange))
                    let currentTimeSeconds = CMTimeGetSeconds(currentTime)
                    let bufferedAhead = bufferEnd - currentTimeSeconds

                    self.bufferProgress = max(0, bufferedAhead)
                    self.lastBufferUpdate = now

                    #if os(tvOS)
                    // Log buffer status on tvOS to help diagnose issues
                    if Int(currentTimeSeconds) % 60 == 0 && Int(currentTimeSeconds) > 0 {
                        print("📊 tvOS Buffer Status at \(Int(currentTimeSeconds))s: \(bufferedAhead)s ahead")
                    }
                    #endif
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Playback Controls

    func play() {
        player?.play()
        updateNowPlayingInfo()
        startProgressTimer()
        setIdleTimerDisabled(true)  // Keep screen awake during playback
    }

    func pause() {
        player?.pause()
        updateNowPlayingInfo()
        stopProgressTimer()
        setIdleTimerDisabled(false)  // Allow screen to sleep when paused
    }

    // MARK: - Idle Timer Management

    private func setIdleTimerDisabled(_ disabled: Bool) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime) { [weak self] _ in
            Task { @MainActor in
                self?.updateNowPlayingInfo()
            }
        }
    }

    func seek(by seconds: Double) {
        let newTime = currentTime + seconds
        let clampedTime = max(0, min(newTime, duration))
        seek(to: clampedTime)
    }

    func setRate(_ rate: Float) {
        player?.rate = rate
    }

    // MARK: - Progress Tracking

    /// Start periodic progress saving (every 2 minutes)
    private func startProgressTimer() {
        stopProgressTimer()

        // Use DispatchSourceTimer on background queue to avoid blocking main thread
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 120, repeating: 120)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.saveProgressWithTimeout()
            }
        }
        timer.resume()
        progressTimer = timer
    }

    /// Stop periodic progress saving
    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    /// Save progress to Floatplane API with timeout protection
    private func saveProgressWithTimeout() async {
        // Use Task.withTimeout-like pattern to prevent hanging
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.saveProgress()
            }

            // Add timeout task (10 seconds)
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }

            // Wait for first to complete, then cancel others
            await group.next()
            group.cancelAll()
        }
    }

    /// Save progress to Floatplane API
    func saveProgress() async {
        guard let videoId = currentVideoId else { return }

        let progressInSeconds = Int(currentTime)

        do {
            _ = try await FloatplaneAPI.shared.updateProgress(
                videoId: videoId,
                contentType: "video",
                progress: progressInSeconds
            )
        } catch {
            print("Failed to save progress: \(error)")
        }
    }

    // MARK: - Cleanup

    private func cleanupPlayer() {
        // FIRST: Immediately stop playback and audio to prevent overlap
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        // Re-enable idle timer (allow screen to sleep)
        setIdleTimerDisabled(false)

        // Remove time observer
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Remove background observer
        if let backgroundObserver = backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }

        // Remove video end observer
        if let videoEndObserver = videoEndObserver {
            NotificationCenter.default.removeObserver(videoEndObserver)
            self.videoEndObserver = nil
        }

        // Stop progress timer
        stopProgressTimer()

        // Stop observing rate changes
        rateObservation?.invalidate()
        rateObservation = nil

        // Cancel all subscriptions
        cancellables.removeAll()

        player = nil
    }

    // MARK: - Fullscreen Control

    func enterFullScreen(animated: Bool = true) {
        guard let playerViewController = playerViewController else {
            print("🎬 [Fullscreen] enterFullScreen: no playerViewController")
            return
        }
        print("🎬 [Fullscreen] enterFullScreen invoked")
        let selector = NSSelectorFromString("enterFullScreenAnimated:completionHandler:")
        if playerViewController.responds(to: selector) {
            playerViewController.perform(selector, with: animated, with: nil)
        }
    }

    func exitFullScreen(animated: Bool = true) {
        guard let playerViewController = playerViewController else {
            print("🎬 [Fullscreen] exitFullScreen: no playerViewController")
            return
        }
        print("🎬 [Fullscreen] exitFullScreen invoked")
        let selector = NSSelectorFromString("exitFullScreenAnimated:completionHandler:")
        if playerViewController.responds(to: selector) {
            playerViewController.perform(selector, with: animated, with: nil)
        } else {
            // Fallback: Try private API selector for older/other versions if the standard one fails
            let privateSelector = NSSelectorFromString("_transitionFromFullScreenAnimated:completionHandler:")
            if playerViewController.responds(to: privateSelector) {
                playerViewController.perform(privateSelector, with: animated, with: nil)
            }
        }
    }

    #if !os(tvOS)
    /// Force the device into landscape orientation and enter native fullscreen,
    /// overriding the system rotation lock. Mirrors what YouTube / the official
    /// Floatplane app do when you tap their rotate-to-landscape button.
    ///
    /// Uses iOS 16's `requestGeometryUpdate` API; deployment target is 18.5+
    /// so the availability check is just defensive.
    func forceLandscape() {
        requestOrientation(.landscape)
        enterFullScreen()
    }

    /// Mirror of `forceLandscape()` — invoked when the user exits fullscreen
    /// or otherwise wants to return to portrait while rotation lock is on.
    func forcePortrait() {
        requestOrientation(.portrait)
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
                // Errors here (e.g. user-locked rotation refusing) are non-fatal.
            }
        }
    }
    #endif

    func reset() {
        cleanupPlayer()
        currentVideoId = nil
        currentVideoTitle = nil
        currentPost = nil
        shouldRestoreVideoPlayer = false
        availableQualities = []
        currentQuality = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        playerState = .idle
        playerViewController = nil
        playerViewControllerDelegate = nil
        hasPIPSession = false

        // Release audio focus so we don't keep ducking other apps after the
        // user has fully left the player. setActive(true) is re-issued from
        // setupAudioSession() the next time a video loads (GH #40).
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Note: deinit cannot call async methods, so cleanup happens via onDisappear in views
}
