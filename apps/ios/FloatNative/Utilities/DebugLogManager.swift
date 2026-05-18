//
//  DebugLogManager.swift
//  FloatNative
//
//  Ring-buffer of recent diagnostic events. Surfaced from Settings → Debug Log
//  so users can copy/paste a real error into a GitHub issue. The buffer is
//  bounded; nothing is persisted to disk.
//
//  Thread-safe: `append` is callable from any thread. `@Published` updates
//  hop to the main queue so SwiftUI views observe consistently.
//

import Foundation
import os

final class DebugLogManager: ObservableObject {

    static let shared = DebugLogManager()

    enum Category: String, Codable {
        case api
        case decode
        case auth
        case other
    }

    struct Entry: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let category: Category
        let message: String
        let detail: String?

        init(category: Category, message: String, detail: String?) {
            self.id = UUID()
            self.timestamp = Date()
            self.category = category
            self.message = message
            self.detail = detail
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let limit: Int
    private let lock = OSAllocatedUnfairLock()
    private var storage: [Entry] = []

    init(limit: Int = 200) {
        self.limit = limit
    }

    func append(_ entry: Entry) {
        lock.lock()
        storage.insert(entry, at: 0)
        if storage.count > limit {
            storage.removeLast(storage.count - limit)
        }
        let snapshot = storage
        lock.unlock()
        publishOnMain(snapshot)
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        let snapshot = storage
        lock.unlock()
        publishOnMain(snapshot)
    }

    /// Render entries as a single block of text suitable for emailing or
    /// pasting into a GitHub issue.
    func exportText() -> String {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return snapshot.map { entry in
            var lines = [
                "[\(formatter.string(from: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)"
            ]
            if let detail = entry.detail, !detail.isEmpty {
                lines.append(detail)
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func publishOnMain(_ snapshot: [Entry]) {
        if Thread.isMainThread {
            self.entries = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries = snapshot
            }
        }
    }
}

extension DebugLogManager.Entry {
    static func api(_ message: String, detail: String? = nil) -> Self {
        .init(category: .api, message: message, detail: detail)
    }

    static func decode(message: String, verbose: String?) -> Self {
        .init(category: .decode, message: message, detail: verbose)
    }

    static func auth(_ message: String, detail: String? = nil) -> Self {
        .init(category: .auth, message: message, detail: detail)
    }
}
