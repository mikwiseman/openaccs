import Darwin
import Foundation

public enum AtomicFile {
    /// Writes `data` to a temp file in the same folder, fsyncs, then renames over `url`.
    /// Readers never see a half-written file. The temp name never looks like `*.json.tmp`
    /// (Claude promotes leftover `local_*.json.tmp` files).
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = try writeTemp(data, in: dir, permissions: permissions)
        guard rename(temp.path, url.path) == 0 else {
            let err = errno
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    /// Creates `url` only if nothing exists there (never replaces). Returns false if it already existed.
    /// Uses temp + link(2), so the final name appears complete or not at all.
    @discardableResult
    public static func createExclusively(_ data: Data, at url: URL, permissions: mode_t = 0o600) throws -> Bool {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = try writeTemp(data, in: dir, permissions: permissions)
        defer { unlink(temp.path) }
        if link(temp.path, url.path) == 0 { return true }
        if errno == EEXIST { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func writeTemp(_ data: Data, in dir: URL, permissions: mode_t) throws -> URL {
        let temp = dir.appending(path: ".openaccs-\(UUID().uuidString).partial")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard ok, fsync(fd) == 0 else {
            let err = errno
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        fchmod(fd, permissions)
        return temp
    }
}
