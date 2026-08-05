# frozen_string_literal: true

module Sodalite
  module DB
    # The statements a migration step turns into. Separate from `SQL` because
    # compiling an arrow and carrying a functor across a database are two jobs,
    # and only one of them is a query.
    module DDL
      # An object seen as its name and nothing else. `SQL.index_name` asks a
      # definition for `name` and reads no other part of it, so this is enough to
      # ask the naming rule what an object's indexes were called under the name it
      # *had*. Reading them there is the point: spelling `index_<table>_on_<field>`
      # a second time here would be a second name, and a drop that names the index
      # by the wrong one is a drop that misses.
      Named = Data.define(:name)

      module_function

      # DDL is derived from the step, not typed out beside it. A step can need
      # more than one statement, so this always answers with a list of
      # `[sql, binds]`.
      #
      # Every identifier goes through `SQL.quote` for the reason the compiler
      # does it: the schema is allowed to name an object `order` and an
      # attribute `group`, and the migration was the one road to a presentation
      # that still spelled it bare — so declaring that schema worked and
      # arriving at it by migrating was a syntax error.
      def ddl(step, schema)
        table, *rest = step.args
        case step.kind
        when :create_table then create_table(schema.table(table))
        when :drop_table then [drop_table(table)]
        when :rename_table then rename_table(schema.table(rest[0]), table)
        when :merge_tables then merge_tables(schema, table, rest[0], rest[1])
        when :split_table then split_table(schema, table, rest[0], rest[1])
        else alter(step, schema, table, rest)
        end
      end

      def alter(step, schema, table, rest)
        case step.kind
        when :add_attribute then add_column(schema, table, rest[0], step.default)
        when :drop_attribute then [["ALTER TABLE #{SQL.quote(table)} DROP COLUMN #{SQL.quote(rest[0])}", []]]
        when :rename_attribute then [rename_column(table, rest[0], rest[1])]
        end
      end

      # An object and the indexes its morphisms ask for are created together,
      # because `Sql#create_tables!` creates them together: a presentation
      # reached by migrating and the same presentation reached by declaring it
      # have to be the same database, and two roads that disagree about the
      # indexes are the ledger and the migration disagreeing about what the
      # schema said.
      #
      # Exactly once, at the step that makes the object. `CREATE INDEX` here has
      # no `IF NOT EXISTS`, so a second emission against one database raises —
      # which is why only a creation emits the set, and why `rename_table`, the one
      # other step that emits it, drops the old names before it does.
      def create_table(definition)
        [[SQL.create_table_statement(definition), []], *SQL.index_statements(definition)]
      end

      # An isomorphism of objects carries the morphisms out of it, so it has to
      # carry the indexes those morphisms asked for. SQLite and Postgres both keep
      # an index across `RENAME TO` under the name it was created with, so the
      # renamed object was left holding `index_posts_on_author` — a name
      # `SQL.index_name` no longer computes for it, which means nothing can find it
      # again and a later `create_table :posts` collides with a name it never
      # emitted.
      #
      # `schema` is the presentation the step lands in, not the one it left:
      # `migrate!` moves the model to the step's shape before carrying it and
      # `rollback!` moves it to the shape the inverse lands in, so the renamed
      # object is what the schema holds and the name it had is only in the step's
      # args. Measured against both paths rather than assumed.
      #
      # Drop and re-create rather than rename: Postgres has `ALTER INDEX ... RENAME
      # TO` and SQLite has nothing, and the pair that both speak is this one. The
      # cost is honest — the index is rebuilt, which a rename would not have paid —
      # and it is the cost of the object keeping the indexes its arrows mean.
      def rename_table(renamed, before)
        old = Named.new(name: before)
        [["ALTER TABLE #{SQL.quote(before)} RENAME TO #{SQL.quote(renamed.name)}", []],
         *renamed.foreign_keys.keys.map { |field| drop_index(SQL.index_name(old, field)) },
         *SQL.index_statements(renamed)]
      end

      def drop_table(table)
        ["DROP TABLE #{SQL.quote(table)}", []]
      end

      def drop_index(name)
        ["DROP INDEX #{SQL.quote(name)}", []]
      end

      def rename_column(table, from, to)
        ["ALTER TABLE #{SQL.quote(table)} RENAME COLUMN #{SQL.quote(from)} TO #{SQL.quote(to)}", []]
      end

      # Σ on instances is `INSERT ... SELECT` per injection, then drop the sides.
      def merge_tables(schema, sources, into, tag)
        target = schema.table(into)
        sources.reduce(create_table(target)) do |statements, source|
          statements + [inject(target, source, tag), drop_table(source)]
        end
      end

      # One injection of the coproduct. The tag is bound rather than written into
      # the text: it names which injection an element came through, and a name is
      # a value like any other.
      def inject(target, source, tag)
        picked = target.fields.map { |field| field == tag ? '?' : SQL.quote(field) }
        ["INSERT INTO #{SQL.quote(target.name)} (#{columns(target.fields)}) " \
         "SELECT #{picked.join(', ')} FROM #{SQL.quote(source)}", [source.to_s]]
      end

      def split_table(schema, table, tag, into)
        statements = into.flat_map do |value, name|
          target = schema.table(name)
          fields = columns(target.fields)
          create_table(target) +
            [["INSERT INTO #{SQL.quote(name)} (#{fields}) SELECT #{fields} " \
              "FROM #{SQL.quote(table)} WHERE #{SQL.quote(tag)} = ?", [value]]]
        end
        statements << drop_table(table)
      end

      def columns(fields)
        fields.map { |field| SQL.quote(field) }.join(', ')
      end

      # `ADD COLUMN` leaves existing rows NULL while the induced map on instances
      # says the column is the constant default, so something has to fill them.
      # That is not free, and the cost was never written down: an `UPDATE` with
      # no `WHERE` rewrites every row under a lock, which on a table large enough
      # to be worth migrating is the whole cost of the migration.
      #
      # So the default is declared in the DDL, where Postgres 11+ and SQLite give
      # existing rows their value by reading the schema instead of by touching
      # the rows. The `UPDATE` stays as the fallback for a backend that does not,
      # narrowed to the rows still missing a value — which makes it a no-op
      # wherever the declaration already worked, and safe to run again wherever a
      # migration was interrupted partway through.
      #
      # What is not fixed: the fallback is still one scan. Cutting it into key
      # ranges would need the emitter to know how many rows there are, and it
      # knows the presentation and nothing about the instance. The one
      # consequence of declaring the default is that the column keeps it
      # afterwards; nothing here reads it, because `insert` writes every field of
      # the row.
      def add_column(schema, table, field, default)
        definition = schema.table(table)
        column = "#{SQL.quote(field)} #{SQL.sql_type(definition.column_type(field))}"
        column += " DEFAULT #{literal(default)}" unless default.nil?
        statements = [["ALTER TABLE #{SQL.quote(table)} ADD COLUMN #{column}", []]]
        statements << backfill(table, field, default) unless default.nil?
        statements + index_for(definition, field)
      end

      def backfill(table, field, default)
        column = SQL.quote(field)
        ["UPDATE #{SQL.quote(table)} SET #{column} = ? WHERE #{column} IS NULL", [default]]
      end

      # A morphism declared later gets the index a morphism declared with the
      # object gets. Only that one: the object's other indexes are already there,
      # and there is no `IF NOT EXISTS` to make a second emission harmless. It is
      # read out of `SQL.index_statements` at the arrow's own position rather
      # than spelled again here, because one statement with two spellings is two
      # statements that can drift.
      def index_for(definition, field)
        position = definition.foreign_keys.keys.index(field)
        position.nil? ? [] : [SQL.index_statements(definition).fetch(position)]
      end

      # A DDL default cannot be a bind parameter on either backend, so this is
      # the one place the emitter writes a value into statement text instead of
      # handing it to the driver. The value is the migration's own declaration
      # and not something a request carried, but it is still rendered by kind and
      # a string's quote still doubled: "this input is trusted" is a claim about
      # today's callers, and the emitter outlives them. A kind with no rendering
      # raises, because interpolating one it has not thought about is how that
      # claim stops being true quietly.
      def literal(value)
        case value
        when Integer, Float, TrueClass, FalseClass then value.to_s
        when String then "'#{value.gsub("'", "''")}'"
        else
          raise MigrationError,
                "#{value.class} has no DDL literal, so #{value.inspect} cannot be a column default"
        end
      end
    end
  end
end
