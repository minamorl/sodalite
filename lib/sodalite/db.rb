# frozen_string_literal: true

# `sodalite/db` is an optional layer on the core, and says so by requiring it.
require_relative '../sodalite'

require_relative 'db/address'
require_relative 'db/aggregate'
require_relative 'db/schema'
require_relative 'db/migration'
require_relative 'db/plan'
require_relative 'db/carries'
require_relative 'db/ledger'
require_relative 'db/change'
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
  #   SELECT(query)          -> Relation
  #   INSERT(table, row)     -> key
  #   UPDATE(query, changes) -> count
  #   DELETE(query)          -> count
  #   ATOMICALLY(subtree)    -> Berylx::Ok / Berylx::Err
  #
  # A handler map for those five is a **model of the relational theory over the
  # schema**. `find_user` stops being an effect and goes back to being what it
  # always was: a named arrow, built once and reused. Application verbs remain
  # for the things that really are effects — send mail, charge a card — they just
  # stop being how a service reaches its own data.
  #
  # The behaviour ledger had this signature fixed at four, and it is five now.
  # Said plainly, because widening a fixed signature is the kind of thing that is
  # otherwise done quietly: the four-operation spelling of "change a value" is
  # `SELECT`, `DELETE`, `INSERT` inside `ATOMICALLY`, and that is atomic without
  # being serialisable under READ COMMITTED — two scopes read one row, the first
  # deletes it, the second re-evaluates its guard against a row already gone and
  # then writes a value computed from its stale read. No assignment-only fifth
  # operation would have been safe either, for the same reason. What is safe is a
  # change written as a function of the value it replaces, guarded inside the one
  # statement that applies it, which is what `UPDATE` takes and what `Change` is.
  # The argument is spelled out in `db/change.rb`.
  #
  # `Memory` and `Sql` are then two models of one theory rather than a stub and
  # the real thing, which is what `test/db_conformance_test.rb` exists to check.
  module DB
    SELECT = :sodalite_db_select
    INSERT = :sodalite_db_insert
    UPDATE = :sodalite_db_update
    DELETE = :sodalite_db_delete
    ATOMICALLY = :sodalite_db_atomically

    TAGS = [SELECT, INSERT, UPDATE, DELETE, ATOMICALLY].freeze

    module_function

    # `equations:` are the path equations of the presentation — see `Schema`.
    # None is the free category on the graph of foreign keys, which is exactly
    # what every schema declared before this was, so leaving them off changes
    # nothing.
    #
    # The spec may be written braced or bare, because bare is how every existing
    # schema is spelled and a keyword argument turns a bare trailing hash into
    # keywords. The one name that costs is `equations` itself: an object called
    # that has to be declared inside braces, where it is a table again.
    def schema(spec = nil, equations: [], **tables)
      Schema.new(spec || tables, equations: equations)
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

    # `transactional_ddl:` is forwarded rather than named again: the port is one
    # method and cannot be asked whether its DDL rolls back, so the caller says,
    # and there is one place that decides what the default is.
    def sql(schema, connection, **)
      Sql.new(schema, connection, **)
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
          UPDATE => ->(payload) { model.update(payload[0], payload[1]) },
          DELETE => ->(query) { model.delete(query) },
          ATOMICALLY => ->(payload) { scope(payload, rebuild) }
        }
      end

      private

      # Named rather than inlined so the map above stays one line per operation,
      # which is the signature said in code — and the scope is the one entry that
      # does not fit on a line.
      def scope(payload, rebuild)
        node, focus = payload
        model.atomically { Berylx::EffectTree.run(node, focus, handlers: rebuild.call({})) }
      end
    end

    # Given the history the application was written against, the model is asked
    # at construction whether the database agrees — the same rule the router
    # follows, that a check which can be made at boot is made at boot rather
    # than on the one request that happens to exercise it.
    #
    # It refuses a database missing an expansion this code needs, and passes a
    # database that has not yet had a contraction applied, because that is the
    # normal state between deploying new code and dropping the old shape.
    def capability(model, history: nil)
      model.verify!(history) if history
      Capability.new(model: model)
    end

    # The one-capability shorthand. `Effects.assemble` is the general form.
    def handlers(model, effects = {}, fixed: true, **)
      Effects.assemble(capabilities: [capability(model)], effects: effects,
                       world: fixed ? :fixed : :real, **)
    end
  end
end
