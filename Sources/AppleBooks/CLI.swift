import Foundation
import Darwin

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
            return try options.json ? CollectionFormatter.json(collections) : CollectionFormatter.text(collections)
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
