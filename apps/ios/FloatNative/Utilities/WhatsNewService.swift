//
//  WhatsNewService.swift
//  FloatNative
//
//  Loads the bundled `whats-new.json`, decides whether to show the popup
//  for this launch, and persists the last-seen version so it doesn't fire
//  again until the next release.
//
//  Design notes (per #42):
//  - Fresh installs are suppressed — we set lastSeen = current on first
//    launch so the popup only ever fires after an *upgrade*.
//  - Skipped versions don't accumulate — we always show only the latest.
//  - Settings → "What's New in this version" re-opens the sheet on demand
//    without mutating lastSeen.
//

import Foundation
import SwiftUI

struct WhatsNewContent: Codable, Equatable {
    let version: String
    let title: String
    let items: [Item]

    struct Item: Codable, Equatable, Identifiable {
        let icon: String
        let title: String
        let body: String
        var id: String { title }
    }
}

@MainActor
final class WhatsNewService: ObservableObject {
    static let shared = WhatsNewService()

    private static let lastSeenVersionKey = "lastSeenWhatsNewVersion"
    private static let firstLaunchKey = "whatsNewFirstLaunchSeeded"

    /// Bundled content, decoded once. `nil` means the JSON isn't present
    /// or didn't parse — we just no-op the feature in that case.
    let content: WhatsNewContent?

    @Published var isPresented = false

    private init() {
        self.content = Self.loadBundledContent()
    }

    /// Call once from the app's root `.onAppear`. Sets `isPresented = true`
    /// if there's something new to show. First-launch users are suppressed
    /// (we treat the bundled version as "already seen").
    func presentIfNeeded() {
        guard let content else { return }
        let defaults = UserDefaults.standard

        if !defaults.bool(forKey: Self.firstLaunchKey) {
            // First launch ever — pre-mark the current version as seen so
            // the popup doesn't fire on a fresh install. The popup only
            // appears after an *update* bumps `version`.
            defaults.set(true, forKey: Self.firstLaunchKey)
            defaults.set(content.version, forKey: Self.lastSeenVersionKey)
            return
        }

        let lastSeen = defaults.string(forKey: Self.lastSeenVersionKey)
        if lastSeen != content.version {
            isPresented = true
        }
    }

    /// Settings-triggered re-open. Doesn't touch lastSeen.
    func presentManually() {
        guard content != nil else { return }
        isPresented = true
    }

    /// Called by WhatsNewSheet's Close button.
    func dismiss() {
        if let content {
            UserDefaults.standard.set(content.version, forKey: Self.lastSeenVersionKey)
        }
        isPresented = false
    }

    // MARK: - Bundle loading

    private static func loadBundledContent() -> WhatsNewContent? {
        guard let url = Bundle.main.url(forResource: "whats-new", withExtension: "json") else {
            print("⚠️ [WhatsNew] whats-new.json not found in bundle")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(WhatsNewContent.self, from: data)
        } catch {
            print("⚠️ [WhatsNew] failed to decode whats-new.json: \(error)")
            return nil
        }
    }
}
