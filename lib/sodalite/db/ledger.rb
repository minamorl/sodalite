# frozen_string_literal: true

require 'securerandom'
require 'socket'
require 'time'

module Sodalite
  module DB
    # Who is allowed to act on a history. Separate from `Ledger` because it is a
    # different question — `Ledger` decides what a history *means* — and because
    # the lock is the one piece with an owner and an age.
    #
    # The row carries a token, a holder, and the time it was taken, so a refusal
    # names the runner that is in the way and says how long it has been there,
    # instead of speculating that one crashed.
    module MigrationLock
      # The explicit way to clear a lock a dead runner left behind. Never
      # automatic: a lock that lets go of itself after a timeout is not a lock,
      # and the only thing worse than a stuck migration is two of them.
      #
      # `older_than` is in seconds and has no default, because only the caller
      # knows how long the migration it is about to displace normally takes.
      def steal_lock!(older_than:)
        held = read_lock
        return 'no migration lock is held, so there was nothing to steal' unless held

        age = lock_age(held)
        refuse_young_lock!(held, age, older_than)
        release_lock(held[:token])
        "cleared the migration lock held by #{held[:holder]} since #{held[:acquired_at]} (#{age.round}s)"
      end

      private

      def with_lock
        # The migration runner is outside request paths, so OS randomness is an allowed effect here.
        token = SecureRandom.hex(8)
        raise MigrationError, held_lock_message unless claim_lock(token)

        begin
          yield
        ensure
          release_lock(token)
        end
      end

      # What the row says, rather than the guess about a crashed runner this
      # used to make. A holder and an age are things an operator can act on; a
      # speculation with no way to check it is not.
      def held_lock_message
        held = read_lock
        return 'another migration is running; it let the lock go before this run could read it' unless held

        "another migration is running: #{held[:holder]} has held the lock since #{held[:acquired_at]} " \
          "(#{lock_age(held).round}s); if that runner is gone, clear it with " \
          'steal_lock!(older_than: <seconds>)'
      end

      def refuse_young_lock!(held, age, older_than)
        return if age >= older_than

        raise MigrationError,
              "the migration lock is #{age.round}s old, which is younger than the #{older_than}s asked " \
              "for, so it was left alone; #{held[:holder]} may still be working"
      end

      # A row written before the lock carried a time has no age, and a lock
      # nobody can date is exactly the one an operator has to be able to clear.
      def lock_age(held)
        return Float::INFINITY unless held[:acquired_at]

        Time.now.utc - Time.iso8601(held[:acquired_at])
      end

      # Reading the hostname, the pid, and the clock is an effect, and it is an
      # allowed one here for the same reason `with_lock`'s `SecureRandom` is:
      # the migration runner is outside request paths.
      def lock_holder
        "#{Socket.gethostname}:#{Process.pid}"
      end

      def lock_acquired_at
        Time.now.utc.iso8601
      end
    end

    # What a step would do to rows, asked before it does it — and the sentences
    # for the two answers that mean it must not run.
    #
    # The wording lives here rather than in a model on purpose: three models
    # refusing one step in three wordings would be three refusals, and the point
    # of three models is that they are models of one thing. A model contributes
    # the *reading* — a `SELECT DISTINCT`, a dataset, a walk over a Hash — and
    # nothing else.
    module Preflight
      private

      def refuse_violations!(step)
        violations = preflight_violations(step)
        return if violations.empty?

        raise MigrationError, "#{step} cannot be carried: #{violations.join('; ')}"
      end

      # A `split_table` sends each row to the table its tag names. A tag the
      # decomposition does not list is a row with nowhere to go: the per-fibre
      # `INSERT ... SELECT ... WHERE tag = ?` never picks it up and the closing
      # `DROP TABLE` then takes it. The in-memory model raises `KeyError` at the
      # same row, which is the same fact said less usefully.
      def unlisted_tags(table, tag, into, values)
        values.uniq.reject { |value| into.key?(value) }.sort_by(&:to_s)
              .map { |value| unlisted_tag_violation(table, tag, value, into) }
      end

      # A `merge_tables` is the coproduct, so two sources holding one key make a
      # target with two rows under one key — and under a primary key, one row
      # and a lost one. `holders` is `{ key value => the sources holding it }`;
      # which of those is a collision is one decision, not three.
      def colliding_keys(key, holders)
        holders.select { |_value, sources| sources.uniq.size > 1 }
               .keys.sort_by(&:to_s)
               .map { |value| colliding_key_violation(key, value, holders[value].uniq) }
      end

      def unlisted_tag_violation(table, tag, value, into)
        "#{table}.#{tag} = #{value.inspect} is not one of the decomposition's tags " \
          "(#{into.keys.map(&:inspect).join(', ')}), so those rows have nowhere to go"
      end

      def colliding_key_violation(key, value, sources)
        "#{key} #{value.inspect} is in more than one of #{sources.join(', ')}, " \
          'so the coproduct would have two rows under one key'
      end
    end

    # The shared migration protocol. Backends only store the ledger, carry a
    # step, and provide a lock; every decision about history lives here.
    module Ledger
      include MigrationLock
      include Preflight

      def applied
        read_ledger
      end

      def migrate!(history)
        refuse_untransactional_ddl!(:migrate!)
        with_lock do
          spec = {}
          seen = read_ledger
          ordered_steps(history).each do |step|
            spec = step.apply(spec)
            next if seen.key?(step.fingerprint)

            with_schema(spec) { apply_step(step) }
          end
        end
        self
      end

      def rollback!(history, to:)
        refuse_untransactional_ddl!(:rollback!)
        with_lock do
          steps = ordered_steps(history)
          ensure_reversible!(steps.drop(to))
          specs = specifications(steps)
          rollback_steps(steps, specs, read_ledger, to)
          @schema = Schema.new(specs[to])
        end
        self
      end

      # The ledger is the truth, so this reads the ledger and nothing else. That
      # is the decision, not an omission: what a database *is* has one recorded
      # history, and a boot check that re-derived the shape from the catalog
      # would be a second opinion about it — one that would have to be told
      # which differences are allowed, because a contraction not yet applied is
      # a legal difference and so is an index someone added for a slow morning.
      #
      # What it therefore does not catch, said out loud: a column added by hand,
      # a table dropped by hand, a type widened by hand, a row rewritten by
      # hand. A database can pass this and not have the shape the history
      # describes. `create_tables_for_test!` is the same gap from the other
      # side — a schema built with no history at all — and it is refused here
      # for exactly that reason.
      def verify!(history)
        steps = ordered_steps(history)
        declared = steps.to_h { |step| [step.fingerprint, step] }
        seen = read_ledger
        verify_checkout!(declared, seen)
        verify_expansions!(declared, seen)

        # An unapplied contract step is safe: deploy code that no longer needs
        # the shape first, then contract the database afterwards.
        self
      end

      private

      # One step is one transaction. `carry` runs a list of statements and
      # `record_step` writes the row that says it ran; interrupted between them,
      # the database is changed and the ledger is silent, so the next run
      # carries the step again — `ADD COLUMN` against a column that is already
      # there — and from that point the only way forward is editing the ledger
      # by hand. `merge_tables` is worse: create, insert, drop per source, and
      # an interruption inside it leaves a state with no name.
      #
      # The lock stays outside the scope. `claim_lock` and `release_lock` write
      # rows, and rows written inside would roll back with it — which would
      # release a lock the failed step never let go of.
      #
      # The reading comes before the scope, not inside it: a step that must not
      # run is refused, and a refusal is not a rollback.
      def apply_step(step)
        refuse_violations!(step)
        migration_scope do
          carry(step)
          record_step(step)
        end
      end

      # The inverse is carried under the same scope for the same reason, and
      # read first for the same reason: undoing a `merge_tables` is a
      # `split_table`, which is one of the two steps that can be asked to do
      # something rows do not allow.
      def undo_step(step, inverse)
        refuse_violations!(inverse)
        migration_scope do
          carry(inverse)
          forget_step(step)
        end
      end

      # A model that cannot put DDL in a transaction cannot make a step atomic,
      # and a step that is not atomic is the failure the scope exists to make
      # unreachable. So it refuses instead of running and hoping.
      #
      # There is no override keyword. A refusal that can be waived by an
      # argument is not a refusal, and what the waiver would buy is exactly the
      # hand recovery named here.
      def refuse_untransactional_ddl!(operation)
        return if transactional_ddl?

        raise MigrationError,
              "#{self.class} cannot #{operation}: this database has no transactional DDL, so a step " \
              'would be carried outside a transaction and an interruption could leave the schema ' \
              'changed with nothing in the ledger, which the next run would carry again against a ' \
              'shape that already has it. Apply the steps by hand and insert their fingerprints into ' \
              'the migration ledger, or migrate on a database whose DDL is transactional'
      end

      def ensure_reversible!(steps)
        irreversible = steps.reject(&:reversible?)
        return if irreversible.empty?

        raise MigrationError, "cannot rollback irreversible migrations: #{irreversible.join(', ')}"
      end

      def specifications(steps)
        steps.each_with_object([{}]) { |step, all| all << step.apply(all.last) }
      end

      def rollback_steps(steps, specs, seen, target)
        (steps.length - 1).downto(target) do |index|
          step = steps[index]
          next unless seen.key?(step.fingerprint)

          with_schema(specs[index]) { undo_step(step, step.inverse(specs[index])) }
        end
      end

      # `@schema` moves to the shape the step is carried against, because
      # `carry` and the reading before it are both spelled against it — and it
      # moves back if the step does not hold. A model left describing a shape
      # its storage does not have is the same lie the ledger row exists to
      # prevent, told in memory instead of on disk.
      def with_schema(spec)
        before = @schema
        @schema = Schema.new(spec)
        yield
      rescue StandardError
        @schema = before
        raise
      end

      def verify_checkout!(declared, seen)
        newer = seen.keys - declared.keys
        return if newer.empty?

        raise MigrationError, "this checkout is older than the migration ledger: #{newer.join(', ')}"
      end

      def verify_expansions!(declared, seen)
        missing = declared.reject { |fingerprint, _step| seen.key?(fingerprint) }
                          .values.select(&:expand?)
        return if missing.empty?

        raise MigrationError, "database is missing required migrations: #{missing.join(', ')}"
      end

      # The solved order, not the declaration order. Two branches that each
      # appended a step merge into one set, and the set is what has meaning.
      def ordered_steps(history)
        history.plan.order
      end
    end
  end
end
