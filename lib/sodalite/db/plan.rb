# frozen_string_literal: true

module Sodalite
  module DB
    # Ordering is computed from the names each presentation morphism consumes
    # and emits; declaration order is not part of the migration's meaning.
    class Plan
      attr_reader :layers, :order

      def initialize(steps, presentations)
        check_duplicate_steps!(steps)
        @facts = steps.to_h do |step|
          spec = presentations.fetch(step)
          [step, [step.requires(spec), step.provides(spec), step.removes(spec)]]
        end
        check_unprovided!
        @layers = solve(steps).freeze
        @order = @layers.flatten.freeze
        freeze
      end

      def width
        layers.map(&:size).max || 0
      end

      def expand_only?
        order.all?(&:expand?)
      end

      def contract_steps
        order.reject(&:expand?)
      end

      private

      def check_duplicate_steps!(steps)
        duplicate = steps.tally.find { |_step, count| count > 1 }&.first
        return unless duplicate

        raise MigrationError, "#{duplicate} and #{duplicate} both provide the same names"
      end

      def solve(steps)
        remaining = steps.dup
        available = initial_names
        [].tap do |result|
          until remaining.empty?
            layer = remaining.select { |step| ready?(step, available) }
            circular!(remaining) if layer.empty?
            check_layer_supplies!(layer, available)
            # Fingerprints are the tie-breaker so two runners reach one order.
            layer.sort_by!(&:fingerprint)
            result << layer.freeze
            layer.each { |step| advance!(available, @facts.fetch(step)) }
            remaining -= layer
          end
        end
      end

      def initial_names
        required = @facts.values.flat_map(&:first).uniq
        supplied = @facts.values.flat_map { |facts| facts[1] }.uniq
        required.reject { |name| supplied.any? { |provider| covers?(provider, name) } }
      end

      def ready?(step, available)
        required, provided, = @facts.fetch(step)
        requirements_met = required.all? { |name| available.any? { |present| covers?(present, name) } }
        names_free = provided.none? { |name| available.any? { |present| covers?(present, name) } }
        requirements_met && names_free
      end

      def check_unprovided!
        removed = @facts.values.flat_map { |facts| facts[2] }
        missing = initial_names.reject { |name| removed.any? { |gone| covers?(gone, name) } }
        return if missing.empty?

        steps = @facts.select { |_step, facts| facts[0].intersect?(missing) }.keys
        raise MigrationError, "requirements #{missing.inspect} are not provided for #{steps.join(', ')}"
      end

      def check_layer_supplies!(layer, available)
        owners = {}
        layer.each do |step|
          @facts.fetch(step)[1].each do |name|
            previous = owners[name]
            raise MigrationError, "#{previous} and #{step} both provide #{name.inspect}" if previous
            raise MigrationError, "#{step} provides existing #{name.inspect}" if available.include?(name)

            owners[name] = step
          end
        end
      end

      def advance!(available, facts)
        _required, provided, removed = facts
        removed.each { |name| available.delete_if { |present| covers?(name, present) } }
        available.concat(provided).uniq!
      end

      def covers?(removed, name)
        wildcard = removed.to_s.end_with?('.*')
        removed == name || (wildcard && name.to_s.start_with?(removed.to_s.delete_suffix('*')))
      end

      def circular!(steps)
        raise MigrationError, "migration dependency cycle: #{steps.join(', ')}"
      end
    end
  end
end
