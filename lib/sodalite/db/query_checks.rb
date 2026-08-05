# frozen_string_literal: true

module Sodalite
  module DB
    # Everything an arrow can be wrong about, checked when it is built. A query
    # that fails on the one request that happens to exercise it is a query that
    # fails at 3am, so none of these wait until evaluation.
    #
    # The field checks judge against a *table*, not against the carrier. A
    # pullback compares an attribute of the object at the end of a path, and that
    # object is not the carrier; the carrier is only what the table defaults to.
    module QueryChecks
      # `updatable!` is spelled here and half of what it refuses is spelled in
      # `ChangeChecks`, so the dependency is declared rather than left to whoever
      # mixes both into the same object.
      include ChangeChecks

      # Deleting through an arrow means naming rows of the carrier, so the arrow
      # has to *be* a subobject of them. A projection, a fold, a coproduct, and a
      # window each leave that world — their elements are tuples, groups, or a
      # chosen presentation rather than rows — and each model would then name a
      # different set, which for a projection is usually the empty one.
      #
      # A composition does stay inside it, but the rows it names are rows of the
      # codomain rather than of the object the arrow started at. That is almost
      # never what the caller meant, so it is said out loud or it is refused.
      def deletable!(confirm_carrier: nil)
        subobject!(:delete, 'remove', confirm_carrier)
      end

      # An update names rows the same way, so it inherits every refusal above
      # rather than restating it: the two operations differ in what they do to the
      # rows an arrow names, not in which rows an arrow may name.
      #
      # What it adds is the pullback — whose guard cannot be evaluated inside the
      # statement — and the changes themselves, which are judged here so that the
      # models do not each judge them. Both live in `db/change.rb`, beside the
      # vocabulary they are about.
      def updatable!(changes, confirm_carrier: nil)
        subobject!(:update, 'change', confirm_carrier)
        check_no_pullback!
        check_changes!(changes)
        self
      end

      private

      # The shared core. Each caller names its own operation, because a refusal
      # that will not say which operation was refused is a refusal the reader has
      # to guess at from the stack.
      def subobject!(operation, verb, confirm_carrier)
        window = "a window on a #{operation} is not a subobject"
        refuse_subobject!(operation, :select, 'the image is a set of tuples, not of rows') if projection
        refuse_subobject!(operation, :group, 'a fold yields groups, not rows') if grouped?
        refuse_subobject!(operation, :union, 'the coproduct is not an object of the schema') if united?
        refuse_subobject!(operation, :order, window) if ordered?
        refuse_subobject!(operation, :limit, window) if limit_rows
        refuse_subobject!(operation, :offset, window) if offset_rows
        check_operation_carrier!(operation, verb, confirm_carrier)
        self
      end

      def refuse_subobject!(operation, phase, reason)
        raise QueryError, "#{operation} needs a subobject of #{carrier}, and #{phase} is not one — #{reason}"
      end

      def check_operation_carrier!(operation, verb, confirm_carrier)
        return if carrier == root || confirm_carrier&.to_sym == carrier

        raise QueryError,
              "#{operation} over #{root} would #{verb} rows of #{carrier} — " \
              "pass confirm_carrier: #{carrier.inspect} to mean it"
      end

      def check_field!(field, table = carrier)
        return if schema.table(table).field?(field)

        raise QueryError, "#{table} has no field #{field.inspect}"
      end

      # `where(:city, 'tokyo')` leaves the operator implicit and
      # `where(:age, :gte, 18)` spells it out; they are the same operation, so
      # every spelling of it resolves the pair here.
      def comparison(operator_or_value, value)
        value.equal?(NO_OPERAND) ? [:eq, operator_or_value] : [operator_or_value, value]
      end

      def check_comparison!(field, operator, operand, table = carrier)
        raise QueryError, "unknown comparison #{operator.inspect}" unless COMPARISONS.key?(operator)
        raise QueryError, "#{table}.#{field} cannot be compared to nil — use where_null" if operand.nil?

        check_ordered!(field, operator, table) if %i[gt gte lt lte].include?(operator)
        check_complementable!(field, table) if operator == :not
      end

      # An order comparison is a subobject only where the type carries an order.
      def check_ordered!(field, operator, table = carrier)
        return if ORDERED_TYPES.include?(base_type(field, table))

        raise QueryError, "#{table}.#{field} has no order, so #{operator} is not a subobject of it"
      end

      # Over `A + 1` the complement of a subobject is not its SQL negation:
      # `NOT (x = 3)` leaves the rows where x is nothing out of both sides.
      def check_complementable!(field, table = carrier)
        return unless nullable?(field, table)

        raise QueryError,
              "#{table}.#{field} is nullable, so its complement is three-valued — " \
              'eliminate the null first with where_present'
      end

      def check_nullable!(field, operation)
        check_fragment_open!(operation)
        check_field!(field)
        return if nullable?(field)

        raise QueryError, "#{carrier}.#{field} is not nullable, so #{operation} is not a filter"
      end

      # The object a path of morphisms arrives at. Each name has to be a morphism
      # out of the object reached so far, or the path is not a path in C at all —
      # and a pullback along nothing is not a pullback.
      def path_target(paths)
        raise QueryError, 'a pullback needs a morphism to pull back along' if paths.empty?

        paths.reduce(carrier) do |table, fk|
          schema.target_of(table, fk)
        rescue SchemaError
          raise QueryError, "#{table} has no morphism #{fk.inspect} to pull back along"
        end
      end

      def check_unionable!(other)
        raise QueryError, 'a union needs two arrows over the same carrier' unless other.carrier == carrier
        raise QueryError, 'a union of grouped or ordered arrows is not a relation' if
          grouped? || ordered? || other.grouped? || other.ordered?
        return if other.output_fields == output_fields

        raise QueryError,
              "a union needs the same output: #{output_fields.inspect} vs #{other.output_fields.inspect}"
      end

      def check_not_united!(operation)
        return unless united?

        raise QueryError, "#{operation} cannot follow union — the coproduct is not an object of the schema"
      end

      # A foreign key column is an attribute too, once you ask what it holds: the
      # target's key. Reading `attributes` here would judge `posts.author` to
      # have no type at all, so an order comparison on it would be refused for a
      # reason that is not true. `column_type` is the one place that resolves it.
      def nullable?(field, table = carrier)
        declared = schema.table(table).column_type(field)
        declared.is_a?(Symbol) && declared.to_s.end_with?('?')
      end

      def base_type(field, table = carrier)
        declared = schema.table(table).column_type(field)
        declared.is_a?(Symbol) ? declared.to_s.delete_suffix('?').to_sym : nil
      end

      # Ordering happens on what the query outputs, not on what it started from.
      def check_output_field!(field)
        return if output_fields.include?(field.to_sym)

        raise QueryError, "#{field.inspect} is not in the result: #{output_fields.inspect}"
      end

      # The fold consumes the relation, so the fragment is closed once it starts.
      # A subobject of a *grouped* relation is `HAVING`, which is a different
      # operation and is not offered yet rather than being quietly conflated.
      def check_fragment_open!(operation)
        return unless grouped?

        raise QueryError, "#{operation} cannot follow group — the fragment ends where the fold begins"
      end
    end
  end
end
