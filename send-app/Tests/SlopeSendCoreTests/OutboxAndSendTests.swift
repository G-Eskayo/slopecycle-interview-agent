import Foundation
import Testing
@testable import SlopeSendCore

private let now = Date(timeIntervalSince1970: 1_793_644_205)

private func draft(_ notes: String = "SYNTHETIC TEST DATA", recording: URL? = nil, respondent: String = "P-07") -> Draft {
    Draft(respondentLabel: respondent, interviewType: .parent, interviewDate: "2026-11-02", notes: notes, recordingURL: recording)
}

private func writer(_ gh: FakeGitHub, token: String = "test-token") -> GitHubQueueWriter {
    GitHubQueueWriter(client: gh, repo: RepoRef(owner: "acme", name: "queue"), token: token,
                      apiBase: URL(string: "https://api.example.test")!, backoff: noBackoff)
}

private func service(_ gh: FakeGitHub, outbox: Outbox, settings: QueueSettings = goodSettings,
                     compressor: any RecordingCompressor = FakeCompressor(mode: .writes(Data("aac".utf8)))) -> SendService {
    SendService(outbox: outbox, client: gh, appVersion: "1.0.0", compressor: compressor,
                apiBase: URL(string: "https://api.example.test")!, backoff: noBackoff, settings: { settings })
}

@Suite struct OutboxTests {
    @Test func notesOnly() async throws {
        let box = Outbox(root: tempDir())
        let saved = try await box.save(draft("SYNTHETIC TEST DATA ✅ naïve café 👩🏽‍💻\nline two"), interviewer: "Alex",
                                       appVersion: "1.0.0", now: now, randomHex: "0000abcd")
        let s = saved.stored
        #expect(s.id == "2026-11-02T183005Z-0000abcd")
        #expect(s.fileNames == ["meta.json", "notes.txt"])
        let bytes = try Data(contentsOf: s.url(of: "notes.txt"))
        #expect(String(decoding: bytes, as: UTF8.self) == "SYNTHETIC TEST DATA ✅ naïve café 👩🏽‍💻\nline two")
        #expect(s.meta.notesSHA256 == SHA256Hex.of(bytes))
        #expect(s.meta.recordingFile == nil && s.meta.recordingSHA256 == nil)
        #expect(saved.recording == .none)
        #expect(try box.load(id: s.id) == s)
    }

    @Test func notesKeptExactlyAsTyped() async throws {
        let box = Outbox(root: tempDir())
        let typed = "  SYNTHETIC TEST DATA with leading spaces and trailing newline\n\n"
        let s = try await box.save(draft(typed), interviewer: "A", appVersion: "1", now: now).stored
        #expect(try Data(contentsOf: s.url(of: "notes.txt")) == Data(typed.utf8))
    }

    @Test func respondentTrimmed() async throws {
        let box = Outbox(root: tempDir())
        let s = try await box.save(draft(respondent: "  P-07 \n"), interviewer: "A", appVersion: "1", now: now).stored
        #expect(s.meta.respondentLabel == "P-07")
    }

    @Test func longNotes() async throws {
        let box = Outbox(root: tempDir())
        let long = String(repeating: "SYNTHETIC TEST DATA — dictated sentence with ünïcödé 🎙️. ", count: 50_000) // ~3 MB
        let s = try await box.save(draft(long), interviewer: "A", appVersion: "1", now: now).stored
        #expect(try Data(contentsOf: s.url(of: "notes.txt")).count == long.utf8.count)
    }

    @Test func emptyNotesWithRecordingCompresses() async throws {
        let dir = tempDir()
        let original = dir.appendingPathComponent("Voice Memo.WAV")
        try Data("RIFF original bytes".utf8).write(to: original)
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        let saved = try await box.save(draft("   \n", recording: original), interviewer: "A", appVersion: "1", now: now,
                                       compressor: FakeCompressor(mode: .writes(Data("compressed".utf8))))
        let s = saved.stored
        #expect(s.fileNames == ["meta.json", "recording.m4a"])
        #expect(s.meta.notesFile == nil && s.meta.notesSHA256 == nil)
        #expect(s.meta.recordingSHA256 == SHA256Hex.of(Data("compressed".utf8)))
        #expect(saved.recording == .compressed(bytes: 10))
        // The original is untouched and still where it was.
        #expect(try Data(contentsOf: original) == Data("RIFF original bytes".utf8))
    }

    @Test func compressionFailureSendsOriginalUnchanged() async throws {
        let dir = tempDir()
        let original = dir.appendingPathComponent("memo.MP3")
        try Data("ID3 original".utf8).write(to: original)
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        let saved = try await box.save(draft(recording: original), interviewer: "A", appVersion: "1", now: now,
                                       compressor: FakeCompressor(mode: .fails))
        #expect(saved.recording == .sentOriginal)
        #expect(saved.stored.meta.recordingFile == "recording.mp3")
        #expect(try Data(contentsOf: saved.stored.url(of: "recording.mp3")) == Data("ID3 original".utf8))
        #expect(saved.stored.meta.recordingSHA256 == SHA256Hex.of(Data("ID3 original".utf8)))
        #expect(!FileManager.default.fileExists(atPath: saved.stored.url(of: "recording.m4a").path))
    }

    @Test func bigOriginalThatCompressesSmallIsAccepted() async throws {
        let dir = tempDir()
        let original = dir.appendingPathComponent("long.wav")
        try makeSparseFile(original, size: Draft.maxFileBytes * 2)
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        let saved = try await box.save(draft(recording: original), interviewer: "A", appVersion: "1", now: now,
                                       compressor: FakeCompressor(mode: .writes(Data(count: 1000))))
        #expect(saved.recording == .compressed(bytes: 1000))
    }

    @Test func compressedOver100MBRefusedAndNothingLeft() async throws {
        let dir = tempDir()
        let original = dir.appendingPathComponent("long.wav")
        try Data("x".utf8).write(to: original)
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        await #expect(throws: DraftProblem.fileTooLarge(bytes: Draft.maxFileBytes + 1)) {
            _ = try await box.save(draft(recording: original), interviewer: "A", appVersion: "1", now: now,
                                   compressor: FakeCompressor(mode: .writesSparse(Draft.maxFileBytes + 1)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path).isEmpty)
    }

    @Test func failedCompressionOfOver100MBOriginalRefused() async throws {
        let dir = tempDir()
        let original = dir.appendingPathComponent("huge.mov")
        try makeSparseFile(original, size: Draft.maxFileBytes + 1)
        let box = Outbox(root: dir.appendingPathComponent("outbox"))
        await #expect(throws: DraftProblem.fileTooLarge(bytes: Draft.maxFileBytes + 1)) {
            _ = try await box.save(draft(recording: original), interviewer: "A", appVersion: "1", now: now,
                                   compressor: FakeCompressor(mode: .fails))
        }
        #expect(box.pending().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path).isEmpty)
    }

    @Test func invalidDraftWritesNothing() async throws {
        let box = Outbox(root: tempDir())
        await #expect(throws: DraftProblem.nothingToSend) {
            _ = try await box.save(draft(" "), interviewer: "A", appVersion: "1", now: now)
        }
        await #expect(throws: DraftProblem.missingRespondent) {
            _ = try await box.save(draft(respondent: " "), interviewer: "A", appVersion: "1", now: now)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.root.path).isEmpty)
    }

    @Test func pendingIsOldestFirstAndIgnoresJunk() async throws {
        let box = Outbox(root: tempDir())
        let late = try await box.save(draft(), interviewer: "A", appVersion: "1", now: now.addingTimeInterval(60)).stored
        let early = try await box.save(draft(), interviewer: "A", appVersion: "1", now: now).stored
        let mid = try await box.save(draft(), interviewer: "A", appVersion: "1", now: now.addingTimeInterval(30)).stored
        // Junk: half-written temp folder, a damaged folder, a stray file.
        try FileManager.default.createDirectory(at: box.root.appendingPathComponent(".incoming-2026-11-02T000000Z-00000000"),
                                                withIntermediateDirectories: true)
        let damaged = box.root.appendingPathComponent("2026-11-01T000000Z-deadbeef")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: damaged.appendingPathComponent("meta.json"))
        try Data().write(to: box.root.appendingPathComponent(".DS_Store"))

        #expect(box.pending().map(\.id) == [early.id, mid.id, late.id])
        // Damaged data is never deleted.
        #expect(FileManager.default.fileExists(atPath: damaged.path))
    }

    @Test func folderMissingAListedFileIsNotSent() async throws {
        let box = Outbox(root: tempDir())
        let s = try await box.save(draft(), interviewer: "A", appVersion: "1", now: now).stored
        try FileManager.default.removeItem(at: s.url(of: "notes.txt"))
        #expect(box.pending().isEmpty)
        #expect(throws: OutboxError.corrupt(id: s.id, reason: "notes.txt missing")) { try box.load(id: s.id) }
    }

    @Test func removeRefusesPathTricks() throws {
        let root = tempDir()
        let box = Outbox(root: root.appendingPathComponent("outbox"))
        try box.remove(id: "..") // must not delete the parent
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
}

@Suite struct WriterTests {
    func stored(_ box: Outbox, notes: String = "SYNTHETIC TEST DATA") async throws -> StoredSubmission {
        try await box.save(draft(notes), interviewer: "Alex", appVersion: "1.0.0", now: now).stored
    }

    @Test func singleCommitWithContractLayout() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let s = try await stored(box)
        let outcome = try await writer(gh).write(s)
        guard case .committed(_, let attempts) = outcome else { Issue.record("not committed"); return }
        #expect(attempts == 1)
        #expect(gh.history.count == 2)
        #expect(gh.history[0].message == "Submission \(s.id) from Alex")
        let files = gh.filesOnMain
        #expect(files["README.md"] != nil) // base_tree kept
        #expect(files["submissions/\(s.id)/meta.json"] == s.meta.jsonData())
        #expect(files["submissions/\(s.id)/notes.txt"] == Data("SYNTHETIC TEST DATA".utf8))
        #expect(files.keys.filter { $0.hasPrefix("submissions/") }.count == 2)
    }

    @Test func requestSequenceAndHeaders() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        _ = try await writer(gh).write(try await stored(box))
        let calls = gh.requests.map { "\($0.method) \($0.url.path.replacingOccurrences(of: "/repos/acme/queue/", with: ""))" }
        #expect(calls.count == 8)
        #expect(calls[0] == "GET git/ref/heads/main")
        #expect(calls[1].hasPrefix("GET contents/submissions/"))
        #expect(calls[2] == "POST git/blobs" && calls[3] == "POST git/blobs")
        #expect(calls[4].hasPrefix("GET git/commits/"))
        #expect(Array(calls[5...]) == ["POST git/trees", "POST git/commits", "PATCH git/refs/heads/main"])
        for r in gh.requests {
            #expect(r.headers["Authorization"] == "Bearer test-token")
            #expect(r.headers["Accept"] == "application/vnd.github+json")
            #expect(r.headers["X-GitHub-Api-Version"] == "2022-11-28")
            #expect(!r.url.absoluteString.contains("test-token"))
        }
    }

    @Test func retriesWhenSomeoneElseSendsFirst() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        gh.raceBeforePatch = { n in n <= 2 } // main moves before our first two ref updates
        let s = try await stored(box)
        let outcome = try await writer(gh).write(s)
        #expect(outcome == .committed(commitSHA: gh.main, attempts: 3))
        // Their two commits and ours, linear, nothing lost.
        #expect(gh.history.map(\.message) == ["Submission \(s.id) from Alex", "external", "external", "init"])
        #expect(gh.filesOnMain.keys.filter { $0.hasPrefix("submissions/other") }.count == 2)
        #expect(gh.blobPosts == 2) // blobs uploaded once, reused
    }

    @Test func givesUpAfterFiveConflicts() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        gh.raceBeforePatch = { _ in true }
        let s = try await stored(box)
        await #expect(throws: QueueError.conflictRetriesExhausted) { _ = try await writer(gh).write(s) }
        #expect(gh.requests.filter { $0.method == "PATCH" }.count == 5)
        #expect(!gh.filesOnMain.keys.contains { $0.contains(s.id) })
    }

    @Test func alreadyOnMainIsNotWrittenAgain() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let s = try await stored(box)
        _ = try await writer(gh).write(s)
        let before = gh.history.count, blobs = gh.blobPosts
        #expect(try await writer(gh).write(s) == .alreadyPresent)
        #expect(gh.history.count == before)
        #expect(gh.blobPosts == blobs)
    }

    @Test func lostResponseThenResendDoesNotDuplicate() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let s = try await stored(box)
        gh.dropNextPatchResponse = true
        await #expect(throws: QueueError.offline) { _ = try await writer(gh).write(s) }
        #expect(gh.history.count == 2) // it did land
        #expect(try await writer(gh).write(s) == .alreadyPresent)
        #expect(gh.history.count == 2)
    }

    @Test func errorMapping() async throws {
        let box = Outbox(root: tempDir())
        let s = try await stored(box)
        let gh = FakeGitHub()
        await #expect(throws: QueueError.unauthorized) { _ = try await writer(gh, token: "wrong").write(s) }

        let missing = GitHubQueueWriter(client: gh, repo: RepoRef(owner: "acme", name: "nope"), token: "test-token",
                                        apiBase: URL(string: "https://api.example.test")!, backoff: noBackoff)
        await #expect(throws: QueueError.repositoryNotFound) { _ = try await missing.write(s) }

        let empty = FakeGitHub()
        empty.forcedStatus["GET /repos/acme/queue/git/ref/heads/main"] = (409, "Git Repository is empty.")
        await #expect(throws: QueueError.emptyRepository) { _ = try await writer(empty).write(s) }

        let limited = FakeGitHub()
        limited.forcedStatus["POST /repos/acme/queue/git/blobs"] = (403, "Resource not accessible by personal access token")
        await #expect(throws: QueueError.forbidden("Resource not accessible by personal access token")) {
            _ = try await writer(limited).write(s)
        }

        let down = FakeGitHub()
        down.forcedStatus["POST /repos/acme/queue/git/trees"] = (502, "Bad Gateway")
        await #expect(throws: QueueError.http(status: 502, message: "Bad Gateway")) { _ = try await writer(down).write(s) }
        #expect(down.history.count == 1)

        let offline = FakeGitHub()
        offline.offline = true
        await #expect(throws: QueueError.offline) { _ = try await writer(offline).write(s) }
    }

    @Test func refusesOversizedFileAtUploadToo() async throws {
        // Belt and braces: even a hand-edited outbox folder cannot push a >100 MB blob.
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let s = try await stored(box)
        try makeSparseFile(s.url(of: "notes.txt"), size: Draft.maxFileBytes + 1)
        await #expect(throws: DraftProblem.fileTooLarge(bytes: Draft.maxFileBytes + 1)) { _ = try await writer(gh).write(s) }
        #expect(gh.history.count == 1)
    }

    @Test(arguments: [
        ("Alex [skip ci]", "Alex"), ("[SKIP CI] Alex", "Alex"), ("Al[ci skip]ex", "Alex"), ("Alex\n\nskip-checks: true", "Alex"),
        ("[no ci][skip actions]", "unknown"), ("Zoë 👩🏽‍💻", "Zoë 👩🏽‍💻"), ("Alex\nSmith", "Alex Smith"),
    ])
    func commitMessageNeverSkipsCI(_ input: String, _ expected: String) {
        let m = GitHubQueueWriter.commitMessage(id: "2026-11-02T183005Z-3f9a1c2e", interviewer: input)
        #expect(m == "Submission 2026-11-02T183005Z-3f9a1c2e from \(expected)")
        #expect(!m.lowercased().contains("skip"))
        #expect(!m.contains("\n"))
    }

    @Test func connectionCheck() async throws {
        let gh = FakeGitHub()
        try await writer(gh).checkConnection()
        await #expect(throws: QueueError.unauthorized) { try await writer(gh, token: "nope").checkConnection() }
    }
}

@Suite struct SendServiceTests {
    @Test func sendsAndEmptiesOutbox() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let result = try await service(gh, outbox: box).submit(draft())
        guard case .sent(let id, .none) = result else { Issue.record("\(result)"); return }
        #expect(box.pending().isEmpty)
        #expect(gh.filesOnMain["submissions/\(id)/notes.txt"] != nil)
    }

    @Test func missingSettingsSavesNothing() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let svc = service(gh, outbox: box, settings: QueueSettings(interviewer: "", repository: "acme/queue", token: "t"))
        await #expect(throws: SettingsProblem.missingInterviewer) { _ = try await svc.submit(draft()) }
        #expect(box.pending().isEmpty)
        #expect(gh.requests.isEmpty)
    }

    @Test func offlineQueuesThenSendsOldestFirstWithSameIds() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        gh.offline = true
        let svc = service(gh, outbox: box)
        var ids: [String] = []
        for i in 0..<3 {
            let r = try await svc.submit(draft("SYNTHETIC TEST DATA \(i)"))
            guard case .queued(let id, _, .offline) = r else { Issue.record("\(r)"); return }
            ids.append(id)
            try await Task.sleep(nanoseconds: 1_100_000_000) // distinct seconds, so order is by time
        }
        #expect(box.pending().map(\.id) == ids)
        gh.offline = false
        let report = await svc.flush()
        #expect(report.sent == ids)
        #expect(report.remaining == 0)
        // Commits landed oldest first, each with its original id.
        #expect(gh.history.dropLast().reversed().map(\.message) == ids.map { "Submission \($0) from Alex" })
    }

    @Test func badKeyKeepsEverythingAndRetriesLater() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        var settings = goodSettings
        settings.token = "revoked"
        let r = try await service(gh, outbox: box, settings: settings).submit(draft())
        guard case .queued(_, _, .unauthorized) = r else { Issue.record("\(r)"); return }
        #expect(box.pending().count == 1)
        let report = await service(gh, outbox: box).flush()
        #expect(report.sent.count == 1 && box.pending().isEmpty)
    }

    @Test func flushWithMissingSettingsKeepsOutbox() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        _ = try await box.save(draft(), interviewer: "A", appVersion: "1", now: now)
        let report = await service(gh, outbox: box, settings: QueueSettings(interviewer: "A", repository: "", token: "")).flush()
        #expect(report.settingsProblem == .missingRepository)
        #expect(box.pending().count == 1)
    }

    @Test func resendOfSubmissionAlreadyOnMainJustClearsOutbox() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let s = try await box.save(draft(), interviewer: "Alex", appVersion: "1", now: now).stored
        _ = try await writer(gh).write(s) // landed, but the app never heard back
        let commits = gh.history.count
        let report = await service(gh, outbox: box).flush()
        #expect(report.alreadyPresent == [s.id])
        #expect(box.pending().isEmpty)
        #expect(gh.history.count == commits)
    }

    @Test func manyConcurrentSubmitsAllLandOnce() async throws {
        let gh = FakeGitHub(), box = Outbox(root: tempDir())
        let svc = service(gh, outbox: box)
        let results = try await withThrowingTaskGroup(of: SendService.SubmitResult.self) { group in
            for i in 0..<8 { group.addTask { try await svc.submit(draft("SYNTHETIC TEST DATA \(i)")) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.allSatisfy { if case .sent = $0 { return true } else { return false } })
        #expect(gh.history.count == 9)
        #expect(Set(gh.history.dropLast().map(\.message)).count == 8)
        #expect(box.pending().isEmpty)
    }

    @Test func twoMacsRacingBothLand() async throws {
        // Two independent senders (no shared actor) hit the same ref at once.
        let gh = FakeGitHub()
        let a = Outbox(root: tempDir("a")), b = Outbox(root: tempDir("b"))
        let sa = try await a.save(draft("SYNTHETIC TEST DATA A"), interviewer: "A", appVersion: "1", now: now).stored
        let sb = try await b.save(draft("SYNTHETIC TEST DATA B"), interviewer: "B", appVersion: "1", now: now).stored
        async let ra = writer(gh).write(sa)
        async let rb = writer(gh).write(sb)
        let (oa, ob) = try await (ra, rb)
        guard case .committed = oa, case .committed = ob else { Issue.record("\(oa) \(ob)"); return }
        #expect(gh.history.count == 3)
        #expect(gh.filesOnMain["submissions/\(sa.id)/notes.txt"] != nil)
        #expect(gh.filesOnMain["submissions/\(sb.id)/notes.txt"] != nil)
    }
}
