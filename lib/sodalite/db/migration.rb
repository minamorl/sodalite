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

    # The normalisation a fingerprint is taken under, carried inside the digest
    # input rather than beside it. A later change to the rules then produces a
    # visibly different address for every step instead of silently colliding
    # with addresses computed under the old ones.
    FINGERPRINT_SCHEME = 'v1'

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

      # A foreign key is a morphism, so declaring one requires its codomain to
      # already be an object. That holds wherever the declaration appears:
      # without it here, a history could be solved so the arrow is added before
      # the table it points at exists.
      def requires(_spec)
        table, *rest = args
        return rest[0].values.grep(FK).map(&:target).uniq if kind == :create_table
        return table if kind == :merge_tables
        return [attribute(table, rest[0])] if %i[split_table drop_attribute rename_attribute].include?(kind)
        return [table, *fk_target(rest[1])] if kind == :add_attribute

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

      # The content address. `inspect` cannot be the input: it renders a Hash in
      # the order its keys were inserted, so permuting the fields of a
      # `create_table` — a refactor that changes no meaning — would mint a second
      # address for the same step, and a ledger keyed by address would then call
      # an applied step unapplied. `normalise` is the only input, so the address
      # is a function of content and of nothing else.
      def fingerprint
        Digest::SHA256.hexdigest("#{FINGERPRINT_SCHEME}\x1f#{kind}\x1f#{normalise(args)}")[0, 16]
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

      def fk_target(type)
        type.is_a?(FK) ? [type.target] : []
      end

      # Recursive and total. A Hash is an unordered map, so its keys are sorted;
      # an Array is ordered data — `merge_tables` takes a *sequence* of sources,
      # and which one is the first injection is part of what the step says — so
      # its order is kept. A kind nobody anticipated raises rather than falling
      # back to `inspect`, which would put insertion order back into the address
      # somewhere no one is looking.
      def normalise(value)
        case value
        when Hash then normalise_hash(value)
        when Array then "[#{value.map { |element| normalise(element) }.join(',')}]"
        when FK then "fk(#{normalise(value.target)})"
        else normalise_atom(value)
        end
      end

      # Each atom names its kind and its byte length, so `:1`, `'1'` and `1` are
      # three renderings and no separator can be forged from inside a string.
      def normalise_atom(value)
        case value
        when Symbol then tagged('sym', value.to_s)
        when String then tagged('str', value)
        when Integer then tagged('int', value.to_s)
        when Float then tagged('flt', value.to_s)
        # These three carry no payload, so the class name is the whole content.
        when nil, true, false then "lit:#{value.class}"
        else
          raise MigrationError,
                "#{value.class} in #{self} has no fingerprint rendering, so the step has no content " \
                'address; give the normaliser one rather than hashing an inspect string'
        end
      end

      def tagged(tag, text)
        "#{tag}:#{text.bytesize}:#{text}"
      end

      # Keys compare by `to_s` so a Symbol key and a String key sort against each
      # other; their renderings break the tie when they spell the same text,
      # which keeps the order total instead of leaving it to insertion order.
      def normalise_hash(hash)
        pairs = hash.map { |key, value| [key.to_s, normalise(key), normalise(value)] }.sort
        "{#{pairs.map { |_text, key, value| "#{key}=>#{value}" }.join(',')}}"
      end

      def attribute(table, field)
        :"#{table}.#{field}"
      end

      def names_for(table, fields)
        [table, *fields.keys.map { |field| attribute(table, field) }]
      end

      # What a decomposition brings into being: the fibres `into` names, and
      # their attributes. Nothing else — the whole resulting presentation had the
      # step claim every object in the database, the ones other steps make
      # included, so `Plan` read one name as supplied twice and refused to
      # schedule any history holding a split beside another table. The fields
      # come back out of `split`, because "the source's fields minus the tag" is
      # what a fibre *is*, and a second spelling of it here is a second sentence
      # that can drift from the first.
      def split_names(spec)
        table, tag, into = args
        decomposed = split(spec, table, tag, into)
        into.values.map(&:to_sym).uniq.flat_map { |name| names_for(name, decomposed.fetch(name)) }
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

    # The ordered composite. Every fold below walks `plan.order`, the solved
    # order, because that is the only order a migration means: `Plan` exists
    # precisely because the sequence someone typed carries none. `after` in the
    # method names is the unit — a count of steps along that order, the same
    # number line `Ledger#rollback!(to:)` indexes.
    class History
      attr_reader :steps, :plan

      def initialize(steps)
        @steps = steps.map { |step| step.is_a?(Step) ? step : Step[*step] }.freeze
        @plan = Plan.new(@steps, bootstrap_presentations)
        # The composite and the solved order both fail at declaration, never on a request path.
        spec_after(@steps.size)
        freeze
      end

      def size
        @steps.size
      end

      def spec_after(count)
        @plan.order.first(count).reduce({}) { |spec, step| step.apply(spec) }
      end

      def schema_after(count)
        Schema.new(spec_after(count))
      end

      def schema
        schema_after(size)
      end

      # Whether rolling back to `count` would forget anything. Answerable before
      # a single statement runs, because it is a property of the maps.
      def reversible_after?(count)
        @plan.order.drop(count).all?(&:reversible?)
      end

      def irreversible_steps
        @plan.order.reject(&:reversible?)
      end

      def fingerprints
        @plan.order.map(&:fingerprint)
      end

      private

      # `Plan` needs a presentation per step before any order exists, so this one
      # fold has to run in declaration order — it is the bootstrap the solver is
      # computed from, not the public fold, and a step whose declared position
      # has no presentation yet keeps the last one that typechecked.
      def bootstrap_presentations
        before = {}
        @steps.to_h do |step|
          presentation = before
          before = step.apply(before)
          [step, presentation]
        rescue KeyError
          [step, presentation]
        end
      end
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
