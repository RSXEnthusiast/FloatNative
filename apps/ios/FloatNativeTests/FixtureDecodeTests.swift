//
//  FixtureDecodeTests.swift
//  FloatNativeTests
//
//  Decode every JSON fixture in `Fixtures/` through the production model used
//  for that endpoint. A schema regression in the Floatplane response — or a
//  newly-required field that the spec doesn't mark required — fails the test
//  here before it can fail in TestFlight.
//

import Testing
import Foundation
@testable import FloatNative

/// Marker class used to anchor `Bundle(for:)` lookups to the test target.
private final class FixtureBundleAnchor {}

struct FixtureDecodeTests {

    @Test func everyFixtureDecodes() throws {
        let fixtures = try loadFixtures()
        #expect(!fixtures.isEmpty, "No fixtures were discovered. Make sure Fixtures/ is in the test target's resources.")

        for fixture in fixtures {
            let bodyData = try JSONSerialization.data(withJSONObject: fixture.body, options: [])
            let decoder = makeDecoder()
            do {
                try decode(path: fixture.path, body: bodyData, decoder: decoder)
            } catch {
                Issue.record(
                    "Fixture \(fixture.fileName) (\(fixture.path)) failed to decode: \(DecodingErrorFormatter.summary(error))"
                )
                throw error
            }
        }
    }

    @Test func multiCreatorFeedFixtureRoundTrips() throws {
        let fixtures = try loadFixtures().filter {
            $0.path.hasPrefix("/api/v3/content/creator/list")
        }
        for fixture in fixtures {
            let bodyData = try JSONSerialization.data(withJSONObject: fixture.body)
            let response = try makeDecoder().decode(CreatorListResponse.self, from: bodyData)
            #expect(!response.blogPosts.isEmpty || !response.lastElements.isEmpty)
        }
    }

    // MARK: - helpers

    /// Route table mapping request path prefixes to the production model used
    /// to decode that response. Add new entries when capturing fixtures for
    /// new endpoints.
    private func decode(path: String, body: Data, decoder: JSONDecoder) throws {
        switch path {
        case let p where p.hasPrefix("/api/v3/content/creator/list"):
            _ = try decoder.decode(CreatorListResponse.self, from: body)
        case let p where p.hasPrefix("/api/v3/content/post"):
            _ = try decoder.decode(BlogPostDetailedWithInteraction.self, from: body)
        case let p where p.hasPrefix("/api/v3/content/video"):
            _ = try decoder.decode(VideoContent.self, from: body)
        case let p where p.hasPrefix("/api/v3/user/subscriptions"):
            _ = try decoder.decode([UserSubscriptionModel].self, from: body)
        case let p where p.hasPrefix("/api/v3/delivery/info"):
            _ = try decoder.decode(CdnDeliveryV3Response.self, from: body)
        case let p where p.hasPrefix("/api/v3/content/history"):
            _ = try decoder.decode([WatchHistoryResponse].self, from: body)
        case let p where p.hasPrefix("/api/v3/creator/info"):
            _ = try decoder.decode(CreatorModelV3.self, from: body)
        case let p where p.hasPrefix("/api/v3/comment/replies"):
            _ = try decoder.decode([CommentModel].self, from: body)
        case let p where p.hasPrefix("/api/v3/comment"):
            _ = try decoder.decode([CommentModel].self, from: body)
        default:
            Issue.record(
                "No fixture decoder mapping for path \(path). Add one in FixtureDecodeTests.decode(path:body:decoder:)."
            )
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateString) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Bad ISO date: \(dateString)")
            )
        }
        return decoder
    }

    private struct Fixture {
        let fileName: String
        let path: String
        let status: Int
        let body: Any
    }

    private func loadFixtures() throws -> [Fixture] {
        let bundle = Bundle(for: FixtureBundleAnchor.self)
        guard let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) else {
            return []
        }
        var results: [Fixture] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: url)
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let request = top["request"] as? [String: Any],
                  let response = top["response"] as? [String: Any],
                  let path = request["path"] as? String,
                  let status = response["status"] as? Int,
                  let body = response["body"]
            else { continue }
            results.append(Fixture(
                fileName: url.lastPathComponent,
                path: path,
                status: status,
                body: body
            ))
        }
        return results
    }
}
