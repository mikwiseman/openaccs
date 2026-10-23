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
    }
}
