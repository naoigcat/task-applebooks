# frozen_string_literal: true

require "sqlite3"
require "tempfile"

module Books
  class Database
    BOOKS_CONTAINER_PATTERNS = [
      "~/Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary/BKLibrary*.sqlite",
      "~/Library/Containers/com.apple.BKAgentService/Data/Documents/BKLibrary/BKLibrary*.sqlite",
      "~/Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books/BKLibrary/BKLibrary*.sqlite"
    ].freeze

    attr_reader :path

    def self.discover
      BOOKS_CONTAINER_PATTERNS
        .flat_map { |pattern| Dir.glob(File.expand_path(pattern)) }
        .select { |candidate| File.file?(candidate) }
        .max_by { |candidate| File.mtime(candidate) }
    end

    def initialize(path)
      @path = File.expand_path(path)
    end

    def with_connection
      Tempfile.create(["apple-books-library", ".sqlite"]) do |copy|
        copy.close
        copy_to(path: copy.path)

        db = nil
        db = SQLite3::Database.new(copy.path, readonly: true)
        db.results_as_hash = true
        yield db
      ensure
        db&.close
      end
    end

    def copy_to(path:)
      source = nil
      source = SQLite3::Database.new(@path, readonly: true)
      source.execute("VACUUM INTO ?", [path])
    ensure
      source&.close
    end

    def with_writable_connection
      db = nil
      db = SQLite3::Database.new(path, flags: SQLite3::Constants::Open::READWRITE)
      db.results_as_hash = true
      db.busy_timeout = 5_000
      yield db
    ensure
      db&.close
    end
  end
end
