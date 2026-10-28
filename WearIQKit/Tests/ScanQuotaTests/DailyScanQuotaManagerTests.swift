import Foundation
import Testing
@testable import ScanQuota

private final class TestClock: QuotaClock, @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
}

private func makeCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    return c
}

/// 2026-10-28 10:00 Istanbul
private let start = Date(timeIntervalSince1970: 1_793_170_800)

@Suite struct DailyScanQuotaTests {
    private func make(_ clock: TestClock, _ store: InMemoryQuotaStore = InMemoryQuotaStore()) -> DailyScanQuotaManager {
        DailyScanQuotaManager(clock: clock, store: store, calendar: makeCalendar())
    }

    @Test func allowsFourAnalysesPerDay() {
        let q = make(TestClock(start))
        for i in 0..<4 {
            #expect(q.check(productKey: "p\(i)", isPremium: false) == .allowed(remainingBefore: 4 - i))
            #expect(q.recordSuccess(productKey: "p\(i)", isPremium: false))
        }
        #expect(q.remaining() == 0)
        #expect(q.check(productKey: "p5", isPremium: false) == .exhausted)
        #expect(!q.recordSuccess(productKey: "p5", isPremium: false))
    }

    @Test func failedLookupDoesNotConsume() {
        let q = make(TestClock(start))
        // check() alone never consumes; only recordSuccess does.
        _ = q.check(productKey: "broken", isPremium: false)
        #expect(q.remaining() == 4)
    }

    @Test func sameProductIsFree() {
        let q = make(TestClock(start))
        q.recordSuccess(productKey: "a", isPremium: false)
        #expect(q.check(productKey: "a", isPremium: false) == .free)
        q.recordSuccess(productKey: "a", isPremium: false)
        #expect(q.remaining() == 3)
    }

    @Test func resetsNextDay() {
        let clock = TestClock(start)
        let q = make(clock)
        for i in 0..<4 { q.recordSuccess(productKey: "p\(i)", isPremium: false) }
        clock.advance(hours: 15) // 01:00 next day
        #expect(q.remaining() == 4)
    }

    @Test func turningClockBackDoesNotReset() {
        let clock = TestClock(start)
        let store = InMemoryQuotaStore()
        let q = make(clock, store)
        clock.advance(hours: 15) // next day
        for i in 0..<4 { q.recordSuccess(productKey: "p\(i)", isPremium: false) }
        clock.advance(hours: -15) // user sets clock back to "yesterday"
        #expect(q.remaining() == 0)
    }

    @Test func premiumIsUnlimited() {
        let q = make(TestClock(start))
        for i in 0..<20 { #expect(q.check(productKey: "p\(i)", isPremium: true) == .free) }
        #expect(q.remaining(isPremium: false) == 4)
    }

    @Test func storesOnlyHashedKeys() {
        let store = InMemoryQuotaStore()
        make(TestClock(start), store).recordSuccess(productKey: "https://shop.example/p/123", isPremium: false)
        #expect(store.state?.consumedProductKeys.first?.contains("shop") == false)
        #expect(DailyScanQuotaManager.digest("a") == DailyScanQuotaManager.digest("a"))
        #expect(DailyScanQuotaManager.digest("a") != DailyScanQuotaManager.digest("b"))
    }

    @Test func statePersistsAcrossInstances() {
        let clock = TestClock(start)
        let store = InMemoryQuotaStore()
        make(clock, store).recordSuccess(productKey: "x", isPremium: false)
        #expect(make(clock, store).remaining() == 3)
    }
}
