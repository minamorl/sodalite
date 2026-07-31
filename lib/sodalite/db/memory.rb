# frozen_string_literal: true

module Sodalite
  module DB
    # An instance functor `I : C -> Set`, stored as sets of rows and evaluated by
    # actually computing the composites, subobjects, and images.
    #
    # This is not a stub that returns what a test author decided. It is a model
    # of the same theory the SQL model is a model of, which is what makes the
    # conformance check between them mean something.
    class Memory
      attr_reader :schema

      def initialize(schema, seed = {})
        @schema = schema
        @store = schema.names.to_h { |name| [name, []] }
        seed.each { |table, rows| rows.each { |row| insert(table, row) } }
        @lock = Mutex.new
      end

      # --- the functor laws, checkable ---------------------------------------
      # A dangling foreign key is not a bad row. It is a failure to be a functor:
      # the morphism `posts -> users` has no value at that element.
      def functor?
        violations.empty?
      end

      def violations
        @schema.tables.each_value.flat_map do |table|
          table.foreign_keys.flat_map { |field, target| dangling(table, field, target) }
        end
      end

      def dangling(table, field, target)
        keys = keys_of(target)
        @store[table.name].reject { |row| keys.include?(row[field]) }
                          .map { |row| "#{table.name}.#{field}=#{row[field].inspect} has no #{target}" }
      end

      def keys_of(target)
        key = @schema.table(target).key
        @store[target].to_set { |row| row[key] }
      end

      # --- evaluation ---------------------------------------------------------

      def select(query)
        rows = @store.fetch(query.root).map(&:dup)
        query.steps.each { |step| rows = apply(step, rows) }
        Relation[rows, schema: query.row_schema]
      end

      def insert(table_name, row)
        table = @schema.table(table_name)
        typed = table.row_schema.load(stringify(row))
        raise SchemaError, "#{table_name}: #{typed.violations.join('; ')}" unless typed.ok?

        record = table.fields.to_h { |field| [field, row[field]] }
        @store[table.name] << record
        record[table.key]
      end

      def delete(query)
        doomed = select(query).rows.to_set
        table = @schema.table(query.carrier)
        before = @store[table.name].size
        @store[table.name] = @store[table.name].reject { |row| doomed.include?(row) }
        before - @store[table.name].size
      end

      # --- transactions -------------------------------------------------------
      # A snapshot is enough here because the store is plain data. Rollback is
      # not an operation the caller asks for; it is what `Err` means to this
      # handler.
      def atomically
        @lock.synchronize do
          snapshot = @store.transform_values { |rows| rows.map(&:dup) }
          result = yield
          @store = snapshot if result.is_a?(Berylx::Err)
          result
        end
      end

      def rows(table_name)
        @store.fetch(table_name.to_sym).map(&:dup)
      end

      private

      def apply(step, rows)
        kind, *rest = step
        case kind
        when :where  then rows.select { |row| row[rest[0]] == rest[1] }
        when :follow then follow(rows, rest[0], rest[1])
        when :select then rows.map { |row| row.slice(*rest[0]) }.uniq
        end
      end

      # Composition, then image: the set of targets actually hit.
      def follow(rows, fk, target)
        wanted = rows.to_set { |row| row[fk] }
        key = @schema.table(target).key
        @store[target].select { |row| wanted.include?(row[key]) }.map(&:dup)
      end

      def stringify(row)
        row.to_h { |field, value| [field.to_s, value] }
      end
    end
  end
end
