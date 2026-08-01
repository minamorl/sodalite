# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'minitest', '~> 5.0'
gem 'rake', '~> 13.0'
gem 'rubocop', '~> 1.64', require: false
gem 'rubocop-minitest', '~> 0.35', require: false

# The axis is not published yet, so the three siblings come from git. `puma`,
# `rack`, and `zeolite` resolve from rubygems through the gemspec.
gem 'berylx', git: 'https://github.com/minamorl/berylx.git', branch: 'main'
gem 'darkcore', git: 'https://github.com/minamorl/darkcore-ruby.git', branch: 'main'
gem 'zeolite', git: 'https://github.com/minamorl/zeolite.git', branch: 'main'

# The conformance suite needs a second, real model of the relational theory.
# The library itself depends on no driver: `Sodalite::DB.sql` takes anything
# answering `execute(sql, binds) -> rows`.
gem 'sqlite3', '~> 2.0', require: false

# The third model. Sequel is a *backend* here — dialects, identifier quoting,
# pooling — not a second query language, and it stays out of the gemspec for the
# same reason no driver is in it: `DB.sequel` takes a database someone else built.
gem 'sequel', '~> 5.0', require: false
