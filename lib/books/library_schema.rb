# frozen_string_literal: true

require_relative "schema_error"

module Books
  class LibrarySchema
    ATTRIBUTES = %i[
      collection_table collection_id collection_title collection_entity collection_version
      member_table member_pk member_collection_id member_asset_id member_order member_entity member_version
      asset_table asset_id asset_title asset_author asset_sort_author asset_identifier
    ].freeze

    attr_reader(*ATTRIBUTES)

    def self.detect(db)
      new(db).detect
    end

    def initialize(db)
      @db = db
    end

    def detect
      tables = table_names
      @collection_table = find_table(tables, /COLLECTION\z/i, exclude: /MEMBER/i)
      @member_table = find_table(tables, /COLLECTION.*MEMBER/i)
      @asset_table = find_table(tables, /LIBRARYASSET/i)

      @collection_id = required_column(collection_table, /\AZ_PK\z/i)
      @collection_title = first_column(collection_table, /\AZTITLE\z/i, /\AZNAME\z/i)
      @collection_entity = first_column(collection_table, /\AZ_ENT\z/i, required: false)
      @collection_version = first_column(collection_table, /\AZ_OPT\z/i, required: false)
      @member_pk = required_column(member_table, /\AZ_PK\z/i)
      @member_collection_id = first_column(member_table, /\AZCOLLECTION\z/i, /COLLECTION/i)
      @member_asset_id = first_column(member_table, /\AZLIBRARYASSET\z/i, /\AZASSET\z/i, /ASSET/i)
      @member_order = first_column(member_table, /\AZORDER\z/i, /\AZSORTKEY\z/i, /ORDER/i, required: false)
      @member_entity = first_column(member_table, /\AZ_ENT\z/i, required: false)
      @member_version = first_column(member_table, /\AZ_OPT\z/i, required: false)
      @asset_id = required_column(asset_table, /\AZ_PK\z/i)
      @asset_title = first_column(asset_table, /\AZTITLE\z/i, /\AZSORTTITLE\z/i, required: false)
      @asset_author = first_column(asset_table, /\AZAUTHOR\z/i, required: false)
      @asset_sort_author = first_column(asset_table, /\AZSORTAUTHOR\z/i, required: false)
      @asset_identifier = first_column(asset_table, /\AZASSETID\z/i, /\AZBOOKID\z/i, required: false)

      self
    end

    def quote(identifier)
      %("#{identifier.to_s.gsub('"', '""')}")
    end

    private

    def table_names
      @db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map { |row| row["name"] }
    end

    def find_table(tables, pattern, exclude: nil)
      table = tables.find { |name| name.match?(pattern) && !(exclude && name.match?(exclude)) }
      return table if table

      raise SchemaError, "Could not detect the Apple Books table structure: #{pattern.inspect}"
    end

    def required_column(table, *patterns)
      first_column(table, *patterns, required: true)
    end

    def first_column(table, *patterns, required: true)
      columns = @db.table_info(table).map { |column| column["name"] }
      column = patterns.lazy.filter_map { |pattern| columns.find { |name| name.match?(pattern) } }.first
      return column if column || !required

      raise SchemaError, "Required column was not found in #{table}: #{patterns.map(&:inspect).join(', ')}"
    end
  end
end
