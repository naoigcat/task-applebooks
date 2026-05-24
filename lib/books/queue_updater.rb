# frozen_string_literal: true

require "sqlite3"
require "time"

require_relative "collection_reader"
require_relative "database"
require_relative "library_schema"
require_relative "schema_error"

module Books
  class QueueUpdater
    QUEUE_TITLE = "Queue"
    QUEUE_TITLE_TIMESTAMP_FORMAT = "%Y%m%d%H%M%S"

    Result = Struct.new(:queue_id, :queue_title, :book_count, :backup_path, keyword_init: true)

    def initialize(db, database_path:)
      @db = db
      @database_path = database_path
    end

    def add_uncategorized(backup: true, dry_run: false)
      schema = LibrarySchema.detect(@db)
      queue_title = timestamped_queue_title
      if dry_run
        asset_ids = uncategorized_asset_ids(schema)
        return Result.new(queue_id: nil, queue_title: queue_title, book_count: asset_ids.length, backup_path: nil)
      end

      queue_id, asset_ids, backup_path = add_uncategorized_with_lock(schema, queue_title: queue_title, backup: backup)

      Result.new(queue_id: queue_id, queue_title: queue_title, book_count: asset_ids.length, backup_path: backup_path)
    end

    private

    def add_uncategorized_with_lock(schema, queue_title:, backup:)
      @db.execute("BEGIN IMMEDIATE TRANSACTION")
      asset_ids = uncategorized_asset_ids(schema)
      if asset_ids.empty?
        @db.rollback
        return [nil, [], nil]
      end

      backup_path = backup ? backup_database : nil
      queue_id = create_queue_collection(schema, queue_title)
      insert_members(schema, queue_id, asset_ids)
      @db.commit

      [queue_id, asset_ids, backup_path]
    rescue StandardError
      rollback_transaction
      raise
    end

    def timestamped_queue_title
      "#{QUEUE_TITLE}_#{Time.now.strftime(QUEUE_TITLE_TIMESTAMP_FORMAT)}"
    end

    def create_queue_collection(schema, queue_title)
      validate_queue_collection_does_not_exist(schema, queue_title)
      validate_insertable_collection_columns(schema)

      primary_key = reserve_primary_keys(schema, schema.collection_table, schema.collection_id, 1).first
      attributes = {
        schema.collection_id => primary_key,
        schema.collection_title => queue_title
      }

      if schema.collection_entity
        attributes[schema.collection_entity] = primary_key_entity!(schema.collection_table).fetch("Z_ENT")
      end

      if schema.collection_version
        attributes[schema.collection_version] = 1
      end

      insert_row(schema, schema.collection_table, attributes)

      primary_key
    end

    def validate_queue_collection_does_not_exist(schema, queue_title)
      row = @db.get_first_row(
        <<~SQL,
          SELECT #{schema.quote(schema.collection_id)} AS id
          FROM #{schema.quote(schema.collection_table)}
          WHERE #{schema.quote(schema.collection_title)} = ?
          LIMIT 1
        SQL
        [queue_title]
      )
      return unless row

      raise SchemaError, "#{queue_title} collection already exists. Retry after the next second."
    end

    def uncategorized_asset_ids(schema)
      ignored_titles = CollectionReader::IGNORED_COLLECTION_TITLES
      ignored_placeholders = (["?"] * ignored_titles.length).join(", ")
      title_order = schema.asset_title ? "LOWER(a.#{schema.quote(schema.asset_title)})" : "a.#{schema.quote(schema.asset_id)}"
      related_asset_columns = related_asset_columns(schema)
      related_conditions = related_asset_columns.map do |column|
        <<~SQL
          AND NOT EXISTS (
            #{real_collection_member_query(schema, "a.#{schema.quote(column)}", ignored_placeholders)}
          )
        SQL
      end.join

      sql = <<~SQL
        SELECT a.#{schema.quote(schema.asset_id)} AS id
        FROM #{schema.quote(schema.asset_table)} a
        WHERE NOT EXISTS (
          #{real_collection_member_query(schema, "a.#{schema.quote(schema.asset_id)}", ignored_placeholders)}
        )
        #{related_conditions}
        #{asset_exclusion_conditions(schema)}
        #{purchased_asset_condition(schema)}
        ORDER BY #{title_order}, a.#{schema.quote(schema.asset_id)}
      SQL

      @db.execute(sql, ignored_titles * (related_asset_columns.length + 1)).map { |row| row["id"] }
    end

    def real_collection_member_query(schema, asset_expression, ignored_placeholders)
      <<~SQL
        SELECT 1
        FROM #{schema.quote(schema.member_table)} m
        INNER JOIN #{schema.quote(schema.collection_table)} c
          ON c.#{schema.quote(schema.collection_id)} = m.#{schema.quote(schema.member_collection_id)}
        WHERE m.#{schema.quote(schema.member_asset_id)} = #{asset_expression}
          AND c.#{schema.quote(schema.collection_title)} IS NOT NULL
          AND c.#{schema.quote(schema.collection_title)} NOT IN (#{ignored_placeholders})
      SQL
    end

    def related_asset_columns(schema)
      find_columns(schema.asset_table,
        /\AZSERIESCONTAINER\z/i,
        /\AZPURCHASEDANDLOCALPARENT\z/i,
        /\AZLOCALONLYSERIESITEMSPARENT\z/i
      )
    end

    def asset_exclusion_conditions(schema)
      find_columns(schema.asset_table,
        /\AZISHIDDEN\z/i,
        /\AZISSAMPLE\z/i,
        /\AZISEPHEMERAL\z/i,
        /\AZISSUPPLEMENTALCONTENT\z/i
      ).map { |column| "AND COALESCE(a.#{schema.quote(column)}, 0) = 0" }.join("\n")
    end

    def purchased_asset_condition(schema)
      purchase_columns = find_columns(schema.asset_table,
        /\AZPURCHASEDATE\z/i,
        /\AZCANREDOWNLOAD\z/i
      )
      if purchase_columns.empty?
        raise SchemaError, "Could not detect purchase columns in #{schema.asset_table}."
      end

      conditions = purchase_columns.map do |column|
        case column
        when /\AZCANREDOWNLOAD\z/i
          "COALESCE(a.#{schema.quote(column)}, 0) = 1"
        else
          "a.#{schema.quote(column)} IS NOT NULL"
        end
      end

      "AND (#{conditions.join(' OR ')})"
    end

    def insert_members(schema, queue_id, asset_ids)
      validate_insertable_member_columns(schema)
      primary_keys = reserve_primary_keys(schema, schema.member_table, schema.member_pk, asset_ids.length)
      first_order = next_member_order(schema, queue_id)

      asset_ids.each.with_index do |asset_id, index|
        insert_member(schema, queue_id, asset_id, primary_keys[index], first_order + index)
      end
    end

    def insert_member(schema, queue_id, asset_id, primary_key, order)
      attributes = {
        schema.member_pk => primary_key,
        schema.member_collection_id => queue_id,
        schema.member_asset_id => asset_id
      }

      if schema.member_entity
        attributes[schema.member_entity] = primary_key_entity!(schema.member_table).fetch("Z_ENT")
      end

      if schema.member_version
        # Core Data starts optimistic locking versions at 1 for newly inserted rows.
        attributes[schema.member_version] = 1
      end

      if schema.member_order
        attributes[schema.member_order] = order
      end

      insert_row(schema, schema.member_table, attributes)
    end

    def validate_insertable_member_columns(schema)
      validate_insertable_columns(schema, schema.member_table, [
        schema.member_pk,
        schema.member_collection_id,
        schema.member_asset_id,
        schema.member_entity,
        schema.member_version,
        schema.member_order
      ])
    end

    def validate_insertable_collection_columns(schema)
      validate_insertable_columns(schema, schema.collection_table, [
        schema.collection_id,
        schema.collection_title,
        schema.collection_entity,
        schema.collection_version
      ])
    end

    def validate_insertable_columns(schema, table, provided_columns)
      missing_columns = table_info(table).filter_map do |column|
        next if provided_columns.compact.include?(column["name"])
        next unless column["notnull"].to_i == 1 && column["dflt_value"].nil?

        column["name"]
      end

      return if missing_columns.empty?

      raise SchemaError, "Required columns cannot be populated in #{table}: #{missing_columns.join(', ')}"
    end

    def insert_row(schema, table, attributes)
      columns = attributes.keys
      values = attributes.values
      placeholders = (["?"] * values.length).join(", ")
      quoted_columns = columns.map { |column| schema.quote(column) }.join(", ")

      @db.execute("INSERT INTO #{schema.quote(table)} (#{quoted_columns}) VALUES (#{placeholders})", values)
    end

    def find_columns(table, *patterns)
      columns = table_info(table).map { |column| column["name"] }
      patterns.filter_map { |pattern| columns.find { |name| name.match?(pattern) } }
    end

    def table_info(table)
      @table_info ||= {}
      @table_info[table] ||= @db.table_info(table)
    end

    def rollback_transaction
      @db.rollback
    rescue SQLite3::Exception
      nil
    end

    def reserve_primary_keys(schema, table, primary_key_column, count)
      return [] if count.zero?

      entity = primary_key_entity(table)
      unless entity
        max_pk = @db.get_first_value("SELECT MAX(#{schema.quote(primary_key_column)}) FROM #{schema.quote(table)}").to_i
        return ((max_pk + 1)..(max_pk + count)).to_a
      end

      first_key = entity["Z_MAX"].to_i + 1
      @db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_ENT = ?", [first_key + count - 1, entity["Z_ENT"]])
      (first_key...(first_key + count)).to_a
    end

    def primary_key_entity(table)
      @primary_key_entities ||= {}
      @primary_key_entities[table] ||= begin
        return nil unless primary_key_table?

        rows = @db.execute("SELECT Z_ENT, Z_NAME, Z_MAX FROM Z_PRIMARYKEY")
        rows.find { |row| normalized_entity_name(row["Z_NAME"]) == normalized_table_name(table) }
      end
    end

    def primary_key_entity!(table)
      entity = primary_key_entity(table)
      return entity if entity

      raise SchemaError, "Could not detect the Core Data entity for #{table}."
    end

    def primary_key_table?
      @db.get_first_value("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Z_PRIMARYKEY'")
    end

    def normalized_entity_name(name)
      name.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    def normalized_table_name(table)
      table.to_s.sub(/\Az/i, "").downcase.gsub(/[^a-z0-9]/, "")
    end

    def next_member_order(schema, queue_id)
      return 0 unless schema.member_order

      @db.get_first_value(
        "SELECT MAX(#{schema.quote(schema.member_order)}) FROM #{schema.quote(schema.member_table)} WHERE #{schema.quote(schema.member_collection_id)} = ?",
        [queue_id]
      ).to_i + 1
    end

    def backup_database
      timestamp = Time.now.strftime("%Y%m%d%H%M%S%6N")
      backup_path = "#{@database_path}.#{timestamp}.bak"
      Database.new(@database_path).copy_to(path: backup_path)
      backup_path
    end
  end
end
