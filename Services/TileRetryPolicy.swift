//
//  TileRetryPolicy.swift
//  QuiteListie
//
//  Back-off bookkeeping for tiles whose fetch came back empty.
//
//  The map keys tile requests off a "already asked for this one" set so a pan
//  doesn't re-request the same tile every frame. That set is only cleared when a
//  tile leaves the viewport, which means a tile that *failed* is never asked for
//  again while it stays on screen — a blip or a rate-limit pause leaves a hole
//  that only fills if the user happens to zoom away and back.
//
//  This retries a failed tile where it sits, after a growing back-off, and caps
//  the attempts so a tile the service genuinely has nothing for (open sea, a gap
//  in the layer) isn't re-requested on every layout pass.
//
//  Generic over the key so it can be exercised without a live map.
//

import Foundation

struct TileRetryPolicy<Key: Hashable> {
    /// Attempts allowed while the tile stays on screen, the first included.
    let maxAttempts: Int
    /// Back-off before the first retry; each subsequent one doubles it.
    let baseDelay: TimeInterval

    private var failures: [Key: (attempts: Int, at: TimeInterval)] = [:]

    init(maxAttempts: Int = 3, baseDelay: TimeInterval = 2) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
    }

    /// Wait before the attempt that follows `attempts` failures: 2s, then 4s.
    /// Long enough to outlast a blip or a rate-limit pause, short enough that
    /// the map still feels live.
    func delay(afterAttempts attempts: Int) -> TimeInterval {
        baseDelay * pow(2, Double(max(0, attempts - 1)))
    }

    /// Whether `key` may be requested now. True for anything not known to have
    /// failed, false while a back-off is running or once the cap is reached.
    func mayRequest(_ key: Key, now: TimeInterval) -> Bool {
        guard let failure = failures[key] else { return true }
        guard failure.attempts < maxAttempts else { return false }
        return now - failure.at >= delay(afterAttempts: failure.attempts)
    }

    /// Record a failed fetch. Returns how long until the tile may be tried
    /// again, or nil when it has run out of attempts.
    @discardableResult
    mutating func noteFailure(_ key: Key, now: TimeInterval) -> TimeInterval? {
        let attempts = (failures[key]?.attempts ?? 0) + 1
        failures[key] = (attempts, now)
        guard attempts < maxAttempts else { return nil }
        return delay(afterAttempts: attempts)
    }

    /// A tile that arrived: drop its history so later trouble starts fresh.
    mutating func noteSuccess(_ key: Key) {
        failures[key] = nil
    }

    /// A tile that left the viewport. Forgetting it gives a clean attempt if the
    /// user comes back, and keeps the table from growing as they pan.
    mutating func forget(_ key: Key) {
        failures[key] = nil
    }

    mutating func removeAll() {
        failures.removeAll()
    }

    /// Tiles currently being tracked — for tests and diagnostics.
    var trackedCount: Int { failures.count }
}
