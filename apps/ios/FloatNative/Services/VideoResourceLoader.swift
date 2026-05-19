//
//  VideoResourceLoader.swift
//  FloatNative
//
//  Created by Claude on 2024-03-22.
//

import AVFoundation
import Foundation

class VideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    // A WebVTT track that should be exposed alongside the variant playlist
    // as a SUBTITLES rendition (GH #11). Floatplane sends these on the
    // post's video attachments; AVPlayer can't load them out-of-band, so
    // we synthesize a master playlist that references them.
    struct TextTrack {
        let url: URL          // R2 pre-signed URL to the .vtt
        let language: String  // ISO 639-1 / BCP 47 (e.g. "en")
        let label: String     // User-visible name in the CC picker
        let isDefault: Bool   // Whether to autoselect (system caption pref)
    }

    private let session: URLSession
    private let customScheme = "floatnative"

    // Variant URL of the currently-loading asset. Set by AVPlayerManager via
    // `registerCaptions(variantURL:textTracks:durationSeconds:)` immediately
    // before creating the AVURLAsset, then read when AVPlayer requests the
    // synthetic master playlist.
    private var pendingVariantURL: URL?
    private var pendingTextTracks: [TextTrack] = []
    private var pendingDurationSeconds: Int = 0

    override init() {
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config)
        super.init()
    }

    /// AVPlayerManager calls this right before constructing the asset for a
    /// VOD with captions (GH #11). The loader uses this state when AVPlayer
    /// requests the synthetic `floatnative:///__master__.m3u8`.
    func registerCaptions(variantURL: URL, textTracks: [TextTrack], durationSeconds: Int) {
        self.pendingVariantURL = variantURL
        self.pendingTextTracks = textTracks
        self.pendingDurationSeconds = max(durationSeconds, 1)
    }

    /// The synthetic master URL AVPlayerManager passes to AVURLAsset when a
    /// VOD has at least one text track registered. The host segment doubles
    /// as a sentinel the delegate matches on below.
    static let syntheticMasterURL = URL(string: "floatnative://__synth__/master.m3u8")!
    
    // MARK: - Delegate Methods
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url else { return false }
        
        // Handle custom scheme requests
        if url.scheme == customScheme {
            handleCustomSchemeRequest(loadingRequest)
            return true
        }
        
        return false
    }
    
    // MARK: - Handlers
    
    private func handleCustomSchemeRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            return
        }

        // Synthetic master + subtitle paths (GH #11). These don't proxy to
        // any real upstream — they describe a single in-memory rendition
        // list AVPlayer can hand to legibleMediaSelectionGroup.
        if url.host == "__synth__" {
            Task {
                do {
                    let path = url.path
                    if path.hasSuffix("master.m3u8") {
                        try handleSyntheticMaster(loadingRequest)
                    } else if path.hasSuffix("subs.m3u8") {
                        try handleSyntheticSubsPlaylist(loadingRequest, url: url)
                    } else if path.hasSuffix(".vtt") {
                        try await handleSyntheticVTT(loadingRequest, url: url)
                    } else {
                        loadingRequest.finishLoading(with: URLError(.badURL))
                    }
                } catch {
                    loadingRequest.finishLoading(with: error)
                }
            }
            return
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            return
        }

        // Switch scheme back to https
        components.scheme = "https"
        guard let realURL = components.url else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            return
        }

        Task {
            do {
                // Check if this is a Master Playlist or Variant Playlist (m3u8)
                if realURL.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame {
                    try await handleManifestRequest(loadingRequest, realURL: realURL)
                }
                // Check if this is a Key
                else if realURL.absoluteString.contains("key") || realURL.pathExtension == "key" {
                     try await handleKeyRequest(loadingRequest, realURL: realURL)
                }
                // Fallback (shouldn't happen with our rewrite logic, but handle gracefully)
                else {
                    try await handleGenericRequest(loadingRequest, realURL: realURL)
                }
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    // MARK: - Synthetic Master Playlist (GH #11)

    private func handleSyntheticMaster(_ loadingRequest: AVAssetResourceLoadingRequest) throws {
        guard let variantURL = pendingVariantURL else {
            throw URLError(.resourceUnavailable)
        }

        // Re-route the upstream variant URL through our floatnative://
        // interceptor so DPoP + key-rewrite continues to work.
        var variantComponents = URLComponents(url: variantURL, resolvingAgainstBaseURL: false)
        variantComponents?.scheme = customScheme
        guard let interceptedVariantURL = variantComponents?.url else {
            throw URLError(.badURL)
        }

        var lines: [String] = ["#EXTM3U", "#EXT-X-VERSION:3"]

        // Each text track becomes a SUBTITLES rendition pointing at a
        // synthetic per-track playlist.
        for (i, track) in pendingTextTracks.enumerated() {
            let trackId = "subs\(i)"
            let attrs: [String] = [
                "TYPE=SUBTITLES",
                "GROUP-ID=\"subs\"",
                "NAME=\"\(track.label)\"",
                "LANGUAGE=\"\(track.language)\"",
                "AUTOSELECT=\(track.isDefault ? "YES" : "NO")",
                "DEFAULT=\(track.isDefault ? "YES" : "NO")",
                "FORCED=NO",
                "URI=\"floatnative://__synth__/\(trackId)/subs.m3u8\""
            ]
            lines.append("#EXT-X-MEDIA:" + attrs.joined(separator: ","))
        }

        // Single variant pointing at the upstream playlist. BANDWIDTH is
        // required; we don't actually know it here so use a plausible value
        // — AVPlayer doesn't fail master parsing on this.
        let subtitlesAttr = pendingTextTracks.isEmpty ? "" : ",SUBTITLES=\"subs\""
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=4000000\(subtitlesAttr)")
        lines.append(interceptedVariantURL.absoluteString)

        let manifest = lines.joined(separator: "\n") + "\n"
        guard let data = manifest.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }

    private func handleSyntheticSubsPlaylist(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) throws {
        // Path is /<trackId>/subs.m3u8
        let trackId = url.pathComponents.dropFirst().first ?? ""
        guard let index = Int(trackId.dropFirst("subs".count)),
              index < pendingTextTracks.count else {
            throw URLError(.resourceUnavailable)
        }
        let duration = pendingDurationSeconds
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(duration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:\(duration).0,",
            "floatnative://__synth__/\(trackId)/track.vtt",
            "#EXT-X-ENDLIST",
        ]
        let manifest = lines.joined(separator: "\n") + "\n"
        guard let data = manifest.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }

    private func handleSyntheticVTT(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) async throws {
        let trackId = url.pathComponents.dropFirst().first ?? ""
        guard let index = Int(trackId.dropFirst("subs".count)),
              index < pendingTextTracks.count else {
            throw URLError(.resourceUnavailable)
        }
        // Floatplane's text-track URLs are R2 pre-signed and unauth'd —
        // no DPoP needed and adding it would actually break the signature.
        let (data, response) = try await session.data(from: pendingTextTracks[index].url)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }
    
    // MARK: - Manifest Handling
    
    private func handleManifestRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        
        // 1. Download Manifest (using DPoP if needed, assuming the manifest endpoint is protected)
        let data = try await fetchWithDPoP(url: realURL)
        
        guard let manifestString = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        // 2. Rewrite Manifest
        // Base URL for resolving relative paths
        let baseURL = realURL.deletingLastPathComponent()
        
        var newLines: [String] = []
        
        manifestString.enumerateLines { line, _ in
            var processedLine = line
            
            // A. Rewrite KEY URIs to force interception
            // Format: #EXT-X-KEY:METHOD=AES-128,URI="https://..."
            if line.contains("#EXT-X-KEY") {
                if let range = line.range(of: "URI=\"") {
                     let rest = line[range.upperBound...]
                     if let endQuote = rest.firstIndex(of: "\"") {
                         let keyUriString = String(rest[..<endQuote])
                         // If it's already absolute http/s, replace scheme.
                         // If relative, make absolute first, then replace scheme.
                         if let keyURL = URL(string: keyUriString, relativeTo: baseURL) {
                             var keyComponents = URLComponents(url: keyURL, resolvingAgainstBaseURL: true)
                             keyComponents?.scheme = self.customScheme
                             if let newKeyUri = keyComponents?.string {
                                 processedLine = line.replacingOccurrences(of: keyUriString, with: newKeyUri)
                             }
                         }
                     }
                }
            }
            // B. Rewrite Segment URLs to Absolute HTTPS (to bypass interception)
            // Lines that are not tags (#) and not empty are URIs
            else if !line.hasPrefix("#") && !line.isEmpty {
                 if let segmentURL = URL(string: line, relativeTo: baseURL) {
                     // Ensure scheme is http/https
                     if segmentURL.scheme == "http" || segmentURL.scheme == "https" {
                         processedLine = segmentURL.absoluteString
                     }
                 }
            }
            
            newLines.append(processedLine)
        }
        
        let modifiedManifest = newLines.joined(separator: "\n")
        guard let modifiedData = modifiedManifest.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        // 3. Return Data
        loadingRequest.dataRequest?.respond(with: modifiedData)
        loadingRequest.finishLoading()
    }
    
    // MARK: - Key Handling
    
    private func handleKeyRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        
        // Fetch with DPoP (This is what we came here for!)
        let data = try await fetchWithDPoP(url: realURL)
        
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }
    
    private func handleGenericRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        // Just fetch and return
        let data = try await fetchWithDPoP(url: realURL)
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }
    
    // MARK: - Helpers
    
    private func fetchWithDPoP(url: URL) async throws -> Data {
        let accessToken = await FloatplaneAPI.shared.accessToken
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add DPoP
        if let token = accessToken {
             if let dpopProof = try? DPoPManager.shared.generateProof(
                httpMethod: "GET",
                httpUrl: url.absoluteString,
                accessToken: token
             ) {
                 request.setValue(dpopProof, forHTTPHeaderField: "DPoP")
                 request.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
             } else {
                 // Fallback
                 request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
             }
        }
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        
        return data
    }
}
