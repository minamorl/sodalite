# frozen_string_literal: true

module Sodalite
  module DB
    # A third model, lowered onto Sequel's dataset algebra instead of onto SQL
    # text.
    #
    # This is not "use Sequel instead". The arrows are the theory — a schema is a
    # category, a query is a morphism in the regular fragment — and Sequel is a
    # backend: dialects, identifier quoting, connection pooling, type conversion.
    # Different layers, so the right move is to lower onto its expression API and
    # leave the meaning of an arrow untouched. Sequel's own `Dataset` chaining is
    # a second query language and is deliberately not exposed; what is used here
    # is the part that knows how to *spell* things for a given database.
    #
    # What that buys over `DB::Sql`, measured rather than assumed: identifiers
    # are quoted (a table called `order` works), `OFFSET` without `LIMIT` is
    # spelled per dialect rather than as SQLite's `LIMIT -1`, and placeholders are
    # the driver's rather than a hard-coded `?`.
    #
    # `DB::Sql` is kept, not replaced. Three models checked against each other is
    # a stronger claim than two, and the hand-written one is the only one that
    # shows what the compilation actually is.
    #
    # Sequel stays out of the runtime dependencies: this takes a `Sequel::Database`
    # someone else built, the same way `DB::Sql` takes anything with `execute`.
    class Sequel
      include SequelDDL
      include SequelArrows

      LEDGER = :sodalite_migrations

      attr_reader :schema

      def initialize(schema, database)
        @schema = schema.is_a?(History) ? schema.schema : schema
        @db = database
      end

      def create_tables!
        @schema.tables.each_value { |table| create_table(table) }
        self
      end

      # --- reading ------------------------------------------------------------

      def select(query)
        rows = dataset(query).all.map { |row| row.transform_keys(&:to_sym) }
        return Listing[rows, schema: query.row_schema] if query.ordered?

        Relation[rows, schema: query.row_schema]
      end

      def insert(table_name, row)
        table = @schema.table(table_name)
        typed = table.row_schema.load(row.to_h { |field, value| [field.to_s, value] })
        raise SchemaError, "#{table_name}: #{typed.violations.join('; ')}" unless typed.ok?

        @db[table.name].insert(table.fields.to_h { |field| [field, row[field]] })
        row[table.key]
      end

      def delete(query)
        doomed = select(query)
        table = @schema.table(query.carrier)
        @db[table.name].where(table.key => doomed.rows.map { |row| row[table.key] }).delete
        doomed.size
      end

      # Same contract as the other two: the caller never asks for a rollback, it
      # is what `Err` means to the scope. `Sequel::Rollback` is how Sequel spells
      # "unwind without raising past me".
      def atomically
        result = nil
        @db.transaction do
          result = yield
          raise ::Sequel::Rollback if result.is_a?(Berylx::Err)
        end
        result
      end

      # --- migration ----------------------------------------------------------

      def migrate!(history)
        ensure_ledger!
        seen = applied
        history.steps.each_with_index do |step, version|
          next check_fingerprint!(step, version, seen) if seen.key?(version)

          @schema = history.schema_at(version + 1)
          carry(step)
          @db[LEDGER].insert(version: version, step: step.to_s, fingerprint: step.fingerprint)
        end
        self
      end

      def applied
        ensure_ledger!
        @db[LEDGER].select_hash(:version, :fingerprint)
      end

      private

      def ensure_ledger!
        return if @db.table_exists?(LEDGER)

        @db.create_table(LEDGER) do
          Integer :version, primary_key: true
          String :step
          String :fingerprint
        end
      end

      def check_fingerprint!(step, version, seen)
        return if seen[version] == step.fingerprint

        raise MigrationError,
              "migration #{version} was applied as #{seen[version]} but now reads #{step.fingerprint}"
      end
    end
  end
end
