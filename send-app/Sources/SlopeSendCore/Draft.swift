import Foundation
import UniformTypeIdentifiers

/// What the user has typed into the window, before it becomes a Submission.
public struct Draft: Sendable, Equatable {
    /// GitHub's per-file limit, and ours: 100 MiB.
    public static let maxFileBytes: Int64 = 100 * 1024 * 1024

    public var respondentLabel: String
    public var interviewType: InterviewType
    /// `YYYY-MM-DD`
    public var interviewDate: String
    public var notes: String
    public var recordingURL: URL?

    public init(respondentLabel: String, interviewType: InterviewType, interviewDate: String,
                notes: String, recordingURL: URL?) {
        self.respondentLabel = respondentLabel
        self.interviewType = interviewType
        self.interviewDate = interviewDate
        self.notes = notes
        self.recordingURL = recordingURL
    }

    public var trimmedRespondent: String {
        respondentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whitespace-only notes count as no notes.
    public var hasNotes: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Send button rule: a respondent, and notes or a recording.
    public var canSend: Bool {
        !trimmedRespondent.isEmpty && (hasNotes || recordingURL != nil)
    }

    /// The extension of an attached file, lowercased, if it names an audio or video type. Anything else is refused.
    public static func audioVideoExtension(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard ext.wholeMatch(of: /[a-z0-9]{1,10}/) != nil,
              let type = UTType(filenameExtension: ext),
              type.conforms(to: .audiovisualContent) else { throw DraftProblem.notAudioOrVideo }
        return ext
    }

    /// Name used when the original is sent unchanged (compression failed): `recording.<original extension lowercased>`.
    public static func originalRecordingFileName(for url: URL) throws -> String {
        "recording.\(try audioVideoExtension(of: url))"
    }

    /// Size of a regular file on disk, or `recordingUnreadable`.
    public static func fileSize(_ url: URL) throws -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize else { throw DraftProblem.recordingUnreadable }
        return Int64(size)
    }

    /// Size of a file that is about to be sent; refuses anything over 100 MB.
    public static func checkedSendSize(_ url: URL) throws -> Int64 {
        let size = try fileSize(url)
        guard size <= maxFileBytes else { throw DraftProblem.fileTooLarge(bytes: size) }
        return size
    }

    public func validate() throws {
        guard !trimmedRespondent.isEmpty else { throw DraftProblem.missingRespondent }
        guard hasNotes || recordingURL != nil else { throw DraftProblem.nothingToSend }
        guard InterviewDate.isValid(interviewDate) else { throw DraftProblem.badDate }
        if Int64(notes.utf8.count) > Self.maxFileBytes { throw DraftProblem.fileTooLarge(bytes: Int64(notes.utf8.count)) }
        if let url = recordingURL {
            // The 100 MB limit applies to the compressed file, so the original's size is not checked here.
            _ = try Self.audioVideoExtension(of: url)
            _ = try Self.fileSize(url)
        }
    }
}

public enum DraftProblem: Error, Equatable, Sendable, LocalizedError {
    case missingRespondent
    case nothingToSend
    case badDate
    case fileTooLarge(bytes: Int64)
    case recordingUnreadable
    case notAudioOrVideo

    public var errorDescription: String? {
        switch self {
        case .missingRespondent: return "Add a respondent label."
        case .nothingToSend: return "Add notes or attach a recording."
        case .badDate: return "The date isn't valid."
        case .fileTooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "That file is %.0f MB. The limit is 100 MB, so it can't be sent.", mb)
        case .recordingUnreadable: return "The recording file can't be read."
        case .notAudioOrVideo: return "That file isn't an audio or video recording."
        }
    }
}
