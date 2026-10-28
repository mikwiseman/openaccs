import Foundation
import Testing
@testable import ClaudeKit

@Suite struct LocalStorageTests {
    @Test func checksumsAreLevelDBs() {
        #expect(LevelDB.crc32c(Array("123456789".utf8)) == 0xE306_9283)
        #expect(LevelDB.unmask(LevelDB.mask(0x1234_5678)) == 0x1234_5678)
    }

    @Test func recordsAcrossBlocksReadBackWhole() {
        let small = [UInt8](repeating: 7, count: 10)
        let big = (0..<70_000).map { UInt8($0 % 251) }
        var log = LevelDB.framed(small, after: 0)
        log += [UInt8](repeating: 0, count: 0)
        log += LevelDB.framed(big, after: log.count)
        // A record that leaves less than a header's room in its block: the next one starts a new block.
        let filler = [UInt8](repeating: 1, count: LevelDB.blockSize * 3 - log.count - LevelDB.headerSize - 3)
        log += LevelDB.framed(filler, after: log.count)
        log += LevelDB.framed(small, after: log.count)
        #expect(LevelDB.records(log) == [small, big, filler, small])
        // One damaged byte: nothing is trusted.
        var damaged = log
        damaged[20] ^= 1
        #expect(LevelDB.records(damaged) == nil)
        #expect(LevelDB.records(Array(log.dropLast())) == nil)
    }

    @Test func aWriteGoesAfterTheNewestEntryOfTheNewestLog() throws {
        let home = try TempHome()
        let dir = home.url.appending(path: "Data/Local Storage/leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The manifest says log 5 is current and the tables hold entries up to 40; log 5 has a batch at 41–43.
        let edit: [UInt8] = [1] + LevelDB.varint(26) + Array("leveldb.BytewiseComparator".utf8)
            + [2] + LevelDB.varint(5) + [9] + LevelDB.varint(0) + [3] + LevelDB.varint(7) + [4] + LevelDB.varint(40)
        try Data(LevelDB.framed(edit, after: 0)).write(to: dir.appending(path: "MANIFEST-000002"))
        try Data("MANIFEST-000002\n".utf8).write(to: dir.appending(path: "CURRENT"))
        var batch = LevelDB.putBatch(key: [1], value: [2], sequence: 41)
        batch[8] = 3   // three entries
        batch += [1, 1, 3, 1, 4, 0, 1, 5]
        try Data(LevelDB.framed(batch, after: 0)).write(to: dir.appending(path: "000005.log"))
        try Data(LevelDB.framed(LevelDB.putBatch(key: [9], value: [9], sequence: 1), after: 0)).write(to: dir.appending(path: "000004.log"))
        try Data().write(to: dir.appending(path: "LOCK"))

        #expect(ChromiumLocalStorage.set("[\"a\"]", for: "pins", origin: "https://claude.ai", in: home.url.appending(path: "Data")))

        let records = try #require(LevelDB.records([UInt8](try Data(contentsOf: dir.appending(path: "000005.log")))))
        #expect(records.count == 2)
        let written = records[1]
        #expect(LevelDB.lastSequence(ofBatch: written) == 44)
        let key = ChromiumLocalStorage.key("pins", origin: "https://claude.ai")
        #expect(key == Array("_https://claude.ai".utf8) + [0, 1] + Array("pins".utf8))
        #expect(Array(written[12...]) == [1] + LevelDB.varint(UInt64(key.count)) + key + LevelDB.varint(6) + [1] + Array("[\"a\"]".utf8))
        // The older log is left alone.
        #expect(LevelDB.records([UInt8](try Data(contentsOf: dir.appending(path: "000004.log"))))?.count == 1)
    }

    @Test func nothingIsWrittenWhileTheAppHasTheDatabaseOpen() throws {
        let home = try TempHome()
        let data = home.url.appending(path: "Data")
        let dir = data.appending(path: "Local Storage/leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let edit: [UInt8] = [2] + LevelDB.varint(3) + [4] + LevelDB.varint(1)
        try Data(LevelDB.framed(edit, after: 0)).write(to: dir.appending(path: "MANIFEST-000001"))
        try Data("MANIFEST-000001\n".utf8).write(to: dir.appending(path: "CURRENT"))
        try Data().write(to: dir.appending(path: "000003.log"))
        try Data().write(to: dir.appending(path: "LOCK"))
        // Another process holds LevelDB's lock, as the running app does.
        let holder = Process()
        holder.executableURL = URL(filePath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(10)",
                            dir.appending(path: "LOCK").path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { holder.terminate() }
        _ = out.fileHandleForReading.availableData   // waits for "locked"

        #expect(!ChromiumLocalStorage.set("x", for: "k", origin: "https://claude.ai", in: data))
        #expect(try Data(contentsOf: dir.appending(path: "000003.log")).isEmpty)
    }

    @Test func textOutsideLatin1IsSavedAsUTF16() {
        #expect(ChromiumLocalStorage.encoded("é") == [1, 0xE9])
        #expect(ChromiumLocalStorage.encoded("я") == [0, 0x4F, 0x04])
        #expect(ChromiumLocalStorage.decoded([1, 0xE9]) == "é")
        #expect(ChromiumLocalStorage.decoded([0, 0x4F, 0x04]) == "я")
    }

    @Test func snappyBlocksDecompressLikeLevelDB() {
        // "a", then 19 bytes copied from one back.
        #expect(LevelDB.snappy([20, 0x00, 0x61, 0x4A, 0x01, 0x00]) == [UInt8](repeating: 0x61, count: 20))
        // A literal longer than 60 bytes keeps its length in the next byte.
        let long = (0..<100).map { UInt8($0) }
        #expect(LevelDB.snappy([100, 60 << 2, 99] + long) == long)
        // A copy from before the start, or a length that doesn't add up: not trusted.
        #expect(LevelDB.snappy([4, 0x01, 0x05]) == nil)
        #expect(LevelDB.snappy([5, 0x00, 0x61]) == nil)
    }

    @Test func aValueIsReadFromTheLiveTablesAndLogsNewestFirst() throws {
        let home = try TempHome()
        let data = home.url.appending(path: "Data")
        let dir = data.appending(path: "Local Storage/leveldb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let origin = "https://claude.ai"
        let store = ChromiumLocalStorage.key("store", origin: origin), gone = ChromiumLocalStorage.key("gone", origin: origin)
        func value(_ text: String) -> [UInt8] { ChromiumLocalStorage.encoded(text) }
        // Tables 7 and 8 are live; 6 was compacted away (still on disk, never read). Log 9 is the current one.
        try Data(sstable([(store, 50, value("stale"))])).write(to: dir.appending(path: "000006.ldb"))
        try Data(sstable([(gone, 2, value("here")), (store, 3, value("old"))])).write(to: dir.appending(path: "000007.ldb"))
        try Data(sstable([(store, 10, value("{\"state\":{\"width\":288,\"sections\":[]},\"version\":4}"))], compressed: true))
            .write(to: dir.appending(path: "000008.ldb"))
        func file(_ number: UInt64) -> [UInt8] { [7] + LevelDB.varint(0) + LevelDB.varint(number) + LevelDB.varint(100) + LevelDB.varint(1) + [0] + LevelDB.varint(1) + [0] }
        let edits: [[UInt8]] = [
            [1] + LevelDB.varint(26) + Array("leveldb.BytewiseComparator".utf8) + [2] + LevelDB.varint(5) + [3] + LevelDB.varint(10) + [4] + LevelDB.varint(5),
            file(6) + file(7),
            [6] + LevelDB.varint(0) + LevelDB.varint(6) + file(8) + [2] + LevelDB.varint(9) + [4] + LevelDB.varint(10),
        ]
        var manifest: [UInt8] = []
        for edit in edits { manifest += LevelDB.framed(edit, after: manifest.count) }
        try Data(manifest).write(to: dir.appending(path: "MANIFEST-000004"))
        try Data("MANIFEST-000004\n".utf8).write(to: dir.appending(path: "CURRENT"))
        // The log deletes "gone" (sequence 11).
        let delete: [UInt8] = (0..<8).map { UInt8(11 >> (8 * $0) & 0xFF) } + [1, 0, 0, 0] + [0] + LevelDB.varint(UInt64(gone.count)) + gone
        try Data(LevelDB.framed(delete, after: 0)).write(to: dir.appending(path: "000009.log"))
        try Data().write(to: dir.appending(path: "LOCK"))

        #expect(LevelDB.manifest([UInt8](manifest))?.files == [7, 8])
        #expect(ChromiumLocalStorage.get("store", origin: origin, in: data) == "{\"state\":{\"width\":288,\"sections\":[]},\"version\":4}")
        #expect(ChromiumLocalStorage.get("gone", origin: origin, in: data) == nil)
        #expect(ChromiumLocalStorage.get("never", origin: origin, in: data) == nil)

        // Read, changed and written back under one lock; the change sees the newest value.
        #expect(ChromiumLocalStorage.update("store", origin: origin, in: data) { old in old.map { $0.replacingOccurrences(of: "288", with: "300") } })
        #expect(ChromiumLocalStorage.get("store", origin: origin, in: data) == "{\"state\":{\"width\":300,\"sections\":[]},\"version\":4}")
        // Nothing to change: nothing written.
        #expect(!ChromiumLocalStorage.update("never", origin: origin, in: data) { $0 })
        // A live table that can't be read: nothing is trusted.
        try FileManager.default.removeItem(at: dir.appending(path: "000007.ldb"))
        #expect(ChromiumLocalStorage.get("store", origin: origin, in: data) == nil)
        #expect(!ChromiumLocalStorage.update("store", origin: origin, in: data) { _ in "x" })
    }
}

/// A LevelDB table holding these entries (user key, sequence, value) in one data block, as Chromium writes them:
/// keys in order, a restart point, and each block followed by its type and masked checksum.
private func sstable(_ entries: [(key: [UInt8], sequence: UInt64, value: [UInt8])], compressed: Bool = false) -> [UInt8] {
    func internalKey(_ key: [UInt8], _ sequence: UInt64) -> [UInt8] { key + (0..<8).map { UInt8((sequence << 8 | 1) >> (8 * UInt64($0)) & 0xFF) } }
    func block(_ items: [([UInt8], [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        for (key, value) in items { out += LevelDB.varint(0) + LevelDB.varint(UInt64(key.count)) + LevelDB.varint(UInt64(value.count)) + key + value }
        return out + [0, 0, 0, 0] + [1, 0, 0, 0]
    }
    /// Snappy with literals only, at most 60 bytes each.
    func snappy(_ bytes: [UInt8]) -> [UInt8] {
        var out = LevelDB.varint(UInt64(bytes.count)), rest = bytes[...]
        while !rest.isEmpty {
            let chunk = rest.prefix(60)
            out += [UInt8(chunk.count - 1) << 2] + chunk
            rest = rest.dropFirst(chunk.count)
        }
        return out
    }
    var file: [UInt8] = []
    func put(_ contents: [UInt8], type: UInt8) -> [UInt8] {
        let handle = LevelDB.varint(UInt64(file.count)) + LevelDB.varint(UInt64(contents.count))
        let checksum = LevelDB.mask(LevelDB.crc32c(contents + [type]))
        file += contents + [type] + (0..<4).map { UInt8(checksum >> (8 * UInt32($0)) & 0xFF) }
        return handle
    }
    let sorted = entries.sorted { $0.key.lexicographicallyPrecedes($1.key) }
    let data = block(sorted.map { (internalKey($0.key, $0.sequence), $0.value) })
    let dataHandle = compressed ? put(snappy(data), type: 1) : put(data, type: 0)
    let meta = put(block([]), type: 0)
    let index = put(block([(internalKey(sorted.last!.key, sorted.last!.sequence), dataHandle)]), type: 0)
    let handles = meta + index
    return file + handles + [UInt8](repeating: 0, count: 40 - handles.count) + LevelDB.tableMagic
}
