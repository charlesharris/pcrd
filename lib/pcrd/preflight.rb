# frozen_string_literal: true

module Pcrd
  # Runs all pre-migration safety checks and generates the target DDL.
  #
  # Checks are grouped and run top-to-bottom. Connection failures are hard
  # stops (subsequent checks that need a connection are skipped). All table
  # checks run even when earlier tables fail, so the operator sees all
  # problems at once.
  #
  # Returns a Result that includes all check items and a DDL map for display.
  class Preflight
    # Individual check result.
    Item = Data.define(:status, :label, :detail)
    # status: :pass | :fail | :warn | :info

    # Overall preflight result.
    Result = Data.define(:passed, :items, :ddl_map, :row_counts)
    # ddl_map:    Hash<table_name, String>  — generated CREATE TABLE SQL per table
    # row_counts: Hash<table_name, Integer> — estimated row counts

    HARD_FAIL = :fail  # any :fail in items means Result#passed = false

    def initialize(config, options = {})
      @config  = config
      @options = options
      @items   = []
      @ddl_map = {}
      @row_counts = {}
    end

    def run
      @source_pool = open_pool(@config.source)
      @target_pool = @config.target ? open_pool(@config.target) : nil

      check_source_connection
      check_target_connection
      check_wal_level
      check_replication_slots

      (@config.migrate&.tables || []).each { |t| check_table(t) }

      Result.new(
        passed:     @items.none? { |i| i.status == :fail },
        items:      @items,
        ddl_map:    @ddl_map,
        row_counts: @row_counts
      )
    ensure
      @source_pool&.close
      @target_pool&.close
    end

    private

    # ── connection & server checks ──────────────────────────────────────────

    def check_source_connection
      @source_pool.exec("SELECT 1")
      @source_ok = true
      pass("source connection",
           "#{@config.source.host}:#{@config.source.port}/#{@config.source.database}")
    rescue Connection::Error => e
      @source_ok = false
      fail!("source connection", e.message)
    end

    def check_target_connection
      return info("target connection", "not configured — skipping") unless @target_pool

      @target_pool.exec("SELECT 1")
      @target_ok = true
      pass("target connection",
           "#{@config.target.host}:#{@config.target.port}/#{@config.target.database}")
    rescue Connection::Error => e
      @target_ok = false
      fail!("target connection", e.message)
    end

    def check_wal_level
      return skip("wal_level", "source not reachable") unless @source_ok

      result = @source_pool.exec("SELECT setting FROM pg_settings WHERE name = 'wal_level'")
      level  = result[0]["setting"]

      if level == "logical"
        pass("wal_level", "logical")
      else
        fail!("wal_level",
              "#{level.inspect} — must be 'logical'; " \
              "set wal_level = logical in postgresql.conf and restart PostgreSQL")
      end
    end

    def check_replication_slots
      return skip("replication slots", "source not reachable") unless @source_ok

      max_row   = @source_pool.exec("SELECT setting::int FROM pg_settings WHERE name = 'max_replication_slots'")
      used_row  = @source_pool.exec("SELECT count(*)::int FROM pg_replication_slots")
      max_slots = max_row[0]["setting"].to_i
      used      = used_row[0]["count"].to_i
      free      = max_slots - used
      needed    = (@config.migrate&.tables&.length || 1)

      if free >= needed
        pass("replication slots", "#{used} used / #{max_slots} max  (#{free} free, #{needed} needed)")
      else
        fail!("replication slots",
              "#{used} used / #{max_slots} max — need #{needed} free; " \
              "increase max_replication_slots in postgresql.conf")
      end
    end

    # ── per-table checks ────────────────────────────────────────────────────

    def check_table(table_config)
      return unless @source_ok

      name   = table_config.name
      reader = Schema::Reader.new(@source_pool)

      # 1. Source table exists
      unless reader.table_exists?(name)
        fail!("#{name}: source table", "table '#{name}' not found on source")
        return
      end

      source_cols = reader.read(name)
      row_count   = reader.estimated_row_count(name)
      pk_cols     = reader.primary_key_columns(name)
      @row_counts[name] = row_count

      pass("#{name}: source table", "#{format_count(row_count)} rows")

      # 2. Primary key required
      if pk_cols.empty?
        fail!("#{name}: primary key",
              "no primary key found — pcrd requires a primary key for upsert " \
              "semantics during the backfill/streaming overlap window")
      else
        pass("#{name}: primary key", pk_cols.join(", "))
      end

      # 3. Target table must not exist (unless --force-overwrite)
      check_target_table(name, table_config)

      # 4. All spec columns exist on source
      check_spec_columns_exist(name, table_config, source_cols)

      # 5. All type casts are known + run data validation
      check_type_casts(name, table_config, source_cols)

      # 6. Generate DDL for display
      @ddl_map[name] = Schema::DDL.generate(
        source_columns:      source_cols,
        table_config:        table_config,
        primary_key_columns: pk_cols,
        schema_name:         "public"
      )
    rescue Connection::Error => e
      fail!("#{name}", "database error: #{e.message}")
    end

    def check_target_table(name, _table_config)
      return unless @target_ok

      reader = Schema::Reader.new(@target_pool)
      if reader.table_exists?(name)
        if @options["force-overwrite"] || @options[:"force-overwrite"]
          warn("#{name}: target table", "already exists — will be dropped and recreated (--force-overwrite)")
        else
          fail!("#{name}: target table",
                "table '#{name}' already exists on target; " \
                "pass --force-overwrite to drop and recreate it")
        end
      else
        pass("#{name}: target table", "does not exist — will be created")
      end
    end

    def check_spec_columns_exist(name, table_config, source_cols)
      source_names = source_cols.map(&:name)
      missing = (table_config.columns || {}).keys.map(&:to_s) - source_names
      if missing.any?
        fail!("#{name}: column spec",
              "column(s) in spec not found on source: #{missing.join(', ')}")
      else
        pass("#{name}: column spec", "all spec columns found on source")
      end
    end

    def check_type_casts(name, table_config, source_cols)
      col_index = source_cols.each_with_object({}) { |c, h| h[c.name] = c }
      unknown   = []
      safe_changes = []
      validator = Transform::Validator.new(@source_pool)
      failures  = validator.validate(table_config, source_cols)

      (table_config.columns || {}).each do |src_name, col_spec|
        next if col_spec.drop || col_spec.type.nil?

        src_col = col_index[src_name.to_s]
        next unless src_col

        safety = Transform::TypeMap.cast_safety(src_col.type_name, col_spec.type)

        if safety == :unsupported
          unknown << "#{src_name}: #{src_col.display_type} → #{col_spec.type}"
        else
          label = [col_spec.rename ? "rename" : nil,
                   col_spec.type  ? "#{src_col.display_type} → #{col_spec.type}" : nil,
                   "(#{safety.to_s.tr('_', ' ')})"].compact.join("  ")
          safe_changes << "#{src_name}: #{label}"
        end
      end

      if unknown.any?
        fail!("#{name}: type casts",
              "unsupported type transition(s):\n" +
              unknown.map { "      #{_1}" }.join("\n"))
        return
      end

      if safe_changes.any?
        pass("#{name}: type casts", safe_changes.join("\n" + " " * 6))
      end

      hard_fails = failures.reject(&:warn_only)
      warnings   = failures.select(&:warn_only)

      if hard_fails.any?
        msgs = hard_fails.map do |f|
          "#{f.column_name} (#{f.source_type} → #{f.target_type}): " \
          "#{f.failing_count} row(s) would fail — #{f.description}"
        end
        fail!("#{name}: data validation",
              "#{hard_fails.length} cast(s) failed validation:\n" +
              msgs.map { "      #{_1}" }.join("\n"))
      else
        pass("#{name}: data validation", "all casts validated")
      end

      warnings.each do |w|
        warn("#{name}: #{w.column_name}",
             "#{w.source_type} → #{w.target_type}: #{w.description}")
      end
    end

    # ── helpers ─────────────────────────────────────────────────────────────

    def open_pool(conn_config)
      Connection::Pool.new(conn_config)
    end

    def pass(label, detail = nil)  @items << Item.new(status: :pass, label: label, detail: detail) end
    def fail!(label, detail)       @items << Item.new(status: :fail, label: label, detail: detail) end
    def warn(label, detail)        @items << Item.new(status: :warn, label: label, detail: detail) end
    def info(label, detail = nil)  @items << Item.new(status: :info, label: label, detail: detail) end
    def skip(label, reason)        @items << Item.new(status: :info, label: label, detail: "skipped — #{reason}") end

    def format_count(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end
end
