import Foundation

public enum InterviewType: String, Codable, Sendable, CaseIterable {
    case parent
    case expert
}

/// meta.json, format 1 (docs/submission-format.md). Field order and explicit `null`s follow the contract.
public struct SubmissionMeta: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var submissionID: String
    public var sentAt: String
    public var interviewer: String
    public var respondentLabel: String
    public var interviewType: InterviewType
    public var interviewDate: String
    public var notesFile: String?
    public var recordingFile: String?
    public var notesSHA256: String?
    public var recordingSHA256: String?
    public var appVersion: String

    public init(submissionID: String, sentAt: String, interviewer: String, respondentLabel: String,
                interviewType: InterviewType, interviewDate: String, notesFile: String?, recordingFile: String?,
                notesSHA256: String?, recordingSHA256: String?, appVersion: String) {
        self.format = Self.currentFormat
        self.submissionID = submissionID
        self.sentAt = sentAt
        self.interviewer = interviewer
        self.respondentLabel = respondentLabel
        self.interviewType = interviewType
        self.interviewDate = interviewDate
        self.notesFile = notesFile
        self.recordingFile = recordingFile
        self.notesSHA256 = notesSHA256
        self.recordingSHA256 = recordingSHA256
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case format
        case submissionID = "submission_id"
        case sentAt = "sent_at"
        case interviewer
        case respondentLabel = "respondent_label"
        case interviewType = "interview_type"
        case interviewDate = "interview_date"
        case notesFile = "notes_file"
        case recordingFile = "recording_file"
        case notesSHA256 = "notes_sha256"
        case recordingSHA256 = "recording_sha256"
        case appVersion = "app_version"
    }

    /// Pretty-printed JSON with keys in contract order, `null` written explicitly, trailing newline.
    public func jsonData() -> Data {
        let fields: [(String, String)] = [
            ("format", String(format)),
            ("submission_id", Self.quote(submissionID)),
            ("sent_at", Self.quote(sentAt)),
            ("interviewer", Self.quote(interviewer)),
            ("respondent_label", Self.quote(respondentLabel)),
            ("interview_type", Self.quote(interviewType.rawValue)),
            ("interview_date", Self.quote(interviewDate)),
            ("notes_file", notesFile.map(Self.quote) ?? "null"),
            ("recording_file", recordingFile.map(Self.quote) ?? "null"),
            ("notes_sha256", notesSHA256.map(Self.quote) ?? "null"),
            ("recording_sha256", recordingSHA256.map(Self.quote) ?? "null"),
            ("app_version", Self.quote(appVersion)),
        ]
        let body = fields.map { "  \"\($0.0)\": \($0.1)" }.joined(separator: ",\n")
        return Data("{\n\(body)\n}\n".utf8)
    }

    public static func decode(_ data: Data) throws -> SubmissionMeta {
        let meta = try JSONDecoder().decode(SubmissionMeta.self, from: data)
        guard meta.format == currentFormat else {
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.format],
                                                    debugDescription: "unsupported format \(meta.format)"))
        }
        return meta
    }

    static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a String cannot fail.
        let data = try! encoder.encode(s)
        return String(decoding: data, as: UTF8.self)
    }
}
