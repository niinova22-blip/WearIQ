import Foundation

public protocol QuotaClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: QuotaClock {
    public init() {}
    public var now: Date { Date() }
}

/// Persistence for quota state. The app backs this with the Keychain so that
/// reinstalling the app doesn't reset the counter.
public protocol QuotaStateStore: AnyObject {
    func load() -> QuotaState?
    func save(_ state: QuotaState)
}

public final class InMemoryQuotaStore: QuotaStateStore {
    public var state: QuotaState?
    public init(_ state: QuotaState? = nil) { self.state = state }
    public func load() -> QuotaState? { state }
    public func save(_ state: QuotaState) { self.state = state }
}

public struct QuotaState: Codable, Equatable, Sendable {
    /// Day key (yyyy-MM-dd in the user's calendar) the counters belong to.
    public var day: String
    /// Hashes of the product keys analysed on `day`. Re-analysing one of them is free.
    /// Only hashes are kept so the quota store never contains browsing history.
    public var consumedProductKeys: [String]
    /// Latest time we've ever observed. Used to detect the clock being turned back.
    public var highWaterMark: Date

    public init(day: String, consumedProductKeys: [String], highWaterMark: Date) {
        self.day = day
        self.consumedProductKeys = consumedProductKeys
        self.highWaterMark = highWaterMark
    }
}

public enum QuotaDecision: Equatable, Sendable {
    /// A new analysis may run. Call `recordSuccess` only after it actually succeeds.
    case allowed(remainingBefore: Int)
    /// This product was already analysed today (or user is premium); no charge.
    case free
    case exhausted
}

/// Daily allowance of successful garment analyses for free users.
///
/// Rules:
/// - `dailyLimit` (4) new successful analyses per day.
/// - Failed lookups never consume (callers only record on success).
/// - Re-analysing a product already analysed today is free; reopening a saved
///   analysis must not go through this manager at all.
/// - Turning the device clock back does not reset the day (high-water mark).
///   Turning it forward cannot be fully prevented offline; `trustedTime` can be
///   plugged in later with a server timestamp.
public final class DailyScanQuotaManager {
    public let dailyLimit: Int
    private let clock: QuotaClock
    private let store: QuotaStateStore
    private let calendar: Calendar

    public init(dailyLimit: Int = 4, clock: QuotaClock = SystemClock(), store: QuotaStateStore, calendar: Calendar = .current) {
        self.dailyLimit = dailyLimit
        self.clock = clock
        self.store = store
        self.calendar = calendar
    }

    public func remaining(isPremium: Bool = false) -> Int {
        if isPremium { return .max }
        return max(0, dailyLimit - currentState().consumedProductKeys.count)
    }

    public func check(productKey: String, isPremium: Bool) -> QuotaDecision {
        if isPremium { return .free }
        let state = currentState()
        if state.consumedProductKeys.contains(Self.digest(productKey)) { return .free }
        let left = dailyLimit - state.consumedProductKeys.count
        return left > 0 ? .allowed(remainingBefore: left) : .exhausted
    }

    /// Records a successful new analysis. Returns false if the quota was already full.
    @discardableResult
    public func recordSuccess(productKey: String, isPremium: Bool) -> Bool {
        if isPremium { return true }
        var state = currentState()
        let key = Self.digest(productKey)
        if state.consumedProductKeys.contains(key) { return true }
        guard state.consumedProductKeys.count < dailyLimit else { return false }
        state.consumedProductKeys.append(key)
        store.save(state)
        return true
    }

    /// Loads state, rolling over to a new day when appropriate.
    private func currentState() -> QuotaState {
        let observed = clock.now
        guard var state = store.load() else {
            let fresh = QuotaState(day: dayKey(observed), consumedProductKeys: [], highWaterMark: observed)
            store.save(fresh)
            return fresh
        }
        // If the clock went backwards, keep using the latest time we've seen.
        let effective = max(observed, state.highWaterMark)
        let today = dayKey(effective)
        var changed = false
        if effective > state.highWaterMark { state.highWaterMark = effective; changed = true }
        if today != state.day {
            state.day = today
            state.consumedProductKeys = []
            changed = true
        }
        if changed { store.save(state) }
        return state
    }

    /// FNV-1a 64-bit; stable across launches (unlike `Hasher`) and dependency-free.
    static func digest(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
