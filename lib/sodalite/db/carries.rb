# frozen_string_literal: true

module Sodalite
  module DB
    # The instance half of a migration for the in-memory model: what the functor
    # on presentations induces on the rows.
    module Carries
      # How many offending values a violation spells out. The list is there to
      # name which fibres, or which keys, the coproduct came apart on, and a
      # decomposition written by hand has a handful of either; past this many the
      # reader is looking at a systematic mismatch rather than at one value, and
      # the count says that better than a longer list does.
      VIOLATION_SAMPLE = 5

      # The two sentences a refused step is spelled with, kept beside the check
      # rather than inside a model. Every model refuses the same step for the
      # same reason, and copies of the wording would drift while all of them
      # still claimed to be reporting one failure of the coproduct.
      FIBRES_DO_NOT_COVER =
        'the image of %<table>s.%<tag>s is not contained in the decomposition, which names no fibre ' \
        'for %<values>s: the fibres do not cover %<table>s, so the coproduct cannot be taken apart ' \
        'along that tag'
      COPRODUCT_NOT_DISJOINT =
        'the coproduct of %<sources>s is not disjoint on %<key>s, which repeats at %<keys>s: Σ_F tags ' \
        'which injection an element came through but does not make the keys disjoint, so two elements ' \
        'sharing a key are not two elements of the sum'

      # Mirrors `Step#apply` on the presentation side: the object-level changes
      # here, the field-level ones next door.
      def carry(step)
        table, *rest = step.args
        case step.kind
        when :create_table then @store[table] ||= []
        when :drop_table then @store.delete(table)
        when :rename_table then @store[rest[0]] = @store.delete(table)
        when :merge_tables then merge_rows(table, rest[0], rest[1])
        when :split_table then split_rows(table, rest[0], rest[1])
        else carry_fields(step, table, rest)
        end
      end

      # Whether the instances admit the step at all, asked before anything is
      # carried and read against the presentation the step starts from. The two
      # cases are one failure seen from either side: `split_table` needs the
      # tag's image inside the decomposition, `merge_tables` needs the injections
      # to land on disjoint keys. Neither is repaired by making one model behave
      # like the other — a model that deletes the elements it cannot place and a
      # model that raises halfway through are two different wrong answers to the
      # same input — so the step is refused, identically, before either runs.
      def preflight_violations(step)
        table, *rest = step.args
        case step.kind
        when :split_table then uncovered_fibres(table, rest[0], rest[1])
        when :merge_tables then colliding_keys(table)
        else []
        end
      end

      # A tag value naming no fibre is an element the decomposition has nowhere
      # to put: the fibres are then a proper part of the object rather than a
      # cover of it, so there is no coproduct to take apart along the tag.
      def uncovered_fibres(table, tag, into)
        image = @store.fetch(table, []).map { |row| row[tag] }.uniq
        uncovered = image.reject { |value| into.key?(value) }
        return [] if uncovered.empty?

        [format(FIBRES_DO_NOT_COVER, table: table, tag: tag, values: render_values(uncovered))]
      end

      # `Σ_F` records which injection an element came through; it does not make
      # the keys disjoint. A key carried twice is one key on two elements, and a
      # sum of the sources has no such thing — so the union it would build is not
      # the disjoint one the step claims.
      def colliding_keys(sources)
        collided = sources.flat_map { |source| key_values(source) }
                          .tally.select { |_value, count| count > 1 }.keys
        return [] if collided.empty?

        [format(COPRODUCT_NOT_DISJOINT, sources: sources.inspect, key: @schema.table(sources.first).key,
                                        keys: render_values(collided))]
      end

      def key_values(source)
        key = @schema.table(source).key
        @store.fetch(source, []).map { |row| row[key] }
      end

      # Sorted so the sentence is a function of the offending set and not of the
      # order rows happened to arrive in, and sorted on the rendering because the
      # values of a tag need not be mutually comparable.
      def render_values(values)
        shown = values.sort_by(&:inspect).first(VIOLATION_SAMPLE)
        rendered = shown.map(&:inspect)
        rendered << "...#{values.size - shown.size} more" if values.size > shown.size
        "[#{rendered.join(', ')}]"
      end

      # The coproduct on instances: the disjoint union, with each element
      # carrying the injection it came through. Disjointness is not established
      # here — `preflight_violations` has already established it, which is what
      # lets a concatenation be the sum.
      def merge_rows(sources, into, tag)
        @store[into] = sources.flat_map do |source|
          @store.fetch(source).map { |row| row.merge(tag => source.to_s) }
        end
        sources.each { |source| @store.delete(source) }
      end

      # `into.fetch` cannot raise: `preflight_violations` has already put the
      # image of the tag inside `into`, so every row has a fibre to land in. The
      # guarantee is worth naming here rather than rescuing, because a rescue
      # would hide the one case in which it stopped holding — and it would hide
      # it after the targets above had already been emptied.
      def split_rows(table, tag, into)
        rows = @store.fetch(table)
        into.each_value { |name| @store[name.to_sym] = [] }
        rows.each do |row|
          name = into.fetch(row[tag])
          @store[name.to_sym] << row.except(tag)
        end
        @store.delete(table)
      end

      def carry_fields(step, table, rest)
        case step.kind
        when :add_attribute then each_row(table) { |row| row[rest[0]] = step.default }
        when :drop_attribute then each_row(table) { |row| row.delete(rest[0]) }
        when :rename_attribute then each_row(table) { |row| row[rest[1]] = row.delete(rest[0]) }
        end
      end

      def each_row(table, &)
        @store.fetch(table).each(&)
      end
    end
  end
end
