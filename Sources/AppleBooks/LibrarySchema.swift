import Foundation

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
    let memberAssetIdentifier: String?
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
            memberAssetIdentifier: firstColumn(memberColumns, [.exact("ZASSETID"), .exact("ZBOOKID")]),
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
