import CoreServices
import Foundation

/// FSEvents on a set of folders, coalesced: yields once per burst of changes (after `latency`).
/// Folders that don't exist yet are fine; FSEvents reports them once created.
public final class FileWatcher: @unchecked Sendable {
    public let changes: AsyncStream<[String]>
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<[String]>.Continuation
    private let queue = DispatchQueue(label: "is.wai.openaccs.fsevents")

    /// `keepAll`: deliver every batch of paths (by default only the newest waits while the reader is busy).
    public init(paths: [URL], latency: TimeInterval = 1.5, keepAll: Bool = false) {
        (changes, continuation) = AsyncStream<[String]>.makeStream(bufferingPolicy: keepAll ? .unbounded : .bufferingNewest(1))
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            watcher.continuation.yield(Array(paths.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil, callback, &context, paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }

    deinit { stop() }
}
