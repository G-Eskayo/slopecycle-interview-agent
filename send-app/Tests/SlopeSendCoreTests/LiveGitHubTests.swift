import Foundation
import Testing
@testable import SlopeSendCore

/// Opt-in, against a real PRIVATE scratch repo with synthetic data only:
///   SLOPE_SEND_LIVE=1 SLOPE_SEND_TOKEN=… [SLOPE_SEND_REPO=owner/name] [SLOPE_SEND_M4A=/path/x.m4a] swift test --filter Live
/// The token is read from the environment only; it is never written anywhere.
private enum Live {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["SLOPE_SEND_LIVE"] == "1" && !(env["SLOPE_SEND_TOKEN"] ?? "").isEmpty
    static var token: String { env["SLOPE_SEND_TOKEN"] ?? "" }
    static var repo: RepoRef { RepoRef.parse(env["SLOPE_SEND_REPO"] ?? "G-Eskayo/slopecycle-queue-test")! }
    static var settings: QueueSettings { QueueSettings(interviewer: "Live Test", repository: repo.description, token: token) }
    static let client = URLSessionHTTPClient()

    static func writer() -> GitHubQueueWriter { GitHubQueueWriter(client: client, repo: repo, token: token) }

    static func get(_ path: String, raw: Bool = false) async throws -> HTTPResponse {
        let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)")!
        return try await client.send(HTTPRequest(method: "GET", url: url, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": raw ? "application/vnd.github.raw+json" : "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "SlopeCycle-Send-tests",
        ], body: nil))
    }

    static func head() async throws -> String {
        let r = try await get("git/ref/heads/main")
        return try JSONDecoder().decode(RefResponse.self, from: r.body).object.sha
    }

    struct CommitInfo: Decodable { struct C: Decodable { let message: String }; let sha: String; let commit: C; let parents: [Parent]
        struct Parent: Decodable { let sha: String } }

    static func commits(_ n: Int = 20) async throws -> [CommitInfo] {
        try JSONDecoder().decode([CommitInfo].self, from: try await get("commits?sha=main&per_page=\(n)").body)
    }

    /// Checks the folder on main holds exactly the expected files, byte for byte.
    static func verifyFolder(_ id: String, meta: SubmissionMeta, files: [String: Data], at ref: String) async throws {
        let listing = try await get("contents/submissions/\(id)?ref=\(ref)")
        #expect(listing.status == 200)
        struct Entry: Decodable { let name: String; let type: String }
        let entries = try JSONDecoder().decode([Entry].self, from: listing.body)
        #expect(Set(entries.map(\.name)) == Set(files.keys), "folder \(id) has \(entries.map(\.name))")
        #expect(entries.allSatisfy { $0.type == "file" })
        for (name, expected) in files {
            let r = try await get("contents/submissions/\(id)/\(name)?ref=\(ref)", raw: true)
            #expect(r.status == 200)
            #expect(r.body == expected, "\(name) differs")
        }
        let remoteMeta = try SubmissionMeta.decode(try await get("contents/submissions/\(id)/meta.json?ref=\(ref)", raw: true).body)
        #expect(remoteMeta == meta)
        if let n = meta.notesFile { #expect(meta.notesSHA256 == SHA256Hex.of(files[n]!)) }
        if let r = meta.recordingFile { #expect(meta.recordingSHA256 == SHA256Hex.of(files[r]!)) }
    }
}

private func liveDraft(_ notes: String, recording: URL? = nil, respondent: String = "P-90") -> Draft {
    Draft(respondentLabel: respondent, interviewType: .parent, interviewDate: InterviewDate.string(from: Date()),
          notes: notes, recordingURL: recording)
}

@Suite(.serialized, .enabled(if: Live.enabled, "set SLOPE_SEND_LIVE=1 and SLOPE_SEND_TOKEN"))
struct LiveGitHubTests {
    @Test func connectionCheckAndBadKey() async throws {
        try await Live.writer().checkConnection()
        let bad = GitHubQueueWriter(client: Live.client, repo: Live.repo, token: "github_pat_definitely_not_valid")
        await #expect(throws: QueueError.unauthorized) { try await bad.checkConnection() }
    }

    @Test func live1_notesOnly() async throws {
        let box = Outbox(root: tempDir())
        let svc = SendService(outbox: box, client: Live.client, appVersion: "1.0.0", settings: { Live.settings })
        let notes = "SYNTHETIC TEST DATA. Live test 1: notes only. Ünïcödé ✅ 👩🏽‍💻\nSecond line."
        let saved = try await box.save(liveDraft(notes), interviewer: "Live Test", appVersion: "1.0.0", now: Date())
        let meta = saved.stored.meta
        let metaBytes = try Data(contentsOf: saved.stored.url(of: "meta.json"))
        let report = await svc.flush()
        #expect(report.sent == [saved.stored.id], "\(report)")
        #expect(box.pending().isEmpty)
        let head = try await Live.head()
        try await Live.verifyFolder(meta.submissionID, meta: meta,
                                    files: ["meta.json": metaBytes, "notes.txt": Data(notes.utf8)], at: head)
        let top = try await Live.commits(1)[0]
        #expect(top.commit.message == "Submission \(meta.submissionID) from Live Test")
        #expect(top.parents.count == 1)
    }

    @Test(.enabled(if: Live.env["SLOPE_SEND_M4A"] != nil, "set SLOPE_SEND_M4A"))
    func live2_notesAndRecording() async throws {
        let source = URL(fileURLWithPath: Live.env["SLOPE_SEND_M4A"]!)
        let sourceHash = try SHA256Hex.ofFile(source)
        let box = Outbox(root: tempDir())
        let notes = "SYNTHETIC TEST DATA. Live test 2: notes plus a recording."
        let saved = try await box.save(liveDraft(notes, recording: source, respondent: "E-91"),
                                       interviewer: "Live Test", appVersion: "1.0.0", now: Date())
        guard case .compressed = saved.recording else { Issue.record("not compressed: \(saved.recording)"); return }
        let meta = saved.stored.meta
        #expect(meta.recordingFile == "recording.m4a")
        let metaBytes = try Data(contentsOf: saved.stored.url(of: "meta.json"))
        let recBytes = try Data(contentsOf: saved.stored.url(of: "recording.m4a"))
        #expect(meta.recordingSHA256 == SHA256Hex.of(recBytes))
        let outcome = try await Live.writer().write(saved.stored)
        guard case .committed = outcome else { Issue.record("\(outcome)"); return }
        try box.remove(id: saved.stored.id)
        try await Live.verifyFolder(meta.submissionID, meta: meta, files: [
            "meta.json": metaBytes, "notes.txt": Data(notes.utf8), "recording.m4a": recBytes,
        ], at: try await Live.head())
        #expect(try SHA256Hex.ofFile(source) == sourceHash) // original untouched
    }

    @Test func live3_twoConcurrentSendsBothLand() async throws {
        let a = Outbox(root: tempDir("a")), b = Outbox(root: tempDir("b"))
        let now = Date()
        let sa = try await a.save(liveDraft("SYNTHETIC TEST DATA. Live test 3A: concurrent."),
                                  interviewer: "Live Test A", appVersion: "1.0.0", now: now).stored
        let sb = try await b.save(liveDraft("SYNTHETIC TEST DATA. Live test 3B: concurrent."),
                                  interviewer: "Live Test B", appVersion: "1.0.0", now: now).stored
        let before = try await Live.head()
        // Two independent writers, like two teammates' Macs pressing Send at the same moment.
        async let ra = Live.writer().write(sa)
        async let rb = Live.writer().write(sb)
        let (oa, ob) = try await (ra, rb)
        guard case .committed(let ca, let attemptsA) = oa, case .committed(let cb, let attemptsB) = ob else {
            Issue.record("\(oa) \(ob)"); return
        }
        print("LIVE3 attempts A=\(attemptsA) B=\(attemptsB) commits \(ca) \(cb)")
        #expect(ca != cb)
        let recent = try await Live.commits(5)
        // Exactly two new commits, linear, on top of the old head.
        #expect(Set(recent.prefix(2).map(\.sha)) == [ca, cb])
        #expect(recent[2].sha == before)
        #expect(Set(recent.prefix(2).map(\.commit.message)) == ["Submission \(sa.id) from Live Test A",
                                                               "Submission \(sb.id) from Live Test B"])
        let head = try await Live.head()
        for s in [sa, sb] {
            try await Live.verifyFolder(s.id, meta: s.meta, files: [
                "meta.json": try Data(contentsOf: s.url(of: "meta.json")),
                "notes.txt": try Data(contentsOf: s.url(of: "notes.txt")),
            ], at: head)
        }
    }

    @Test func live4_resendOfSentIdIsNoDuplicate() async throws {
        let box = Outbox(root: tempDir())
        let s = try await box.save(liveDraft("SYNTHETIC TEST DATA. Live test 4: resend same id."),
                                   interviewer: "Live Test", appVersion: "1.0.0", now: Date()).stored
        // First send lands, but the outbox copy is kept (as if the reply was lost).
        guard case .committed = try await Live.writer().write(s) else { Issue.record("first send"); return }
        let headAfterFirst = try await Live.head()
        let svc = SendService(outbox: box, client: Live.client, appVersion: "1.0.0", settings: { Live.settings })
        let report = await svc.flush()
        #expect(report.alreadyPresent == [s.id], "\(report)")
        #expect(report.sent.isEmpty)
        #expect(box.pending().isEmpty)
        #expect(try await Live.head() == headAfterFirst) // no new commit
        let messages = try await Live.commits(30).map(\.commit.message)
        #expect(messages.filter { $0.contains(s.id) }.count == 1)
    }
}
