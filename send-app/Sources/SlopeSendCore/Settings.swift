import Foundation

/// The three things a teammate sets once: their name, the queue repo, and the shared access key.
public struct QueueSettings: Sendable, Equatable {
    public var interviewer: String
    public var repository: String
    public var token: String

    public init(interviewer: String, repository: String, token: String) {
        self.interviewer = interviewer
        self.repository = repository
        self.token = token
    }

    /// Validated, trimmed settings, or the first problem found.
    public func validated() throws -> ValidSettings {
        let name = interviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SettingsProblem.missingInterviewer }
        let repoText = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoText.isEmpty else { throw SettingsProblem.missingRepository }
        guard let repo = RepoRef.parse(repoText) else { throw SettingsProblem.badRepository }
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SettingsProblem.missingToken }
        return ValidSettings(interviewer: name, repo: repo, token: key)
    }
}

public struct ValidSettings: Sendable, Equatable {
    public let interviewer: String
    public let repo: RepoRef
    public let token: String
}

public enum SettingsProblem: Error, Equatable, Sendable, LocalizedError {
    case missingInterviewer
    case missingRepository
    case badRepository
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingInterviewer: return "Add your name in Settings."
        case .missingRepository: return "Add the queue repository in Settings."
        case .badRepository: return "The queue repository should look like owner/name."
        case .missingToken: return "Add the access key in Settings."
        }
    }
}

public struct RepoRef: Sendable, Equatable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public var description: String { "\(owner)/\(name)" }

    /// Accepts `owner/name`, and forgivingly `https://github.com/owner/name(.git)`.
    public static func parse(_ text: String) -> RepoRef? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix(".git") { s = String(s.dropLast(4)) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]), name = String(parts[1])
        guard owner.wholeMatch(of: /[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/) != nil,
              name.wholeMatch(of: /[A-Za-z0-9._-]{1,100}/) != nil,
              name != ".", name != ".." else { return nil }
        return RepoRef(owner: owner, name: name)
    }
}
