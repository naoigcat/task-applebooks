import Foundation

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

        // Core Data defaults are not SQLite defaults; raw inserts must supply them.
        let metadataColumns = try findColumns(schema.collectionTable, patterns: [
            .exact("ZCOLLECTIONID"), .exact("ZDELETEDFLAG"), .exact("ZHIDDEN"),
            .exact("ZPLACEHOLDER"), .exact("ZSORTKEY"),
            .exact("ZLASTMODIFICATION"), .exact("ZLOCALMODDATE")
        ])
        try validateInsertableColumns(schema.collectionTable, provided: [
            schema.collectionID, schema.collectionTitle, schema.collectionEntity,
            schema.collectionVersion
        ] + metadataColumns.map(Optional.some))
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
        let now = Date().timeIntervalSinceReferenceDate
        for column in metadataColumns {
            let value: SQLiteValue
            switch column.uppercased() {
            case "ZCOLLECTIONID": value = .text(UUID().uuidString)
            case "ZLASTMODIFICATION", "ZLOCALMODDATE": value = .real(now)
            case "ZSORTKEY":
                let row = try db.query("SELECT MAX(\(schema.quote(column))) AS max_sort FROM \(schema.quote(schema.collectionTable))").first
                value = .integer(max(row?.int64("max_sort") ?? 0, 0) + 10_000)
            default: value = .integer(0)
            }
            attributes.append((column, value))
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
        let localModDate = try findColumns(schema.memberTable, patterns: [.exact("ZLOCALMODDATE")]).first
        try validateInsertableColumns(schema.memberTable, provided: [
            schema.memberPK, schema.memberCollectionID, schema.memberAssetID,
            schema.memberEntity, schema.memberVersion, schema.memberOrder,
            schema.memberAssetIdentifier, localModDate
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
            if let memberIdentifier = schema.memberAssetIdentifier {
                guard let assetIdentifier = schema.assetIdentifier,
                      let identifier = try db.query("""
                        SELECT \(schema.quote(assetIdentifier)) AS identifier
                        FROM \(schema.quote(schema.assetTable))
                        WHERE \(schema.quote(schema.assetID)) = ?
                        """, [.integer(assetID)]).first?.string("identifier"),
                      !identifier.isEmpty else {
                    throw SchemaError(message: "Missing asset identifier for library asset \(assetID).")
                }
                attributes.append((memberIdentifier, .text(identifier)))
            }
            if let localModDate {
                attributes.append((localModDate, .real(Date().timeIntervalSinceReferenceDate)))
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

private func timestamp(_ format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = format
    return formatter.string(from: Date())
}
