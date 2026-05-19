//
//  SleepTimerService.swift
//  FloatNative
//
//  Sleep timer for late-night WAN-Show listeners. Pauses AVPlayerManager
//  playback after a chosen duration elapses. Lives as a singleton so it
//  keeps running across video changes within the same session; resets on
//  cold launch. See #31.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class SleepTimerService: ObservableObject {
    static let shared = SleepTimerService()

    /// Discrete duration options the Settings picker offers (in seconds).
    /// `nil` is the off / cancel state.
    static let options: [TimeInterval] = [
        15 * 60,
        30 * 60,
        45 * 60,
        60 * 60,
        90 * 60,
        120 * 60,
    ]

    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds: Int?

    private var ticker: AnyCancellable?

    var isActive: Bool { endDate != nil }

    private init() {}

    /// Arm (or re-arm) the timer for `duration` seconds. Replaces any
    /// existing armed timer.
    func arm(duration: TimeInterval) {
        cancel(stopTicker: false)
        let end = Date().addingTimeInterval(duration)
        endDate = end
        remainingSeconds = Int(duration)

        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    /// Cancel the timer. Safe to call when already off.
    func cancel() {
        cancel(stopTicker: true)
    }

    private func cancel(stopTicker: Bool) {
        endDate = nil
        remainingSeconds = nil
        if stopTicker {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func tick() {
        guard let endDate else {
            cancel(stopTicker: true)
            return
        }
        let remaining = Int(ceil(endDate.timeIntervalSinceNow))
        if remaining <= 0 {
            AVPlayerManager.shared.pause()
            cancel(stopTicker: true)
        } else {
            remainingSeconds = remaining
        }
    }

    /// Helper for Settings UI to format the countdown.
    static func formatRemaining(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        if totalMinutes >= 60 {
            let h = Double(totalMinutes) / 60.0
            return h.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(h)) hr"
                : String(format: "%.1f hr", h)
        }
        return "\(totalMinutes) min"
    }
}
