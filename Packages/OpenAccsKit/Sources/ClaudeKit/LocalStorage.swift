import Darwin
import Foundation

/// One localStorage value written into a closed Chromium profile (`<dataDir>/Local Storage/leveldb`): a LevelDB
/// write batch appended to the database's newest log, which LevelDB replays when the app opens it next.
/// Done under the database's own lock, and only when every record already there checks out.
enum ChromiumLocalStorage {
    /// Sets `key` of `origin` (like "https://claude.ai") to `value`. false when the database is in use, missing
    /// or not in the shape expected; nothing is written then.
    static func set(_ value: String, for key: String, origin: String, in dataDir: URL) -> Bool {
        let dir = dataDir.appending(path: "Local Storage/leveldb", directoryHint: .isDirectory)
        let lock = open(dir.appending(path: "LOCK").path, O_RDWR)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        var whole = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(lock, F_SETLK, &whole) == 0 else { return false }   // the app has it open

        guard let current = try? String(contentsOf: dir.appending(path: "CURRENT"), encoding: .utf8)
                .trimmingCharacters(in: .newlines), current.hasPrefix("MANIFEST-"), !current.contains("/"),
              let manifest = try? Data(contentsOf: dir.appending(path: current)),
              let state = LevelDB.manifest([UInt8](manifest)) else { return false }
        // Every log LevelDB replays at open, oldest first; the batch goes at the end of the newest.
        let first = state.prevLogNumber == 0 ? state.logNumber : min(state.logNumber, state.prevLogNumber)
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name -> (UInt64, URL)? in
            guard name.hasSuffix(".log"), let number = UInt64(name.dropLast(4)), number >= first else { return nil }
            return (number, dir.appending(path: name))
        }.sorted { $0.0 < $1.0 }
        guard let target = logs.last, FS.isRegularFile(target.1) else { return false }
        var sequence = state.lastSequence
        var tail: [UInt8] = []
        for (_, file) in logs {
            guard let data = try? Data(contentsOf: file), let records = LevelDB.records([UInt8](data)) else { return false }
            for record in records {
                guard let last = LevelDB.lastSequence(ofBatch: record) else { return false }
                sequence = max(sequence, last)
            }
            tail = [UInt8](data)
        }
        let batch = LevelDB.putBatch(key: Self.key(key, origin: origin), value: Self.encoded(value), sequence: sequence + 1)
        let bytes = LevelDB.framed(batch, after: tail.count)
        let fd = open(target.1.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count && fsync(fd) == 0
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
}

/// The parts of LevelDB's on-disk format a single appended write needs (log records, write batches, manifest).
enum LevelDB {
    static let blockSize = 32_768
    static let headerSize = 7

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
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(batch[$1]) << (8 * UInt64($1)) }
        let count = UInt64(u32(batch, 8))
        return count == 0 ? sequence &- 1 : sequence + count - 1
    }

    struct Manifest: Equatable {
        var logNumber: UInt64 = 0
        var prevLogNumber: UInt64 = 0
        var lastSequence: UInt64 = 0
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
                case 6: guard number() != nil, number() != nil else { return nil }           // deleted file
                case 7: guard number() != nil, number() != nil, number() != nil, bytes(), bytes() else { return nil }   // new file
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

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0x82F6_3B78 ^ (c >> 1) : c >> 1 }
    }
}
