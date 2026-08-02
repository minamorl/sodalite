# frozen_string_literal: true

require 'digest'
require_relative 'plan'

module Sodalite
  # Predicate derivation lives beside the functor it describes.
  # rubocop:disable Metrics/ModuleLength
  module DB
    class MigrationError < KeyError; end

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
    #   merge_tables    Σ_F, the coproduct — the       reversible
    #                   discriminator column is the
    #                   coproduct's injection tag
    #   split_table     the decomposition of that      reversible
    #                   coproduct along the tag
    #
    # `Σ_F` and its inverse are the useful half of Spivak's adjoint triple. The
    # right adjoint `Π_F` — folding two tables into one by a *product* over a
    # shared key — is genuinely not here, and is not relabelled as `split` to
    # look complete.
    #
    # "Irreversible" is not a warning printed after the fact. `History` can say
    # before anything runs that rolling back past step 3 would lose information,
    # because losing information is exactly what a non-injective map does.
    STEP_KINDS = %i[create_table drop_table add_attribute drop_attribute rename_attribute
                    rename_table merge_tables split_table].freeze

    # The steps whose induced map on instances is injective — a left inverse
    # exists, so nothing is forgotten.
    INJECTIVE_STEPS = %i[create_table add_attribute rename_attribute rename_table
                         merge_tables split_table].freeze

    # Injectivity asks whether information survives; expansion asks whether the old presentation embeds.
    EXPAND_STEPS = %i[create_table add_attribute].freeze

    Step = Data.define(:kind, :args) do
      def self.[](kind, *args)
        raise MigrationError, "unknown migration step #{kind.inspect}" unless STEP_KINDS.include?(kind)

        new(kind: kind, args: args.freeze)
      end

      def reversible?
        INJECTIVE_STEPS.include?(kind)
      end

      # This is independent of reversibility: an isomorphic rename still breaks
      # old code, because the old presentation is not included under its names.
      def expand?
        EXPAND_STEPS.include?(kind)
      end

      def requires(_spec)
        table, *rest = args
        return rest[0].values.grep(FK).map(&:target).uniq if kind == :create_table
        return table if kind == :merge_tables
        return [attribute(table, rest[0])] if %i[split_table drop_attribute rename_attribute].include?(kind)

        [table]
      end

      def provides(spec)
        table, *rest = args
        case kind
        when :create_table then names_for(table, rest[0])
        when :rename_table then names_for(rest[0], apply(spec).fetch(rest[0]))
        when :merge_tables then [rest[0], attribute(rest[0], :*)]
        when :split_table then split_names(spec)
        else provided_attribute(table, rest)
        end
      end

      def removes(_spec)
        table, *rest = args
        case kind
        when :drop_attribute, :rename_attribute then [attribute(table, rest[0])]
        when :drop_table, :rename_table, :split_table then [table, attribute(table, :*)]
        when :merge_tables then table.flat_map { |name| [name, attribute(name, :*)] }
        else []
        end
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
        when :merge_tables then merge(spec, table, rest[0], rest[1])
        when :split_table then split(spec, table, rest[0], rest[1])
        else apply_to_fields(spec, table, rest)
        end
      end

      # Σ_F: the coproduct of two objects with the same fields, tagged by which
      # side each element came from. Same fields is not a convenience check —
      # without it the coproduct is not an object of the target schema.
      def merge(spec, sources, into, tag)
        fields = sources.map { |source| spec.fetch(source) }
        unless fields.uniq.size == 1
          raise MigrationError, "#{sources.inspect} do not share a shape, so their coproduct is not a table"
        end

        spec.except(*sources).merge(into => fields.first.merge(tag => :string))
      end

      # The decomposition of that coproduct: each fibre of the tag becomes its
      # own object again, and the tag column goes with it.
      def split(spec, table, tag, into)
        fields = spec.fetch(table).except(tag)
        spec.except(table).merge(into.values.to_h { |name| [name.to_sym, fields] })
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
        raise MigrationError, "#{self} forgets information and has no inverse" unless reversible?

        table, *rest = args
        case kind
        when :create_table then Step[:drop_table, table]
        when :add_attribute then Step[:drop_attribute, table, rest[0]]
        when :rename_attribute then Step[:rename_attribute, table, rest[1], rest[0]]
        else inverse_of_shape(table, rest)
        end
      end

      def inverse_of_shape(table, rest)
        case kind
        when :rename_table then Step[:rename_table, rest[0], table]
        when :merge_tables then Step[:split_table, rest[0], rest[1], table.to_h { |name| [name.to_s, name] }]
        when :split_table then Step[:merge_tables, rest[1].values, table, rest[0]]
        end
      end

      def default
        args[3] if kind == :add_attribute
      end

      private

      def attribute(table, field)
        :"#{table}.#{field}"
      end

      def names_for(table, fields)
        [table, *fields.keys.map { |field| attribute(table, field) }]
      end

      def split_names(spec)
        apply(spec).flat_map { |name, fields| names_for(name, fields) }
      end

      def provided_attribute(table, rest)
        field = kind == :rename_attribute ? rest[1] : rest[0]
        %i[add_attribute rename_attribute].include?(kind) ? [attribute(table, field)] : []
      end

      def rename_field(spec, table, from, renamed)
        fields = spec.fetch(table).to_h { |field, type| [field == from ? renamed : field, type] }
        spec.merge(table => fields)
      end
    end

    # The ordered composite. A version is how far along it a database has got.
    class History
      attr_reader :steps, :plan

      def initialize(steps)
        @steps = steps.map { |step| step.is_a?(Step) ? step : Step[*step] }.freeze
        before = {}
        presentations = @steps.to_h do |step|
          presentation = before
          before = step.apply(before)
          [step, presentation]
        rescue KeyError
          [step, presentation]
        end
        @plan = Plan.new(@steps, presentations)
        # The composite and the solved order both fail at declaration, never on a request path.
        spec_at(@steps.size)
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
  # rubocop:enable Metrics/ModuleLength
end
