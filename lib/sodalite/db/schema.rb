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

    # One path equation of the presentation: two composites out of the same
    # object, declared equal.
    #
    # The source is named rather than inferred from the first morphism. Two
    # objects can both carry a `manager`, so an inferred source would be a guess
    # at which one was meant, and a guess in a presentation is a different
    # category.
    #
    # An empty path is **allowed**, and it is the identity: `[:employees,
    # %i[manager], []]` says every employee is their own manager. That is a real
    # constraint, and the composite has a value at every element — the element's
    # own key — so refusing it would be refusing an arrow of the category for
    # being short. Everything downstream reads it that way: the diagnostic
    # compares against the key column, and a rewrite onto an empty side drops
    # the composition entirely, which is exactly what `manager = id` means.
    Equation = Data.define(:from, :left, :right) do
      # A rewrite runs longer -> shorter. Two sides of the same length prove
      # nothing about length, so `Schema#shorter_path` derives nothing from them
      # rather than swapping one for the other forever.
      def longer = left.size >= right.size ? left : right
      def shorter = left.size >= right.size ? right : left
      def shrinking? = left.size != right.size

      def left_name = name(left)
      def right_name = name(right)

      def to_s = "#{from}.#{left_name} = #{from}.#{right_name}"

      private

      # The identity is spelled by the key, because the key is the column a
      # model actually reads for it.
      def name(path) = (path.empty? ? [Table::KEY] : path).join('.')
    end

    # The schema category, finitely presented: objects are tables, morphisms are
    # foreign keys, and `equations` are the path equations — pairs of composites
    # the presentation declares equal.
    #
    # Without them this was the free category on a graph, which is a weaker
    # claim rather than a smaller one: in a free category no two distinct paths
    # are ever equal, so `employee.manager.department = employee.department`
    # could not be said at all. That constraint is not sayable to SQL either —
    # a foreign key relates one column to one key, never one path to another —
    # which is why it belongs to the presentation and not to the DDL.
    #
    # Referential integrity is the condition for an instance to be a functor at
    # all, and `violations` reports it. An equation is a condition on that
    # functor once it exists, and `equation_violations` reports it. Neither is
    # enforced; both are properties an instance has or does not.
    class Schema
      attr_reader :tables, :equations

      # Wiring the objects together is where a foreign key column gets its type:
      # it carries the target's key, and only the whole presentation knows what
      # that key is. The equations are judged after that, because a path is only
      # a path once every morphism in it has a codomain.
      def initialize(spec, equations: [])
        resolved = resolve(spec)
        @tables = spec.to_h do |name, fields|
          [name.to_sym, Table.new(name, fields, foreign_key_types: resolved.fetch(name.to_sym))]
        end.freeze
        @equations = equations.map { |from, left, right| equation!(from, left, right) }.freeze
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

      # And how a model spells an element where a declared equation does not
      # hold. Same reason it lives here: three models compute the two composites
      # three different ways — a walk in Set, a join, a dataset — and one broken
      # element has to come back as one sentence, or the agreement between them
      # is a claim nobody can check by reading it.
      def equation_message(equation, element, left, right)
        "#{equation.from}.#{table(equation.from).key}=#{element.inspect}: " \
          "#{equation.left_name} = #{left.inspect} but #{equation.right_name} = #{right.inspect}"
      end

      # The objects a path visits, `objects[i]` being the domain of `path[i]`.
      # A walk that has to name the row a hop lands on reads it off here rather
      # than re-deriving the chain each time it takes a step.
      def path_objects(from, path)
        path.each_with_object([from.to_sym]) { |fk, visited| visited << target_of(visited.last, fk) }
      end

      # The shortest path the declared equations prove equal to this one.
      #
      # Naive on purpose: only a suffix is matched, only a strictly shorter side
      # is written back, and the answer is fed through again so a chain of
      # equations can collapse more than once. An equation whose sides are the
      # same length is skipped — it proves nothing about length, and rewriting
      # one side onto the other would shrink nothing and could be undone by the
      # same equation forever. That skip is what makes this terminate: every
      # rewrite drops at least one hop.
      def normalise_path(from, path)
        loop do
          shorter = shorter_path(from, path)
          return path unless shorter

          path = shorter
        end
      end

      private

      # A suffix match. The tail of the path is the equation's longer side *and*
      # the object that tail starts at is the object the equation was declared
      # out of — two objects can carry the same morphism name, so the object is
      # half of the match rather than a detail of it.
      def shorter_path(from, path)
        objects = path_objects(from, path)
        equation = @equations.find { |candidate| rewrites?(candidate, objects, path) }
        equation && (path.first(path.size - equation.longer.size) + equation.shorter)
      end

      def rewrites?(equation, objects, path)
        size = equation.longer.size
        equation.shrinking? && size <= path.size &&
          objects[path.size - size] == equation.from && path.last(size) == equation.longer
      end

      # A declared equation is judged the moment it is made, for the same reason
      # a morphism's type is: an equation naming a morphism that does not exist
      # is not a constraint that fails later, it is a sentence about some other
      # category. Every refusal spells both sides, because which of the two is
      # wrong is the whole of what is being reported.
      def equation!(from, left, right)
        equation = Equation.new(from: from.to_sym, left: path!(left), right: path!(right))
        raise SchemaError, "#{equation}: no table #{equation.from.inspect}" unless @tables.key?(equation.from)

        same_codomain!(equation)
        equation
      end

      # Two paths that arrive at different objects are not two spellings of one
      # morphism, so there is no hom-set for them to be equal in.
      def same_codomain!(equation)
        ends = [equation.left, equation.right].map { |path| codomain(equation, path) }
        return if ends.first == ends.last

        raise SchemaError, "#{equation}: #{equation.left_name} arrives at #{ends.first}, " \
                           "#{equation.right_name} at #{ends.last}"
      end

      def path!(path)
        Array(path).map(&:to_sym).freeze
      end

      # The object a path arrives at. Each name has to be a morphism out of the
      # object reached so far, or the path is not a path in this category and
      # the equation is about nothing.
      def codomain(equation, path)
        path.reduce(equation.from) do |object, fk|
          target_of(object, fk)
        rescue SchemaError
          raise SchemaError, "#{equation}: #{object} has no morphism #{fk.inspect}"
        end
      end

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
