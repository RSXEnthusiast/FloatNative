//
//  VideoResourceLoader.swift
//  FloatNative
//
//  Intercepts AVPlayer's HLS subresource requests over a custom scheme so
//  we can attach DPoP / rewrite EXT-X-KEY URIs. The synthetic-HLS-master
//  caption path that lived here previously was abandoned (AVPlayer's HLS
//  parser kept rejecting it); captions are now rendered as a SwiftUI
//  overlay driven by the parsed cues — see CaptionsOverlay + AVPlayerManager.
//

import AVFoundation
import Foundation
import os

class VideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    private let session: URLSession
    private let customScheme = "floatnative"
    private let log = Logger(subsystem: "ca.maplespace.FloatNative", category: "VideoResourceLoader")

    override init() {
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config)
        super.init()
    }

    // MARK: - Delegate Methods

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url else { return false }

        if url.scheme == customScheme {
            handleCustomSchemeRequest(loadingRequest)
            return true
        }

        return false
    }

    // MARK: - Handlers

    private func handleCustomSchemeRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let url = loadingRequest.request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
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
                if realURL.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame {
                    try await handleManifestRequest(loadingRequest, realURL: realURL)
                }
                else if realURL.absoluteString.range(of: "key", options: .caseInsensitive) != nil
                    || realURL.pathExtension == "key" {
                    try await handleKeyRequest(loadingRequest, realURL: realURL)
                }
                else {
                    try await handleGenericRequest(loadingRequest, realURL: realURL)
                }
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    // MARK: - Manifest Handling

    private func handleManifestRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        let data = try await fetchWithDPoP(url: realURL)
        guard let manifestString = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        // Rewrite the manifest so AES-128 keys come back through us (we add
        // DPoP), but segments are fetched directly via https — there's no
        // need to proxy thousands of chunks.
        let baseURL = realURL.deletingLastPathComponent()
        var newLines: [String] = []
        manifestString.enumerateLines { line, _ in
            var processedLine = line

            if line.contains("#EXT-X-KEY") {
                if let range = line.range(of: "URI=\"") {
                    let rest = line[range.upperBound...]
                    if let endQuote = rest.firstIndex(of: "\"") {
                        let keyUriString = String(rest[..<endQuote])
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
            else if !line.hasPrefix("#") && !line.isEmpty {
                // Rewrite relative segment URIs to absolute https so AVPlayer
                // fetches them directly (bypassing this loader).
                if let segmentURL = URL(string: line, relativeTo: baseURL) {
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
        respond(loadingRequest, data: modifiedData, contentType: "public.m3u-playlist")
    }

    private func handleKeyRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        let data = try await fetchWithDPoP(url: realURL)
        respond(loadingRequest, data: data, contentType: "application/octet-stream")
    }

    private func handleGenericRequest(_ loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) async throws {
        let data = try await fetchWithDPoP(url: realURL)
        respond(loadingRequest, data: data, contentType: "application/octet-stream")
    }

    /// Fill both contentInformationRequest and dataRequest from an in-memory
    /// buffer. AVAssetResourceLoader requires contentType on the first
    /// content-information request or it rejects the asset.
    private func respond(_ loadingRequest: AVAssetResourceLoadingRequest, data: Data, contentType: String) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = loadingRequest.dataRequest {
            let offset = Int(dataRequest.requestedOffset)
            let length = dataRequest.requestedLength
            let end = min(offset &+ length, data.count)
            if offset < data.count {
                dataRequest.respond(with: data.subdata(in: offset..<max(end, offset)))
            }
        }
        loadingRequest.finishLoading()
    }

    // MARK: - Network

    private func fetchWithDPoP(url: URL) async throws -> Data {
        let accessToken = await FloatplaneAPI.shared.accessToken

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let token = accessToken {
            if let dpopProof = try? DPoPManager.shared.generateProof(
                httpMethod: "GET",
                httpUrl: url.absoluteString,
                accessToken: token
            ) {
                request.setValue(dpopProof, forHTTPHeaderField: "DPoP")
                request.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
            } else {
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
