# frozen_string_literal: true

# The one command a deploy runs. Migration is never a side effect of boot: the
# app verifies and refuses to start, one runner applies.
#
#   ruby -Ilib examples/service/migrate.rb              # apply what is pending
#   ruby -Ilib examples/service/migrate.rb plan         # the solved layers
#   ruby -Ilib examples/service/migrate.rb rollback 2   # walk back to two steps
#   ruby -Ilib examples/service/migrate.rb steal 900    # clear a lock a dead runner left
#
# The model here is the in-memory one so the example runs with no database. A
# real deploy hands in `Sodalite::DB.sql(schema, connection)` or
# `Sodalite::DB.sequel(schema, database)` — the same protocol, the same ledger,
# the same lock.
#
# One step is one transaction — the DDL and the ledger row commit together or
# neither does — so a backend without transactional DDL is refused rather than
# left to strand a half-applied step. `DB.sql` assumes it has one, which is true
# of SQLite and Postgres; a MySQL deploy declares otherwise and is turned away:
#
#   Sodalite::DB.sql(schema, connection, transactional_ddl: false).migrate!(HISTORY)
#   # => MigrationError: ... cannot migrate!: this database has no transactional DDL

require_relative 'app'

HISTORY = Service::HISTORY
model = Sodalite::DB.memory(HISTORY.schema)

case ARGV.first
when 'plan'
  HISTORY.plan.layers.each_with_index do |layer, depth|
    puts "layer #{depth}: #{layer.join(', ')}"
  end
  puts "expansion-only: #{HISTORY.plan.expand_only?}"
  puts "contractions:   #{HISTORY.plan.contract_steps.join(', ')}" unless HISTORY.plan.expand_only?
when 'rollback'
  target = Integer(ARGV.fetch(1))
  model.migrate!(HISTORY).rollback!(HISTORY, to: target)
  puts "rolled back to #{target}; #{model.applied.size} step(s) still applied"
when 'steal'
  # The lock carries who took it and when, so a runner that died is a fact an
  # operator can read rather than guess at. Clearing it is never automatic — a
  # lock that lets go of itself after a timeout is not a lock — so the age the
  # caller is willing to displace is spelled out, and a younger one is refused.
  puts model.steal_lock!(older_than: Integer(ARGV.fetch(1)))
else
  model.migrate!(HISTORY)
  puts "applied #{model.applied.size} of #{HISTORY.size} step(s)"
end
