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

Backups are created before updates by default. Run the update command only when Apple Books-related processes are not writing to the database.
