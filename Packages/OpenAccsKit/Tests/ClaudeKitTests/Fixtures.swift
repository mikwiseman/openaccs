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
