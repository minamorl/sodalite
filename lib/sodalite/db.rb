# frozen_string_literal: true

# `sodalite/db` is an optional layer on the core, and says so by requiring it.
require_relative '../sodalite'

require_relative 'db/aggregate'
require_relative 'db/schema'
require_relative 'db/migration'
require_relative 'db/plan'
require_relative 'db/carries'
require_relative 'db/ledger'
require_relative 'db/query_checks'
require_relative 'db/query_phases'
require_relative 'db/query'
require_relative 'db/relation'
require_relative 'db/evaluates'
require_relative 'db/memory'
require_relative 'db/sql'
require_relative 'db/ddl'
require_relative 'db/sequel_arrows'
require_relative 'db/sequel_ddl'
require_relative 'db/sequel'

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

    # The ordered composite of schema morphisms. Its final schema is a value, so
    # nothing has to be typed twice: `history.schema` is what the models use.
    def history(*steps)
      History.new(steps)
    end

    def memory(schema, seed = {})
      Memory.new(schema, seed)
    end

    def sql(schema, connection)
      Sql.new(schema, connection)
    end

    # A third model, over a `Sequel::Database` someone else built. Sequel is a
    # backend — dialects, quoting, pooling — not a second query language, so
    # arrows are lowered onto its expression API and mean exactly what they meant.
    def sequel(schema, database)
      Sequel.new(schema, database)
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

    # A model, as something an app can be given alongside other capabilities.
    #
    # A transaction does not need anything swapped — the model is stateful, and
    # its snapshot or its `BEGIN` is what the scope is — so it rebuilds the same
    # map and runs the subtree under it.
    Capability = Data.define(:model) do
      def effects(rebuild)
        {
          SELECT => ->(query) { model.select(query) },
          INSERT => ->(payload) { model.insert(payload[0], payload[1]) },
          DELETE => ->(query) { model.delete(query) },
          ATOMICALLY => lambda { |payload|
            node, focus = payload
            model.atomically { Berylx::EffectTree.run(node, focus, handlers: rebuild.call({})) }
          }
        }
      end
    end

    def capability(model)
      Capability.new(model: model)
    end

    # The one-capability shorthand. `Effects.assemble` is the general form.
    def handlers(model, effects = {}, fixed: true, **)
      Effects.assemble(capabilities: [capability(model)], effects: effects,
                       world: fixed ? :fixed : :real, **)
    end
  end
end
