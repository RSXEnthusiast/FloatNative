//
//  CustomVideoPlayer.swift
//  FloatNative
//
//  Custom video player with native Picture-in-Picture support
//  Uses AVPlayerViewController wrapped in UIViewControllerRepresentable
//

import SwiftUI
import AVKit

#if os(tvOS)
/// Custom AVPlayerViewController subclass that manages transport bar items efficiently
/// Prevents pulsing animation by avoiding unnecessary transport bar regeneration
class CustomAVPlayerViewController: AVPlayerViewController {
    private var likeAction: UIAction?
    private var dislikeAction: UIAction?
    private var likeHandler: (() async -> Void)?
    private var dislikeHandler: (() async -> Void)?

    /// Update the like button title and state without recreating the entire transport bar
    func updateLikeButton(count: Int, isLiked: Bool) {
        guard let likeAction = likeAction else { return }
        var items = transportBarCustomMenuItems

        // Create updated action with new title and icon
        let newAction = UIAction(
            title: "Like (\(count))",
            image: UIImage(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
        ) { [weak self] _ in
            guard let self = self, let handler = self.likeHandler else { return }
            Task {
                await handler()
            }
        }

        // Replace the old action in the menu items array
        if let index = items.firstIndex(where: { $0 === likeAction }) {
            items[index] = newAction
            self.likeAction = newAction
            transportBarCustomMenuItems = items
        }
    }

    /// Update the dislike button title and state without recreating the entire transport bar
    func updateDislikeButton(count: Int, isDisliked: Bool) {
        guard let dislikeAction = dislikeAction else { return }
        var items = transportBarCustomMenuItems

        // Create updated action with new title and icon
        let newAction = UIAction(
            title: "Dislike (\(count))",
            image: UIImage(systemName: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        ) { [weak self] _ in
            guard let self = self, let handler = self.dislikeHandler else { return }
            Task {
                await handler()
            }
        }

        // Replace the old action in the menu items array
        if let index = items.firstIndex(where: { $0 === dislikeAction }) {
            items[index] = newAction
            self.dislikeAction = newAction
            transportBarCustomMenuItems = items
        }
    }

    /// Set the initial transport bar items (call once during setup)
    func setInitialTransportBarItems(
        likeCount: Int,
        dislikeCount: Int,
        isLiked: Bool,
        isDisliked: Bool,
        onLike: @escaping () async -> Void,
        onDislike: @escaping () async -> Void,
        onDescription: @escaping () -> Void,
        onComments: @escaping () -> Void,
        qualityMenu: UIMenu
    ) {
        self.likeHandler = onLike
        self.dislikeHandler = onDislike

        // Create like action
        let likeAction = UIAction(
            title: "Like (\(likeCount))",
            image: UIImage(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
        ) { _ in
            Task {
                await onLike()
            }
        }
        self.likeAction = likeAction

        // Create dislike action
        let dislikeAction = UIAction(
            title: "Dislike (\(dislikeCount))",
            image: UIImage(systemName: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        ) { _ in
            Task {
                await onDislike()
            }
        }
        self.dislikeAction = dislikeAction

        // Create description action
        let descriptionAction = UIAction(
            title: "Description",
            image: UIImage(systemName: "doc.text")
        ) { _ in
            onDescription()
        }

        // Create comments action
        let commentsAction = UIAction(
            title: "Comments",
            image: UIImage(systemName: "bubble.left.and.bubble.right")
        ) { _ in
            onComments()
        }

        // Set all items once
        transportBarCustomMenuItems = [
            likeAction,
            dislikeAction,
            descriptionAction,
            commentsAction,
            qualityMenu
        ]
    }
}
#endif

/// A custom video player that supports Picture-in-Picture
/// SwiftUI's VideoPlayer doesn't support PiP, so we use AVPlayerViewController
struct CustomVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsPlaybackControls: Bool = true

    // tvOS-specific custom transport bar items
    #if os(tvOS)
    var customMenuItems: [UIMenuElement] = []
    var contextualActions: [UIAction] = []
    #endif

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Check if we should reuse existing playerViewController
        // Reuse during: PiP restoration, fullscreen transitions, and layout changes (like rotation)
        // This prevents black screen issues when AVPlayerViewController changes presentation mode
        if let existingController = AVPlayerManager.shared.playerViewController,
           existingController.player === player,
           let existingDelegate = AVPlayerManager.shared.playerViewControllerDelegate {

            // Reuse the existing delegate (Coordinator) to maintain callback connection
            existingController.delegate = existingDelegate as? AVPlayerViewControllerDelegate
            existingController.showsPlaybackControls = showsPlaybackControls
            return existingController
        }


        #if os(tvOS)
        let controller = CustomAVPlayerViewController()
        #else
        let controller = AVPlayerViewController()
        #endif

        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.allowsPictureInPicturePlayback = true
        controller.delegate = context.coordinator

        #if os(tvOS)
        // Apply tvOS-specific customizations
        if !customMenuItems.isEmpty {

            controller.transportBarCustomMenuItems = customMenuItems
        } else {
            print("⚠️ CustomVideoPlayer: customMenuItems is EMPTY - no transport bar items will be applied!")
        }
        if !contextualActions.isEmpty {
            controller.contextualActions = contextualActions
        }
        // GH #11: previously suppressed subtitles entirely via
        // `allowedSubtitleOptionLanguages = [""]`. With captions wiring on
        // the asset (via AVMediaSelectionGroup once the synthetic-master
        // path is re-enabled), the tvOS swipe-down Info panel surfaces a
        // proper Subtitles submenu — so we don't restrict the language
        // list. AVPlayer hides the entry on its own when the asset
        // exposes no legible tracks, so this is safe before captions ship.
        #endif

        // Store BOTH controller AND coordinator in AVPlayerManager to keep alive during PiP
        AVPlayerManager.shared.playerViewController = controller
        AVPlayerManager.shared.playerViewControllerDelegate = context.coordinator

        // GH #11: side-loaded captions. AVPlayerViewController has a built-in
        // contentOverlayView that sits *above* the video surface and *below*
        // the playback controls, which is exactly where subtitles belong.
        // The hosted SwiftUI view observes AVPlayerManager and re-renders
        // when the active cue changes.
        attachCaptionsOverlay(to: controller)

        return controller
    }

    /// Mount a SwiftUI captions overlay onto the AVPlayerViewController's
    /// content overlay so it sits above the video but under the controls.
    private func attachCaptionsOverlay(to controller: AVPlayerViewController) {
        guard let overlayHost = controller.contentOverlayView else { return }
        let hosting = UIHostingController(rootView: CaptionsOverlay(playerManager: AVPlayerManager.shared))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // Don't let the hosting view intercept the player's touch / focus
        // handling — the overlay itself already sets allowsHitTesting(false).
        hosting.view.isUserInteractionEnabled = false

        overlayHost.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: overlayHost.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: overlayHost.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: overlayHost.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: overlayHost.bottomAnchor),
        ])
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Update player if it changed
        if uiViewController.player !== player {
            uiViewController.player = player
        }

        // Update playback controls visibility
        uiViewController.showsPlaybackControls = showsPlaybackControls

        #if os(tvOS)
        // Always apply transport bar items when they change
        // Trust SwiftUI's change detection - if this method is called, something changed
        let newItemsCount = customMenuItems.count

        // Only update if the items have actually changed to avoid resetting focus
        if context.coordinator.lastCustomMenuItemsCount != newItemsCount ||
           context.coordinator.lastCustomMenuItems.elementsEqual(customMenuItems, by: { $0.hashValue == $1.hashValue }) == false { // Using hashValue for comparison, might need a more robust solution for complex UIMenuElement types
            
            if newItemsCount > 0 {
                uiViewController.transportBarCustomMenuItems = customMenuItems
                context.coordinator.lastCustomMenuItems = customMenuItems
                context.coordinator.lastCustomMenuItemsCount = newItemsCount
                

            } else {
                // If items become empty, clear them
                uiViewController.transportBarCustomMenuItems = []
                context.coordinator.lastCustomMenuItems = []
                context.coordinator.lastCustomMenuItemsCount = 0
            }
        }

        // Update contextual actions (these are time-based, not state-based)
        uiViewController.contextualActions = contextualActions
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: CustomVideoPlayer
        var lastCustomMenuItems: [UIMenuElement] = []
        var lastCustomMenuItemsCount: Int = 0

        init(_ parent: CustomVideoPlayer) {
            self.parent = parent

        }

        // Prevent the player view controller from being dismissed when PiP starts
        // This keeps the VideoPlayerView alive in the navigation stack so it can be restored later
        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
            return false  // Keep the view alive during PiP
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            print("🎬 PiP: Starting Picture in Picture")
            Task { @MainActor in
                AVPlayerManager.shared.isPIPActive = true
                AVPlayerManager.shared.hasPIPSession = true
            }
        }

        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            // PiP started successfully
        }

        func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            // PiP about to stop
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            print("🎬 PiP: Stopped Picture in Picture")
            Task { @MainActor in
                AVPlayerManager.shared.isPIPActive = false
                AVPlayerManager.shared.shouldRestoreVideoPlayer = false
                // Keep stored references for potential re-entry to PiP
                // Cleanup happens only when loading a different video
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            print("🎬 PiP: Restoring user interface")

            // Signal to restore video player UI when user taps PiP window
            Task { @MainActor in
                AVPlayerManager.shared.shouldRestoreVideoPlayer = true

                // Give the navigation system time to respond
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

                completionHandler(true)
            }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
            print("🎬 PiP: Failed to start - \(error.localizedDescription)")
        }

        #if !os(tvOS)
        // MARK: - Fullscreen transitions

        // AVPlayerViewController often pauses the player when leaving
        // fullscreen. If the user was playing when they exited, restart
        // playback after the transition. Also force the device back to
        // portrait so the AVPlayerViewController's built-in close button
        // acts as a "back to portrait" toggle when system rotation lock is
        // engaged (otherwise the inline view would render rotated).
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            // Capture state synchronously — we're already on the main thread
            // when UIKit fires this delegate, but the compiler needs us to
            // tell it explicitly that AVPlayerManager touches are main-isolated.
            let wasPlaying = MainActor.assumeIsolated { AVPlayerManager.shared.isPlaying }

            coordinator.animate(alongsideTransition: nil) { _ in
                MainActor.assumeIsolated {
                    if wasPlaying {
                        AVPlayerManager.shared.play()
                    }
                    AVPlayerManager.shared.forcePortrait()
                }
            }
        }
        #endif
    }
}
