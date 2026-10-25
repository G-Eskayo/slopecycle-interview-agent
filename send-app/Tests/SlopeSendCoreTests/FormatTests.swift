import Foundation
import Testing
@testable import SlopeSendCore

@Suite struct SubmissionIDTests {
    let date = Date(timeIntervalSince1970: 1_793_644_205) // 2026-11-02T18:30:05Z

    @Test func matchesContractFormat() {
        #expect(SubmissionID.make(at: date, randomHex: "3f9a1c2e") == "2026-11-02T183005Z-3f9a1c2e")
        #expect(SubmissionID.isoTimestamp(date) == "2026-11-02T18:30:05Z")
        let random = SubmissionID.make(at: date)
        #expect(SubmissionID.isValid(random))
        #expect(random.hasPrefix("2026-11-02T183005Z-"))
    }

    @Test func isUTCRegardlessOfLocalZone() {
        // The formatter must not use TimeZone.current: same instant, same id.
        let a = SubmissionID.compactTimestamp(date)
        #expect(a == "2026-11-02T183005Z")
    }

    @Test func sortsByTime() {
        let earlier = SubmissionID.make(at: date, randomHex: "ffffffff")
        let later = SubmissionID.make(at: date.addingTimeInterval(1), randomHex: "00000000")
        #expect(earlier < later)
    }

    @Test func randomPartsDiffer() {
        let ids = Set((0..<200).map { _ in SubmissionID.make(at: date) })
        #expect(ids.count == 200)
    }

    @Test(arguments: ["", "2026-11-02T183005Z", "2026-11-02T183005Z-3F9A1C2E", "2026-11-02T18:30:05Z-3f9a1c2e",
                      "2026-11-02T183005Z-3f9a1c2", "../2026-11-02T183005Z-3f9a1c2e", ".incoming-2026-11-02T183005Z-3f9a1c2e",
                      "2026-11-02T183005Z-3f9a1c2e/"])
    func rejectsMalformed(_ s: String) {
        #expect(!SubmissionID.isValid(s))
    }

    @Test func interviewDateValidation() {
        #expect(InterviewDate.isValid("2026-11-02"))
        #expect(!InterviewDate.isValid("2026-02-30"))
        #expect(!InterviewDate.isValid("2026-11-2"))
        #expect(!InterviewDate.isValid("02/11/2026"))
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-11-03T02:00Z is still Nov 2 in California: the interview day is local.
        #expect(InterviewDate.string(from: Date(timeIntervalSince1970: 1_793_671_200), timeZone: tz) == "2026-11-02")
    }
}

@Suite struct MetaTests {
    func sample(notes: Bool = true, recording: Bool = true, interviewer: String = "Alex") -> SubmissionMeta {
        SubmissionMeta(submissionID: "2026-11-02T183005Z-3f9a1c2e", sentAt: "2026-11-02T18:30:05Z",
                       interviewer: interviewer, respondentLabel: "P-07", interviewType: .parent,
                       interviewDate: "2026-11-02", notesFile: notes ? "notes.txt" : nil,
                       recordingFile: recording ? "recording.m4a" : nil,
                       notesSHA256: notes ? String(repeating: "a", count: 64) : nil,
                       recordingSHA256: recording ? String(repeating: "b", count: 64) : nil, appVersion: "1.0.0")
    }

    @Test func exactContractText() {
        let text = String(decoding: sample(notes: false).jsonData(), as: UTF8.self)
        #expect(text == """
        {
          "format": 1,
          "submission_id": "2026-11-02T183005Z-3f9a1c2e",
          "sent_at": "2026-11-02T18:30:05Z",
          "interviewer": "Alex",
          "respondent_label": "P-07",
          "interview_type": "parent",
          "interview_date": "2026-11-02",
          "notes_file": null,
          "recording_file": "recording.m4a",
          "notes_sha256": null,
          "recording_sha256": "\(String(repeating: "b", count: 64))",
          "app_version": "1.0.0"
        }

        """)
    }

    @Test func allTwelveKeysAlwaysPresent() throws {
        for (n, r) in [(true, true), (true, false), (false, true)] {
            let obj = try JSONSerialization.jsonObject(with: sample(notes: n, recording: r).jsonData()) as! [String: Any]
            #expect(Set(obj.keys) == ["format", "submission_id", "sent_at", "interviewer", "respondent_label",
                                      "interview_type", "interview_date", "notes_file", "recording_file",
                                      "notes_sha256", "recording_sha256", "app_version"])
            #expect((obj["notes_file"] is NSNull) == !n)
            #expect((obj["recording_sha256"] is NSNull) == !r)
            #expect(obj["format"] as? Int == 1)
        }
    }

    @Test(arguments: ["Zoë 👩🏽‍💻", "Quote \" back\\slash / slash", "line\nbreak\ttab", "\u{0001}ctl", "日本語"])
    func hostileStringsRoundTrip(_ name: String) throws {
        let meta = sample(interviewer: name)
        let data = meta.jsonData()
        _ = try JSONSerialization.jsonObject(with: data) // valid JSON
        #expect(try SubmissionMeta.decode(data) == meta)
    }

    @Test func rejectsOtherFormats() {
        var text = String(decoding: sample().jsonData(), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"format\": 1", with: "\"format\": 2")
        #expect(throws: (any Error).self) { try SubmissionMeta.decode(Data(text.utf8)) }
    }
}

@Suite struct RespondentLabelTests {
    @Test(arguments: ["Jane Doe", "José Núñez", "Mary Jane Smith", "Anne-Marie O'Neil", "  Jane   Doe  ", "Zoë Ångström"])
    func warnsOnNames(_ s: String) {
        #expect(RespondentLabel.looksLikeFullName(s))
    }

    @Test(arguments: ["P-07", "Parent 7", "P07", "PTA Chair", "jane doe", "Jane", "", "   ", "E-03 Coach", "Shop Owner2", "J Doe"])
    func noWarningOnLabels(_ s: String) {
        #expect(!RespondentLabel.looksLikeFullName(s))
    }
}

@Suite struct SettingsTests {
    @Test func missingPieces() {
        #expect(throws: SettingsProblem.missingInterviewer) { try QueueSettings(interviewer: "  ", repository: "a/b", token: "t").validated() }
        #expect(throws: SettingsProblem.missingRepository) { try QueueSettings(interviewer: "A", repository: "", token: "t").validated() }
        #expect(throws: SettingsProblem.badRepository) { try QueueSettings(interviewer: "A", repository: "just-a-name", token: "t").validated() }
        #expect(throws: SettingsProblem.missingToken) { try QueueSettings(interviewer: "A", repository: "a/b", token: " \n").validated() }
    }

    @Test func trimsPastedValues() throws {
        let v = try QueueSettings(interviewer: " Alex ", repository: " https://github.com/G-Eskayo/slopecycle-queue.git \n",
                                  token: " github_pat_x\n").validated()
        #expect(v.interviewer == "Alex")
        #expect(v.repo == RepoRef(owner: "G-Eskayo", name: "slopecycle-queue"))
        #expect(v.token == "github_pat_x")
    }

    @Test(arguments: ["a/b/c", "/b", "a/", "a b/c", "a/..", "-a/b", "a/b?x=1", "../../etc", "a/b#x"])
    func badRepos(_ s: String) {
        #expect(RepoRef.parse(s) == nil)
    }
}

@Suite struct DraftTests {
    func draft(_ respondent: String = "P-07", notes: String = "", recording: URL? = nil) -> Draft {
        Draft(respondentLabel: respondent, interviewType: .expert, interviewDate: "2026-11-02", notes: notes, recordingURL: recording)
    }

    @Test func sendButtonRule() {
        let rec = URL(fileURLWithPath: "/tmp/x.m4a")
        #expect(!draft("", notes: "hi").canSend)
        #expect(!draft("  \n", notes: "hi").canSend)
        #expect(!draft("P-07").canSend)
        #expect(!draft("P-07", notes: " \n\t ").canSend)
        #expect(draft("P-07", notes: "hi").canSend)
        #expect(draft("P-07", recording: rec).canSend)
        #expect(draft("Jane Doe", notes: "hi").canSend) // the name warning never blocks
    }

    @Test func nonAudioRefused() throws {
        let dir = tempDir()
        for name in ["notes.txt", "photo.png", "doc.pdf", "noextension", "archive.zip"] {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            #expect(throws: DraftProblem.notAudioOrVideo) { try draft(recording: url).validate() }
        }
    }

    @Test func audioAndVideoExtensionsAccepted() throws {
        for ext in ["m4a", "MP3", "wav", "caf", "aiff", "aif", "mp4", "MOV", "m4v"] {
            #expect(try Draft.audioVideoExtension(of: URL(fileURLWithPath: "/x/a.\(ext)")) == ext.lowercased())
        }
    }

    @Test func missingRecordingFileIsUnreadable() {
        #expect(throws: DraftProblem.recordingUnreadable) {
            try draft(recording: URL(fileURLWithPath: "/nonexistent/\(UUID()).m4a")).validate()
        }
    }

    @Test func folderPretendingToBeAudioIsUnreadable() throws {
        let dir = tempDir().appendingPathComponent("fake.m4a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: DraftProblem.recordingUnreadable) { try draft(recording: dir).validate() }
    }

    @Test func sendSizeLimitIsExactly100MiB() throws {
        let dir = tempDir()
        let ok = dir.appendingPathComponent("ok.m4a"), big = dir.appendingPathComponent("big.m4a")
        try makeSparseFile(ok, size: Draft.maxFileBytes)
        try makeSparseFile(big, size: Draft.maxFileBytes + 1)
        #expect(try Draft.checkedSendSize(ok) == 104_857_600)
        #expect(throws: DraftProblem.fileTooLarge(bytes: 104_857_601)) { try Draft.checkedSendSize(big) }
    }
}

@Suite struct HTTPClientTests {
    /// Regression: a cached GET of heads/main made every ref update a "conflict" against real GitHub.
    @Test func realClientNeverUsesHTTPCache() {
        let config = URLSessionHTTPClient.uncachedSession.configuration
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
}
