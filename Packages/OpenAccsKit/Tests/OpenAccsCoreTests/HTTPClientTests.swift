import Foundation
import Network
import Testing
@testable import OpenAccsCore

@Suite struct HTTPClientTests {
    @Test func redirectsNeverForwardCredentials() async throws {
        let destination = try LocalHTTPResponse("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        let targetPort = try await destination.start()
        defer { destination.stop() }
        let source = try LocalHTTPResponse("HTTP/1.1 302 Found\r\nLocation: http://localhost:\(targetPort)/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let sourcePort = try await source.start()
        defer { source.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(sourcePort)/usage")!)
        request.setValue("sessionKey=fixture-only", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSessionHTTPClient().send(request)
        #expect(response.statusCode == 302)
        #expect(destination.requests == 0)
    }
}

/// Real loopback HTTP: URLProtocol mocks do not exercise URLSession's redirect behavior.
private final class LocalHTTPResponse: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data
    private let queue = DispatchQueue(label: "OpenAccs.HTTPTest")
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }

    init(_ response: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.response = Data(response.utf8)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] _, _, _, _ in
                lock.withLock { count += 1 }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}
