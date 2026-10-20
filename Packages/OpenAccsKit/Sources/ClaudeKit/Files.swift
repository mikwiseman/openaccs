import Darwin
import Foundation

/// File checks that never follow symlinks (lstat), for folders Claude reads and writes.
enum FS {
    /// The item's type (`S_IFREG`, `S_IFDIR`, `S_IFLNK`…), nil when nothing is there.
    static func kind(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func exists(_ url: URL) -> Bool { kind(url) != nil }
    static func isRegularFile(_ url: URL) -> Bool { kind(url) == S_IFREG }
    static func isDirectory(_ url: URL) -> Bool { kind(url) == S_IFDIR }

    /// Entry names of a real directory; nil when it is missing, a symlink or unreadable.
    static func names(in dir: URL) -> [String]? {
        guard isDirectory(dir) else { return nil }
        return try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    }

    static func size(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_size
    }

    /// Modification time in whole microseconds, the precision a copy keeps when its date is set.
    static func modificationMicros(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int64(info.st_mtimespec.tv_sec) * 1_000_000 + (Int64(info.st_mtimespec.tv_nsec) + 500) / 1_000
    }

    static func modificationDate(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let t = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }

    /// True when every existing folder from `base` (exclusive) down to `dir` is a real directory,
    /// so a write below it can never go through a link. Missing folders are fine; they get created.
    static func noLinks(below base: URL, to dir: URL) -> Bool {
        let root = base.standardizedFileURL.path
        let path = dir.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return false }
        var current = URL(filePath: root, directoryHint: .isDirectory)
        for part in path.dropFirst(root.count).split(separator: "/") {
            current.append(path: String(part), directoryHint: .isDirectory)
            switch kind(current) {
            case nil: return true
            case S_IFDIR: continue
            default: return false
            }
        }
        return true
    }

    /// Creates a private folder (0700) with any missing parents.
    static func makeDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Only names that are safe as one path component (UUIDs, `local_…` ids).
    static func isSafeName(_ name: some StringProtocol) -> Bool {
        !name.isEmpty && name.count <= 128 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// One backup folder per run: `<backups>/<date time> <label>/<original absolute path>`.
/// Created lazily, so a run that replaces nothing leaves no folder behind.
struct Backups {
    let root: URL

    init(base: URL, label: String, now: Date = Date()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        root = base.appending(path: "\(formatter.string(from: now)) \(label)", directoryHint: .isDirectory)
    }

    /// Copies `file` into the backup (keeps its dates). Returns the copy.
    @discardableResult
    func copy(_ file: URL) throws -> URL {
        let destination = try slot(for: file)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Moves `file` into the backup instead of deleting it. Returns the new location.
    @discardableResult
    func move(_ file: URL) throws -> URL {
        let destination = try slot(for: file)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    private func slot(for file: URL) throws -> URL {
        let relative = String(file.standardizedFileURL.path.drop { $0 == "/" })
        let base = root.appending(path: relative)
        try FS.makeDirectory(base.deletingLastPathComponent())
        var candidate = base
        var n = 1
        while FS.exists(candidate) {
            candidate = base.deletingLastPathComponent().appending(path: "\(base.lastPathComponent).\(n)")
            n += 1
        }
        return candidate
    }
}
