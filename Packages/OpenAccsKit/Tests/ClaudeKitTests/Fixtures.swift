import Foundation
import OpenAccsCore
@testable import ClaudeKit

/// A throwaway home folder. Tests never see the real one.
final class TempHome {
    let url: URL
    var paths: Paths { Paths(home: url) }

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "claudekit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        try write(relative, Data(text.utf8))
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @discardableResult
    func writeJSON(_ relative: String, _ object: Any) throws -> URL {
        try write(relative, JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: relative).path)
    }

    func json(at file: URL) -> [String: Any] {
        (try? Data(contentsOf: file)).flatMap(JSON.object) ?? [:]
    }

    /// A localStorage database like a window's app leaves it, with one unrelated value in it.
    func makeLocalStorage(in dataDir: URL) throws {
        let dir = localStorageDir(dataDir)
        guard !FS.exists(dir) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let edit: [UInt8] = [1] + LevelDB.varint(26) + Array("leveldb.BytewiseComparator".utf8)
            + [2] + LevelDB.varint(3) + [3] + LevelDB.varint(4) + [4] + LevelDB.varint(7)
        try Data(LevelDB.framed(edit, after: 0)).write(to: dir.appending(path: "MANIFEST-000001"))
        try Data("MANIFEST-000001\n".utf8).write(to: dir.appending(path: "CURRENT"))
        let other = LevelDB.putBatch(key: ChromiumLocalStorage.key("theme", origin: PinList.origin), value: ChromiumLocalStorage.encoded("dark"), sequence: 8)
        try Data(LevelDB.framed(other, after: 0)).write(to: dir.appending(path: "000003.log"))
        try Data().write(to: dir.appending(path: "LOCK"))
    }

    func localStorageDir(_ dataDir: URL) -> URL {
        dataDir.appending(path: "Local Storage/leveldb", directoryHint: .isDirectory)
    }

    /// The newest value of a localStorage key, read back from the log.
    func localStorageValue(in dataDir: URL, _ key: String) -> String? {
        guard let log = try? Data(contentsOf: localStorageDir(dataDir).appending(path: "000003.log")),
              let records = LevelDB.records([UInt8](log)) else { return nil }
        var value: String?
        for batch in records {
            var i = 12
            while i < batch.count {
                let tag = batch[i]
                i += 1
                guard let n = LevelDB.readVarint(batch, &i) else { return nil }
                let k = Array(batch[i..<i + Int(n)])
                i += Int(n)
                guard tag == 1, let m = LevelDB.readVarint(batch, &i) else { continue }
                if k == ChromiumLocalStorage.key(key, origin: PinList.origin) {
                    value = String(decoding: batch[i + 1..<i + Int(m)], as: UTF8.self)
                }
                i += Int(m)
            }
        }
        return value
    }

    /// Every regular file below `relative` (relative paths).
    func files(under relative: String) -> [String] {
        let root = url.appending(path: relative)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { item -> String? in
            guard let file = item as? URL, (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        }.sorted()
    }
}

/// A fake Claude main process for `ClaudeProfiles(paths:processes:)`.
func claudeProcess(pid: pid_t = 4242, dataDir: URL?, launched: Date = Date(timeIntervalSince1970: 0)) -> ClaudeProcess {
    var args = ["/Applications/Claude.app/Contents/MacOS/Claude"]
    if let dataDir { args.append("--user-data-dir=\(dataDir.path)") }
    return ClaudeProcess(pid: pid, arguments: args, launchDate: launched)
}

/// Set once, read from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
