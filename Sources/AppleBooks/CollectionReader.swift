import Foundation

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

            let books = rows.compactMap { row -> Book? in
                guard row.int64("member_pk") != nil else { return nil }
                return Book(
                    title: row.string("asset_title"),
                    author: displayAuthor(row.string("asset_author"), row.string("asset_sort_author")),
                    identifier: row.string("asset_identifier") ?? row.string("member_asset_identifier"),
                    order: row.int64("member_order")
                )
            }
            result.append(BookCollection(id: id, title: title, books: books))
        }

        return result.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private func query(for schema: LibrarySchema) -> String {
        var selects = [
            "c.\(SQLiteDatabase.quote(schema.collectionID)) AS \(SQLiteDatabase.quote("collection_id"))",
            "c.\(SQLiteDatabase.quote(schema.collectionTitle)) AS \(SQLiteDatabase.quote("collection_title"))",
            "m.\(SQLiteDatabase.quote(schema.memberPK)) AS \(SQLiteDatabase.quote("member_pk"))"
        ]
        let optional: [(String, String?, String)] = [
            ("a", schema.assetTitle, "asset_title"),
            ("a", schema.assetAuthor, "asset_author"),
            ("a", schema.assetSortAuthor, "asset_sort_author"),
            ("a", schema.assetIdentifier, "asset_identifier"),
            ("m", schema.memberAssetIdentifier, "member_asset_identifier"),
            ("m", schema.memberOrder, "member_order")
        ]
        selects += optional.compactMap { tableAlias, column, alias in
            guard let column else { return nil }
            return "\(tableAlias).\(SQLiteDatabase.quote(column)) AS \(SQLiteDatabase.quote(alias))"
        }

        let orderColumn = schema.memberOrder.map {
            "m.\(SQLiteDatabase.quote($0))"
        } ?? "a.\(SQLiteDatabase.quote(schema.assetTitle ?? schema.assetID))"

        return """
        SELECT \(selects.joined(separator: ",\n          "))
        FROM \(SQLiteDatabase.quote(schema.collectionTable)) c
        LEFT JOIN \(SQLiteDatabase.quote(schema.memberTable)) m
          ON m.\(SQLiteDatabase.quote(schema.memberCollectionID)) = c.\(SQLiteDatabase.quote(schema.collectionID))
        LEFT JOIN \(SQLiteDatabase.quote(schema.assetTable)) a
          ON a.\(SQLiteDatabase.quote(schema.assetID)) = m.\(SQLiteDatabase.quote(schema.memberAssetID))
        WHERE c.\(SQLiteDatabase.quote(schema.collectionTitle)) IS NOT NULL
          AND \(schema.activeCollectionCondition)
        ORDER BY LOWER(c.\(SQLiteDatabase.quote(schema.collectionTitle))), \(orderColumn)
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
