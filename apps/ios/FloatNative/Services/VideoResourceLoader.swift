//
//  VideoResourceLoader.swift
//  FloatNative
//
//  Created by Claude on 2024-03-22.
//

import AVFoundation
import Foundation
import os

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
    private let log = Logger(subsystem: "ca.maplespace.FloatNative", category: "VideoResourceLoader")

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
        let info = loadingRequest.contentInformationRequest != nil ? "INFO" : ""
        let data = loadingRequest.dataRequest != nil ? "DATA" : ""
        let dataRange = loadingRequest.dataRequest.map { "off=\($0.requestedOffset) len=\($0.requestedLength)" } ?? "—"
        log.debug("⟶ \(info)\(data) \(url.absoluteString) (\(dataRange, privacy: .public))")

        // Handle custom scheme requests
        if url.scheme == customScheme {
            handleCustomSchemeRequest(loadingRequest)
            return true
        }

        return false
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        log.debug("✕ cancelled \(loadingRequest.request.url?.absoluteString ?? "—")")
    }

    // MARK: - Response helpers (GH #11)
    //
    // Apple's AVAssetResourceLoader docs are emphatic: the FIRST request for
    // an asset arrives with a contentInformationRequest that MUST be populated
    // (contentType, contentLength, isByteRangeAccessSupported) before the
    // data is returned, otherwise AVPlayer refuses the asset. Skipping this
    // is what produced the cryptic -12860/-12785 errors we saw initially.

    // AVAssetResourceLoadingContentInformationRequest.contentType expects a
    // UTI string. There's no AVFileType constant for HLS playlists so we use
    // the system-registered UTI directly. The MIME-type equivalent is
    // application/vnd.apple.mpegurl but contentType wants the UTI.
    private static let playlistContentType = "public.m3u-playlist"
    private static let webVTTContentType = "org.w3.webvtt"

    private func respondInMemory(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        data: Data,
        contentType: String,
        label: String
    ) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = loadingRequest.dataRequest {
            let offset = Int(dataRequest.requestedOffset)
            let length = dataRequest.requestedLength
            let end = min(offset + length, data.count)
            if offset >= data.count {
                log.error("dataRequest offset \(offset) past EOF \(data.count) for \(label)")
                loadingRequest.finishLoading(with: URLError(.dataNotAllowed))
                return
            }
            let slice = data.subdata(in: offset..<end)
            dataRequest.respond(with: slice)
        }
        loadingRequest.finishLoading()
        log.debug("← \(label) bytes=\(data.count) contentType=\(contentType)")
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
            log.error("synthetic master requested without pendingVariantURL set")
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

        // CODECS + RESOLUTION are strongly recommended by the HLS authoring
        // spec. The upstream Floatplane variant we point at is H.264 high +
        // AAC-LC (avc1.640028, mp4a.40.2) at 1080p — values cribbed from the
        // delivery-info payload. Adding them keeps AVPlayer's strict parser
        // happy. SUBTITLES attr ties the rendition group to the variant.
        let subtitlesAttr = pendingTextTracks.isEmpty ? "" : ",SUBTITLES=\"subs\""
        let streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\(subtitlesAttr)"
        lines.append(streamInf)
        lines.append(interceptedVariantURL.absoluteString)

        let manifest = lines.joined(separator: "\n") + "\n"
        log.debug("synthetic master playlist:\n\(manifest, privacy: .public)")
        guard let data = manifest.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        respondInMemory(loadingRequest, data: data, contentType: Self.playlistContentType, label: "synth/master")
    }

    private func handleSyntheticSubsPlaylist(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) throws {
        // Path is /<trackId>/subs.m3u8
        let trackId = url.pathComponents.dropFirst().first ?? ""
        guard let index = Int(trackId.dropFirst("subs".count)),
              index < pendingTextTracks.count else {
            log.error("synthetic subs request for unknown trackId=\(trackId)")
            throw URLError(.resourceUnavailable)
        }
        let duration = pendingDurationSeconds
        let lines: [String] = [
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
        log.debug("synthetic subs playlist for \(trackId):\n\(manifest, privacy: .public)")
        guard let data = manifest.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        respondInMemory(loadingRequest, data: data, contentType: Self.playlistContentType, label: "synth/subs.m3u8")
    }

    private func handleSyntheticVTT(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) async throws {
        let trackId = url.pathComponents.dropFirst().first ?? ""
        guard let index = Int(trackId.dropFirst("subs".count)),
              index < pendingTextTracks.count else {
            log.error("synthetic vtt request for unknown trackId=\(trackId)")
            throw URLError(.resourceUnavailable)
        }
        // Floatplane's text-track URLs are R2 pre-signed and unauth'd —
        // no DPoP needed and adding it would actually break the signature.
        let trackURL = pendingTextTracks[index].url
        log.debug("fetching WebVTT from \(trackURL.absoluteString, privacy: .private)")
        let (data, response) = try await session.data(from: trackURL)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            log.error("WebVTT fetch returned \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }
        respondInMemory(loadingRequest, data: data, contentType: Self.webVTTContentType, label: "synth/track.vtt")
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

        respondInMemory(loadingRequest, data: modifiedData, contentType: Self.playlistContentType, label: "variant m3u8")
    }

    // MARK: - Key Handling

    private func handleKeyRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        let data = try await fetchWithDPoP(url: realURL)
        respondInMemory(loadingRequest, data: data, contentType: "application/octet-stream", label: "key")
    }

    private func handleGenericRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        let data = try await fetchWithDPoP(url: realURL)
        respondInMemory(loadingRequest, data: data, contentType: "application/octet-stream", label: "generic")
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
