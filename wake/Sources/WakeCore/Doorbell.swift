import Foundation

/// Rings one URL with a bounded number of retries, because right after waking the network is often not up yet.
/// Not polling: it runs only when an event (login, wake) happens, and gives up after the last delay.
public struct Doorbell: Sendable {
    public static let defaultDelays: [Double] = [0, 5, 15, 30, 60, 120]

    public let url: URL
    public let delays: [Double]
    public let send: @Sendable (URL) async -> Bool
    public let sleep: @Sendable (Double) async -> Void

    public init(url: URL, delays: [Double] = Doorbell.defaultDelays,
                send: @escaping @Sendable (URL) async -> Bool = Doorbell.post,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.url = url
        self.delays = delays
        self.send = send
        self.sleep = sleep
    }

    /// Returns the attempt number that succeeded (1-based), or nil if every attempt failed.
    public func ring() async -> Int? {
        for (i, delay) in delays.enumerated() {
            if delay > 0 { await sleep(delay) }
            if await send(url) { return i + 1 }
        }
        return nil
    }

    @Sendable public static func post(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

/// Collapses a burst of events (wake + screen unlock + network change within seconds) into one ring.
public actor Debouncer {
    private var lastRing: Date?
    private let window: TimeInterval
    public init(window: TimeInterval = 20) { self.window = window }

    public func shouldRing(at now: Date = Date()) -> Bool {
        if let last = lastRing, now.timeIntervalSince(last) < window { return false }
        lastRing = now
        return true
    }
}
