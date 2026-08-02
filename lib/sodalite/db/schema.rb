# frozen_string_literal: true

module Sodalite
  module DB
    class SchemaError < StandardError; end

    # A foreign key declaration. In the schema category this is a morphism
    # `posts -> users`; in the stored row it is a column holding the target's key.
    FK = Data.define(:target)

    # One object of the schema category.
    #
    # `attributes` are morphisms into leaf objects (`name : users -> String`) and
    # `foreign_keys` are morphisms between objects (`author : posts -> users`).
    # `row_schema` is an ordinary zeolite schema, which is the whole reason this
    # belongs in sodalite: the type of a row and the type of a response body are
    # the same kind of object, declared in the same vocabulary.
    class Table
      attr_reader :name, :attributes, :foreign_keys, :key, :row_schema, :fields

      # `references` is `{ field => [target, target_key, target_key_type] }`,
      # resolved by the schema once every table's key is known. A table cannot
      # work this out alone, and assuming the codomain is keyed by an integer is
      # how a table keyed by a UUID becomes one nobody can reference.
      def initialize(name, spec, key: :id, references: {})
        @name = name.to_sym
        @foreign_keys = morphisms(spec)
        @attributes = leaves(spec)
        @key = key.to_sym
        raise SchemaError, "#{@name} has no key #{@key.inspect}" unless @attributes.key?(@key)

        @fields = (@attributes.keys + @foreign_keys.keys).freeze
        @references = resolved(references)
        @row_schema = Zeolite.schema(row_spec(spec)).named(name.to_s.capitalize)
        freeze
      end

      # The type of a foreign key column is the type of the key it carries.
      def fk_type(field)
        @references.fetch(field.to_sym)[2]
      end

      # How the constraint spells its codomain: `users(id)`.
      def fk_reference(field)
        target, target_key, = @references.fetch(field.to_sym)
        "#{target}(#{target_key})"
      end

      def field?(field)
        @fields.include?(field.to_sym)
      end

      # A foreign key column carries the target's key, so its type is the
      # target's key type. The schema resolves that when it wires the tables up.
      def morphisms(spec)
        spec.select { |_field, type| type.is_a?(FK) }
            .to_h { |field, declared| [field.to_sym, declared.target.to_sym] }.freeze
      end
      private :morphisms

      def leaves(spec)
        spec.reject { |_field, type| type.is_a?(FK) }
            .to_h { |field, type| [field.to_sym, type] }.freeze
      end
      private :leaves

      # An unresolved foreign key defaults to an integer `id`, which is what a
      # `Table` built outside a schema has to assume.
      def resolved(given)
        @foreign_keys.keys.to_h { |field| [field, given.fetch(field, [nil, :id, :integer])] }.freeze
      end
      private :resolved

      def row_spec(spec)
        spec.to_h do |field, type|
          [field.to_sym, type.is_a?(FK) ? fk_type(field) : type]
        end
      end
      private :row_spec
    end

    # The schema category, finitely presented: objects are tables, morphisms are
    # foreign keys, and the one path equation enforced here is referential
    # integrity — which is not a rule about rows but the condition for an
    # instance to be a functor at all.
    class Schema
      attr_reader :tables

      # Two passes, because a foreign key's type is a fact about the table it
      # points at. The first pass learns every table's key; the second builds the
      # tables again with the codomain of each morphism resolved.
      def initialize(spec)
        draft = spec.to_h { |name, fields| [name.to_sym, Table.new(name, fields)] }
        check_targets!(draft)
        keys = draft.transform_values { |table| [table.key, table.attributes.fetch(table.key)] }
        @tables = spec.to_h do |name, fields|
          [name.to_sym, Table.new(name, fields, references: resolve(draft.fetch(name.to_sym), keys))]
        end.freeze
        freeze
      end

      # The order tables can be created in: a table is created after everything
      # it points at, so an inline `REFERENCES` has something to refer to. A
      # cycle cannot be linearised, so those tables keep declaration order and a
      # strict database will say so — which is more honest than pretending the
      # constraint is not there.
      def creation_order
        placed = []
        remaining = @tables.values
        until remaining.empty?
          ready = remaining.select { |table| satisfied?(table, placed) }
          break if ready.empty?

          placed.concat(ready)
          remaining -= ready
        end
        placed + remaining
      end

      def table(name)
        @tables.fetch(name.to_sym) { raise SchemaError, "no table #{name.inspect}" }
      end

      def names
        @tables.keys
      end

      # Start an arrow at this object.
      def [](name)
        Query.start(self, table(name).name)
      end

      # The codomain of a morphism.
      def target_of(table_name, fk)
        table = table(table_name)
        target = table.foreign_keys[fk.to_sym]
        raise SchemaError, "#{table_name} has no foreign key #{fk.inspect}" unless target

        target
      end

      private

      # A self-reference is satisfiable in place; anything else has to be created
      # first.
      def satisfied?(table, placed)
        names = placed.map(&:name)
        table.foreign_keys.each_value.all? { |target| target == table.name || names.include?(target) }
      end

      def resolve(table, keys)
        table.foreign_keys.to_h do |field, target|
          key, type = keys.fetch(target)
          [field, [target, key, type]]
        end
      end

      def check_targets!(tables)
        tables.each_value do |table|
          table.foreign_keys.each do |field, target|
            next if tables.key?(target)

            raise SchemaError, "#{table.name}.#{field} points at unknown table #{target.inspect}"
          end
        end
      end
    end
  end
end
