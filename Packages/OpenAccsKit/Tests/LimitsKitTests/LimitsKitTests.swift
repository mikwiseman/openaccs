import Foundation
import OpenAccsCore

/// A fresh folder under the system temp directory (never the real home).
func makeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "openaccs-limits-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Milliseconds since 1970 for a date `seconds` from now.
func msFromNow(_ seconds: TimeInterval) -> Int64 {
    Int64((Date().timeIntervalSince1970 + seconds) * 1000)
}
