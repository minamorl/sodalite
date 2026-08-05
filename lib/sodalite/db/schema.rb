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
      # The key is `id` by construction, not by choice: `Schema` builds every
      # object the same way, so a configurable key would have to be threaded
      # through `Schema` — and through everything that spells a join from it —
      # before it meant anything.
      KEY = :id

      attr_reader :name, :attributes, :foreign_keys, :key, :row_schema, :fields

      # `foreign_key_types` is what the schema worked out for the morphisms out
      # of this object: the type of the target's key, which no single object of
      # the category knows on its own.
      def initialize(name, spec, foreign_key_types:)
        @name = name.to_sym
        @foreign_keys = morphisms(spec)
        @attributes = leaves(spec)
        @key = KEY
        raise SchemaError, "#{@name} has no key #{@key.inspect}" unless @attributes.key?(@key)

        @column_types = column_types(spec, foreign_key_types)
        @fields = (@attributes.keys + @foreign_keys.keys).freeze
        @row_schema = Zeolite.schema(@column_types).named(name.to_s.capitalize)
        freeze
      end

      def field?(field)
        @fields.include?(field.to_sym)
      end

      # The declared leaf type for an attribute, the target's key type for a
      # foreign key. Everything that has to name a column's type reads this one
      # accessor, so a foreign key cannot be called an integer in the DDL and
      # something else in the row schema — which validates against it.
      def column_type(field)
        @column_types[field.to_sym]
      end

      # A foreign key column carries the target's key, so its type is the
      # target's key type. The schema resolves that when it wires the tables up
      # and hands the answer back in.
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

      # Every column's type in declaration order, which is both what a row is
      # typed by and what `column_type` answers — one table, so the two cannot
      # come apart.
      def column_types(spec, foreign_key_types)
        spec.to_h do |field, type|
          [field.to_sym, type.is_a?(FK) ? foreign_key_types.fetch(field.to_sym) : type]
        end.freeze
      end
      private :column_types
    end

    # The schema category, finitely presented: objects are tables, morphisms are
    # foreign keys, and the one path equation enforced here is referential
    # integrity — which is not a rule about rows but the condition for an
    # instance to be a functor at all.
    class Schema
      attr_reader :tables

      # Wiring the objects together is where a foreign key column gets its type:
      # it carries the target's key, and only the whole presentation knows what
      # that key is.
      def initialize(spec)
        resolved = resolve(spec)
        @tables = spec.to_h do |name, fields|
          [name.to_sym, Table.new(name, fields, foreign_key_types: resolved.fetch(name.to_sym))]
        end.freeze
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

      # How a model spells a morphism that has no value at an element. Every
      # model reports the same failure, so the sentence is written once rather
      # than once per model, where the copies drift while all claiming to be
      # checking the same law.
      def dangling_message(table_name, field, value, target)
        "#{table_name}.#{field}=#{value.inspect} has no #{target}"
      end

      private

      # Every morphism is resolved across the whole presentation before a single
      # object is built from it. That is what lets one point forward, or at its
      # own object, and it keeps the diagnostic for a broken one from depending
      # on the order the objects happen to be declared in.
      def resolve(spec)
        keys = key_types(spec)
        spec.to_h { |name, fields| [name.to_sym, foreign_key_types(name, fields, keys)] }
      end

      # The key's type is read off the presentation, because the schema needs it
      # before it can build the object that would answer for it. A key declared
      # as a foreign key is not a leaf type, so it counts as absent here for the
      # same reason `Table` refuses it.
      def key_types(spec)
        spec.to_h do |name, fields|
          declared = fields.find { |field, _type| field.to_sym == Table::KEY }&.last
          [name.to_sym, declared.is_a?(FK) ? nil : declared]
        end
      end

      def foreign_key_types(name, fields, keys)
        fields.select { |_field, type| type.is_a?(FK) }
              .to_h { |field, declared| [field.to_sym, key_type(name, field, declared.target, keys)] }
      end

      # A morphism whose type cannot be resolved is a build error rather than a
      # column that quietly claims to hold an integer. The row schema validates
      # against this type, so getting it wrong is a hole in the boundary, not a
      # cosmetic mismatch with the DDL.
      def key_type(name, field, target, keys)
        arrow = "#{name.to_sym}.#{field.to_sym}"
        target = target.to_sym
        raise SchemaError, "#{arrow} points at unknown table #{target.inspect}" unless keys.key?(target)

        declared = keys.fetch(target)
        return declared if declared

        raise SchemaError, "#{arrow} points at #{target}, which has no key #{Table::KEY.inspect}"
      end
    end
  end
end
