import CryptoKit
import Foundation

/// A Submission saved on disk, ready to send (or re-send) with its fixed id.
public struct StoredSubmission: Sendable, Equatable {
    public let id: String
    public let folder: URL
    public let meta: SubmissionMeta

    /// Files that go into the queue folder, meta.json first.
    public var fileNames: [String] {
        ["meta.json"] + [meta.notesFile, meta.recordingFile].compactMap { $0 }
    }

    public func url(of fileName: String) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }
}

/// What happened to the attached recording when it was saved.
public enum RecordingHandling: Sendable, Equatable {
    case none
    case compressed(bytes: Int64)
    /// Compression failed; the original file is sent unchanged.
    case sentOriginal
}

public struct SavedSubmission: Sendable, Equatable {
    public let stored: StoredSubmission
    public let recording: RecordingHandling
}

public enum OutboxError: Error, Equatable, Sendable, LocalizedError {
    case corrupt(id: String, reason: String)
    case changedWhileCopying

    public var errorDescription: String? {
        switch self {
        case .corrupt(let id, let reason): return "Saved submission \(id) is damaged: \(reason)"
        case .changedWhileCopying: return "The recording changed while it was being saved. Try again."
        }
    }
}

/// `~/Library/Application Support/SlopeCycle Send/outbox/<submission_id>/`. A folder appears only once it is
/// complete (written under a hidden temporary name, then renamed), and is removed only after GitHub accepted it.
public struct Outbox: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SlopeCycle Send", isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
    }

    /// Writes the draft into a new outbox folder: notes as typed, and the recording compressed to
    /// `recording.m4a` (or, if compression fails, the original copied unchanged). Nothing is left behind on error.
    public func save(_ draft: Draft, interviewer: String, appVersion: String, now: Date,
                     compressor: any RecordingCompressor = AACSpeechCompressor(),
                     randomHex: String? = nil) async throws -> SavedSubmission {
        try draft.validate()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var id = randomHex.map { SubmissionID.make(at: now, randomHex: $0) } ?? SubmissionID.make(at: now)
        // Same second and same random suffix is astronomically unlikely, but never overwrite.
        while fm.fileExists(atPath: root.appendingPathComponent(id).path) {
            id = SubmissionID.make(at: now)
        }

        let temp = root.appendingPathComponent(".incoming-\(id)", isDirectory: true)
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            var notesFile: String?
            var notesHash: String?
            if draft.hasNotes {
                let data = Data(draft.notes.utf8)
                try data.write(to: temp.appendingPathComponent("notes.txt"), options: .atomic)
                notesFile = "notes.txt"
                notesHash = SHA256Hex.of(data)
            }

            var recordingFile: String?
            var recordingHash: String?
            var handling = RecordingHandling.none
            if let source = draft.recordingURL {
                let compressed = temp.appendingPathComponent("recording.m4a")
                do {
                    try await compressor.compress(source, to: compressed)
                    let size = try Draft.fileSize(compressed)
                    guard size > 0 else { throw CompressionError.emptyOutput }
                    recordingFile = "recording.m4a"
                    handling = .compressed(bytes: size)
                } catch let problem as DraftProblem {
                    throw problem
                } catch {
                    // Fall back to the original, unchanged.
                    try? fm.removeItem(at: compressed)
                    let name = try Draft.originalRecordingFileName(for: source)
                    let before = try Draft.checkedSendSize(source)
                    let dest = temp.appendingPathComponent(name)
                    try fm.copyItem(at: source, to: dest)
                    guard try Draft.fileSize(dest) == before else { throw OutboxError.changedWhileCopying }
                    recordingFile = name
                    handling = .sentOriginal
                }
                let dest = temp.appendingPathComponent(recordingFile!)
                _ = try Draft.checkedSendSize(dest) // the 100 MB limit applies to what is sent
                recordingHash = try SHA256Hex.ofFile(dest)
            }

            let meta = SubmissionMeta(
                submissionID: id,
                sentAt: SubmissionID.isoTimestamp(now),
                interviewer: interviewer,
                respondentLabel: draft.trimmedRespondent,
                interviewType: draft.interviewType,
                interviewDate: draft.interviewDate,
                notesFile: notesFile,
                recordingFile: recordingFile,
                notesSHA256: notesHash,
                recordingSHA256: recordingHash,
                appVersion: appVersion)
            try meta.jsonData().write(to: temp.appendingPathComponent("meta.json"), options: .atomic)

            let final = root.appendingPathComponent(id, isDirectory: true)
            try fm.moveItem(at: temp, to: final)
            return SavedSubmission(stored: StoredSubmission(id: id, folder: final, meta: meta), recording: handling)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Complete submissions, oldest first (ids sort by send time). Damaged folders are skipped, never deleted.
    public func pending() -> [StoredSubmission] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { SubmissionID.isValid($0) }
            .sorted()
            .compactMap { try? load(id: $0) }
    }

    public func load(id: String) throws -> StoredSubmission {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let metaData: Data
        do {
            metaData = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        } catch {
            throw OutboxError.corrupt(id: id, reason: "meta.json missing")
        }
        let meta: SubmissionMeta
        do {
            meta = try SubmissionMeta.decode(metaData)
        } catch {
            throw OutboxError.corrupt(id: id, reason: "meta.json unreadable")
        }
        guard meta.submissionID == id else { throw OutboxError.corrupt(id: id, reason: "id mismatch") }
        guard meta.notesFile != nil || meta.recordingFile != nil else {
            throw OutboxError.corrupt(id: id, reason: "no notes or recording")
        }
        let stored = StoredSubmission(id: id, folder: folder, meta: meta)
        for name in stored.fileNames where !FileManager.default.fileExists(atPath: stored.url(of: name).path) {
            throw OutboxError.corrupt(id: id, reason: "\(name) missing")
        }
        return stored
    }

    public func contains(id: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path)
    }

    public func remove(id: String) throws {
        guard SubmissionID.isValid(id) else { return }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}

public enum SHA256Hex {
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func ofFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
