import Foundation

/// A deliberately small TOML reader — enough for the config files agent
/// harnesses write (codex's `config.toml`): tables, dotted and quoted keys,
/// strings, integers, floats, booleans, arrays (multi-line too), inline
/// tables, and array-of-tables headers. Dates parse as strings. Anything
/// outside that subset throws with a line number rather than guessing.
public enum MiniTOML {
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case integer(Int)
        case float(Double)
        case bool(Bool)
        case array([Value])
        case table([String: Value])

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var tableValue: [String: Value]? {
            if case .table(let value) = self { return value }
            return nil
        }

        public var arrayValue: [Value]? {
            if case .array(let value) = self { return value }
            return nil
        }

        public subscript(key: String) -> Value? {
            tableValue?[key]
        }

        /// Only string-valued entries, for `env`-style maps.
        public var stringMap: [String: String] {
            guard let table = tableValue else { return [:] }
            return table.compactMapValues { value in
                switch value {
                case .string(let s): s
                case .integer(let i): String(i)
                case .float(let d): String(d)
                case .bool(let b): String(b)
                default: nil
                }
            }
        }
    }

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var line: Int
        public var message: String
        public var description: String { "line \(line): \(message)" }
    }

    public static func parse(_ text: String) throws -> [String: Value] {
        var parser = Parser(text: text)
        return try parser.parseDocument()
    }

    // MARK: - Parser

    private struct Parser {
        let chars: [Character]
        var index = 0
        var line = 1
        var root: [String: Value] = [:]
        /// Key path of the current `[table]` header.
        var current: [String] = []
        /// Headers declared as `[[array]]`; new `[[x]]` appends, `[x.y]` addresses the last element.
        var arrayTables: Set<String> = []

        init(text: String) {
            chars = Array(text)
        }

        mutating func parseDocument() throws -> [String: Value] {
            while true {
                skipWhitespaceAndComments(includingNewlines: true)
                guard let c = peek() else { break }
                if c == "[" {
                    try parseHeader()
                } else {
                    let path = try parseKeyPath()
                    skipInlineWhitespace()
                    guard consume("=") else { throw error("expected '=' after key") }
                    skipInlineWhitespace()
                    let value = try parseValue()
                    try set(current + path, to: value)
                    try expectEndOfLine()
                }
            }
            return root
        }

        // MARK: Headers and keys

        mutating func parseHeader() throws {
            _ = consume("[")
            let isArray = consume("[")
            skipInlineWhitespace()
            let path = try parseKeyPath()
            skipInlineWhitespace()
            guard consume("]") else { throw error("expected ']' to close table header") }
            if isArray {
                guard consume("]") else { throw error("expected ']]' to close array-of-tables header") }
                let joined = path.joined(separator: "\u{1}")
                arrayTables.insert(joined)
                var array = lookupArray(path) ?? []
                array.append(.table([:]))
                try setRaw(path, to: .array(array))
            } else if lookup(path) == nil {
                try setRaw(path, to: .table([:]))
            }
            current = path
            try expectEndOfLine()
        }

        mutating func parseKeyPath() throws -> [String] {
            var parts: [String] = []
            repeat {
                skipInlineWhitespace()
                parts.append(try parseSimpleKey())
                skipInlineWhitespace()
            } while consume(".")
            return parts
        }

        mutating func parseSimpleKey() throws -> String {
            guard let c = peek() else { throw error("expected key") }
            if c == "\"" { return try parseBasicString() }
            if c == "'" { return try parseLiteralString() }
            var key = ""
            while let ch = peek(), ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                key.append(ch)
                advance()
            }
            guard !key.isEmpty else { throw error("expected key, found '\(c)'") }
            return key
        }

        // MARK: Values

        mutating func parseValue() throws -> Value {
            guard let c = peek() else { throw error("expected value") }
            switch c {
            case "\"": return .string(try parseBasicString())
            case "'": return .string(try parseLiteralString())
            case "[": return try parseArray()
            case "{": return try parseInlineTable()
            case "t", "f":
                if consumeWord("true") { return .bool(true) }
                if consumeWord("false") { return .bool(false) }
                throw error("unexpected token")
            default:
                return try parseNumberOrDate()
            }
        }

        mutating func parseArray() throws -> Value {
            _ = consume("[")
            var items: [Value] = []
            while true {
                skipWhitespaceAndComments(includingNewlines: true)
                if consume("]") { return .array(items) }
                items.append(try parseValue())
                skipWhitespaceAndComments(includingNewlines: true)
                if consume(",") { continue }
                skipWhitespaceAndComments(includingNewlines: true)
                guard consume("]") else { throw error("expected ',' or ']' in array") }
                return .array(items)
            }
        }

        mutating func parseInlineTable() throws -> Value {
            _ = consume("{")
            var table: [String: Value] = [:]
            skipInlineWhitespace()
            if consume("}") { return .table(table) }
            while true {
                skipInlineWhitespace()
                let path = try parseKeyPath()
                skipInlineWhitespace()
                guard consume("=") else { throw error("expected '=' in inline table") }
                skipInlineWhitespace()
                let value = try parseValue()
                table = try inserting(value, at: path[...], into: table)
                skipInlineWhitespace()
                if consume(",") { continue }
                guard consume("}") else { throw error("expected ',' or '}' in inline table") }
                return .table(table)
            }
        }

        mutating func parseNumberOrDate() throws -> Value {
            var token = ""
            while let ch = peek(), !ch.isWhitespace, ch != ",", ch != "]", ch != "}", ch != "#" {
                token.append(ch)
                advance()
            }
            guard !token.isEmpty else { throw error("expected value") }
            let cleaned = token.replacingOccurrences(of: "_", with: "")
            if let int = Int(cleaned) { return .integer(int) }
            if cleaned.hasPrefix("0x"), let int = Int(cleaned.dropFirst(2), radix: 16) { return .integer(int) }
            if let double = Double(cleaned) { return .float(double) }
            if cleaned == "inf" || cleaned == "+inf" { return .float(.infinity) }
            if cleaned == "-inf" { return .float(-.infinity) }
            if cleaned == "nan" { return .float(.nan) }
            // Dates and times: keep the text, that's all a config scan needs.
            if token.first?.isNumber == true, token.contains("-") || token.contains(":") {
                return .string(token)
            }
            throw error("unrecognized value '\(token)'")
        }

        mutating func parseBasicString() throws -> String {
            _ = consume("\"")
            if consume("\"") {
                // Either an empty string or the opening of a multi-line one.
                guard consume("\"") else { return "" }
                return try parseMultilineBasicString()
            }
            var out = ""
            while let ch = peek() {
                advance()
                if ch == "\"" { return out }
                if ch == "\n" { throw error("newline in string") }
                if ch == "\\" {
                    out.append(try parseEscape())
                } else {
                    out.append(ch)
                }
            }
            throw error("unterminated string")
        }

        mutating func parseMultilineBasicString() throws -> String {
            if consume("\n") { line += 1 } else if consume("\r") { _ = consume("\n"); line += 1 }
            var out = ""
            while let ch = peek() {
                if ch == "\"", peek(1) == "\"", peek(2) == "\"" {
                    advance(); advance(); advance()
                    return out
                }
                advance()
                if ch == "\n" { line += 1 }
                if ch == "\\" {
                    if let next = peek(), next == "\n" || next.isWhitespace {
                        // Line-ending backslash trims the following whitespace.
                        while let ws = peek(), ws.isWhitespace {
                            if ws == "\n" { line += 1 }
                            advance()
                        }
                        continue
                    }
                    out.append(try parseEscape())
                } else {
                    out.append(ch)
                }
            }
            throw error("unterminated multi-line string")
        }

        mutating func parseEscape() throws -> Character {
            guard let ch = peek() else { throw error("dangling escape") }
            advance()
            switch ch {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "b": return "\u{8}"
            case "f": return "\u{c}"
            case "u", "U":
                let width = ch == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<width {
                    guard let h = peek() else { throw error("short unicode escape") }
                    hex.append(h)
                    advance()
                }
                guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                    throw error("bad unicode escape")
                }
                return Character(scalar)
            default:
                throw error("unknown escape '\\\(ch)'")
            }
        }

        mutating func parseLiteralString() throws -> String {
            _ = consume("'")
            if consume("'") {
                guard consume("'") else { return "" }
                if consume("\n") { line += 1 }
                var out = ""
                while let ch = peek() {
                    if ch == "'", peek(1) == "'", peek(2) == "'" {
                        advance(); advance(); advance()
                        return out
                    }
                    if ch == "\n" { line += 1 }
                    out.append(ch)
                    advance()
                }
                throw error("unterminated multi-line literal string")
            }
            var out = ""
            while let ch = peek() {
                advance()
                if ch == "'" { return out }
                if ch == "\n" { throw error("newline in literal string") }
                out.append(ch)
            }
            throw error("unterminated literal string")
        }

        // MARK: Tree writes

        mutating func set(_ path: [String], to value: Value) throws {
            if let existing = lookup(path), case .table = existing, case .table = value {
                // Re-opening an implicitly created table is fine; redefining a leaf is not.
            } else if lookup(path) != nil {
                throw error("duplicate key '\(path.joined(separator: "."))'")
            }
            try setRaw(path, to: value)
        }

        mutating func setRaw(_ path: [String], to value: Value) throws {
            root = try inserting(value, at: path[...], into: root)
        }

        /// Insert following array-of-tables semantics: a path prefix that
        /// names an `[[x]]` header addresses its last element.
        func inserting(_ value: Value, at path: ArraySlice<String>, into table: [String: Value]) throws -> [String: Value] {
            guard let head = path.first else { return table }
            var table = table
            if path.count == 1 {
                table[head] = value
                return table
            }
            switch table[head] {
            case .table(let child):
                table[head] = .table(try inserting(value, at: path.dropFirst(), into: child))
            case .array(var items):
                guard case .table(let last)? = items.last else {
                    throw error("cannot extend array '\(head)' with a table")
                }
                items[items.count - 1] = .table(try inserting(value, at: path.dropFirst(), into: last))
                table[head] = .array(items)
            case nil:
                table[head] = .table(try inserting(value, at: path.dropFirst(), into: [:]))
            default:
                throw error("'\(head)' is not a table")
            }
            return table
        }

        func lookup(_ path: [String]) -> Value? {
            var node: Value = .table(root)
            for key in path {
                switch node {
                case .table(let table):
                    guard let next = table[key] else { return nil }
                    node = next
                case .array(let items):
                    guard case .table(let last)? = items.last, let next = last[key] else { return nil }
                    node = next
                default:
                    return nil
                }
            }
            return node
        }

        func lookupArray(_ path: [String]) -> [Value]? {
            lookup(path)?.arrayValue
        }

        // MARK: Lexing helpers

        func peek(_ offset: Int = 0) -> Character? {
            let i = index + offset
            return i < chars.count ? chars[i] : nil
        }

        mutating func advance() {
            index += 1
        }

        mutating func consume(_ c: Character) -> Bool {
            guard peek() == c else { return false }
            advance()
            return true
        }

        mutating func consumeWord(_ word: String) -> Bool {
            let w = Array(word)
            for (i, ch) in w.enumerated() where peek(i) != ch { return false }
            if let after = peek(w.count), after.isLetter || after.isNumber || after == "_" { return false }
            index += w.count
            return true
        }

        mutating func skipInlineWhitespace() {
            while let ch = peek(), ch == " " || ch == "\t" { advance() }
        }

        mutating func skipWhitespaceAndComments(includingNewlines: Bool) {
            while let ch = peek() {
                if ch == " " || ch == "\t" || ch == "\r" {
                    advance()
                } else if ch == "\n", includingNewlines {
                    line += 1
                    advance()
                } else if ch == "#" {
                    while let c = peek(), c != "\n" { advance() }
                } else {
                    return
                }
            }
        }

        mutating func expectEndOfLine() throws {
            skipInlineWhitespace()
            if peek() == "#" { while let c = peek(), c != "\n" { advance() } }
            guard let ch = peek() else { return }
            if ch == "\r" { advance() }
            guard consume("\n") else { throw error("unexpected '\(ch)' after value") }
            line += 1
        }

        func error(_ message: String) -> ParseError {
            ParseError(line: line, message: message)
        }
    }
}
