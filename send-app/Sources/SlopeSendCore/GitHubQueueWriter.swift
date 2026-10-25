import Foundation

public enum QueueError: Error, Equatable, Sendable, LocalizedError {
    /// No connection; try again when the network comes back.
    case offline
    case unauthorized
    case repositoryNotFound
    case emptyRepository
    case forbidden(String)
    case conflictRetriesExhausted
    case http(status: Int, message: String)
    case badResponse(String)

    public var isOffline: Bool { self == .offline }

    /// Short, plain reason for the status line. Never contains the access key.
    public var errorDescription: String? {
        switch self {
        case .offline: return "no internet connection"
        case .unauthorized: return "the access key was not accepted"
        case .repositoryNotFound: return "the access key can't see the queue repository"
        case .emptyRepository: return "the queue repository has no main branch yet"
        case .forbidden(let m): return "GitHub refused: \(m)"
        case .conflictRetriesExhausted: return "the queue was busy"
        case .http(let status, _): return "GitHub error \(status)"
        case .badResponse: return "unexpected reply from GitHub"
        }
    }
}

/// Writes one Submission as one commit through GitHub's Git Data API (docs/submission-format.md):
/// GET ref → (already there? done) → POST blobs → GET commit → POST tree on base_tree → POST commit →
/// PATCH ref without force. A 409/422 on the ref move means someone else sent first: re-read and redo
/// the tree and commit, up to `maxAttempts` times. Blobs are reused across attempts.
public struct GitHubQueueWriter: Sendable {
    public enum Outcome: Sendable, Equatable {
        case committed(commitSHA: String, attempts: Int)
        /// The folder already exists on main (an earlier send landed): nothing written.
        case alreadyPresent
    }

    public static let maxAttempts = 5

    let client: any HTTPClient
    let repo: RepoRef
    let token: String
    let apiBase: URL
    let backoff: @Sendable (Int) async -> Void

    public init(client: any HTTPClient, repo: RepoRef, token: String,
                apiBase: URL = URL(string: "https://api.github.com")!,
                backoff: @escaping @Sendable (Int) async -> Void = GitHubQueueWriter.defaultBackoff) {
        self.client = client
        self.repo = repo
        self.token = token
        self.apiBase = apiBase
        self.backoff = backoff
    }

    /// A short randomised pause between ref-move attempts, so two racing senders spread out.
    public static let defaultBackoff: @Sendable (Int) async -> Void = { attempt in
        let ms = UInt64(200 * attempt) + UInt64.random(in: 0...300)
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// `Submission <id> from <interviewer>`, single line, with CI-skip markers removed (the processor
    /// reserves "[skip ci]" for its own commits).
    public static func commitMessage(id: String, interviewer: String) -> String {
        var name = interviewer.components(separatedBy: .newlines).joined(separator: " ")
        let markers = [/\[\s*skip\s+ci\s*\]/, /\[\s*ci\s+skip\s*\]/, /\[\s*no\s+ci\s*\]/,
                       /\[\s*skip\s+actions\s*\]/, /\[\s*actions\s+skip\s*\]/, /skip-checks\s*:\s*true/]
        for marker in markers {
            name = name.replacing(marker.ignoresCase(), with: "")
        }
        name = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "Submission \(id) from \(name.isEmpty ? "unknown" : name)"
    }

    // MARK: - Write

    public func write(_ submission: StoredSubmission) async throws -> Outcome {
        var blobs: [(path: String, sha: String)]?
        for attempt in 1...Self.maxAttempts {
            let head = try await headCommitSHA()
            if try await folderExists(submission.id, at: head) { return .alreadyPresent }
            if blobs == nil { blobs = try await createBlobs(submission) }
            let baseTree = try await treeSHA(ofCommit: head)
            let tree = try await createTree(base: baseTree, entries: blobs!)
            let commit = try await createCommit(
                message: Self.commitMessage(id: submission.id, interviewer: submission.meta.interviewer),
                tree: tree, parent: head)
            if try await moveMain(to: commit) {
                return .committed(commitSHA: commit, attempts: attempt)
            }
            if attempt < Self.maxAttempts { await backoff(attempt) }
        }
        throw QueueError.conflictRetriesExhausted
    }

    /// "Test connection": the key can see the repo and its main branch.
    public func checkConnection() async throws {
        let r = try await call("GET", "repos/\(repo.owner)/\(repo.name)")
        try expectOK(r, notFound: .repositoryNotFound)
        _ = try await headCommitSHA()
    }

    // MARK: - Steps

    func headCommitSHA() async throws -> String {
        let r = try await call("GET", "repos/\(repo.owner)/\(repo.name)/git/ref/heads/main")
        if r.status == 409 { throw QueueError.emptyRepository }
        try expectOK(r, notFound: .repositoryNotFound)
        return try decode(RefResponse.self, r).object.sha
    }

    func folderExists(_ id: String, at commit: String) async throws -> Bool {
        let r = try await call("GET", "repos/\(repo.owner)/\(repo.name)/contents/submissions/\(id)",
                               query: [URLQueryItem(name: "ref", value: commit)])
        if r.status == 404 { return false }
        try expectOK(r, notFound: .repositoryNotFound)
        return true
    }

    func createBlobs(_ s: StoredSubmission) async throws -> [(path: String, sha: String)] {
        var out: [(String, String)] = []
        for name in s.fileNames {
            let data = try Data(contentsOf: s.url(of: name), options: .mappedIfSafe)
            guard Int64(data.count) <= Draft.maxFileBytes else { throw DraftProblem.fileTooLarge(bytes: Int64(data.count)) }
            var body = Data(#"{"encoding":"base64","content":""#.utf8)
            body.append(data.base64EncodedData())
            body.append(Data(#""}"#.utf8))
            let r = try await call("POST", "repos/\(repo.owner)/\(repo.name)/git/blobs", body: body)
            try expectOK(r, notFound: .repositoryNotFound)
            out.append(("submissions/\(s.id)/\(name)", try decode(SHAResponse.self, r).sha))
        }
        return out
    }

    func treeSHA(ofCommit sha: String) async throws -> String {
        let r = try await call("GET", "repos/\(repo.owner)/\(repo.name)/git/commits/\(sha)")
        try expectOK(r, notFound: .repositoryNotFound)
        return try decode(CommitResponse.self, r).tree.sha
    }

    func createTree(base: String, entries: [(path: String, sha: String)]) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "base_tree": base,
            "tree": entries.map { ["path": $0.path, "mode": "100644", "type": "blob", "sha": $0.sha] },
        ])
        let r = try await call("POST", "repos/\(repo.owner)/\(repo.name)/git/trees", body: body)
        try expectOK(r, notFound: .repositoryNotFound)
        return try decode(SHAResponse.self, r).sha
    }

    func createCommit(message: String, tree: String, parent: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "message": message, "tree": tree, "parents": [parent],
        ])
        let r = try await call("POST", "repos/\(repo.owner)/\(repo.name)/git/commits", body: body)
        try expectOK(r, notFound: .repositoryNotFound)
        return try decode(SHAResponse.self, r).sha
    }

    /// True if main now points at `commit`; false if main moved underneath us (409/422).
    func moveMain(to commit: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["sha": commit, "force": false])
        let r = try await call("PATCH", "repos/\(repo.owner)/\(repo.name)/git/refs/heads/main", body: body)
        if r.status == 409 || r.status == 422 { return false }
        try expectOK(r, notFound: .repositoryNotFound)
        return true
    }

    // MARK: - Plumbing

    func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> HTTPResponse {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "SlopeCycle-Send",
        ]
        if body != nil { headers["Content-Type"] = "application/json" }
        let request = HTTPRequest(method: method, url: components.url!, headers: headers, body: body)
        do {
            return try await client.send(request)
        } catch is URLError {
            throw QueueError.offline
        } catch let e as NSError where e.domain == NSURLErrorDomain {
            throw QueueError.offline
        }
    }

    func expectOK(_ r: HTTPResponse, notFound: QueueError) throws {
        switch r.status {
        case 200..<300: return
        case 401: throw QueueError.unauthorized
        case 403: throw QueueError.forbidden(githubMessage(r))
        case 404: throw notFound
        default: throw QueueError.http(status: r.status, message: githubMessage(r))
        }
    }

    func githubMessage(_ r: HTTPResponse) -> String {
        (try? JSONDecoder().decode(MessageResponse.self, from: r.body).message) ?? ""
    }

    func decode<T: Decodable>(_ type: T.Type, _ r: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: r.body)
        } catch {
            throw QueueError.badResponse("\(T.self)")
        }
    }
}

struct RefResponse: Decodable { struct Obj: Decodable { let sha: String }; let object: Obj }
struct SHAResponse: Decodable { let sha: String }
struct CommitResponse: Decodable { struct Tree: Decodable { let sha: String }; let tree: Tree }
struct MessageResponse: Decodable { let message: String }
