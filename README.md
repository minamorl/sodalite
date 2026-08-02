# Sodalite

[![CI](https://github.com/minamorl/sodalite/actions/workflows/ci.yml/badge.svg)](https://github.com/minamorl/sodalite/actions/workflows/ci.yml)
[![Ruby 3.2+](https://img.shields.io/badge/Ruby-3.2%2B-CC342D.svg)](https://www.ruby-lang.org/)

**A web framework where the request is a value, the world is a parameter, and nothing untyped gets in
or out.**

```ruby
require 'sodalite'

load_user = Berylx::Task[:load_user] do |lay, io|
  user = io.perform(:find_user, lay[:request].get.params.id)
  user ? lay[:user].set(user) : lay.reject(:not_found, 'no such user')
end

present = Berylx::Task[:present] do |lay|
  lay[:response].set(Sodalite.ok({ id: lay[:user].get[:id], name: lay[:user].get[:name] }))
end

show_user = Sodalite::Route[
  :get, '/users/:id',
  params:    { id: :integer },
  query:     { loud: :boolean? },
  responses: { 200 => { id: :integer, name: :string } },
  run:       load_user >> present
]

app = Sodalite::App.new(
  routes:   [show_user],
  handlers: Sodalite::Effects.real(find_user: ->(id) { DB.user(id) }),
  errors:   { not_found: 404 }
)
```

```sh
GET /users/7     -> 200 {"id":7,"name":"mina"}
GET /users/9     -> 404 {"error":{"code":"not_found","message":"no such user"},"violations":[]}
GET /users/abc   -> 400 {"error":{"code":"invalid_request",...},
                         "violations":[{"path":"/params/id","code":"type_mismatch",
                                        "message":"expected integer, got string"}]}
```

## Using it

[**The usage guide**](docs/usage.md) walks the work in the order it happens. You do not start a
service by choosing a route template — you start by deciding what the data is, so that is where the
guide starts too.

| I want to... | Start here |
| --- | --- |
| design the tables, and know what is *not* enforced | [Design the schema](docs/usage.md#2-design-the-schema) |
| understand how this relates to a domain model | [How this differs from a domain model](docs/usage.md#3-how-this-differs-from-a-domain-model) |
| write the queries my service asks | [Ask questions of it: arrows](docs/usage.md#5-ask-questions-of-it-arrows) |
| put it behind HTTP | [Declare a route](docs/usage.md#7-declare-a-route) |
| add a column without taking the service down | [Deploy a schema change](docs/usage.md#12-deploy-a-schema-change) |
| test without writing a single mock | [Test](docs/usage.md#14-test) |
| find out why it refused to start | [When it refuses](docs/usage.md#16-when-it-refuses) |

Two things worth knowing before you design anything: every table's key is the attribute named `id`,
and `DB.fk` declares a morphism in *your* schema rather than a `REFERENCES` constraint in the
database. Both are explained where you meet them.

The rest of this README says *why* the framework is shaped this way. The guide says how to work it.

## The stack

Nothing in this column is new. The framework is the wiring, and the wiring is the whole claim: each
of these four already refuses to guess, so a request has nowhere left to be vague.

```
puma        transport: sockets, a thread pool, graceful shutdown
  |  Rack env — a Hash of unknown provenance
zeolite     in:  declared shape -> generated Data, or 400 with every violation
  |  Berylx::Root[request:, response:]
berylx      the route is a composition of named tasks over focused state
  |  io.perform(:find_user, id)
darkcore    every effect is a tagged value; the handler map is the world
  |  Berylx::Ok(lay) / Berylx::Err(partial_lay, error)
zeolite     out: the JSON the client will receive, checked against what the route publishes
  |  Rack triple
puma
```

## The four properties

**1. The request is a value.** The Rack env does not reach your code. A route declares the shape of
its path parameters, query, and body; what a task receives is a frozen `Data` instance with real
readers. A request that does not fit never becomes one — it is a 400 listing *every* violation, each
located by a JSON Pointer that says which part of the request it came from.

**2. The world is a parameter.** Every effect is `io.perform(tag, payload)`, dispatched through the
handler map the app is running under. The same routes, the same router, the same sieve, the same
workflow — with no database, no clock, and no socket:

```ruby
Sodalite::App.new(routes: ROUTES, handlers: Sodalite::Effects.real(find_user: DB.method(:user)))
Sodalite::App.new(routes: ROUTES, handlers: Sodalite::Effects.fixed(find_user: ->(_id) { { id: 7 } }))
```

The framework's own IO goes through the same door — `:sodalite_clock`, `:sodalite_id`,
`:sodalite_log`, `:sodalite_contract` — so there is no `Time.now` and no `SecureRandom` reachable
from a request path except through a handler you supplied. A whole request is reproducible byte for
byte.

**3. Failure keeps its state.** A route is a berylx workflow, so a failure is
`Err(partial_lay, error)`: which named task failed, with what state, and what the earlier steps had
already established. The client sees the status you declared for that code; the log sees the task
name and the trace. An error you did not map is a 500 whose message does not leak.

**4. Cross-cutting is a handler swap.** Build timing, audit, retry, or dry-run with
`Effects.around`, which wraps the interpreter and passes the wrapped map into `parallel`, `branch`,
and `rescue` subtrees. The route is never rewritten to be observed. No `before_action`, no callback
chain to get the order wrong in.

## What it refuses

- **No DSL.** Routes and schemas are Ruby literals. Nothing is `instance_eval`ed, nothing is
  `method_missing`ed, no class is reopened, no file is autoloaded.
- **No global state.** There is no `Sodalite.configure`. The app is an object, it is given what it
  needs at construction, it freezes itself, and the only per-request state is one `Berylx::Root`.
- **No ORM, no views, no assets, no generators.** This is a framework for services with contracts.
- **No implicit type guessing.** Bodies go through the sieve unchanged; path and query take one
  explicit *declared* decode step, because a URL carries no types and JSON does.
- **No durability.** In-process, like berylx. Work that must survive a restart wants a durable engine.
- **No Rails compatibility.** Rack compatibility at the transport edge, and that is the extent of it.

## Ambiguity is a boot error

Every check that can be made when the app is built is made then, because a route that fails on the
one request that happens to exercise it is a route that fails at 3am.

- A template parameter that is not declared, or a declared parameter not in the template.
- Two routes that could answer the same request.
- Two different parameter names in the same position (`/users/:id` and `/users/:slug`).
- A `run:` that berylx cannot compile.
- An effect tag colliding with a framework or berylx tag.

Matching is a segment trie built once and frozen: static beats parameter, and a static prefix that
dead-ends backtracks rather than shadowing a parameter route that would have matched. Segments are
split before they are percent-decoded, so `%2F` is data inside one segment and never invents a path
separator.

## Assembling a service

A service reaches a database *and* an object store *and* whatever verbs it invented. All four go in
one place:

```ruby
app = Sodalite::App.build(
  routes:       ROUTES,
  capabilities: [Sodalite::DB.capability(db), Sodalite::Store.capability(objects)],
  effects:      { send_mail: Mailer.method(:deliver) },
  errors:       { not_found: 404, forbidden: 403 },
  world:        :real
)
```

Swap `world:` and the capabilities, and the same routes run against fixed values with no database, no
clock, and no socket. Scopes survive the swap: a saga rebuilds the map with the store journalled and
still reaches the database; a transaction rolls the database back and leaves the store alone, because
an object store cannot join a transaction and this does not pretend it can.

Liveness and readiness are two questions, so they are two routes. Liveness is framework-level;
readiness is not, because only the service knows what it needs before it should be sent traffic:

```ruby
Sodalite.health
Sodalite.health(path: '/ready', checks: {
  database: ->(io) { io.perform(Sodalite::DB::SELECT, HEARTBEAT) },
  objects:  ->(io) { io.perform(Sodalite::Store::LIST, '') }
})
```

A check that returns falsy or raises is down, and any down check makes the whole answer 503.

## The document is a fold over the routes

Every route already carries its full declared shape as data, so the published contract is derived
rather than maintained:

```ruby
Sodalite::OpenAPI.document(app, title: 'users', version: '1.0')
```

Path templates are rewritten to OpenAPI's spelling, enums publish their closed set, `?` becomes
`nullable` and drops out of `required`, and the statuses the framework itself can produce — 400, 404,
405, and 415/413 where a body is declared — are published too, with the error shape that is actually
sent. It will not invent: a refinement's predicate is a Ruby block with no JSON Schema, so it
publishes its own label in `description` rather than claiming a wider contract than the service
accepts.

## The database is a theory with models

`Sodalite::DB` replaces "the handler map is a bag of lambdas" with a fixed relational signature, so a
handler map becomes a *model* of a theory rather than a model of nothing.

```ruby
SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
)

in_tokyo = SCHEMA[:posts].where(:title, 'hello').follow(:author).where(:city, 'tokyo').select(:name)

busy = SCHEMA[:users].group(:city).count(:people).having(:people, :gt, 1).order(:people, :desc)
adults = SCHEMA[:users].where(:age, :gte, 18).union(SCHEMA[:users].where_null(:age))
```

`where` takes an order comparison wherever the attribute type carries an order, and a complement
wherever the type is a plain set — over a nullable column `NOT (x = 3)` is three-valued, so the
complement is refused there and `where_null` / `where_present` eliminate the `A + 1` explicitly.

A schema is a finitely presented category: tables are objects, foreign keys are morphisms, and an
instance is a functor into `Set` — so a dangling foreign key is not a bad row, it is a failure to be a
functor, and `model.functor?` says so. There is no `join` in the query language: `follow` is
composition, and the join is what the compiler emits.

```
SELECT DISTINCT t1.name FROM posts t0 JOIN users t1 ON t0.author = t1.id
WHERE t0.title = ? AND t1.city = ?
```

Three models, not a stub and the real thing: `DB.memory` (an instance functor into Set), `DB.sql`
(arrows compiled to SQL text, no driver anywhere near it), and `DB.sequel` (the same arrows lowered
onto Sequel's expression API, which knows dialects and quoting). `test/db_conformance_test.rb` drives
fifty arrow shapes through all three and asserts they agree. That is the upgrade: the fixed world no
longer returns what a test author decided, it computes the same query somewhere cheaper — and a bug
would have to occur in three independent lowerings, identically, to survive.

Sequel is a **backend** here, not a second query language: the arrows are the theory, and dialects,
quoting, and pooling are what Sequel is for. It stays out of the runtime dependencies the same way no
driver is in them — `DB.sequel` takes a database someone else built.

A transaction is a combinator whose handler runs the subtree, and rollback is what `Err` means to it:

```ruby
Sodalite::DB.atomically(:checkout, reserve >> charge >> confirm)
```

Nobody asks for the rollback. `berylx` short-circuits at the first `Err`, the scope sees it, and the
failure still carries which named task produced it. [The design note](docs/rdbms.md) works through the
category theory, and section 7 names the five places it does not reach — `NULL`, ordering, aggregation,
isolation levels, and schema migration.

## History and storage

A migration step is a functor, so **reversibility is computed rather than promised**:

```ruby
HISTORY = Sodalite::DB.history(
  [:create_table,     :users, { id: :integer, name: :string }],
  [:add_attribute,    :users, :city, :string, 'unknown'],
  [:rename_attribute, :users, :city, :town]
)

HISTORY.schema              # the composite — nothing is declared twice
HISTORY.reversible_to?(0)   # => true; a drop_attribute would make it false
```

`rename` is an isomorphism, `add_attribute` is injective (the column is the constant default, so the
original projects back out), `drop_attribute` is a projection and forgets. That answer arrives before
a statement runs. Both models carry the history and the conformance suite covers "migrate, then
query".

**The order is solved, not declared.** Each step says what names it requires, provides, and removes,
and those solve into layers — so two branches that each appended a step merge without the index drift
that an ordered ledger turns into a false fingerprint mismatch. The ledger is keyed by the step's
content, and a contradiction (two steps supplying one name, a requirement nobody supplies, a cycle) is
refused at declaration rather than at 3am.

**Expansion is not reversibility.** `rename_attribute` is an isomorphism, so it rolls back perfectly,
and it still breaks every process running the old code — the old presentation is not *included* in the
new one under its own names. Reversibility asks for an inverse; compatibility asks for an inclusion.
Only `create_table` and `add_attribute` are inclusions, which is what makes "is this release
expansion-only?" a computed answer rather than a claim in a pull request. The application is one
explicit command, boot verifies and refuses, and [the procedure](docs/migrations.md#the-procedure)
says who runs what and when.

Object storage gets the same treatment. A bucket is a partial function `Key ⇀ Object` whose keys form
a poset under the prefix order, so `list(prefix)` is that order's principal filter — and there are no
transactions, which the design states rather than hides:

```ruby
Sodalite::Store.saga(:publish, upload >> index >> announce)
```

A write records its inverse; an `Err` replays the inverses backwards. It is lax — compensation cannot
unread — and there is a test asserting that rather than a footnote mentioning it. `Store.memory` and
`Store.filesystem` are conformance-checked against each other; `Store.s3` is the same shape over a
four-method port. [The design note](docs/migrations.md) has the rest.

## Streaming

The sieve reads NDJSON and SSE one record at a time; this writes them the same way, validating each
record as it is emitted.

```ruby
lay[:response].set(
  Sodalite.stream(200, { seq: :integer, kind: Zeolite.enum(:tick, :done) }) do |emit, io|
    io.perform(:subscribe).each { |event| emit.call({ seq: event.seq, kind: event.kind }) }
  end
)
```

## Install

```ruby
gem 'sodalite'
```

Ruby 3.2 or newer, tested through Ruby 4.0. Depends on
[zeolite](https://github.com/minamorl/zeolite), [berylx](https://github.com/minamorl/berylx),
[darkcore](https://github.com/minamorl/darkcore-ruby), rack, and puma. Neither berylx nor darkcore is
published yet, so development takes all three siblings from git.

## Documentation

| Guide | What it covers |
| --- | --- |
| [Using sodalite](docs/usage.md) | The task-indexed guide: routes, requests, effects, the database, schema changes, deploys, tests, and every refusal explained |
| [The design](docs/design.md) | Why each layer is there, the two vocabularies, and what is deliberately not built |
| [History and storage](docs/migrations.md) | Migrations as functors with computed reversibility, and object storage as a partial function with sagas |
| [The RDBMS boundary](docs/rdbms.md) | The database as a theory with models: schemas as categories, queries as arrows, transactions as combinators |
| [`examples/service/`](examples/service) | A complete service: routes, a database, an object store, a saga, health and readiness, `config.ru`, and the OpenAPI document |
| [`examples/minimal.rb`](examples/minimal.rb) | The smallest thing that runs, twice — against a fixed world in process, and on Puma |

```sh
ruby -Ilib examples/service/app.rb          # the whole service, against a fixed world
ruby -Ilib examples/service/app.rb openapi  # its published document, from the routes
ruby -Ilib examples/service/boot.rb         # the same service on puma
ruby -Ilib examples/service/migrate.rb plan # the solved migration layers, before applying any
rackup examples/service/config.ru           # or any Rack server
```

## Why "sodalite"

In mineralogy the **sodalite cage** is the structural unit that zeolite frameworks are assembled
from — the β-cage that Zeolite A, X, and Y are built out of. "Framework" is the crystallographic term
for those structures, not a metaphor borrowed for the occasion. This is the framework built on the
sieve, named after the sieve's own building block.

## Development

```sh
bundle install
bundle exec rake        # tests + rubocop
```

## License

MIT.
