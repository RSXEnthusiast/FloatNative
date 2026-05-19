import SwiftUI

/// Renders the currently-active WebVTT cue(s) over the AVPlayer surface.
/// Observes `AVPlayerManager.currentTime` and `captionCues` — when the user
/// toggles `captionsEnabled` we hide the overlay without touching the cues.
///
/// We didn't fight AVPlayer's HLS parser any longer (synthetic master kept
/// hitting CoreMediaErrorDomain -12881); rendering ourselves is what the
/// industry calls "side-loaded subtitles" and it's bulletproof.
struct CaptionsOverlay: View {
    @ObservedObject var playerManager: AVPlayerManager

    private var activeText: String {
        guard playerManager.captionsEnabled, !playerManager.captionCues.isEmpty else { return "" }
        let active = VTTCueParser.activeCues(playerManager.captionCues, at: playerManager.currentTime)
        return active.map { stripVTTTags($0.payload) }.joined(separator: "\n")
    }

    var body: some View {
        VStack {
            Spacer()
            if !activeText.isEmpty {
                Text(activeText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)  // never intercept taps meant for the player chrome
        .animation(.easeInOut(duration: 0.15), value: activeText)
    }

    /// Strip the most common WebVTT inline tags so plain Text renders cleanly.
    /// Floatplane's auto-generated captions only use `<c>` colour and `<i>`
    /// emphasis tags so far; the regex covers any single-letter tag with
    /// optional class settings.
    private func stripVTTTags(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return raw }
        let ns = raw as NSString
        return regex.stringByReplacingMatches(
            in: raw,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }
}
