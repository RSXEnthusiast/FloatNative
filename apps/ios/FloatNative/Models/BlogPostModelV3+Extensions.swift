import Foundation

extension BlogPostModelV3 {
    /// Helper to identify if a post is a livestream.
    /// Since the Generated ModelType enum might not contain .livestream,
    /// we use heuristics (video duration == 0) or other metadata to detect it.
    var isLivestream: Bool {
        // Heuristic: Livestreams have video but 0 duration.
        // We also check if the creator has an active livestream model if possible,
        // but primarily rely on the post metadata.
        return metadata.hasVideo && metadata.videoDuration == 0
    }
}

extension PostMetadataModel {
    /// Duration to show on cards. On a multi-video post (e.g. `C3GeAE0LmM`,
    /// videoCount=3) `videoDuration` is the SUM of every video attachment,
    /// which made the card look like a 24-minute video when the primary clip
    /// is actually 22 minutes (GH #29). Floatplane returns `displayDuration`
    /// for that primary clip; prefer it, fall back to videoDuration on
    /// legacy responses that don't carry the new field.
    var preferredDisplayDuration: Double {
        if let displayDuration {
            return Double(displayDuration)
        }
        return videoDuration
    }

    /// Tail label appended to the duration on cards for posts that bundle
    /// extra video parts (GH #23, #29). `videoCount=3` becomes `" +2"`.
    /// Empty string when the post is a normal single-video post.
    var additionalPartsSuffix: String {
        guard let videoCount, videoCount > 1 else { return "" }
        return " +\(videoCount - 1)"
    }
}
