# Apple Books CLI

Swift CLI for reading My Collections from the local Apple Books SQLite database and adding uncategorized purchased books to a timestamped queue collection.

## Build

macOS, Swift 6.0 or later, and mise are required.

``` sh
mise run build
```

## Export

The default command outputs readable text. Add --json for JSON output.

``` sh
mise run export
mise run export --json
mise run export --database ~/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/BKLibrary-1-091020131601.sqlite
```

If --database is omitted, the newest BKLibrary*.sqlite file in the supported Apple Books container paths is used. Export first copies the database with VACUUM INTO, so WAL contents are included in a consistent read-only snapshot.

## Add to Queue

Adds purchased books that are not in any My Collections collection to Queue_yyyymmddHHMMSS. Books that are only in automatic collections such as Books, Downloaded, Library, and Want to Read are treated as uncategorized.

``` sh
mise run enqueue
mise run enqueue --dry-run
mise run enqueue --no-backup
```

Backups are created before updates by default. Quit Books before running the update command, and reopen it afterward to reload the collections. Run the update command only when Apple Books-related processes are not writing to the database.

## Source Layout

All executable sources are in `Sources/AppleBooks`:

- `main.swift` and `CLI.swift`: entry point, arguments, command dispatch, and error reporting.
- `SQLite.swift`: SQLite values, statements, identifier quoting, and table metadata.
- `AppleBooksDatabase.swift`: database discovery, snapshots, and connection setup.
- `LibrarySchema.swift`: Apple Books table and column detection.
- `CollectionReader.swift` and `CollectionFormatter.swift`: collection models, queries, and text/JSON output.
- `QueueUpdater.swift`: uncategorized book selection, backups, and transactional queue updates.
