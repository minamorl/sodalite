# frozen_string_literal: true

require 'monitor'

module Sodalite
  module DB
    # An instance functor `I : C -> Set`, stored as sets of rows and evaluated by
    # actually computing the composites, subobjects, and images.
    #
    # This is not a stub that returns what a test author decided. It is a model
    # of the same theory the SQL model is a model of, which is what makes the
    # conformance check between them mean something.
    class Memory # rubocop:disable Metrics/ClassLength
      include Carries
      include Evaluates
      include Ledger

      attr_reader :schema

      def initialize(schema, seed = {})
        @applied = schema.is_a?(History) ? schema.steps.to_h { |step| [step.fingerprint, step.to_s] } : {}
        @schema = schema.is_a?(History) ? schema.schema : schema
        @store = @schema.names.to_h { |name| [name, []] }
        seed.each { |table, rows| rows.each { |row| insert(table, row) } }
        # A `Monitor`, not a `Mutex`, because one thread reaches this twice: a
        # scope nests inside a scope, and `Ledger#migrate!` claims the migration
        # lock from inside one. `Mutex` answers a second take with `ThreadError`.
        @lock = Monitor.new
        @depth = 0
        @lock_row = nil
      end

      def read_ledger = @applied.dup

      def record_step(step)
        @applied[step.fingerprint] = step.to_s
        nil
      end

      def forget_step(step)
        @applied.delete(step.fingerprint)
        nil
      end

      # There is no race to lose here — the monitor settles it before the row is
      # written — so this claims by writing the same row the other two models
      # decide from, and answers from it for the same reason they do.
      def claim_lock(token)
        @lock.synchronize do
          next false if @lock_row

          @lock_row = { token: token, holder: lock_holder, acquired_at: lock_acquired_at }
          true
        end
      end

      def read_lock
        @lock.synchronize { @lock_row&.dup }
      end

      def release_lock(token)
        @lock.synchronize { @lock_row = nil if @lock_row&.fetch(:token) == token }
        nil
      end

      # A snapshot is as transactional as this model gets, and here that is the
      # whole of it: there is no DDL, only a Hash of Arrays, and
      # `migration_scope` puts every bit of it back.
      def transactional_ddl? = true

      # A migration step's scope. The snapshot is as deep as `atomically`'s,
      # because a restored store that shared row Hashes with the failed one
      # would carry the failure back in.
      #
      # The applied ledger is snapshotted with the store, and that pairing is
      # the point: a step recorded against rows that were rolled back, or rows
      # kept against a step that was not recorded, is exactly the state this
      # scope exists to make unreachable.
      #
      # It unwinds on a raise rather than on an `Err` result, which is where it
      # parts company with `atomically` — a migration block has no result to
      # speak of, and `atomically`'s asymmetry (a raise leaves this model's
      # writes standing) is fine for a request path and not fine for a step.
      def migration_scope
        @lock.synchronize do
          store = @store.transform_values { |rows| rows.map(&:dup) }
          applied = @applied.dup
          yield
        rescue StandardError
          @store = store
          @applied = applied
          raise
        end
      end

      # Two readings, taken before anything is carried. The sentences are
      # `Preflight`'s, so this model and the other two refuse a step in one
      # wording rather than three — and this is the model that would otherwise
      # answer with a `KeyError` naming the tag it could not place.
      def preflight_violations(step)
        table, *rest = step.args
        case step.kind
        when :split_table then unlisted_tags(table, rest[0], rest[1], tag_values(table, rest[0]))
        when :merge_tables then colliding_keys(key_of(rest[0]), key_holders(table, rest[0]))
        else []
        end
      end

      # --- the functor laws, checkable ---------------------------------------
      # A dangling foreign key is not a bad row. It is a failure to be a functor:
      # the morphism `posts -> users` has no value at that element.
      #
      # This is a **diagnostic, not an invariant**, and that is the decision
      # rather than an omission. `insert` does not check that the target of a
      # foreign key exists, `delete` does not check that nothing points at the
      # row it removes, and the DDL emits no `REFERENCES`. So an instance can
      # stop being a functor between two writes, and this is what says so, when
      # the caller asks. Guarding the writes instead would impose a constraint
      # the schema does not declare, and would turn something an instance *is*
      # into something a model enforces on its behalf.
      def functor?
        violations.empty?
      end

      def violations
        @schema.tables.each_value.flat_map do |table|
          table.foreign_keys.flat_map { |field, target| dangling(table, field, target) }
        end
      end

      # The sentence belongs to the schema, not to the model: three models report
      # the same broken morphism, and three copies of the wording would drift
      # while all three still claimed to be checking one law.
      def dangling(table, field, target)
        keys = keys_of(target)
        @store[table.name].reject { |row| keys.include?(row[field]) }
                          .map { |row| @schema.dangling_message(table.name, field, row[field], target) }
      end

      def keys_of(target)
        key = @schema.table(target).key
        @store[target].to_set { |row| row[key] }
      end

      # --- evaluation ---------------------------------------------------------

      def select(query)
        rows = source(query)
        rows = fold(query, rows) if query.grouped?
        if query.grouped?
          rows = rows.select do |row|
            query.havings.all? do |h|
              compare?(row[h[0]], h[2], h[1])
            end
          end
        end
        return present(query, rows) if query.ordered?

        Relation[rows, schema: query.row_schema]
      end

      # Phase one, including the coproduct: SQL's `UNION` deduplicates, so it is
      # set union, and `Relation` is a set — the two agree without extra work.
      def source(query)
        rows = phase_one(query)
        query.unions.each { |other| rows = (rows + phase_one(other)).uniq }
        rows
      end

      # Phase one is a walk, and the carrier walks with it: composition moves it
      # to the codomain, and a pullback's path starts wherever it currently
      # stands. Nothing in a step records that on its own, so it is carried.
      def phase_one(query)
        rows = @store.fetch(query.root).map(&:dup)
        carrier = query.root
        query.steps.each do |step|
          rows = apply(step, rows, carrier)
          carrier = carrier_after(step, carrier)
        end
        rows
      end

      # A fold along the fibers of the grouping map: partition, then reduce each
      # fibre into its monoid — `Aggregate#fold`, which is also where the `A + 1`
      # of a nullable column is eliminated, so nothing here re-derives it.
      #
      # The merge cannot lose a column: a fold named after a grouping key, or
      # after a fold already taken, is refused when the arrow is built, so there
      # is no key for it to overwrite.
      def fold(query, rows)
        rows.group_by { |row| row.slice(*query.grouping) }
            .map { |key, fibre| key.merge(query.aggregates.to_h { |agg| [agg.name, agg.fold(fibre)] }) }
      end

      # A total order, applied to the set. `<=>` down the ordering keys, with
      # direction flipping the comparison rather than reversing afterwards, so a
      # mixed asc/desc order is one pass.
      def present(query, rows)
        ordered = rows.sort do |left, right|
          query.total_ordering.reduce(0) do |verdict, ordering|
            next verdict unless verdict.zero?

            compare(left[ordering.field], right[ordering.field], ordering.direction)
          end
        end
        ordered = ordered.drop(query.offset_rows) if query.offset_rows
        ordered = ordered.first(query.limit_rows) if query.limit_rows
        Listing[ordered, schema: query.row_schema]
      end

      def compare(left, right, direction)
        verdict = left <=> right
        direction == :desc ? -verdict : verdict
      end

      def insert(table_name, row)
        table = @schema.table(table_name)
        typed = table.row_schema.load(stringify(row))
        raise SchemaError, "#{table_name}: #{typed.violations.join('; ')}" unless typed.ok?

        record = table.fields.to_h { |field| [field, row[field]] }
        @store[table.name] << record
        record[table.key]
      end

      # `deletable!` comes first because everything it refuses would otherwise be
      # answered instead of refused. A projection selects tuples, and a tuple is
      # equal to no row of the carrier, so the rejection below would match
      # nothing and the caller would be told that zero rows went — an answer
      # shaped exactly like a fact.
      #
      # With it in front, only whole rows of the carrier can reach the rejection,
      # so full-row equality here is equality of elements of the very set
      # `select` returned, and the count is measured on the store: how many
      # elements actually left, not how many the arrow named.
      def delete(query, confirm_carrier: nil)
        query.deletable!(confirm_carrier: confirm_carrier)
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
      #
      # `DB.atomically` is a combinator, so being composed — and therefore
      # nested — is its premise, and a nested scope joins the outermost one
      # instead of opening a second. It gets no savepoint of its own: the
      # snapshot is taken once on the way in at depth zero and restored once on
      # the way out, if the *outermost* scope's result is an `Err`. An inner
      # scope runs the block and hands the result back untouched. This is the
      # reading all three models spell identically — `Sql` emits one `BEGIN`,
      # `Sequel` joins its outer transaction — and `Berylx`'s `sequence`
      # short-circuits on the first `Err`, so an inner failure normally *is* the
      # outer failure.
      #
      # The cost, and it is the same cost in all three: recovering from an inner
      # `Err` with a `rescue` combinator commits, because the outermost scope is
      # the only one that decides.
      #
      # `@depth` is a plain ivar, which is safe because it is only read or
      # written with the monitor held and the outermost scope has already put it
      # back to zero when the monitor is released — so a thread that was waiting
      # at the door sees zero and gets its own outermost scope, never half of
      # somebody else's.
      def atomically
        @lock.synchronize do
          outermost = @depth.zero?
          @depth += 1
          snapshot = @store.transform_values { |rows| rows.map(&:dup) } if outermost
          result = yield
          @store = snapshot if outermost && result.is_a?(Berylx::Err)
          result
        ensure
          @depth -= 1
        end
      end

      def rows(table_name)
        @store.fetch(table_name.to_sym).map(&:dup)
      end

      private

      def tag_values(table, tag)
        @store.fetch(table).map { |row| row[tag] }
      end

      def key_holders(sources, into)
        key = key_of(into)
        sources.each_with_object(Hash.new { |all, value| all[value] = [] }) do |source, holders|
          @store.fetch(source).each { |row| holders[row[key]] << source }
        end
      end

      # The sources of a coproduct share a shape, so they share the key the
      # target has — and the target is the one of them the schema still knows
      # about once the step has been applied to the presentation.
      def key_of(into)
        @schema.table(into).key
      end

      def stringify(row)
        row.to_h { |field, value| [field.to_s, value] }
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
