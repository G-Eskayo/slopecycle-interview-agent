import Foundation

/// Saves each Submission into the outbox first, then sends everything waiting there, oldest first.
/// Flushes run one at a time; a Submission leaves the outbox only after GitHub has it on main.
public actor SendService {
    public enum SubmitResult: Sendable, Equatable {
        case sent(id: String, recording: RecordingHandling)
        /// Saved in the outbox; it goes out on the next flush (network back, launch, settings fixed).
        case queued(id: String, recording: RecordingHandling, reason: QueueError)
    }

    public struct FlushReport: Sendable, Equatable {
        public var sent: [String] = []
        public var alreadyPresent: [String] = []
        public var failed: [String: QueueError] = [:]
        public var settingsProblem: SettingsProblem?
        public var remaining: Int = 0
    }

    public let outbox: Outbox
    let client: any HTTPClient
    let settings: @Sendable () -> QueueSettings
    let appVersion: String
    let compressor: any RecordingCompressor
    let apiBase: URL
    let backoff: @Sendable (Int) async -> Void
    let clock: @Sendable () -> Date
    private var lastFlush: Task<FlushReport, Never>?

    public init(outbox: Outbox, client: any HTTPClient, appVersion: String,
                compressor: any RecordingCompressor = AACSpeechCompressor(),
                apiBase: URL = URL(string: "https://api.github.com")!,
                backoff: @escaping @Sendable (Int) async -> Void = GitHubQueueWriter.defaultBackoff,
                clock: @escaping @Sendable () -> Date = { Date() },
                settings: @escaping @Sendable () -> QueueSettings) {
        self.outbox = outbox
        self.client = client
        self.appVersion = appVersion
        self.compressor = compressor
        self.apiBase = apiBase
        self.backoff = backoff
        self.clock = clock
        self.settings = settings
    }

    /// Throws `SettingsProblem` (nothing saved; open Settings) or `DraftProblem` / file errors (nothing saved).
    /// Otherwise the Submission is safely in the outbox and the result says whether it already went out.
    public func submit(_ draft: Draft) async throws -> SubmitResult {
        let valid = try settings().validated()
        let saved = try await outbox.save(draft, interviewer: valid.interviewer, appVersion: appVersion,
                                          now: clock(), compressor: compressor)
        let id = saved.stored.id
        let report = await flush()
        if !outbox.contains(id: id) { return .sent(id: id, recording: saved.recording) }
        let reason = report.failed[id] ?? (report.failed.values.first(where: \.isOffline) ?? .offline)
        return .queued(id: id, recording: saved.recording, reason: reason)
    }

    /// Sends everything in the outbox, oldest first. Safe to call from any event; calls are serialised.
    @discardableResult
    public func flush() async -> FlushReport {
        let previous = lastFlush
        let task = Task { [previous] in
            _ = await previous?.value
            return await self.runFlush()
        }
        lastFlush = task
        return await task.value
    }

    private func runFlush() async -> FlushReport {
        var report = FlushReport()
        let pending = outbox.pending()
        guard !pending.isEmpty else { return report }
        let valid: ValidSettings
        do {
            valid = try settings().validated()
        } catch {
            report.settingsProblem = error as? SettingsProblem
            report.remaining = pending.count
            return report
        }
        let writer = GitHubQueueWriter(client: client, repo: valid.repo, token: valid.token,
                                       apiBase: apiBase, backoff: backoff)
        for (index, submission) in pending.enumerated() {
            do {
                switch try await writer.write(submission) {
                case .committed: report.sent.append(submission.id)
                case .alreadyPresent: report.alreadyPresent.append(submission.id)
                }
                try? outbox.remove(id: submission.id)
            } catch let error as QueueError {
                report.failed[submission.id] = error
                if error.isOffline {
                    for later in pending[(index + 1)...] { report.failed[later.id] = .offline }
                    break
                }
            } catch {
                report.failed[submission.id] = .badResponse(String(describing: type(of: error)))
            }
        }
        report.remaining = outbox.pending().count
        return report
    }
}
