# Thor Apple Books

This Thor script reads My Collections from the local Apple Books SQLite database and prints each collection's contents to standard output.

## Setup

Ruby 3.1 or later is required. When using mise, this repository uses Ruby 3.4.9 as defined in `mise.toml`.

```sh
bundle install
```

## Usage

```sh
thor books:export
```

By default, the command outputs a readable text format. Specify `--json` to output JSON.

```sh
thor books:export --json
thor books:export --database ~/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/BKLibrary-1-091020131601.sqlite
```

To run the command without `bundle exec`, the `thor` command and the gems listed in the Gemfile must be available from the current Ruby environment. If `thor` is not found after running `bundle install`, install the Thor executable with `gem install thor`.

`export` does not query the Apple Books database directly. It first copies the database to a consistent temporary file that includes the WAL contents, then opens that copy in read-only mode.

## Add to Queue

Adds purchased books that are not in any My Collections collection to a newly created `Queue_yyyymmddHHMMSS` collection. Books that are only in automatic collections such as `Books`, `Downloaded`, `Library`, and `Want to Read` are treated as uncategorized.

```sh
thor books:enqueue_uncategorized
```

Specify `--dry-run` to check only the number of target books before making changes.

```sh
thor books:enqueue_uncategorized --dry-run
```

By default, the database file is backed up before it is updated. The destination `Queue_yyyymmddHHMMSS` collection is created when the command runs.

```sh
thor books:enqueue_uncategorized --no-backup
```

`enqueue_uncategorized` updates the Apple Books database. Run it only when Apple Books-related processes are not writing to the database. Backups are created as SQLite files that include the WAL contents.
