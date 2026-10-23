/// A TOML value as Codex writes it in ~/.codex/config.toml. Dates and times are left out: Codex never writes them.
public indirect enum TOMLValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [TOMLValue]? { if case .array(let value) = self { value } else { nil } }
    public var table: [String: TOMLValue]? { if case .table(let value) = self { value } else { nil } }
}

/// A small reader and editor for ~/.codex/config.toml. It reads the file into a value tree and edits its text in
/// place: an edit replaces only the text of what it changes, and every other byte stays as it was, because
/// Codex and the ChatGPT app keep their own state in the same file.
///
/// Every edit is read back before it is kept. When the new text would mean anything but the intended change
/// (a table defined twice, a key added to an inline table), the edit is refused and the text stays as it is.
public struct TOMLFile: Sendable {
    public private(set) var text: String
    private var scalars: [Unicode.Scalar]
    private var root: [String: TOMLValue]
    private var entries: [Entry]

    /// nil when the text is not TOML this reader understands.
    public init?(text: String) {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        do { try parser.parse() } catch { return nil }
        self.text = text
        scalars = parser.scalars
        root = parser.root.value
        entries = parser.entries
    }

    /// The value of `key` in `table` ([] for the top level).
    public func value(_ key: String, in table: [String]) -> TOMLValue? {
        var current = root
        for name in table {
            guard case .table(let next) = current[name] else { return nil }
            current = next
        }
        return current[key]
    }

    /// The MCP servers by name, each with all of its tables merged ([mcp_servers.x], [mcp_servers.x.env], env = {…}).
    public var mcpServers: [String: TOMLValue] { root["mcp_servers"]?.table ?? [:] }

    /// Sets one key. An existing key gets only its value's text replaced (a comment after it stays); a new key
    /// goes after the last key of its table, and a missing table is added at the end of the file. Returns false,
    /// changing nothing, when that would not mean exactly this change.
    @discardableResult
    public mutating func set(_ key: String, _ value: TOMLValue, in table: [String]) -> Bool {
        guard self.value(key, in: table) != value else { return true }
        let path = table + [key]
        let line = "\(Self.key(key)) = \(Self.inline(value))\n"
        let edit: Edit
        if let entry = keyEntry(path) {
            edit = Edit(range: entry.value, text: Self.inline(value))
        } else if let end = endOfTable(table) {
            edit = Edit(range: end..<end, text: (startsLine(end) ? "" : "\n") + line)
        } else if table.isEmpty {
            edit = Edit(range: 0..<0, text: line + (scalars.isEmpty ? "" : "\n"))
        } else {
            edit = Edit(range: scalars.count..<scalars.count, text: separator + Self.header(table) + line)
        }
        return apply([edit], expecting: Self.setting(path[...], to: value, in: root))
    }

    /// Removes one key's lines. Returns false, changing nothing, when the key is not on lines of its own
    /// (it is inside an inline table, or it is a table).
    @discardableResult
    public mutating func remove(_ key: String, in table: [String]) -> Bool {
        guard value(key, in: table) != nil else { return true }
        let path = table + [key]
        guard let entry = keyEntry(path) else { return false }
        return apply([Edit(range: entry.lines, text: "")], expecting: Self.setting(path[...], to: nil, in: root))
    }

    /// Replaces, adds or (with nil) removes the whole text of one MCP server: [mcp_servers.<name>] and all of its
    /// [mcp_servers.<name>.*] tables. The new text takes the place of the first of them; a new server goes after
    /// the last MCP server, or at the end of the file. Returns false, changing nothing, when it can't be done cleanly.
    @discardableResult
    public mutating func setServer(_ name: String, _ value: TOMLValue?) -> Bool {
        guard mcpServers[name] != value else { return true }
        let prefix = ["mcp_servers", name]
        var newText = ""
        if let value {
            guard case .table(let server) = value else { return false }
            newText = Self.render(server, at: prefix)
        }
        let own = sections.filter { $0.path.starts(with: prefix) }.map(\.range)
        // Its keys written inside other tables: `name = { … }` under [mcp_servers], or dotted keys.
        let stray = entries.filter { !$0.isHeader && !$0.inArray && $0.path.starts(with: prefix) && !$0.table.starts(with: prefix) }
        var edits: [Edit] = []
        var removed = stray.map(\.lines)
        if value == nil {
            removed += own.map(withBlankLines)
        } else if let first = own.first {
            edits.append(Edit(range: first, text: newText))
            removed += own.dropFirst().map(withBlankLines)
        } else if let end = sections.last(where: { $0.path.first == "mcp_servers" })?.range.upperBound {
            edits.append(Edit(range: end..<end, text: (startsLine(end) ? "" : "\n") + "\n" + newText))
        } else {
            edits.append(Edit(range: scalars.count..<scalars.count, text: separator + newText))
        }
        edits += Self.joined(removed).map { Edit(range: $0, text: "") }
        return apply(edits, expecting: Self.setting(prefix[...], to: value, in: root))
    }

    /// A table as TOML text under the header `path` ([] for a whole file): its keys in sorted order, plain values
    /// first, then each sub-table under its own header. A table that holds only tables gets no header of its own.
    public static func render(_ table: [String: TOMLValue], at path: [String] = []) -> String {
        var plain = "", tables = ""
        for (name, value) in table.sorted(by: { $0.key < $1.key }) {
            if case .table(let sub) = value {
                tables += (tables.isEmpty ? "" : "\n") + render(sub, at: path + [name])
            } else {
                plain += "\(key(name)) = \(inline(value))\n"
            }
        }
        let top = (!path.isEmpty && (!plain.isEmpty || tables.isEmpty) ? header(path) : "") + plain
        return top + (top.isEmpty || tables.isEmpty ? "" : "\n") + tables
    }

    // MARK: Writing values

    static func header(_ path: [String]) -> String { "[" + path.map(key).joined(separator: ".") + "]\n" }

    static func key(_ name: String) -> String {
        !name.isEmpty && name.unicodeScalars.allSatisfy(Parser.isBare) ? name : quoted(name)
    }

    static func inline(_ value: TOMLValue) -> String {
        switch value {
        case .string(let string): quoted(string)
        case .integer(let number): String(number)
        case .float(let number): "\(number)"   // Swift writes inf, -inf and nan the way TOML does
        case .bool(let flag): flag ? "true" : "false"
        case .array(let items): "[" + items.map(inline).joined(separator: ", ") + "]"
        case .table(let table) where table.isEmpty: "{}"
        case .table(let table):
            "{ " + table.sorted(by: { $0.key < $1.key }).map { "\(key($0.key)) = \(inline($0.value))" }.joined(separator: ", ") + " }"
        }
    }

    static func quoted(_ string: String) -> String {
        var text = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\t": text += "\\t"
            case "\r": text += "\\r"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            case "\u{00}"..."\u{1F}", "\u{7F}":
                let hex = String(scalar.value, radix: 16, uppercase: true)
                text += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text + "\""
    }

    // MARK: Editing text

    private struct Edit {
        var range: Range<Int>
        var text: String
    }

    /// Makes the edits, reads the result back and keeps it only when its values are `expected`.
    private mutating func apply(_ edits: [Edit], expecting expected: [String: TOMLValue]) -> Bool {
        var scalars = self.scalars
        // From the end, so earlier offsets stay right; at one offset, a removal before an insertion.
        for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) > ($1.range.lowerBound, $1.range.upperBound) }) {
            scalars.replaceSubrange(edit.range, with: edit.text.unicodeScalars)
        }
        guard let edited = TOMLFile(text: String(String.UnicodeScalarView(scalars))),
              Self.pruned(edited.root) == Self.pruned(expected) else { return false }
        self = edited
        return true
    }

    private func keyEntry(_ path: [String]) -> Entry? {
        entries.first { !$0.isHeader && !$0.inArray && $0.path == path }
    }

    /// The text of each table that has a header, outside arrays of tables: from its header to the end of its last key.
    private var sections: [(path: [String], range: Range<Int>)] {
        var all: [(path: [String], range: Range<Int>, inArray: Bool)] = []
        for entry in entries {
            if entry.isHeader {
                all.append((entry.table, entry.lines, entry.inArray))
            } else if let last = all.indices.last {
                all[last].range = all[last].range.lowerBound..<entry.lines.upperBound
            }
        }
        return all.filter { !$0.inArray }.map { ($0.path, $0.range) }
    }

    /// Where a new key of `table` goes: after its last key, or after its header when it has none.
    private func endOfTable(_ table: [String]) -> Int? {
        if table.isEmpty { return entries.prefix { !$0.isHeader }.last?.lines.upperBound }
        return sections.first { $0.path == table }?.range.upperBound
    }

    private func startsLine(_ offset: Int) -> Bool { offset == 0 || scalars[offset - 1] == "\n" }

    /// What goes at the end of the file before a new table, so one blank line comes before it.
    private var separator: String {
        guard let last = scalars.last else { return "" }
        if last != "\n" { return "\n\n" }
        return scalars.count > 1 && scalars[scalars.count - 2] == "\n" ? "" : "\n"
    }

    /// `range` (whole lines) with the blank lines just before it, or when there are none, just after it, so removing
    /// a table leaves the same spacing between its neighbours.
    private func withBlankLines(_ range: Range<Int>) -> Range<Int> {
        let blank: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
        var start = range.lowerBound
        while start > 0 {
            var lineStart = start - 1
            while lineStart > 0, scalars[lineStart - 1] != "\n" { lineStart -= 1 }
            guard scalars[lineStart..<start].allSatisfy(blank) else { break }
            start = lineStart
        }
        if start < range.lowerBound { return start..<range.upperBound }
        var end = range.upperBound
        while let newline = scalars[end...].firstIndex(of: "\n"), scalars[end..<newline].allSatisfy(blank) {
            end = newline + 1
        }
        return range.lowerBound..<end
    }

    /// Ranges joined where they overlap or touch, so no text is removed twice.
    private static func joined(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func setting(_ path: ArraySlice<String>, to value: TOMLValue?, in table: [String: TOMLValue]) -> [String: TOMLValue] {
        var table = table
        guard let name = path.first else { return table }
        if path.count == 1 {
            table[name] = value
        } else {
            table[name] = .table(setting(path.dropFirst(), to: value, in: table[name]?.table ?? [:]))
        }
        return table
    }

    /// Without empty tables, which mean nothing to Codex (removing a table's last key may leave its header).
    private static func pruned(_ table: [String: TOMLValue]) -> [String: TOMLValue] {
        table.compactMapValues { value in
            guard case .table(let sub) = value else { return value }
            let rest = pruned(sub)
            return rest.isEmpty ? nil : .table(rest)
        }
    }
}

/// One header or key, with where its text is.
private struct Entry {
    /// The table a key is in, or the table a header opens.
    var table: [String]
    /// The key (a dotted key has several parts); empty for a header.
    var key: [String]
    /// Under an array of tables ([[…]]), where a path names no single table, so edits leave it alone.
    var inArray: Bool
    /// Its whole lines, the newline included.
    var lines: Range<Int>
    /// A key's value.
    var value: Range<Int>

    var isHeader: Bool { key.isEmpty }
    var path: [String] { table + key }
}

/// Reads the text line by line. It refuses what TOML forbids (a key or table defined twice, keys added to an
/// inline table), so a file Codex would not load is never edited.
private struct Parser {
    /// A table while reading, with how it was made: a header may open a table only once, and dotted keys may
    /// add only to tables that dotted keys made.
    final class Table {
        enum Origin { case implied, header, dottedKeys }
        enum Slot {
            case table(Table)
            case tables([Table])
            case value(TOMLValue)
        }
        var origin: Origin
        var slots: [String: Slot] = [:]
        init(_ origin: Origin) { self.origin = origin }

        var value: [String: TOMLValue] {
            slots.mapValues { slot in
                switch slot {
                case .table(let table): .table(table.value)
                case .tables(let tables): .array(tables.map { .table($0.value) })
                case .value(let value): value
                }
            }
        }
    }

    struct Invalid: Error {}

    let scalars: [Unicode.Scalar]
    var pos = 0
    let root = Table(.header)
    var entries: [Entry] = []

    init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

    static func isBare(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
    }

    mutating func parse() throws {
        var table = root, path: [String] = [], inArray = false
        while pos < scalars.count {
            let start = pos
            skipSpaces()
            if peek == nil || peek == "\n" || peek == "\r" || peek == "#" {
                try endLine()
            } else if peek == "[" {
                pos += 1
                let isArray = peek == "["
                if isArray { pos += 1 }
                skipSpaces()
                path = try key()
                try expect("]")
                if isArray { try expect("]") }
                try endLine()
                (table, inArray) = try open(path, isArray: isArray)
                entries.append(Entry(table: path, key: [], inArray: inArray, lines: start..<pos, value: pos..<pos))
            } else {
                let key = try self.key()
                try expect("=")
                skipSpaces()
                let valueStart = pos
                let value = try self.value()
                let valueEnd = pos
                try endLine()
                try put(value, at: key, in: table)
                entries.append(Entry(table: path, key: key, inArray: inArray, lines: start..<pos, value: valueStart..<valueEnd))
            }
        }
    }

    /// The table a header opens, made where missing, and whether it is in an array of tables.
    func open(_ path: [String], isArray: Bool) throws -> (Table, Bool) {
        var table = root, inArray = false
        for (i, name) in path.enumerated() {
            let last = i == path.count - 1
            switch table.slots[name] {
            case nil where last && isArray:
                let new = Table(.header)
                table.slots[name] = .tables([new])
                return (new, true)
            case nil:
                let new = Table(last ? .header : .implied)
                table.slots[name] = .table(new)
                table = new
            case .table(let existing)?:
                if last {
                    guard !isArray, existing.origin == .implied else { throw Invalid() }
                    existing.origin = .header
                }
                table = existing
            case .tables(let existing)?:
                inArray = true
                if last {
                    guard isArray else { throw Invalid() }
                    let new = Table(.header)
                    table.slots[name] = .tables(existing + [new])
                    return (new, true)
                }
                table = existing[existing.count - 1]
            case .value?:
                throw Invalid()
            }
        }
        return (table, inArray)
    }

    /// Puts a key's value into `table`, making the tables its dotted parts name.
    func put(_ value: TOMLValue, at key: [String], in table: Table) throws {
        var table = table
        for name in key.dropLast() {
            switch table.slots[name] {
            case nil:
                let new = Table(.dottedKeys)
                table.slots[name] = .table(new)
                table = new
            case .table(let existing)? where existing.origin == .dottedKeys:
                table = existing
            default:
                throw Invalid()
            }
        }
        guard table.slots[key[key.count - 1]] == nil else { throw Invalid() }
        table.slots[key[key.count - 1]] = .value(value)
    }

    // MARK: Lines and keys

    var peek: Unicode.Scalar? { pos < scalars.count ? scalars[pos] : nil }

    func starts(_ text: String) -> Bool {
        scalars[pos...].starts(with: text.unicodeScalars)
    }

    mutating func expect(_ c: Unicode.Scalar) throws {
        guard peek == c else { throw Invalid() }
        pos += 1
    }

    mutating func skipSpaces() {
        while peek == " " || peek == "\t" { pos += 1 }
    }

    /// The rest of a line, which may hold only spaces and a comment, and its newline.
    mutating func endLine() throws {
        skipSpaces()
        if peek == "#" { while let c = peek, c != "\n", c != "\r" { pos += 1 } }
        guard peek != nil else { return }
        if peek == "\r" { pos += 1 }
        try expect("\n")
    }

    /// Spaces, newlines and comments, as arrays and inline tables allow.
    mutating func skipBlank() throws {
        skipSpaces()
        while peek == "#" || peek == "\n" || peek == "\r" {
            try endLine()
            skipSpaces()
        }
    }

    /// A key and the spaces after it: bare, quoted or dotted (`a."b c".d`).
    mutating func key() throws -> [String] {
        var parts: [String] = []
        while true {
            if peek == "\"" {
                parts.append(try basicString())
            } else if peek == "'" {
                parts.append(try literalString())
            } else {
                let start = pos
                while let c = peek, Self.isBare(c) { pos += 1 }
                guard pos > start else { throw Invalid() }
                parts.append(String(String.UnicodeScalarView(scalars[start..<pos])))
            }
            skipSpaces()
            guard peek == "." else { return parts }
            pos += 1
            skipSpaces()
        }
    }

    // MARK: Values

    mutating func value() throws -> TOMLValue {
        if starts("\"\"\"") || starts("'''") { return .string(try multilineString()) }
        switch peek {
        case "\"": return .string(try basicString())
        case "'": return .string(try literalString())
        case "[": return try array()
        case "{": return try inlineTable()
        default: return try scalar()
        }
    }

    mutating func basicString() throws -> String {
        pos += 1
        var text = String.UnicodeScalarView()
        while true {
            guard let c = peek, c != "\n", c != "\r" else { throw Invalid() }
            if c == "\"" {
                pos += 1
                return String(text)
            }
            if c == "\\" { try escape(into: &text) } else { text.append(c); pos += 1 }
        }
    }

    mutating func literalString() throws -> String {
        pos += 1
        let start = pos
        while let c = peek, c != "'", c != "\n", c != "\r" { pos += 1 }
        let text = String(String.UnicodeScalarView(scalars[start..<pos]))
        try expect("'")
        return text
    }

    /// A """ or ''' string. A newline right after the opening quotes is not part of it, and in a """ string a
    /// backslash at the end of a line removes the newline and the spaces after it.
    mutating func multilineString() throws -> String {
        let quote = scalars[pos]
        pos += 3
        if starts("\r\n") { pos += 2 } else if peek == "\n" { pos += 1 }
        var text = String.UnicodeScalarView()
        while true {
            guard let c = peek else { throw Invalid() }
            if c == quote, starts(String(repeating: String(quote), count: 3)) {
                // Up to two more quotes right before the closing ones belong to the string.
                var quotes = 3
                while quotes < 5, pos + quotes < scalars.count, scalars[pos + quotes] == quote { quotes += 1 }
                text.append(contentsOf: repeatElement(quote, count: quotes - 3))
                pos += quotes
                return String(text)
            }
            if c == "\\", quote == "\"" {
                var next = pos + 1
                while next < scalars.count, scalars[next] == " " || scalars[next] == "\t" { next += 1 }
                if next < scalars.count, scalars[next] == "\n" || scalars[next] == "\r" {
                    pos = next
                    while let s = peek, s == " " || s == "\t" || s == "\n" || s == "\r" { pos += 1 }
                } else {
                    try escape(into: &text)
                }
                continue
            }
            text.append(c)
            pos += 1
        }
    }

    mutating func escape(into text: inout String.UnicodeScalarView) throws {
        pos += 1
        guard let c = peek else { throw Invalid() }
        pos += 1
        switch c {
        case "b": text.append("\u{08}")
        case "t": text.append("\t")
        case "n": text.append("\n")
        case "f": text.append("\u{0C}")
        case "r": text.append("\r")
        case "\"": text.append("\"")
        case "\\": text.append("\\")
        case "u", "U":
            let count = c == "u" ? 4 : 8
            guard pos + count <= scalars.count, scalars[pos..<pos + count].allSatisfy(\.properties.isASCIIHexDigit),
                  let code = UInt32(String(String.UnicodeScalarView(scalars[pos..<pos + count])), radix: 16),
                  let scalar = Unicode.Scalar(code) else { throw Invalid() }
            text.append(scalar)
            pos += count
        default:
            throw Invalid()
        }
    }

    /// `[…]`, over several lines if need be, with comments and a trailing comma.
    mutating func array() throws -> TOMLValue {
        pos += 1
        var items: [TOMLValue] = []
        while true {
            try skipBlank()
            if peek == "]" {
                pos += 1
                return .array(items)
            }
            items.append(try value())
            try skipBlank()
            if peek == "," { pos += 1 } else { try expect("]"); return .array(items) }
        }
    }

    /// `{ a = 1, b.c = "x" }`. Its tables are whole: nothing outside it adds to them.
    mutating func inlineTable() throws -> TOMLValue {
        pos += 1
        var table: [String: TOMLValue] = [:]
        while true {
            try skipBlank()
            if peek == "}" {
                pos += 1
                return .table(table)
            }
            let key = try self.key()
            try expect("=")
            skipSpaces()
            guard Self.put(try value(), at: key[...], in: &table) else { throw Invalid() }
            try skipBlank()
            if peek == "," { pos += 1 } else { try expect("}"); return .table(table) }
        }
    }

    static func put(_ value: TOMLValue, at key: ArraySlice<String>, in table: inout [String: TOMLValue]) -> Bool {
        let name = key[key.startIndex]
        if key.count == 1 {
            guard table[name] == nil else { return false }
            table[name] = value
            return true
        }
        var sub: [String: TOMLValue] = [:]
        if let existing = table[name] {
            guard case .table(let found) = existing else { return false }
            sub = found
        }
        guard put(value, at: key.dropFirst(), in: &sub) else { return false }
        table[name] = .table(sub)
        return true
    }

    /// A number or a boolean. Dates and times are refused.
    mutating func scalar() throws -> TOMLValue {
        let start = pos
        while let c = peek, Self.isBare(c) || c == "+" || c == "." { pos += 1 }
        let word = String(String.UnicodeScalarView(scalars[start..<pos]))
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        let digits = word.filter { $0 != "_" }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
            guard let number = Int(digits.dropFirst(2), radix: radix) else { throw Invalid() }
            return .integer(number)
        }
        if let number = Int(digits) { return .integer(number) }
        // A float has a fraction or an exponent; a whole number too big for Int is refused, not rounded.
        guard digits.contains(where: { ".eE".contains($0) }), digits.allSatisfy({ "0123456789+-.eE".contains($0) }),
              let number = Double(digits) else { throw Invalid() }
        return .float(number)
    }
}
