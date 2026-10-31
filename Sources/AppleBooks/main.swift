import Foundation
import Darwin

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
