import Foundation
import SQLite3

nonisolated(unsafe) private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var stringValue: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .null, .blob: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        case .text(let value): return Int64(value)
        case .null, .blob: return nil
        }
    }
}

struct SQLiteRow {
    private let values: [String: SQLiteValue]

    init(_ values: [String: SQLiteValue]) {
        self.values = values
    }

    subscript(_ name: String) -> SQLiteValue? { values[name] }

    func string(_ name: String) -> String? { self[name]?.stringValue }
    func int64(_ name: String) -> Int64? { self[name]?.int64Value }
}

struct SQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(path: String, flags: Int32) throws {
        var connection: OpaquePointer?
        let result = path.withCString { sqlite3_open_v2($0, &connection, flags, nil) }
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let connection { sqlite3_close(connection) }
            throw SQLiteError(message: message)
        }
        handle = connection
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        let prepareResult = sql.withCString {
            sqlite3_prepare_v2(handle, $0, -1, &statement, nil)
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError(message: errorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw SQLiteError(message: errorMessage()) }
    }

    func setBusyTimeout(_ milliseconds: Int32) throws {
        guard sqlite3_busy_timeout(handle, milliseconds) == SQLITE_OK else {
            throw SQLiteError(message: errorMessage())
        }
    }

    func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        var statement: OpaquePointer?
        let prepareResult = sql.withCString {
            sqlite3_prepare_v2(handle, $0, -1, &statement, nil)
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteError(message: errorMessage())
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw SQLiteError(message: errorMessage()) }

            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index) else { continue }
                row[String(cString: name)] = columnValue(statement, index: index)
            }
            rows.append(SQLiteRow(row))
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
                }
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else { throw SQLiteError(message: errorMessage()) }
        }
    }

    private func columnValue(_ statement: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let value = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: value))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    private func errorMessage() -> String { String(cString: sqlite3_errmsg(handle)) }
}
