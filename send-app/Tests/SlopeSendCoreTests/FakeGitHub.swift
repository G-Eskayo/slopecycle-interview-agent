import CryptoKit
import Foundation
@testable import SlopeSendCore

/// An in-memory GitHub that implements just the Git Data API calls the writer uses, with real
/// fast-forward semantics on the ref, plus knobs for races, outages and lost responses.
final class FakeGitHub: HTTPClient, @unchecked Sendable {
    struct Commit { let tree: String; let parent: String?; let message: String }

    private let lock = NSLock()
    private(set) var main: String
    private var commits: [String: Commit] = [:]
    private var trees: [String: [String: String]] = [:] // tree sha → flattened path → blob sha
    private(set) var blobs: [String: Data] = [:]
    private(set) var requests: [HTTPRequest] = []
    private var counter = 0

    var offline = false
    var forcedStatus: [String: (Int, String)] = [:] // "METHOD path-suffix" → status, message
    /// Called just before a PATCH is applied; return true to have another sender move main first.
    var raceBeforePatch: (@Sendable (Int) -> Bool)?
    private var patchCount = 0
    /// Apply the next PATCH but lose the response (connection drops).
    var dropNextPatchResponse = false
    let token: String

    init(token: String = "test-token") {
        self.token = token
        let tree = "tree-root"
        trees[tree] = ["README.md": "blob-readme"]
        blobs["blob-readme"] = Data("queue".utf8)
        main = "commit-root"
        commits[main] = Commit(tree: tree, parent: nil, message: "init")
    }

    // MARK: inspection

    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    var history: [Commit] {
        withLock {
            var out: [Commit] = []
            var cur: String? = main
            while let c = cur, let commit = commits[c] { out.append(commit); cur = commit.parent }
            return out
        }
    }

    /// Files on main: path → bytes.
    var filesOnMain: [String: Data] {
        withLock {
            let tree = trees[commits[main]!.tree]!
            return tree.mapValues { blobs[$0]! }
        }
    }

    var blobPosts: Int { withLock { requests.filter { $0.method == "POST" && $0.url.path.hasSuffix("/git/blobs") }.count } }

    /// Another sender adds a commit on main.
    func externalCommit(path: String = "submissions/other/meta.json") {
        withLock {
            counter += 1
            let blob = "blob-ext-\(counter)"
            blobs[blob] = Data("{}".utf8)
            var tree = trees[commits[main]!.tree]!
            tree["\(path)-\(counter)"] = blob
            let treeSHA = "tree-ext-\(counter)"
            trees[treeSHA] = tree
            let c = "commit-ext-\(counter)"
            commits[c] = Commit(tree: treeSHA, parent: main, message: "external")
            main = c
        }
    }

    // MARK: HTTPClient

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (shouldRace, n) = withLock { () -> (Bool, Int) in
            requests.append(request)
            if request.method == "PATCH" { patchCount += 1; return (true, patchCount) }
            return (false, 0)
        }
        if offline { throw URLError(.notConnectedToInternet) }
        if shouldRace, let race = raceBeforePatch, race(n) { externalCommit() }
        return try withLock { try handle(request) }
    }

    private func json(_ status: Int, _ obj: Any) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func handle(_ r: HTTPRequest) throws -> HTTPResponse {
        guard r.headers["Authorization"] == "Bearer \(token)" else { return json(401, ["message": "Bad credentials"]) }
        let path = r.url.path
        for (key, value) in forcedStatus where "\(r.method) \(path)".hasSuffix(key) {
            return json(value.0, ["message": value.1])
        }
        if r.method == "GET" && path == "/repos/acme/queue" { return json(200, ["full_name": "acme/queue", "private": true]) }
        let prefix = "/repos/acme/queue/"
        guard path.hasPrefix(prefix) else { return json(404, ["message": "Not Found"]) }
        let rest = String(path.dropFirst(prefix.count))
        let body = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch (r.method, rest) {
        case ("GET", "git/ref/heads/main"):
            return json(200, ["ref": "refs/heads/main", "object": ["sha": main, "type": "commit"]])
        case ("GET", _) where rest.hasPrefix("contents/"):
            let folder = String(rest.dropFirst("contents/".count))
            let ref = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ref" }?.value ?? main
            guard let commit = commits[ref], let tree = trees[commit.tree] else { return json(404, ["message": "No commit found"]) }
            let hits = tree.keys.filter { $0.hasPrefix(folder + "/") }
            return hits.isEmpty ? json(404, ["message": "Not Found"]) : json(200, hits.map { ["path": $0] })
        case ("POST", "git/blobs"):
            guard body["encoding"] as? String == "base64", let content = body["content"] as? String,
                  let data = Data(base64Encoded: content) else { return json(422, ["message": "bad blob"]) }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            blobs[sha] = data
            return json(201, ["sha": sha])
        case ("GET", _) where rest.hasPrefix("git/commits/"):
            let sha = String(rest.dropFirst("git/commits/".count))
            guard let c = commits[sha] else { return json(404, ["message": "Not Found"]) }
            return json(200, ["sha": sha, "tree": ["sha": c.tree]])
        case ("POST", "git/trees"):
            guard let base = body["base_tree"] as? String, var tree = trees[base],
                  let entries = body["tree"] as? [[String: String]] else { return json(422, ["message": "bad tree"]) }
            for e in entries {
                guard e["mode"] == "100644", e["type"] == "blob", let p = e["path"], let s = e["sha"], blobs[s] != nil
                else { return json(422, ["message": "bad entry"]) }
                tree[p] = s
            }
            counter += 1
            let sha = "tree-\(counter)"
            trees[sha] = tree
            return json(201, ["sha": sha])
        case ("POST", "git/commits"):
            guard let tree = body["tree"] as? String, trees[tree] != nil, let parents = body["parents"] as? [String],
                  parents.count == 1, let message = body["message"] as? String else { return json(422, ["message": "bad commit"]) }
            counter += 1
            let sha = "commit-\(counter)"
            commits[sha] = Commit(tree: tree, parent: parents[0], message: message)
            return json(201, ["sha": sha])
        case ("PATCH", "git/refs/heads/main"):
            guard let sha = body["sha"] as? String, let c = commits[sha] else { return json(422, ["message": "bad sha"]) }
            guard body["force"] as? Bool == false else { return json(400, ["message": "test expects force false"]) }
            guard c.parent == main else { return json(422, ["message": "Update is not a fast forward"]) }
            main = sha
            if dropNextPatchResponse {
                dropNextPatchResponse = false
                throw URLError(.networkConnectionLost)
            }
            return json(200, ["object": ["sha": sha]])
        default:
            return json(404, ["message": "Not Found"])
        }
    }
}

/// Never sleeps, so retry tests run instantly.
let noBackoff: @Sendable (Int) async -> Void = { _ in }

func tempDir(_ name: String = #function) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("slopesend-tests", isDirectory: true)
        .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A compressor that never touches AVFoundation (fast, deterministic).
struct FakeCompressor: RecordingCompressor {
    enum Mode: Sendable { case writes(Data), fails, writesSparse(Int64) }
    let mode: Mode
    func compress(_ source: URL, to destination: URL) async throws {
        switch mode {
        case .writes(let data): try data.write(to: destination)
        case .fails: throw CompressionError.readFailed("fake")
        case .writesSparse(let size): try makeSparseFile(destination, size: size)
        }
    }
}

func makeSparseFile(_ url: URL, size: Int64) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: UInt64(size))
    try h.close()
}

let goodSettings = QueueSettings(interviewer: "Alex", repository: "acme/queue", token: "test-token")
