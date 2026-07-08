import Foundation

/// Bounded async semaphore used to cap outstanding HTTP requests to a single
/// upstream tile service. Ensures that when a hundred tiles are requested
/// simultaneously we don't fire a hundred concurrent fetches — they queue
/// in-process, cancellation propagates cleanly, and the tile API isn't hammered
/// into serving 15 s worth of pileup timeouts.
actor FetchLimiter {
    private let defaultCapacity: Int
    private var capacity: Int
    private var inFlight = 0
    /// If set, the capacity was temporarily reduced. Once the wall-clock passes
    /// this date, capacity is restored on the next release/acquire.
    private var restoreCapacityAt: Date?

    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []
    /// IDs that were cancelled before their waiter got enqueued — swept when
    /// the enqueue eventually runs.
    private var cancelledBeforeEnqueue: Set<UUID> = []

    init(capacity: Int) {
        self.defaultCapacity = capacity
        self.capacity = capacity
    }

    /// Temporarily shrink capacity for `seconds`. If the server tells us to
    /// slow down (rate-limit warning), throttle everyone down. In-flight
    /// requests continue but new acquires wait. Capacity restores automatically
    /// once the deadline passes.
    func throttle(to newCapacity: Int, for seconds: TimeInterval) {
        capacity = max(1, newCapacity)
        restoreCapacityAt = Date().addingTimeInterval(seconds)
    }

    /// Wait for a slot. Returns `false` if the calling task is cancelled while
    /// waiting (so the caller can bail without holding a slot).
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        maybeRestoreCapacity()
        if inFlight < capacity {
            inFlight += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                Task { await self.enqueue(id: id, cont: cont) }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// Return a slot. Hand off directly to a waiting task if any.
    func release() {
        maybeRestoreCapacity()
        // If we've been throttled and inFlight exceeds current capacity, drop
        // the count without handing off — that shrinks us naturally.
        if inFlight > capacity {
            inFlight = max(0, inFlight - 1)
            return
        }
        if let next = waiters.first {
            waiters.removeFirst()
            next.cont.resume(returning: true)
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }

    private func maybeRestoreCapacity() {
        guard let deadline = restoreCapacityAt, Date() >= deadline else { return }
        capacity = defaultCapacity
        restoreCapacityAt = nil
    }

    // MARK: - Race-free enqueue/cancel

    private func enqueue(id: UUID, cont: CheckedContinuation<Bool, Never>) {
        if cancelledBeforeEnqueue.remove(id) != nil {
            cont.resume(returning: false)
            return
        }
        if inFlight < capacity {
            inFlight += 1
            cont.resume(returning: true)
            return
        }
        waiters.append(Waiter(id: id, cont: cont))
    }

    private func cancel(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let w = waiters.remove(at: idx)
            w.cont.resume(returning: false)
        } else {
            // Cancel arrived before enqueue — flag so enqueue bails.
            cancelledBeforeEnqueue.insert(id)
        }
    }
}
