# frozen_string_literal: true

require 'securerandom'

module Sodalite
  module DB
    # The shared migration protocol. Backends only store the ledger, carry a
    # step, and provide a lock; every decision about history lives here.
    module Ledger
      def applied
        read_ledger
      end

      def migrate!(history)
        with_lock do
          spec = {}
          seen = read_ledger
          ordered_steps(history).each do |step|
            spec = step.apply(spec)
            next if seen.key?(step.fingerprint)

            @schema = Schema.new(spec)
            carry(step)
            record_step(step)
          end
        end
        self
      end

      def rollback!(history, to:)
        with_lock do
          steps = ordered_steps(history)
          ensure_reversible!(steps.drop(to))
          specs = specifications(steps)
          rollback_steps(steps, specs, read_ledger, to)
          @schema = Schema.new(specs[to])
        end
        self
      end

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

          @schema = Schema.new(specs[index])
          carry(step.inverse(specs[index]))
          forget_step(step)
        end
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

      def with_lock
        # The migration runner is outside request paths, so OS randomness is an allowed effect here.
        token = SecureRandom.hex(8)
        unless claim_lock(token)
          raise MigrationError,
                'another migration is running; a crashed migration runner may have left the lock behind'
        end

        begin
          yield
        ensure
          release_lock(token)
        end
      end
    end
  end
end
