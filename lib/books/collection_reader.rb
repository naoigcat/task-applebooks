# frozen_string_literal: true

require_relative "library_schema"
require_relative "schema_error"

module Books
  class CollectionReader
    IGNORED_COLLECTION_TITLES = ["Books", "Downloaded", "My Samples", "Want to Read", "Library"].freeze

    def initialize(db)
      @db = db
    end

    def collections
      schema = LibrarySchema.detect(@db)
      rows = @db.execute(query(schema))

      rows
        .group_by { |row| row["collection_id"] }
        .values
        .map { |collection_rows| build_collection(collection_rows) }
        .reject { |collection| ignored_collection?(collection) }
        .sort_by { |collection| collection[:title].downcase }
    end

    private

    def ignored_collection?(collection)
      IGNORED_COLLECTION_TITLES.include?(collection[:title])
    end

    def query(schema)
      # Select only existing columns because Apple Books schema details can change across macOS updates.
      optional_selects = {
        "asset_title" => ["a", schema.asset_title],
        "asset_author" => ["a", schema.asset_author],
        "asset_sort_author" => ["a", schema.asset_sort_author],
        "asset_identifier" => ["a", schema.asset_identifier],
        "member_order" => ["m", schema.member_order]
      }.filter_map do |alias_name, (table_alias, column)|
        "#{table_alias}.#{schema.quote(column)} AS #{schema.quote(alias_name)}" if column
      end

      order_column = schema.member_order ? "m.#{schema.quote(schema.member_order)}" : "a.#{schema.quote(schema.asset_title || schema.asset_id)}"

      <<~SQL
        SELECT
          c.#{schema.quote(schema.collection_id)} AS collection_id,
          c.#{schema.quote(schema.collection_title)} AS collection_title,
          a.#{schema.quote(schema.asset_id)} AS asset_pk
          #{optional_selects.empty? ? "" : ",\n          #{optional_selects.join(",\n          ")}"}
        FROM #{schema.quote(schema.collection_table)} c
        INNER JOIN #{schema.quote(schema.member_table)} m
          ON m.#{schema.quote(schema.member_collection_id)} = c.#{schema.quote(schema.collection_id)}
        INNER JOIN #{schema.quote(schema.asset_table)} a
          ON a.#{schema.quote(schema.asset_id)} = m.#{schema.quote(schema.member_asset_id)}
        WHERE c.#{schema.quote(schema.collection_title)} IS NOT NULL
        ORDER BY LOWER(c.#{schema.quote(schema.collection_title)}), #{order_column}
      SQL
    end

    def build_collection(rows)
      {
        id: rows.first["collection_id"],
        title: rows.first["collection_title"],
        books: rows.map do |row|
          {
            title: row["asset_title"],
            author: display_author(row["asset_author"], row["asset_sort_author"]),
            identifier: row["asset_identifier"],
            order: row["member_order"]
          }.compact
        end
      }
    end

    def display_author(author, sort_author)
      return first_author(sort_author) if author.to_s.strip.empty?
      return author unless multiple_authors?(author)

      first_author(sort_author) || first_author(author)
    end

    def multiple_authors?(author)
      author.to_s.match?(/(?:\A|[^[:alpha:]])multiple[[:space:][:punct:]]*authors?(?:\z|[^[:alpha:]])/i)
    end

    def first_author(author)
      author.to_s
            .split(/\s*(?:;|&|\band\b|\/|／|、|，)\s*/i)
            .map(&:strip)
            .find { |name| !name.empty? && !multiple_authors?(name) }
    end
  end
end
