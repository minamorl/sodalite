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

      def initialize(name, spec, key: :id)
        @name = name.to_sym
        @foreign_keys = morphisms(spec)
        @attributes = leaves(spec)
        @key = key.to_sym
        raise SchemaError, "#{@name} has no key #{@key.inspect}" unless @attributes.key?(@key)

        @fields = (@attributes.keys + @foreign_keys.keys).freeze
        @row_schema = Zeolite.schema(row_spec(spec)).named(name.to_s.capitalize)
        freeze
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

      def row_spec(spec)
        spec.to_h do |field, type|
          [field.to_sym, type.is_a?(FK) ? :integer : type]
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

      def initialize(spec)
        @tables = spec.to_h { |name, fields| [name.to_sym, Table.new(name, fields)] }.freeze
        check_targets!
        freeze
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

      def check_targets!
        @tables.each_value do |table|
          table.foreign_keys.each do |field, target|
            next if @tables.key?(target)

            raise SchemaError, "#{table.name}.#{field} points at unknown table #{target.inspect}"
          end
        end
      end
    end
  end
end
