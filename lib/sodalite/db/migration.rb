# frozen_string_literal: true

require 'digest'

module Sodalite
  module DB
    class MigrationError < StandardError; end

    # A schema change is a functor `F : C -> D` between presentations, and the
    # data migration is what `F` induces on instances. Writing `up` and `down` by
    # hand means writing that pair yourself, where nothing checks they agree.
    #
    # Here a step is declared as data and both directions are *derived*, which
    # makes reversibility a property that can be computed rather than a promise
    # someone typed:
    #
    #   rename          an isomorphism                 reversible
    #   create_table    adds an empty object           reversible
    #   add_attribute   injective (the column is the   reversible
    #                   constant default, so the
    #                   original projects back out)
    #   drop_attribute  a projection, not injective    IRREVERSIBLE
    #   drop_table      forgets an object              IRREVERSIBLE
    #
    # "Irreversible" is not a warning printed after the fact. `History` can say
    # before anything runs that rolling back past step 3 would lose information,
    # because losing information is exactly what a non-injective map does.
    STEP_KINDS = %i[create_table drop_table add_attribute drop_attribute rename_attribute rename_table].freeze

    # The steps whose induced map on instances is injective — a left inverse
    # exists, so nothing is forgotten.
    INJECTIVE_STEPS = %i[create_table add_attribute rename_attribute rename_table].freeze

    Step = Data.define(:kind, :args) do
      def self.[](kind, *args)
        raise MigrationError, "unknown migration step #{kind.inspect}" unless STEP_KINDS.include?(kind)

        new(kind: kind, args: args.freeze)
      end

      def reversible?
        INJECTIVE_STEPS.include?(kind)
      end

      def fingerprint
        Digest::SHA256.hexdigest("#{kind}\x1f#{args.inspect}")[0, 16]
      end

      def to_s
        "#{kind}(#{args.map(&:inspect).join(', ')})"
      end

      # The presentation half of the functor: spec in, spec out, pure.
      def apply(spec)
        table, *rest = args
        case kind
        when :create_table then spec.merge(table => rest[0])
        when :drop_table then spec.except(table)
        when :rename_table then spec.except(table).merge(rest[0] => spec.fetch(table))
        else apply_to_fields(spec, table, rest)
        end
      end

      def apply_to_fields(spec, table, rest)
        case kind
        when :add_attribute then spec.merge(table => spec.fetch(table).merge(rest[0] => rest[1]))
        when :drop_attribute then spec.merge(table => spec.fetch(table).except(rest[0]))
        when :rename_attribute then rename_field(spec, table, rest[0], rest[1])
        end
      end

      # The inverse functor, when the step has one. `default` is what makes
      # `add_attribute` total, and dropping the column is what undoes it.
      def inverse(_spec)
        table, *rest = args
        case kind
        when :create_table then Step[:drop_table, table]
        when :add_attribute then Step[:drop_attribute, table, rest[0]]
        when :rename_attribute then Step[:rename_attribute, table, rest[1], rest[0]]
        when :rename_table then Step[:rename_table, rest[0], table]
        else raise MigrationError, "#{self} forgets information and has no inverse"
        end
      end

      def default
        args[3] if kind == :add_attribute
      end

      private

      def rename_field(spec, table, from, renamed)
        fields = spec.fetch(table).to_h { |field, type| [field == from ? renamed : field, type] }
        spec.merge(table => fields)
      end
    end

    # The ordered composite. A version is how far along it a database has got.
    class History
      attr_reader :steps

      def initialize(steps)
        @steps = steps.map { |step| step.is_a?(Step) ? step : Step[*step] }.freeze
        spec_at(@steps.size) # fail at declaration if the composite does not typecheck
        freeze
      end

      def size
        @steps.size
      end

      def spec_at(version)
        @steps.first(version).reduce({}) { |spec, step| step.apply(spec) }
      end

      def schema_at(version)
        Schema.new(spec_at(version))
      end

      def schema
        schema_at(size)
      end

      # Whether rolling back to `version` would forget anything. Answerable
      # before a single statement runs, because it is a property of the maps.
      def reversible_to?(version)
        @steps.drop(version).all?(&:reversible?)
      end

      def irreversible_steps
        @steps.reject(&:reversible?)
      end

      def fingerprints
        @steps.map(&:fingerprint)
      end
    end
  end
end
