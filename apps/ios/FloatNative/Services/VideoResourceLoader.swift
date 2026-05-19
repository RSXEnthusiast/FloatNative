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
    /// Cache of the full WebVTT body per track index. Each AVPlayer subtitle
    /// segment request reads from this cache; we only hit R2 once per video.
    private var vttBodyCache: [Int: String] = [:]
    /// HLS subtitle segment duration. Apple's HLS Authoring Spec recommends
    /// short subtitle segments aligned with video segments; 6s matches what
    /// Apple's reference samples use and is well within Floatplane variant
    /// chunk durations (typically ~10s).
    private static let subtitleSegmentDuration: Int = 6

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
        // New video → flush the WebVTT cache so we re-fetch instead of serving
        // the previous video's cues.
        self.vttBodyCache.removeAll()
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
                // Check if this is a Key. Match case-insensitively: Floatplane's
                // EXT-X-KEY URIs use `/api/video/watchKey?token=…`, which
                // wouldn't match a literal "key" substring search.
                else if realURL.absoluteString.range(of: "key", options: .caseInsensitive) != nil
                    || realURL.pathExtension == "key" {
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

        var lines: [String] = ["#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-INDEPENDENT-SEGMENTS"]

        // Each text track becomes a SUBTITLES rendition pointing at a per-
        // track playlist. URI is relative to the master so AVPlayer resolves
        // it against `floatnative://__synth__/master.m3u8` → the loader's
        // synthetic subs path.
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
                "URI=\"\(trackId)/subs.m3u8\""
            ]
            lines.append("#EXT-X-MEDIA:" + attrs.joined(separator: ","))
        }

        // Variant URI is the upstream HTTPS URL directly — Floatplane's
        // variant URL embeds a query-string token, so it's pre-authenticated
        // and AVPlayer can fetch it without going through our loader. This
        // avoids the AVPlayer HLS parser quirk where master playlists with
        // non-http variant URIs are rejected as InvalidPlaylist (-12881).
        let subtitlesAttr = pendingTextTracks.isEmpty ? "" : ",SUBTITLES=\"subs\""
        let streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\(subtitlesAttr)"
        lines.append(streamInf)
        lines.append(variantURL.absoluteString)

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
        let totalDuration = pendingDurationSeconds
        let segDuration = Self.subtitleSegmentDuration
        let segmentCount = max(1, Int(ceil(Double(totalDuration) / Double(segDuration))))

        // Apple's HLS parser rejects WebVTT playlists with a single long
        // segment as invalid (CoreMediaErrorDomain -12881 / "invalid
        // playlist"). Match Apple's reference: TARGETDURATION = the per-
        // segment duration, then one #EXTINF per segment with a per-segment
        // URL the loader can fingerprint via its index.
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(segDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        for i in 0..<segmentCount {
            let isLast = i == segmentCount - 1
            let actualDur: Double
            if isLast {
                let remainder = totalDuration - i * segDuration
                actualDur = max(0.001, Double(remainder))
            } else {
                actualDur = Double(segDuration)
            }
            lines.append("#EXTINF:\(String(format: "%.3f", actualDur)),")
            // Relative URI — AVPlayer resolves against the subs.m3u8 URL.
            lines.append("seg-\(i).vtt")
        }
        lines.append("#EXT-X-ENDLIST")
        let manifest = lines.joined(separator: "\n") + "\n"
        log.debug("synthetic subs playlist for \(trackId) (\(segmentCount) segments × \(segDuration)s):\n\(manifest, privacy: .public)")
        guard let data = manifest.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        respondInMemory(loadingRequest, data: data, contentType: Self.playlistContentType, label: "synth/subs.m3u8")
    }

    private func handleSyntheticVTT(_ loadingRequest: AVAssetResourceLoadingRequest, url: URL) async throws {
        // Path is either /<trackId>/seg-<N>.vtt (chunked) or /<trackId>/track.vtt (legacy)
        let comps = Array(url.pathComponents.dropFirst())
        guard let trackId = comps.first,
              let index = Int(trackId.dropFirst("subs".count)),
              index < pendingTextTracks.count else {
            log.error("synthetic vtt request for unknown trackId=\(comps.first ?? "?")")
            throw URLError(.resourceUnavailable)
        }
        let filePart = comps.last ?? "track.vtt"
        let segmentIndex: Int
        if filePart.hasPrefix("seg-"), let dot = filePart.firstIndex(of: ".") {
            let numStr = filePart[filePart.index(filePart.startIndex, offsetBy: 4)..<dot]
            segmentIndex = Int(numStr) ?? 0
        } else {
            segmentIndex = 0
        }

        // Cache the full WebVTT body per track. R2 URLs are 15-min pre-signed;
        // a 60-min video would otherwise re-fetch on every segment.
        let body: String
        if let cached = vttBodyCache[index] {
            body = cached
        } else {
            let trackURL = pendingTextTracks[index].url
            log.debug("fetching WebVTT from \(trackURL.absoluteString, privacy: .private)")
            let (raw, response) = try await session.data(from: trackURL)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                log.error("WebVTT fetch returned \(httpResponse.statusCode)")
                throw URLError(.badServerResponse)
            }
            guard let parsed = String(data: raw, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            vttBodyCache[index] = parsed
            body = parsed
        }

        let segment = buildSegmentVTT(
            from: body,
            segmentIndex: segmentIndex,
            segmentDuration: Self.subtitleSegmentDuration
        )
        guard let data = segment.data(using: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        respondInMemory(loadingRequest, data: data, contentType: Self.webVTTContentType, label: "synth/seg-\(segmentIndex).vtt")
    }

    // MARK: - WebVTT slicing (GH #11)

    private struct VTTCue {
        let startSec: Double
        let endSec: Double
        let payload: String  // identifier (if any) + settings line + text — everything after the timestamp line
    }

    /// Slice the source WebVTT into the cues that overlap a given HLS segment
    /// window and return a fresh WebVTT body with the proper X-TIMESTAMP-MAP
    /// header for that segment. Cue timestamps are kept in their original
    /// (absolute) form, which is how Apple's reference subtitle samples are
    /// structured — X-TIMESTAMP-MAP=MPEGTS:0 anchors LOCAL=0 to PTS=0 so the
    /// renderer reads cue times as absolute video offsets.
    private func buildSegmentVTT(from source: String, segmentIndex: Int, segmentDuration: Int) -> String {
        let segStart = Double(segmentIndex * segmentDuration)
        let segEnd = segStart + Double(segmentDuration)
        let cues = parseWebVTTCues(source)
        let filtered = cues.filter { $0.startSec < segEnd && $0.endSec > segStart }

        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        for cue in filtered {
            out += "\(formatVTTTime(cue.startSec)) --> \(formatVTTTime(cue.endSec))\n"
            out += "\(cue.payload)\n\n"
        }
        return out
    }

    private func parseWebVTTCues(_ content: String) -> [VTTCue] {
        // Normalize CRLF; WebVTT spec allows either but our splitter is `\n`.
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Cues are blank-line-separated blocks. The first block is the WEBVTT
        // header; subsequent blocks may be NOTE, STYLE, REGION, or a cue.
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [VTTCue] = []
        for (i, block) in blocks.enumerated() {
            if i == 0 { continue }  // header block
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("NOTE") || trimmed.hasPrefix("STYLE") || trimmed.hasPrefix("REGION") { continue }
            let lines = trimmed.components(separatedBy: "\n")
            // Find the timestamp line (the first line containing "-->")
            guard let tsIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let tsLine = lines[tsIdx]
            guard let (startSec, endSec) = parseVTTTimestampLine(tsLine) else { continue }
            let payloadLines = lines.suffix(from: tsIdx + 1)
            let payload = payloadLines.joined(separator: "\n")
            cues.append(VTTCue(startSec: startSec, endSec: endSec, payload: payload))
        }
        return cues
    }

    /// Parse a WebVTT timestamp line of the form
    /// `HH:MM:SS.mmm --> HH:MM:SS.mmm [settings]` or `MM:SS.mmm --> ...`.
    /// Returns (start, end) in seconds. Any cue settings are dropped — we
    /// preserve them by including them in the payload, but for timing purposes
    /// we only need the two timestamps.
    private func parseVTTTimestampLine(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let leftStr = parts[0].trimmingCharacters(in: .whitespaces)
        let rightStr = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        guard let start = parseVTTTimestamp(leftStr), let end = parseVTTTimestamp(rightStr) else { return nil }
        return (start, end)
    }

    private func parseVTTTimestamp(_ str: String) -> Double? {
        // HH:MM:SS.mmm OR MM:SS.mmm
        let dotParts = str.components(separatedBy: ".")
        guard dotParts.count == 2, let ms = Double(dotParts[1]) else { return nil }
        let colonParts = dotParts[0].components(separatedBy: ":")
        guard !colonParts.isEmpty else { return nil }
        let nums = colonParts.compactMap { Double($0) }
        guard nums.count == colonParts.count else { return nil }
        // [HH], MM, SS pattern: walk right-to-left.
        var total: Double = 0
        if nums.count == 3 { total = nums[0] * 3600 + nums[1] * 60 + nums[2] }
        else if nums.count == 2 { total = nums[0] * 60 + nums[1] }
        else if nums.count == 1 { total = nums[0] }
        return total + ms / 1000.0
    }

    private func formatVTTTime(_ seconds: Double) -> String {
        let totalMs = max(0, Int((seconds * 1000).rounded()))
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
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
