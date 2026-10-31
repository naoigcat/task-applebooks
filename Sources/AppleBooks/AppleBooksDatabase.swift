import Foundation
import SQLite3

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
