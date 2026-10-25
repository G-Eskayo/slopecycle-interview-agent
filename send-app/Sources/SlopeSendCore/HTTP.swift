import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The only network seam. Tests substitute a fake GitHub.
public protocol HTTPClient: Sendable {
    /// Throws `URLError` for transport failures (offline etc.); any HTTP status is returned, not thrown.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    /// No HTTP cache: GitHub marks API replies cacheable for 60 s, and a cached `heads/main` would make every
    /// ref update look like a conflict (found by the live test). Every read must hit GitHub.
    public init(session: URLSession = URLSessionHTTPClient.uncachedSession) {
        self.session = session
    }

    public static let uncachedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.httpBody = request.body
        r.timeoutInterval = 120
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}
