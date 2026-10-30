import Darwin
import Foundation

// MARK: Protocol

/// One command from `openaccs` to the running app: one JSON line in, one JSON line out.
/// Actions name accounts by id; the CLI resolves names with `AccountMatch` first.
public struct ControlRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case status, refresh, open, launch, restart, connect, rename, remove, add
    }

    /// What `add` adds.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case claude, codex, grok, grokBot = "grok-bot", kimi, zai
    }

    public var command: Command
    public var id: UUID?
    public var kind: Kind?
    /// rename: the new name. add claude: the profile's name. add grok-bot: the Grok Bot account.
    public var name: String?
    /// add kimi/zai: the API key. Never logged, never passed to another process.
    public var key: String?
    /// add kimi/zai: "global" or "china".
    public var region: String?

    public init(_ command: Command, id: UUID? = nil, kind: Kind? = nil, name: String? = nil, key: String? = nil, region: String? = nil) {
        self.command = command
        self.id = id
        self.kind = kind
        self.name = name
        self.key = key
        self.region = region
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    /// Why the command failed, in words the CLI prints as is. nil = done.
    public var error: String?
    /// Every account after the command, in panel order. Row numbers count from 1 in this order.
    public var accounts: [ControlAccount]
    /// Something the user should know that isn't about one account.
    public var notice: String?
    public var launch: ControlLaunchResult?

    public init(error: String? = nil, accounts: [ControlAccount] = [], notice: String? = nil, launch: ControlLaunchResult? = nil) {
        self.error = error
        self.accounts = accounts
        self.notice = notice
        self.launch = launch
    }
}

/// The outcome of ensuring one saved Claude profile is open. No sign-in or quota inference.
public struct ControlLaunchResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case opened, alreadyOpen = "already_open", failed }
    public var id: UUID
    public var label: String
    public var status: Status
    public var pid: Int32?
    public var error: String?

    public init(id: UUID, label: String, status: Status, pid: Int32? = nil, error: String? = nil) {
        self.id = id
        self.label = label
        self.status = status
        self.pid = pid
        self.error = error
    }
}

public enum ControlError: Error, Equatable, LocalizedError {
    /// Nothing listens on the socket (no file, or a stale one).
    case unreachable
    /// Another live server already answers on this socket.
    case alreadyRunning
    /// Something that isn't a socket sits where the socket goes; it is never removed.
    case notASocket
    case pathTooLong
    /// The other side closed the connection before answering.
    case connectionLost
    case badMessage
    case system(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: "OpenAccs isn't running."
        case .alreadyRunning: "Another OpenAccs already answers on this socket."
        case .notASocket: "Something that isn't a socket is in the way of the control socket."
        case .pathTooLong: "The control socket path is too long."
        case .connectionLost: "OpenAccs closed the connection before answering."
        case .badMessage: "OpenAccs answered something this version can't read. Quit and reopen OpenAccs."
        case .system(let message): message
        }
    }

    static func posix(_ what: String, _ code: Int32 = errno) -> ControlError {
        .system("\(what): \(String(cString: strerror(code)))")
    }
}

extension Paths {
    /// The app's control socket. Its folder is 0700, the socket 0600.
    public var controlSocket: URL { appSupport.appending(path: "control.sock") }
}

enum ControlWire {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]   // never pretty: one message = one line
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: Server

/// The app's side: a Unix domain socket that answers one request per connection. The handler may take
/// minutes (a browser sign-in); the connection stays open until it returns. If the client goes away
/// first, the handler's task is cancelled.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public let socket: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "is.wai.openaccs.control")
    private var listener: DispatchSourceRead?

    public init(socket: URL, handler: @escaping Handler) {
        self.socket = socket
        self.handler = handler
    }

    /// Binds the socket (folder 0700, socket 0600) and starts answering. A stale socket left by a previous run
    /// is removed; a live one means another app answers here, and this one doesn't start.
    public func start() throws {
        ignoreSIGPIPE()
        let dir = socket.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(dir.path, 0o700) == 0 else { throw ControlError.posix("chmod \(dir.path)") }
        var info = stat()
        if lstat(socket.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw ControlError.notASocket }
            if let fd = try? UnixSocket.connect(socket.path) {
                Darwin.close(fd)
                throw ControlError.alreadyRunning
            }
            unlink(socket.path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.posix("socket") }
        do {
            guard try UnixSocket.withAddress(socket.path, { bind(fd, $0, $1) }) == 0 else { throw ControlError.posix("bind") }
            guard chmod(socket.path, 0o600) == 0 else { throw ControlError.posix("chmod") }
            guard listen(fd, 16) == 0 else { throw ControlError.posix("listen") }
        } catch {
            Darwin.close(fd)
            throw error
        }
        UnixSocket.setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    /// Stops accepting connections. Commands already running finish and answer.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    deinit { listener?.cancel() }

    private func acceptPending(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            UnixSocket.noSIGPIPE(client)
            UnixSocket.setNonBlocking(client)
            Connection(fd: client, handler: handler).start()
        }
    }
}

/// One client: read a line, run the handler, write a line, close. Everything touching the descriptor runs
/// on `queue`; the descriptor is closed only in the read source's cancel handler.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let handler: ControlServer.Handler
    private let queue = DispatchQueue(label: "is.wai.openaccs.control.connection")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var task: Task<Void, Never>?
    private var finished = false

    init(fd: Int32, handler: @escaping ControlServer.Handler) {
        self.fd = fd
        self.handler = handler
    }

    func start() {
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { self.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
        // A client that connects and never asks is dropped.
        queue.asyncAfter(deadline: .now() + 10) { if self.task == nil { self.finish() } }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while !finished {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if task == nil { buffer.append(contentsOf: chunk[0..<n]) }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { break }
            // The client went away (Ctrl-C): stop what it asked for.
            task?.cancel()
            finish()
            return
        }
        guard task == nil, !finished else { return }
        if let newline = buffer.firstIndex(of: 0x0A) {
            let request = try? ControlWire.decoder.decode(ControlRequest.self, from: Data(buffer[..<newline]))
            let handler = self.handler
            task = Task {
                let response: ControlResponse
                if let request {
                    response = await handler(request)
                } else {
                    response = ControlResponse(error: "OpenAccs didn't understand this command. If you just updated OpenAccs, quit and reopen it.")
                }
                self.queue.async { self.reply(response) }
            }
        } else if buffer.count > 1 << 20 {
            finish()
        }
    }

    private func reply(_ response: ControlResponse) {
        guard !finished else { return }
        var data = (try? ControlWire.encoder.encode(response)) ?? Data(#"{"accounts":[],"error":"OpenAccs couldn't encode its answer."}"#.utf8)
        data.append(0x0A)
        UnixSocket.writeAll(fd, data, waitMilliseconds: 10_000)
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        source?.cancel()
    }
}

// MARK: Client

/// The CLI's side. Blocking: a command waits as long as the app works on it.
public enum ControlClient {
    /// Sends `request` and waits for the answer. Throws `.unreachable` when no app listens.
    public static func send(_ request: ControlRequest, to socket: URL) throws -> ControlResponse {
        ignoreSIGPIPE()
        let fd = try UnixSocket.connect(socket.path)
        defer { Darwin.close(fd) }
        var line = try ControlWire.encoder.encode(request)
        line.append(0x0A)
        guard UnixSocket.writeAll(fd, line, waitMilliseconds: -1) else { throw ControlError.connectionLost }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                guard let newline = buffer.firstIndex(of: 0x0A) else { continue }
                guard let response = try? ControlWire.decoder.decode(ControlResponse.self, from: Data(buffer[..<newline])) else {
                    throw ControlError.badMessage
                }
                return response
            }
            if n < 0, errno == EINTR { continue }
            throw ControlError.connectionLost
        }
    }

    /// True when an app accepts connections on `socket`.
    public static func isAnswering(_ socket: URL) -> Bool {
        guard let fd = try? UnixSocket.connect(socket.path) else { return false }
        Darwin.close(fd)
        return true
    }
}

// MARK: Sockets

enum UnixSocket {
    /// macOS accepts socket paths longer than `sun_path` (up to SOCK_MAXADDRLEN) when `sun_len` says so,
    /// so a home folder with a long path still works.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        let bytes = Array(path.utf8)
        let offset = 2   // sun_len, sun_family
        let length = offset + bytes.count + 1
        guard length <= Int(SOCK_MAXADDRLEN) else { throw ControlError.pathTooLong }
        var storage = [UInt8](repeating: 0, count: Int(SOCK_MAXADDRLEN))
        storage[0] = UInt8(length)
        storage[1] = UInt8(AF_UNIX)
        storage.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        return storage.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(length)) }
    }

    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.posix("socket") }
        noSIGPIPE(fd)
        let result: Int32
        do {
            result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            switch code {
            case ENOENT, ECONNREFUSED, ENOTSOCK, ENOTDIR, EPROTOTYPE: throw ControlError.unreachable
            default: throw ControlError.posix("connect", code)
            }
        }
        return fd
    }

    static func noSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Writes everything; on a non-blocking descriptor waits up to `waitMilliseconds` (-1 = forever) for room.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data, waitMilliseconds: Int32) -> Bool {
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, waitMilliseconds) > 0 { continue }
                }
                return false
            }
            return true
        }
    }
}
