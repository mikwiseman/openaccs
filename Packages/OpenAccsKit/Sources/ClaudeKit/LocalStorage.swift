import Darwin
import Foundation

/// localStorage of a closed Chromium profile (`<dataDir>/Local Storage/leveldb`). A value is read from the live
/// tables and logs, newest first, and written as a LevelDB write batch appended to the newest log, which LevelDB
/// replays when the app opens it next. Done under the database's own lock, and only when every record already
/// there checks out.
enum ChromiumLocalStorage {
    /// Sets `key` of `origin` (like "https://claude.ai") to `value`. false when the database is in use, missing
    /// or not in the shape expected; nothing is written then.
    static func set(_ value: String, for key: String, origin: String, in dataDir: URL) -> Bool {
        withDatabase(dataDir) { $0.append(Self.key(key, origin: origin), Self.encoded(value)) } ?? false
    }

    /// The newest value of `key`; nil when there is none, or the database is in use, missing or not in the shape expected.
    static func get(_ key: String, origin: String, in dataDir: URL) -> String? {
        guard case .value(let bytes)? = withDatabase(dataDir, { $0.newest(Self.key(key, origin: origin)) }) else { return nil }
        return decoded(bytes)
    }

    /// Sets `key` to what `change` makes of its newest value (nil: none), read and written under one lock. false
    /// when nothing was written: `change` gave nil, or the database is in use, missing or not in the shape expected.
    static func update(_ key: String, origin: String, in dataDir: URL, _ change: (String?) -> String?) -> Bool {
        withDatabase(dataDir) { database in
            let row = Self.key(key, origin: origin)
            let current: String?
            switch database.newest(row) {
            case .unreadable: return false
            case .none: current = nil
            case .value(let bytes):
                guard let text = decoded(bytes) else { return false }
                current = text
            }
            guard let value = change(current) else { return false }
            return database.append(row, Self.encoded(value))
        } ?? false
    }

    /// Runs `body` while holding the database's lock; nil when it is in use (the app has it open), missing or not
    /// in the shape expected.
    private static func withDatabase<T>(_ dataDir: URL, _ body: (LevelDB.Database) -> T) -> T? {
        let dir = dataDir.appending(path: "Local Storage/leveldb", directoryHint: .isDirectory)
        let lock = open(dir.appending(path: "LOCK").path, O_RDWR)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        var whole = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(lock, F_SETLK, &whole) == 0 else { return nil }   // the app has it open

        guard let current = try? String(contentsOf: dir.appending(path: "CURRENT"), encoding: .utf8)
                .trimmingCharacters(in: .newlines), current.hasPrefix("MANIFEST-"), !current.contains("/"),
              let manifest = try? Data(contentsOf: dir.appending(path: current)),
              let state = LevelDB.manifest([UInt8](manifest)) else { return nil }
        // Every log LevelDB replays at open, oldest first.
        let first = state.prevLogNumber == 0 ? state.logNumber : min(state.logNumber, state.prevLogNumber)
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name -> (UInt64, URL)? in
            guard name.hasSuffix(".log"), let number = UInt64(name.dropLast(4)), number >= first else { return nil }
            return (number, dir.appending(path: name))
        }.sorted { $0.0 < $1.0 }.map(\.1)
        return body(LevelDB.Database(dir: dir, state: state, logs: logs))
    }

    /// Chromium's localStorage row key: `_<origin>\0` and the key in its own encoding.
    static func key(_ key: String, origin: String) -> [UInt8] {
        Array("_\(origin)".utf8) + [0] + encoded(key)
    }

    /// Chromium's localStorage string: 1 and Latin-1 bytes when every character fits, else 0 and UTF-16LE.
    static func encoded(_ string: String) -> [UInt8] {
        let units = Array(string.utf16)
        if units.allSatisfy({ $0 < 256 }) { return [1] + units.map { UInt8($0) } }
        return [0] + units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    static func decoded(_ bytes: [UInt8]) -> String? {
        switch bytes.first {
        case 1: return String(decoding: bytes.dropFirst().map { UInt16($0) }, as: UTF16.self)
        case 0 where bytes.count % 2 == 1:
            let units = stride(from: 1, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        default: return nil
        }
    }
}

/// The parts of LevelDB's on-disk format that reading a value and appending a write need (log records, write
/// batches, tables, manifest).
enum LevelDB {
    static let blockSize = 32_768
    static let headerSize = 7

    /// A database opened under its lock: its manifest's state and the logs it replays at open, oldest first.
    struct Database {
        enum Lookup { case none, value([UInt8]), unreadable }

        var dir: URL
        var state: Manifest
        var logs: [URL]

        /// The newest entry for `key` in the live tables and the logs: its value, or none when that entry deletes it.
        func newest(_ key: [UInt8]) -> Lookup {
            var best: (sequence: UInt64, value: [UInt8]?)?
            func consider(_ entries: [(key: [UInt8], sequence: UInt64, value: [UInt8]?)]) {
                for entry in entries where entry.key == key && best.map({ $0.sequence < entry.sequence }) ?? true {
                    best = (entry.sequence, entry.value)
                }
            }
            for number in state.files.sorted() {
                let name = String(format: "%06llu", number)
                guard let data = (try? Data(contentsOf: dir.appending(path: "\(name).ldb"))) ?? (try? Data(contentsOf: dir.appending(path: "\(name).sst"))),
                      let entries = LevelDB.table([UInt8](data)) else { return .unreadable }
                consider(entries)
            }
            for log in logs {
                guard let data = try? Data(contentsOf: log), let records = LevelDB.records([UInt8](data)) else { return .unreadable }
                for batch in records {
                    guard let entries = LevelDB.entries(ofBatch: batch) else { return .unreadable }
                    consider(entries)
                }
            }
            return best?.value.map(Lookup.value) ?? .none
        }

        /// Puts `value` at the end of the newest log, after the newest entry anywhere.
        func append(_ key: [UInt8], _ value: [UInt8]) -> Bool {
            guard let target = logs.last, FS.isRegularFile(target) else { return false }
            var sequence = state.lastSequence
            var tail: [UInt8] = []
            for file in logs {
                guard let data = try? Data(contentsOf: file), let records = LevelDB.records([UInt8](data)) else { return false }
                for record in records {
                    guard let last = LevelDB.lastSequence(ofBatch: record) else { return false }
                    sequence = max(sequence, last)
                }
                tail = [UInt8](data)
            }
            let batch = LevelDB.putBatch(key: key, value: value, sequence: sequence + 1)
            let bytes = LevelDB.framed(batch, after: tail.count)
            let fd = open(target.path, O_WRONLY | O_APPEND)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            return written == bytes.count && fsync(fd) == 0
        }
    }

    /// A log's records (whole, reassembled from fragments); nil if any record is damaged or the file
    /// doesn't end where a record ends.
    static func records(_ data: [UInt8]) -> [[UInt8]]? {
        var records: [[UInt8]] = [], pending: [UInt8]?
        var offset = 0
        while offset < data.count {
            let left = blockSize - offset % blockSize
            if left < headerSize {   // a block's trailer: zeros
                let end = min(offset + left, data.count)
                guard data[offset..<end].allSatisfy({ $0 == 0 }) else { return nil }
                offset = end
                continue
            }
            guard offset + headerSize <= data.count else { return nil }
            let checksum = u32(data, offset), length = Int(data[offset + 4]) | Int(data[offset + 5]) << 8, type = data[offset + 6]
            let start = offset + headerSize
            guard (1...4).contains(type), headerSize + length <= left, start + length <= data.count,
                  unmask(checksum) == crc32c([type] + data[start..<start + length]) else { return nil }
            let fragment = Array(data[start..<start + length])
            switch type {
            case 1:
                guard pending == nil else { return nil }
                records.append(fragment)
            case 2:
                guard pending == nil else { return nil }
                pending = fragment
            case 3:
                guard pending != nil else { return nil }
                pending! += fragment
            default:
                guard let first = pending else { return nil }
                records.append(first + fragment)
                pending = nil
            }
            offset = start + length
        }
        return pending == nil ? records : nil
    }

    /// `record` as the bytes that go after a log of `size` bytes (fragmented across blocks like LevelDB does).
    static func framed(_ record: [UInt8], after size: Int) -> [UInt8] {
        var out: [UInt8] = [], blockOffset = size % blockSize, rest = record[...], first = true
        repeat {
            let left = blockSize - blockOffset
            if left < headerSize {
                out += [UInt8](repeating: 0, count: left)
                blockOffset = 0
            }
            let take = min(rest.count, blockSize - blockOffset - headerSize)
            let last = take == rest.count
            let type: UInt8 = first && last ? 1 : first ? 2 : last ? 4 : 3
            let fragment = Array(rest.prefix(take))
            let checksum = mask(crc32c([type] + fragment))
            out += [UInt8(checksum & 0xFF), UInt8(checksum >> 8 & 0xFF), UInt8(checksum >> 16 & 0xFF), UInt8(checksum >> 24),
                    UInt8(take & 0xFF), UInt8(take >> 8), type] + fragment
            blockOffset += headerSize + take
            rest = rest.dropFirst(take)
            first = false
        } while !rest.isEmpty
        return out
    }

    /// A write batch with one put.
    static func putBatch(key: [UInt8], value: [UInt8], sequence: UInt64) -> [UInt8] {
        var out: [UInt8] = (0..<8).map { UInt8(sequence >> (8 * UInt64($0)) & 0xFF) } + [1, 0, 0, 0, 1]
        out += varint(UInt64(key.count)) + key + varint(UInt64(value.count)) + value
        return out
    }

    /// The sequence number of a batch's last entry.
    static func lastSequence(ofBatch batch: [UInt8]) -> UInt64? {
        guard batch.count >= 12 else { return nil }
        let sequence = u64(batch, 0)
        let count = UInt64(u32(batch, 8))
        return count == 0 ? sequence &- 1 : sequence + count - 1
    }

    /// A batch's entries with their sequence numbers (nil value: a deletion); nil when it is not in the shape expected.
    static func entries(ofBatch batch: [UInt8]) -> [(key: [UInt8], sequence: UInt64, value: [UInt8]?)]? {
        guard batch.count >= 12 else { return nil }
        let sequence = u64(batch, 0), count = Int(u32(batch, 8))
        var i = 12, result: [(key: [UInt8], sequence: UInt64, value: [UInt8]?)] = []
        func bytes() -> [UInt8]? {
            guard let n = readVarint(batch, &i), i + Int(n) <= batch.count else { return nil }
            defer { i += Int(n) }
            return Array(batch[i..<i + Int(n)])
        }
        for k in 0..<count {
            guard i < batch.count else { return nil }
            let tag = batch[i]
            i += 1
            guard tag <= 1, let key = bytes() else { return nil }
            let value = tag == 1 ? bytes() : nil
            if tag == 1, value == nil { return nil }
            result.append((key, sequence + UInt64(k), value))
        }
        return result
    }

    static let tableMagic: [UInt8] = [0x57, 0xFB, 0x80, 0x8B, 0x24, 0x75, 0x47, 0xDB]

    /// Every entry of a table file, from its index (user key, sequence; nil value: a deletion); nil when it is not
    /// in the shape expected.
    static func table(_ data: [UInt8]) -> [(key: [UInt8], sequence: UInt64, value: [UInt8]?)]? {
        guard data.count >= 48, Array(data.suffix(8)) == tableMagic else { return nil }
        var i = data.count - 48
        guard readVarint(data, &i) != nil, readVarint(data, &i) != nil,   // the meta index, not needed
              let offset = readVarint(data, &i), let size = readVarint(data, &i),
              let index = block(data, offset: offset, size: size).flatMap(blockEntries) else { return nil }
        var result: [(key: [UInt8], sequence: UInt64, value: [UInt8]?)] = []
        for (_, handle) in index {
            var j = 0
            guard let offset = readVarint(handle, &j), let size = readVarint(handle, &j),
                  let entries = block(data, offset: offset, size: size).flatMap(blockEntries) else { return nil }
            for (key, value) in entries {
                guard key.count >= 8 else { return nil }
                let trailer = u64(key, key.count - 8)
                result.append((Array(key.dropLast(8)), trailer >> 8, trailer & 0xFF == 1 ? value : nil))
            }
        }
        return result
    }

    /// A table block's contents, checked against its checksum and decompressed (Snappy).
    static func block(_ data: [UInt8], offset: UInt64, size: UInt64) -> [UInt8]? {
        guard offset <= UInt64(data.count), size <= UInt64(data.count), Int(offset) + Int(size) + 5 <= data.count else { return nil }
        let start = Int(offset), end = start + Int(size)
        let contents = Array(data[start..<end]), type = data[end]
        guard unmask(u32(data, end + 1)) == crc32c(contents + [type]) else { return nil }
        switch type {
        case 0: return contents
        case 1: return snappy(contents)
        default: return nil
        }
    }

    /// A block's key-value entries, each key rebuilt from the prefix it shares with the one before.
    static func blockEntries(_ block: [UInt8]) -> [([UInt8], [UInt8])]? {
        guard block.count >= 4 else { return nil }
        let restarts = Int(u32(block, block.count - 4))
        guard restarts >= 1, 4 + 4 * restarts <= block.count else { return nil }
        let end = block.count - 4 - 4 * restarts
        var i = 0, key: [UInt8] = [], result: [([UInt8], [UInt8])] = []
        while i < end {
            guard let shared = readVarint(block, &i), let unshared = readVarint(block, &i), let length = readVarint(block, &i),
                  shared <= UInt64(key.count), unshared <= UInt64(end), length <= UInt64(end), i + Int(unshared) + Int(length) <= end else { return nil }
            key = Array(key.prefix(Int(shared))) + block[i..<i + Int(unshared)]
            i += Int(unshared)
            result.append((key, Array(block[i..<i + Int(length)])))
            i += Int(length)
        }
        return result
    }

    /// Snappy's raw format: the length, then literals and copies of what came before.
    static func snappy(_ input: [UInt8]) -> [UInt8]? {
        var i = 0
        guard let length = readVarint(input, &i), length < 1 << 30 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(Int(length))
        func copy(_ count: Int, _ offset: Int) -> Bool {
            guard offset > 0, offset <= out.count, out.count + count <= Int(length) else { return false }
            for _ in 0..<count { out.append(out[out.count - offset]) }
            return true
        }
        func little(_ n: Int) -> Int? {
            guard i + n <= input.count else { return nil }
            defer { i += n }
            return (0..<n).reduce(0) { $0 | Int(input[i + $1]) << (8 * $1) }
        }
        while i < input.count {
            let tag = input[i]
            i += 1
            switch tag & 3 {
            case 0:
                var count = Int(tag >> 2)
                if count >= 60 {
                    guard let long = little(count - 59) else { return nil }
                    count = long
                }
                count += 1
                guard i + count <= input.count, out.count + count <= Int(length) else { return nil }
                out += input[i..<i + count]
                i += count
            case 1:
                guard let low = little(1), copy(Int((tag >> 2) & 7) + 4, Int(tag >> 5) << 8 | low) else { return nil }
            case 2:
                guard let offset = little(2), copy(Int(tag >> 2) + 1, offset) else { return nil }
            default:
                guard let offset = little(4), copy(Int(tag >> 2) + 1, offset) else { return nil }
            }
        }
        return out.count == Int(length) ? out : nil
    }

    struct Manifest: Equatable {
        var logNumber: UInt64 = 0
        var prevLogNumber: UInt64 = 0
        var lastSequence: UInt64 = 0
        /// The live table files, by number.
        var files: Set<UInt64> = []
    }

    /// Log numbers and last sequence from a MANIFEST (a log of version edits); nil on anything unexpected.
    static func manifest(_ data: [UInt8]) -> Manifest? {
        guard let records = records(data) else { return nil }
        var result = Manifest()
        for edit in records {
            var i = 0
            func number() -> UInt64? { readVarint(edit, &i) }
            func bytes() -> Bool {
                guard let n = number(), i + Int(n) <= edit.count else { return false }
                i += Int(n)
                return true
            }
            while i < edit.count {
                guard let tag = number() else { return nil }
                switch tag {
                case 1: guard bytes() else { return nil }                                     // comparator
                case 2: guard let n = number() else { return nil }; result.logNumber = n
                case 3: guard number() != nil else { return nil }                            // next file
                case 4: guard let n = number() else { return nil }; result.lastSequence = n
                case 5: guard number() != nil, bytes() else { return nil }                   // compact pointer
                case 6:                                                                      // deleted file
                    guard number() != nil, let n = number() else { return nil }
                    result.files.remove(n)
                case 7:                                                                      // new file
                    guard number() != nil, let n = number(), number() != nil, bytes(), bytes() else { return nil }
                    result.files.insert(n)
                case 9: guard let n = number() else { return nil }; result.prevLogNumber = n
                default: return nil
                }
            }
        }
        return result
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        return out + [UInt8(v)]
    }

    static func readVarint(_ data: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < data.count, shift <= 63 {
            let byte = data[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    static func crc32c(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }

    static func mask(_ crc: UInt32) -> UInt32 { ((crc >> 15) | (crc << 17)) &+ 0xA282_EAD8 }
    static func unmask(_ masked: UInt32) -> UInt32 {
        let rot = masked &- 0xA282_EAD8
        return (rot >> 17) | (rot << 15)
    }

    private static func u32(_ data: [UInt8], _ i: Int) -> UInt32 {
        UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    private static func u64(_ data: [UInt8], _ i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[i + $1]) << (8 * UInt64($1)) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0x82F6_3B78 ^ (c >> 1) : c >> 1 }
    }
}
