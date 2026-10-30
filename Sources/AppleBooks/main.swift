import Foundation
import SQLite3
import Darwin

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

struct SchemaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ColumnPattern: CustomStringConvertible {
    case exact(String)
    case contains(String)

    func matches(_ name: String) -> Bool {
        let upper = name.uppercased()
        switch self {
        case .exact(let value): return upper == value.uppercased()
        case .contains(let value): return upper.contains(value.uppercased())
        }
    }

    var description: String {
        switch self {
        case .exact(let value): return "\\A\(value)\\z"
        case .contains(let value): return value
        }
    }
}

struct ColumnInfo {
    let name: String
    let notNull: Bool
    let defaultValue: SQLiteValue
}

struct LibrarySchema {
    let collectionTable: String
    let collectionID: String
    let collectionTitle: String
    let collectionDeletedFlag: String?
    let collectionEntity: String?
    let collectionVersion: String?
    let memberTable: String
    let memberPK: String
    let memberCollectionID: String
    let memberAssetID: String
    let memberOrder: String?
    let memberEntity: String?
    let memberVersion: String?
    let assetTable: String
    let assetID: String
    let assetTitle: String?
    let assetAuthor: String?
    let assetSortAuthor: String?
    let assetIdentifier: String?

    static func detect(_ db: SQLiteDatabase) throws -> LibrarySchema {
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }

        let collectionTable = try findTable(tables, description: "COLLECTION", where: {
            $0.uppercased().hasSuffix("COLLECTION") && !$0.uppercased().contains("MEMBER")
        })
        let memberTable = try findTable(tables, description: "COLLECTION.*MEMBER", where: {
            let upper = $0.uppercased()
            return upper.contains("COLLECTION") && upper.contains("MEMBER")
        })
        let assetTable = try findTable(tables, description: "LIBRARYASSET", where: {
            $0.uppercased().contains("LIBRARYASSET")
        })

        let collectionColumns = try tableInfo(db, collectionTable).map(\.name)
        let memberColumns = try tableInfo(db, memberTable).map(\.name)
        let assetColumns = try tableInfo(db, assetTable).map(\.name)

        return LibrarySchema(
            collectionTable: collectionTable,
            collectionID: try requiredColumn(collectionTable, collectionColumns, [.exact("Z_PK")]),
            collectionTitle: try firstColumn(collectionTable, collectionColumns, [.exact("ZTITLE"), .exact("ZNAME")]),
            collectionDeletedFlag: firstColumn(collectionColumns, [.exact("ZDELETEDFLAG")]),
            collectionEntity: firstColumn(collectionColumns, [.exact("Z_ENT")]),
            collectionVersion: firstColumn(collectionColumns, [.exact("Z_OPT")]),
            memberTable: memberTable,
            memberPK: try requiredColumn(memberTable, memberColumns, [.exact("Z_PK")]),
            memberCollectionID: try firstColumn(memberTable, memberColumns, [.exact("ZCOLLECTION"), .contains("COLLECTION")]),
            memberAssetID: try firstColumn(memberTable, memberColumns, [.exact("ZLIBRARYASSET"), .exact("ZASSET"), .contains("ASSET")]),
            memberOrder: firstColumn(memberColumns, [.exact("ZORDER"), .exact("ZSORTKEY"), .contains("ORDER")]),
            memberEntity: firstColumn(memberColumns, [.exact("Z_ENT")]),
            memberVersion: firstColumn(memberColumns, [.exact("Z_OPT")]),
            assetTable: assetTable,
            assetID: try requiredColumn(assetTable, assetColumns, [.exact("Z_PK")]),
            assetTitle: firstColumn(assetColumns, [.exact("ZTITLE"), .exact("ZSORTTITLE")]),
            assetAuthor: firstColumn(assetColumns, [.exact("ZAUTHOR")]),
            assetSortAuthor: firstColumn(assetColumns, [.exact("ZSORTAUTHOR")]),
            assetIdentifier: firstColumn(assetColumns, [.exact("ZASSETID"), .exact("ZBOOKID")])
        )
    }

    func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    var activeCollectionCondition: String {
        guard let collectionDeletedFlag else { return "1" }
        return "COALESCE(c.\(quote(collectionDeletedFlag)), 0) = 0"
    }

    private static func findTable(
        _ tables: [String],
        description: String,
        where predicate: (String) -> Bool
    ) throws -> String {
        guard let table = tables.first(where: predicate) else {
            throw SchemaError(message: "Could not detect the Apple Books table structure: \(description)")
        }
        return table
    }

    private static func requiredColumn(
        _ table: String,
        _ columns: [String],
        _ patterns: [ColumnPattern]
    ) throws -> String {
        try firstColumn(table, columns, patterns)
    }

    private static func firstColumn(
        _ columns: [String],
        _ patterns: [ColumnPattern]
    ) -> String? {
        for pattern in patterns {
            if let column = columns.first(where: { pattern.matches($0) }) { return column }
        }
        return nil
    }

    private static func firstColumn(
        _ table: String,
        _ columns: [String],
        _ patterns: [ColumnPattern]
    ) throws -> String {
        guard let column = firstColumn(columns, patterns) else {
            let descriptions = patterns.map(\.description).joined(separator: ", ")
            throw SchemaError(message: "Required column was not found in \(table): \(descriptions)")
        }
        return column
    }

    private static func tableInfo(_ db: SQLiteDatabase, _ table: String) throws -> [ColumnInfo] {
        let quoted = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try db.query("PRAGMA table_info(\(quoted))").compactMap { row in
            guard let name = row.string("name") else { return nil }
            return ColumnInfo(
                name: name,
                notNull: row.int64("notnull") == 1,
                defaultValue: row["dflt_value"] ?? .null
            )
        }
    }
}

struct Book: Encodable {
    let title: String?
    let author: String?
    let identifier: String?
    let order: Int64?

    private enum CodingKeys: String, CodingKey { case title, author, identifier, order }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let title { try container.encode(title, forKey: .title) }
        if let author { try container.encode(author, forKey: .author) }
        if let identifier { try container.encode(identifier, forKey: .identifier) }
        if let order { try container.encode(order, forKey: .order) }
    }
}

struct BookCollection: Encodable {
    let id: Int64
    let title: String
    let books: [Book]
}

struct CollectionReader {
    static let ignoredCollectionTitles = ["Books", "Downloaded", "My Samples", "Want to Read", "Library"]

    let db: SQLiteDatabase

    func collections() throws -> [BookCollection] {
        let schema = try LibrarySchema.detect(db)
        let rows = try db.query(query(for: schema))
        let grouped = Dictionary(grouping: rows) { $0.int64("collection_id") ?? 0 }
        var result: [BookCollection] = []

        for rows in grouped.values {
            guard let first = rows.first,
                  let id = first.int64("collection_id"),
                  let title = first.string("collection_title") else {
                throw SchemaError(message: "A collection row was missing its ID or title.")
            }
            if Self.ignoredCollectionTitles.contains(title) { continue }

            let books = rows.map { row in
                Book(
                    title: row.string("asset_title"),
                    author: displayAuthor(row.string("asset_author"), row.string("asset_sort_author")),
                    identifier: row.string("asset_identifier"),
                    order: row.int64("member_order")
                )
            }
            result.append(BookCollection(id: id, title: title, books: books))
        }

        return result.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private func query(for schema: LibrarySchema) -> String {
        var selects = [
            "c.\(schema.quote(schema.collectionID)) AS \(schema.quote("collection_id"))",
            "c.\(schema.quote(schema.collectionTitle)) AS \(schema.quote("collection_title"))",
            "a.\(schema.quote(schema.assetID)) AS \(schema.quote("asset_pk"))"
        ]
        let optional: [(String, String?, String)] = [
            ("a", schema.assetTitle, "asset_title"),
            ("a", schema.assetAuthor, "asset_author"),
            ("a", schema.assetSortAuthor, "asset_sort_author"),
            ("a", schema.assetIdentifier, "asset_identifier"),
            ("m", schema.memberOrder, "member_order")
        ]
        selects += optional.compactMap { tableAlias, column, alias in
            guard let column else { return nil }
            return "\(tableAlias).\(schema.quote(column)) AS \(schema.quote(alias))"
        }

        let orderColumn = schema.memberOrder.map {
            "m.\(schema.quote($0))"
        } ?? "a.\(schema.quote(schema.assetTitle ?? schema.assetID))"

        return """
        SELECT \(selects.joined(separator: ",\n          "))
        FROM \(schema.quote(schema.collectionTable)) c
        INNER JOIN \(schema.quote(schema.memberTable)) m
          ON m.\(schema.quote(schema.memberCollectionID)) = c.\(schema.quote(schema.collectionID))
        INNER JOIN \(schema.quote(schema.assetTable)) a
          ON a.\(schema.quote(schema.assetID)) = m.\(schema.quote(schema.memberAssetID))
        WHERE c.\(schema.quote(schema.collectionTitle)) IS NOT NULL
          AND \(schema.activeCollectionCondition)
        ORDER BY LOWER(c.\(schema.quote(schema.collectionTitle))), \(orderColumn)
        """
    }

    private func displayAuthor(_ author: String?, _ sortAuthor: String?) -> String? {
        let authorText = author ?? ""
        if authorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstAuthor(sortAuthor)
        }
        if !multipleAuthors(authorText) { return author }
        return firstAuthor(sortAuthor) ?? firstAuthor(author)
    }

    private func multipleAuthors(_ author: String) -> Bool {
        author.range(of: #"(?i)(^|[^\p{L}])multiple[\s\p{P}]*authors?($|[^\p{L}])"#, options: .regularExpression) != nil
    }

    private func firstAuthor(_ author: String?) -> String? {
        guard let author else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"\s*(?:;|&|\band\b|/|／|、|，)\s*"#, options: [.caseInsensitive])
        var parts: [String] = []
        var end = author.startIndex
        for match in pattern.matches(in: author, range: NSRange(author.startIndex..., in: author)) {
            guard let range = Range(match.range, in: author) else { continue }
            parts.append(String(author[end..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            end = range.upperBound
        }
        parts.append(String(author[end...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.first { !$0.isEmpty && !multipleAuthors($0) }
    }
}

enum Formatter {
    static func text(_ collections: [BookCollection]) -> String {
        collections.map { collection in
            var lines = ["\(collection.title) (\(collection.books.count) books)"]
            for (index, book) in collection.books.enumerated() {
                let details = [
                    book.author,
                    book.identifier.map { "ID: \($0)" }
                ].compactMap { $0 }.joined(separator: " / ")
                let title = book.title ?? ""
                lines.append("\(index + 1). \(title)")
                if !details.isEmpty { lines.append("   \(details)") }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func json(_ collections: [BookCollection]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let output = String(data: try encoder.encode(collections), encoding: .utf8) else {
            throw SchemaError(message: "Could not encode collections as JSON.")
        }
        return output
    }
}

struct PrimaryKeyEntity {
    let entity: Int64
    let name: String
    let max: Int64
}

struct QueueResult {
    let queueTitle: String
    let bookCount: Int
    let backupPath: String?
}

final class QueueUpdater {
    private let db: SQLiteDatabase
    private let databasePath: String
    private var tableInfoCache: [String: [ColumnInfo]] = [:]

    init(db: SQLiteDatabase, databasePath: String) {
        self.db = db
        self.databasePath = databasePath
    }

    func addUncategorized(backup: Bool, dryRun: Bool) throws -> QueueResult {
        let schema = try LibrarySchema.detect(db)
        let queueTitle = "Queue_\(timestamp("yyyyMMddHHmmss"))"
        if dryRun {
            let count = try uncategorizedAssetIDs(schema).count
            return QueueResult(queueTitle: queueTitle, bookCount: count, backupPath: nil)
        }

        let result = try addWithLock(schema, queueTitle: queueTitle, backup: backup)
        return QueueResult(queueTitle: queueTitle, bookCount: result.assetIDs.count, backupPath: result.backupPath)
    }

    private func addWithLock(
        _ schema: LibrarySchema,
        queueTitle: String,
        backup: Bool
    ) throws -> (assetIDs: [Int64], backupPath: String?) {
        try db.execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let assetIDs = try uncategorizedAssetIDs(schema)
            guard !assetIDs.isEmpty else {
                try db.execute("ROLLBACK")
                return ([], nil)
            }

            let backupPath = backup ? try backupDatabase() : nil
            let queueID = try createQueueCollection(schema, title: queueTitle)
            try insertMembers(schema, queueID: queueID, assetIDs: assetIDs)
            try db.execute("COMMIT")
            return (assetIDs, backupPath)
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func createQueueCollection(_ schema: LibrarySchema, title: String) throws -> Int64 {
        let existing = try db.query("""
            SELECT \(schema.quote(schema.collectionID)) AS id
            FROM \(schema.quote(schema.collectionTable))
            WHERE \(schema.quote(schema.collectionTitle)) = ?
            LIMIT 1
            """, [.text(title)])
        if !existing.isEmpty {
            throw SchemaError(message: "\(title) collection already exists. Retry after the next second.")
        }

        try validateInsertableColumns(schema.collectionTable, provided: [
            schema.collectionID, schema.collectionTitle, schema.collectionEntity,
            schema.collectionVersion
        ])
        let primaryKey = try reservePrimaryKeys(schema, table: schema.collectionTable, column: schema.collectionID, count: 1)[0]
        var attributes: [(String, SQLiteValue)] = [
            (schema.collectionID, .integer(primaryKey)),
            (schema.collectionTitle, .text(title))
        ]
        if let entityColumn = schema.collectionEntity {
            attributes.append((entityColumn, .integer(try primaryKeyEntityRequired(schema.collectionTable).entity)))
        }
        if let versionColumn = schema.collectionVersion {
            attributes.append((versionColumn, .integer(1)))
        }
        try insertRow(schema, table: schema.collectionTable, attributes: attributes)
        return primaryKey
    }

    private func uncategorizedAssetIDs(_ schema: LibrarySchema) throws -> [Int64] {
        let ignored = CollectionReader.ignoredCollectionTitles
        let placeholders = Array(repeating: "?", count: ignored.count).joined(separator: ", ")
        let titleOrder = schema.assetTitle.map {
            "LOWER(a.\(schema.quote($0)))"
        } ?? "a.\(schema.quote(schema.assetID))"

        let relatedColumns = try findColumns(schema.assetTable, patterns: [
            .exact("ZSERIESCONTAINER"),
            .exact("ZPURCHASEDANDLOCALPARENT"),
            .exact("ZLOCALONLYSERIESITEMSPARENT")
        ])
        let relatedConditions = relatedColumns.map { column in
            """
            AND NOT EXISTS (
              \(realCollectionMemberQuery(schema, assetExpression: "a.\(schema.quote(column))", placeholders: placeholders))
            )
            """
        }.joined(separator: "\n")
        let purchaseCondition = try purchasedAssetCondition(schema)

        let sql = """
        SELECT a.\(schema.quote(schema.assetID)) AS id
        FROM \(schema.quote(schema.assetTable)) a
        WHERE NOT EXISTS (
          \(realCollectionMemberQuery(schema, assetExpression: "a.\(schema.quote(schema.assetID))", placeholders: placeholders))
        )
        \(relatedConditions)
        \(try assetExclusionConditions(schema))
        AND \(purchaseCondition)
        ORDER BY \(titleOrder), a.\(schema.quote(schema.assetID))
        """

        var values: [SQLiteValue] = []
        for _ in 0...relatedColumns.count {
            values += ignored.map(SQLiteValue.text)
        }
        return try db.query(sql, values).map { row in
            guard let id = row.int64("id") else {
                throw SchemaError(message: "An asset row was missing its ID.")
            }
            return id
        }
    }

    private func realCollectionMemberQuery(
        _ schema: LibrarySchema,
        assetExpression: String,
        placeholders: String
    ) -> String {
        """
        SELECT 1
        FROM \(schema.quote(schema.memberTable)) m
        INNER JOIN \(schema.quote(schema.collectionTable)) c
          ON c.\(schema.quote(schema.collectionID)) = m.\(schema.quote(schema.memberCollectionID))
        WHERE m.\(schema.quote(schema.memberAssetID)) = \(assetExpression)
          AND c.\(schema.quote(schema.collectionTitle)) IS NOT NULL
          AND c.\(schema.quote(schema.collectionTitle)) NOT IN (\(placeholders))
          AND \(schema.activeCollectionCondition)
        """
    }

    private func assetExclusionConditions(_ schema: LibrarySchema) throws -> String {
        try findColumns(schema.assetTable, patterns: [
            .exact("ZISHIDDEN"), .exact("ZISSAMPLE"), .exact("ZISEPHEMERAL"),
            .exact("ZISSUPPLEMENTALCONTENT")
        ]).map { "AND COALESCE(a.\(schema.quote($0)), 0) = 0" }.joined(separator: "\n")
    }

    private func purchasedAssetCondition(_ schema: LibrarySchema) throws -> String {
        let columns = try findColumns(schema.assetTable, patterns: [.exact("ZPURCHASEDATE"), .exact("ZCANREDOWNLOAD")])
        guard !columns.isEmpty else {
            throw SchemaError(message: "Could not detect purchase columns in \(schema.assetTable).")
        }
        let conditions = columns.map { column in
            if column.uppercased() == "ZCANREDOWNLOAD" {
                return "COALESCE(a.\(schema.quote(column)), 0) = 1"
            }
            return "a.\(schema.quote(column)) IS NOT NULL"
        }
        return "(\(conditions.joined(separator: " OR ")))"
    }

    private func insertMembers(_ schema: LibrarySchema, queueID: Int64, assetIDs: [Int64]) throws {
        try validateInsertableColumns(schema.memberTable, provided: [
            schema.memberPK, schema.memberCollectionID, schema.memberAssetID,
            schema.memberEntity, schema.memberVersion, schema.memberOrder
        ])
        let primaryKeys = try reservePrimaryKeys(schema, table: schema.memberTable, column: schema.memberPK, count: assetIDs.count)
        let firstOrder = try nextMemberOrder(schema, queueID: queueID)
        for (index, assetID) in assetIDs.enumerated() {
            var attributes: [(String, SQLiteValue)] = [
                (schema.memberPK, .integer(primaryKeys[index])),
                (schema.memberCollectionID, .integer(queueID)),
                (schema.memberAssetID, .integer(assetID))
            ]
            if let entityColumn = schema.memberEntity {
                attributes.append((entityColumn, .integer(try primaryKeyEntityRequired(schema.memberTable).entity)))
            }
            if let versionColumn = schema.memberVersion {
                attributes.append((versionColumn, .integer(1)))
            }
            if let orderColumn = schema.memberOrder {
                attributes.append((orderColumn, .integer(firstOrder + Int64(index))))
            }
            try insertRow(schema, table: schema.memberTable, attributes: attributes)
        }
    }

    private func insertRow(
        _ schema: LibrarySchema,
        table: String,
        attributes: [(String, SQLiteValue)]
    ) throws {
        let columns = attributes.map { schema.quote($0.0) }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: attributes.count).joined(separator: ", ")
        try db.execute(
            "INSERT INTO \(schema.quote(table)) (\(columns)) VALUES (\(placeholders))",
            attributes.map(\.1)
        )
    }

    private func validateInsertableColumns(_ table: String, provided: [String?]) throws {
        let provided = Set(provided.compactMap { $0 })
        let missing = try tableInfo(table).filter {
            $0.notNull && $0.defaultValue.isNull && !provided.contains($0.name)
        }.map(\.name)
        guard missing.isEmpty else {
            throw SchemaError(message: "Required columns cannot be populated in \(table): \(missing.joined(separator: ", "))")
        }
    }

    private func findColumns(_ table: String, patterns: [ColumnPattern]) throws -> [String] {
        let columns = try tableInfo(table).map(\.name)
        return patterns.compactMap { pattern in columns.first(where: { pattern.matches($0) }) }
    }

    private func tableInfo(_ table: String) throws -> [ColumnInfo] {
        if let cached = tableInfoCache[table] { return cached }
        let quoted = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        let info = try db.query("PRAGMA table_info(\(quoted))").compactMap { row -> ColumnInfo? in
            guard let name = row.string("name") else { return nil }
            return ColumnInfo(name: name, notNull: row.int64("notnull") == 1, defaultValue: row["dflt_value"] ?? .null)
        }
        tableInfoCache[table] = info
        return info
    }

    private func reservePrimaryKeys(
        _ schema: LibrarySchema,
        table: String,
        column: String,
        count: Int
    ) throws -> [Int64] {
        guard count > 0 else { return [] }
        if let entity = try primaryKeyEntity(table) {
            let first = entity.max + 1
            try db.execute(
                "UPDATE \(schema.quote("Z_PRIMARYKEY")) SET \(schema.quote("Z_MAX")) = ? WHERE \(schema.quote("Z_ENT")) = ?",
                [.integer(first + Int64(count) - 1), .integer(entity.entity)]
            )
            return (0..<count).map { first + Int64($0) }
        }

        let row = try db.query("SELECT MAX(\(schema.quote(column))) AS max_pk FROM \(schema.quote(table))").first
        let maxPK = row?.int64("max_pk") ?? 0
        return (0..<count).map { maxPK + 1 + Int64($0) }
    }

    private func primaryKeyEntity(_ table: String) throws -> PrimaryKeyEntity? {
        guard try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Z_PRIMARYKEY'").isEmpty else {
            return nil
        }
        let rows = try db.query("SELECT Z_ENT, Z_NAME, Z_MAX FROM Z_PRIMARYKEY")
        return rows.compactMap { row -> PrimaryKeyEntity? in
            guard let entity = row.int64("Z_ENT"), let name = row.string("Z_NAME"), let max = row.int64("Z_MAX") else {
                return nil
            }
            guard normalizedEntityName(name) == normalizedTableName(table) else { return nil }
            return PrimaryKeyEntity(entity: entity, name: name, max: max)
        }.first
    }

    private func primaryKeyEntityRequired(_ table: String) throws -> PrimaryKeyEntity {
        guard let entity = try primaryKeyEntity(table) else {
            throw SchemaError(message: "Could not detect the Core Data entity for \(table).")
        }
        return entity
    }

    private func normalizedEntityName(_ name: String) -> String {
        name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private func normalizedTableName(_ table: String) -> String {
        let withoutPrefix = table.first.map { $0.lowercased() == "z" } == true ? String(table.dropFirst()) : table
        return normalizedEntityName(withoutPrefix)
    }

    private func nextMemberOrder(_ schema: LibrarySchema, queueID: Int64) throws -> Int64 {
        guard let orderColumn = schema.memberOrder else { return 0 }
        let row = try db.query("""
            SELECT MAX(\(schema.quote(orderColumn))) AS max_order
            FROM \(schema.quote(schema.memberTable))
            WHERE \(schema.quote(schema.memberCollectionID)) = ?
            """, [.integer(queueID)]).first
        return (row?.int64("max_order") ?? 0) + 1
    }

    private func backupDatabase() throws -> String {
        let backupPath = "\(databasePath).\(timestamp("yyyyMMddHHmmssSSSSSS")).bak"
        try AppleBooksDatabase.copyTo(sourcePath: databasePath, destinationPath: backupPath)
        return backupPath
    }
}

enum AppleBooksDatabase {
    private static let directories = [
        "Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary",
        "Library/Containers/com.apple.BKAgentService/Data/Documents/BKLibrary",
        "Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books/BKLibrary"
    ]

    static func expand(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func discover() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = directories.flatMap { relativePath -> [String] in
            let directory = home.appendingPathComponent(relativePath)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
            return names.compactMap { name in
                guard name.hasPrefix("BKLibrary"), name.hasSuffix(".sqlite") else { return nil }
                let path = directory.appendingPathComponent(name).path
                return fileManager.fileExists(atPath: path) ? path : nil
            }
        }
        return candidates.max {
            let left = (try? fileManager.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
            let right = (try? fileManager.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
            return left < right
        }
    }

    static func copyTo(sourcePath: String, destinationPath: String) throws {
        let source = try SQLiteDatabase(path: expand(sourcePath), flags: SQLITE_OPEN_READONLY)
        try source.execute("VACUUM INTO ?", [.text(expand(destinationPath))])
    }

    static func withConsistentRead<T>(_ path: String, _ body: (SQLiteDatabase) throws -> T) throws -> T {
        let temporaryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-books-library-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: temporaryPath) }
        try copyTo(sourcePath: path, destinationPath: temporaryPath)
        let database = try SQLiteDatabase(path: temporaryPath, flags: SQLITE_OPEN_READONLY)
        return try body(database)
    }

    static func writable(_ path: String) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: expand(path), flags: SQLITE_OPEN_READWRITE)
        try database.setBusyTimeout(5_000)
        return database
    }
}

enum Command: Equatable { case export, enqueue }

struct CLIOptions {
    var command: Command = .export
    var database: String?
    var json = false
    var dryRun = false
    var backup = true
}

struct UsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func parseOptions(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var arguments = arguments
    if let first = arguments.first {
        switch first {
        case "export": options.command = .export; arguments.removeFirst()
        case "enqueue": options.command = .enqueue; arguments.removeFirst()
        case "--help", "-h": printUsage(); exit(0)
        default: break
        }
    }

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--json": options.json = true
        case "--dry-run": options.dryRun = true
        case "--backup": options.backup = true
        case "--no-backup": options.backup = false
        case "--help", "-h": printUsage(); exit(0)
        case "-d", "--database":
            index += 1
            guard index < arguments.count else { throw UsageError(message: "Missing path after \(argument).") }
            options.database = arguments[index]
        default:
            if argument.hasPrefix("--database=") {
                options.database = String(argument.dropFirst("--database=".count))
                guard !(options.database?.isEmpty ?? true) else { throw UsageError(message: "Database path cannot be empty.") }
            } else {
                throw UsageError(message: "Unknown option: \(argument)")
            }
        }
        index += 1
    }

    if options.command == .export && options.dryRun { throw UsageError(message: "--dry-run is only valid for enqueue.") }
    if options.command == .enqueue && options.json { throw UsageError(message: "--json is only valid for export.") }
    return options
}

func printUsage() {
    print("""
    Usage: apple-books [export] [options]
           apple-books enqueue [options]

    Options:
      -d, --database PATH  BKLibrary SQLite database path
          --json           Output export as JSON
          --dry-run        Show the enqueue count without changing the database
          --no-backup      Do not create a backup before enqueueing
          --help            Show this help
    """)
}

func run(_ options: CLIOptions) throws {
    let databasePath: String
    if let path = options.database {
        databasePath = AppleBooksDatabase.expand(path)
    } else if let path = AppleBooksDatabase.discover() {
        databasePath = AppleBooksDatabase.expand(path)
    } else {
        throw UsageError(message: "Apple Books database was not found. Specify BKLibrary*.sqlite with --database.")
    }

    switch options.command {
    case .export:
        let output = try AppleBooksDatabase.withConsistentRead(databasePath) { db in
            let collections = try CollectionReader(db: db).collections()
            guard !collections.isEmpty else { throw UsageError(message: "No collections were found.") }
            return try options.json ? Formatter.json(collections) : Formatter.text(collections)
        }
        print(output)
    case .enqueue:
        let db = try AppleBooksDatabase.writable(databasePath)
        let result = try QueueUpdater(db: db, databasePath: databasePath)
            .addUncategorized(backup: options.backup, dryRun: options.dryRun)
        let action = options.dryRun ? "would be added to" : "added to"
        print("\(result.bookCount) books \(action) \(result.queueTitle) collection.")
        if let backupPath = result.backupPath { print("Backup: \(backupPath)") }
    }
}

func timestamp(_ format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = format
    return formatter.string(from: Date())
}

var options = CLIOptions()
do {
    options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    try run(options)
} catch let error as SQLiteError {
    let action = options.command == .export ? "read" : "update"
    fputs("Error: Failed to \(action) SQLite database: \(error.message)\n", stderr)
    exit(1)
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
