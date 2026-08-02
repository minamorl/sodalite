# frozen_string_literal: true

# The one command a deploy runs. Migration is never a side effect of boot: the
# app verifies and refuses to start, one runner applies.
#
#   ruby -Ilib examples/service/migrate.rb              # apply what is pending
#   ruby -Ilib examples/service/migrate.rb plan         # the solved layers
#   ruby -Ilib examples/service/migrate.rb rollback 2   # walk back to two steps
#
# The model here is the in-memory one so the example runs with no database. A
# real deploy hands in `Sodalite::DB.sql(schema, connection)` or
# `Sodalite::DB.sequel(schema, database)` — the same four methods, the same
# ledger, the same lock.

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
else
  model.migrate!(HISTORY)
  puts "applied #{model.applied.size} of #{HISTORY.size} step(s)"
end
