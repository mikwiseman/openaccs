import Foundation

/// Minimal HTTP seam so providers can be tested with canned responses.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageError.unexpected("Not an HTTP response") }
            return (data, http)
        } catch let error as URLError {
            throw UsageError.network(error.localizedDescription)
        }
    }
}

/// Provider endpoints are exact. In particular, URLSession otherwise forwards a manually set
/// Cookie header across origins even when it strips Authorization.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// For tests: returns canned responses by URL prefix and records requests.
public final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    public struct Reply: Sendable {
        public var status: Int
        public var body: Data
        public init(status: Int = 200, body: Data) { self.status = status; self.body = body }
        public init(status: Int = 200, json: String) { self.status = status; self.body = Data(json.utf8) }
    }

    private let lock = NSLock()
    private var routes: [(prefix: String, replies: [Reply])] = []
    public private(set) var requests: [URLRequest] = []

    public init() {}

    /// Replies are served in order; the last one repeats.
    public func on(_ urlPrefix: String, _ replies: Reply...) {
        lock.withLock { routes.append((urlPrefix, replies)) }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        let reply: Reply? = lock.withLock {
            requests.append(request)
            guard let i = routes.firstIndex(where: { url.hasPrefix($0.prefix) }) else { return nil }
            let r = routes[i].replies[0]
            if routes[i].replies.count > 1 { routes[i].replies.removeFirst() }
            return r
        }
        guard let reply else { throw UsageError.network("No stub for \(url)") }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (reply.body, response)
    }
}
