import Foundation
import Testing
@testable import WakeCore

actor Counter { var n = 0; func inc() -> Int { n += 1; return n } }

@Test func ringsOnceWhenTheFirstAttemptWorks() async {
    let c = Counter()
    let bell = Doorbell(url: URL(string: "http://x")!, delays: [0, 5, 15], send: { _ in _ = await c.inc(); return true }, sleep: { _ in })
    #expect(await bell.ring() == 1)
    #expect(await c.n == 1)
}

@Test func keepsTryingWhileTheNetworkComesUp() async {
    let c = Counter()
    let bell = Doorbell(url: URL(string: "http://x")!, delays: [0, 5, 15, 30], send: { _ in await c.inc() >= 3 }, sleep: { _ in })
    #expect(await bell.ring() == 3)
}

@Test func givesUpAfterTheLastDelayInsteadOfPollingForever() async {
    let c = Counter()
    let bell = Doorbell(url: URL(string: "http://x")!, delays: [0, 1, 2], send: { _ in _ = await c.inc(); return false }, sleep: { _ in })
    #expect(await bell.ring() == nil)
    #expect(await c.n == 3)
}

@Test func waitsTheConfiguredDelaysInOrder() async {
    actor Log { var waits: [Double] = []; func add(_ d: Double) { waits.append(d) } }
    let log = Log()
    let bell = Doorbell(url: URL(string: "http://x")!, delays: [0, 5, 15], send: { _ in false }, sleep: { await log.add($0) })
    _ = await bell.ring()
    #expect(await log.waits == [5, 15])
}

@Test func aBurstOfEventsRingsOnce() async {
    let d = Debouncer(window: 20)
    let t0 = Date()
    #expect(await d.shouldRing(at: t0))
    #expect(await !d.shouldRing(at: t0.addingTimeInterval(3)))
    #expect(await d.shouldRing(at: t0.addingTimeInterval(25)))
}

@Test func realPostToAClosedPortFailsCleanly() async {
    #expect(await Doorbell.post(URL(string: "http://127.0.0.1:9/nothing")!) == false)
}
