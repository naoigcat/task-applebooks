# frozen_string_literal: true

require "sqlite3"
require "thor"

require_relative "collection_reader"
require_relative "database"
require_relative "formatter"
require_relative "queue_updater"
require_relative "schema_error"

module Books
  class CLI < Thor
    namespace "books"

    def self.exit_on_failure?
      true
    end

    desc "export", "Export Apple Books My Collections to standard output"
    option :database, aliases: "-d", type: :string, desc: "BKLibrary SQLite database path"
    option :json, type: :boolean, default: false, desc: "Output as JSON"
    def export
      output = handle_database_errors("read") do
        Database.new(database_path).with_connection do |db|
          collections = CollectionReader.new(db).collections
          raise Thor::Error, "No collections were found." if collections.empty?

          Formatter.new(format: options[:json] ? "json" : "text").format(collections)
        end
      end

      puts output
    end

    desc "enqueue_uncategorized", "Add books that are not in any My Collections to a Queue timestamp collection"
    option :database, aliases: "-d", type: :string, desc: "BKLibrary SQLite database path"
    option :dry_run, type: :boolean, default: false, desc: "Show how many books would be added without changing the database"
    option :backup, type: :boolean, default: true, desc: "Create a database backup before writing"
    def enqueue_uncategorized
      result = handle_database_errors("update") do
        path = database_path
        Database.new(path).with_writable_connection do |db|
          QueueUpdater.new(db, database_path: path).add_uncategorized(
            backup: options[:backup],
            dry_run: options[:dry_run]
          )
        end
      end

      action = options[:dry_run] ? "would be added to" : "added to"
      puts "#{result.book_count} books #{action} #{result.queue_title} collection."
      puts "Backup: #{result.backup_path}" if result.backup_path
    end

    default_task :export

    private

    def database_path
      options[:database] || Database.discover || raise(
        Thor::Error,
        "Apple Books database was not found. Specify BKLibrary*.sqlite with --database."
      )
    end

    def handle_database_errors(action)
      yield
    rescue SQLite3::Exception => e
      raise Thor::Error, "Failed to #{action} SQLite database: #{e.message}"
    rescue SchemaError => e
      raise Thor::Error, e.message
    end
  end
end
