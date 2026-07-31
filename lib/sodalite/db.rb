# frozen_string_literal: true

require_relative 'db/schema'
require_relative 'db/query'
require_relative 'db/memory'
require_relative 'db/sql'

module Sodalite
  # The database boundary as a theory with models, rather than a bag of lambdas.
  #
  # An application used to perform `:find_user` — a verb it invented, related to
  # nothing, so a handler map was a model of nothing in particular. The signature
  # here is fixed and small instead:
  #
  #   SELECT(query)        -> Relation
  #   INSERT(table, row)   -> key
  #   DELETE(query)        -> count
  #   ATOMICALLY(subtree)  -> Berylx::Ok / Berylx::Err
  #
  # A handler map for those four is a **model of the relational theory over the
  # schema**. `find_user` stops being an effect and goes back to being what it
  # always was: a named arrow, built once and reused. Application verbs remain
  # for the things that really are effects — send mail, charge a card — they just
  # stop being how a service reaches its own data.
  #
  # `Memory` and `Sql` are then two models of one theory rather than a stub and
  # the real thing, which is what `test/db_conformance_test.rb` exists to check.
  module DB
    SELECT = :sodalite_db_select
    INSERT = :sodalite_db_insert
    DELETE = :sodalite_db_delete
    ATOMICALLY = :sodalite_db_atomically

    TAGS = [SELECT, INSERT, DELETE, ATOMICALLY].freeze

    module_function

    def schema(spec)
      Schema.new(spec)
    end

    def fk(target)
      FK.new(target: target)
    end

    def memory(schema, seed = {})
      Memory.new(schema, seed)
    end

    def sql(schema, connection)
      Sql.new(schema, connection)
    end

    # A transaction reads as a combinator and is a Task underneath.
    #
    # `Berylx::EffectTree.compile` is a closed case over six node types, so a
    # seventh cannot be added from outside; but `EffectTree.run` is public, so a
    # handler can run a berylx node under the same map. That is the whole trick,
    # and it costs berylx no changes. Promoting this to a real `Berylx::Atomic`
    # node would touch `compile` and `berylx.spec` — a converter and human-gate
    # change, not something to do because the surface would read slightly nicer.
    def atomically(name, workflow)
      Berylx::Task[name] do |lay, io|
        io.perform(ATOMICALLY, [workflow, lay])
      end
    end

    # Wire a model into a handler map.
    #
    # The transaction handler has to run subtrees under the finished map, which
    # is not known until the map exists — the same knot berylx ties with
    # `real_handlers(effects, subtree)`. Boot-time wiring, done once, then left
    # alone.
    def handlers(model, effects = {}, fixed: true, **)
      map = {}
      base = effects.merge(effects_for(model, map))
      map.replace(fixed ? Effects.fixed(base, **) : Effects.real(base, **))
    end

    def effects_for(model, map)
      {
        SELECT => ->(query) { model.select(query) },
        INSERT => ->(payload) { model.insert(payload[0], payload[1]) },
        DELETE => ->(query) { model.delete(query) },
        ATOMICALLY => lambda { |payload|
          node, focus = payload
          model.atomically { Berylx::EffectTree.run(node, focus, handlers: map) }
        }
      }
    end
  end
end
