import Foundation

enum CollectionFormatter {
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
