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

      # --- the path equations, checkable --------------------------------------
      # A dangling key is a failure to be a functor at all. An equation is a
      # condition on the functor once it is one, and it is the condition SQL
      # cannot hold for you: a foreign key relates a column to a key, never a
      # path to a path, so `employee.manager.department = employee.department`
      # has nowhere to live except the presentation.
      #
      # Reported, not enforced, for the same reason `functor?` is. `insert` does
      # not check it and no `CHECK` is emitted, so an instance can stop
      # satisfying a declared equation between two writes, and this says so when
      # the caller asks.
      #
      # An element where either composite has no image is **not** reported. Some
      # hop had no value, or landed on no row, so neither side is defined there
      # and an equation between two undefined composites says nothing. That
      # element is already reported — by `violations`, because a morphism with
      # no value at an element *is* a dangling foreign key — and saying it twice
      # in two vocabularies would make one broken row look like two independent
      # failures. It is also the reading the other two models get for free: an
      # inner join drops an element with no image, and `<>` over a NULL is
      # UNKNOWN, so all three land on the same set without being talked into it.
      def satisfies_equations?
        equation_violations.empty?
      end

      def equation_violations
        @schema.equations.flat_map { |equation| unequal(equation) }
      end

      def unequal(equation)
        key = @schema.table(equation.from).key
        @store[equation.from].filter_map do |row|
          left = composite(equation.from, equation.left, row)
          right = composite(equation.from, equation.right, row)
          next if left.nil? || right.nil? || left == right

          @schema.equation_message(equation, row[key], left, right)
        end
      end

      # The value of a composite at one element, or nil where it has none.
      #
      # A path of length n is n-1 lookups and then a column read: the last
      # morphism is the value the equation compares, and the ones before it are
      # how the row carrying it is reached. The empty path is the identity, so
      # its value is the element's own key.
      def composite(from, path, row)
        return row[@schema.table(from).key] if path.empty?

        objects = @schema.path_objects(from, path)
        value = row[path.first]
        path.drop(1).each_with_index do |fk, hop|
          element = element_at(objects[hop + 1], value)
          return nil unless element

          value = element[fk]
        end
        value
      end

      def element_at(object, value)
        return nil if value.nil?

        key = @schema.table(object).key
        @store[object].find { |row| row[key] == value }
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

      # `updatable!` comes first for the reason `deletable!` does below. A
      # projection names tuples rather than elements of the carrier, so the
      # lookup below would find no row carrying such a key and answer that zero
      # rows changed — an answer shaped exactly like a fact — or, where the image
      # happened to keep the key, would change rows through an arrow whose value
      # was never a set of them. It refuses two things more than a deletion does:
      # a pullback guard, which cannot be evaluated inside the statement that
      # applies the change, and a change of a field whose type does not carry it.
      #
      # The rows are then found again in the store, by key. What an arrow hands
      # back is a set of *copies* — `phase_one` opens with
      # `@store.fetch(query.root).map(&:dup)`, and has to, because the value of an
      # arrow is a `Relation` rather than a handle on the instance — so writing
      # into what `select` returned would change nothing while answering as
      # though it had. A subobject names elements of the carrier, the key is what
      # names an element, and the key is therefore the way back from the named set
      # to the set itself.
      #
      # Taken under the monitor, so that a change inside `atomically` composes
      # with the snapshot the way `insert` and `delete` do: the scope copied the
      # store on the way in, and this writes into the one it will or will not put
      # back.
      #
      # The count is the size of the subobject in the store, not the number of
      # rows whose value came out different. `add(0)` is the identity on a value
      # and still a change applied to a row, and rows-applied-to is the count the
      # two compiling models can report.
      def update(query, changes, confirm_carrier: nil)
        query.updatable!(changes, confirm_carrier: confirm_carrier)
        ordered = Change.ordered(changes)
        table = @schema.table(query.carrier)
        @lock.synchronize do
          named = select(query).to_set { |row| row[table.key] }
          held = @store[table.name].select { |row| named.include?(row[table.key]) }
          held.each { |row| apply_changes(row, ordered) }
          held.size
        end
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

      def distinct_values(table, field)
        @store.fetch(table).map { |row| row[field] }.uniq
      end

      def key_holders(sources, key)
        sources.each_with_object(Hash.new { |all, value| all[value] = [] }) do |source, holders|
          @store.fetch(source).each { |row| holders[row[key]] << source }
        end
      end

      def stringify(row)
        row.to_h { |field, value| [field.to_s, value] }
      end

      # In the order `Change.ordered` fixed, and into the row itself. Each change
      # reads only the field it writes, so applying them one after another is the
      # same function as applying them at once, which is what a `SET` list is.
      def apply_changes(row, ordered)
        ordered.each { |field, change| row[field] = changed(row[field], change) }
      end

      # `:add` on a `nothing` is `nothing`.
      #
      # A nullable column is a map into `A + 1` and `+ delta` is a function on
      # `A`. Exactly one extension of it to `A + 1` leaves the coproduct alone —
      # `+ delta` on A, the identity on the adjoined point — and the adjoined
      # point is fixed because there is no element there for a delta to be added
      # to. It is the elimination `compare?` already makes for a subobject and
      # `Aggregate#fold` for a monoid, and it is what the other two models compute
      # unaided, since `NULL + 1` is `NULL`. Reading the nothing as zero would be
      # the special case, and it would have to be written into all three: it
      # invents an element of A where the instance recorded none, and it makes
      # `add(0)` a write.
      def changed(value, change)
        return change.operand if change.kind == :set
        return nil if value.nil?

        value + change.operand
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
