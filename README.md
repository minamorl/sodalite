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

```
SELECT(query)          -> Relation      DELETE(query)       -> count
INSERT(table, row)     -> key           ATOMICALLY(subtree) -> Ok / Err
UPDATE(query, changes) -> count
```

```ruby
SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string, age: :integer? },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
)

in_tokyo = SCHEMA[:posts].where(:title, 'hello').follow(:author).where(:city, 'tokyo').select(:name)
posted_from_tokyo = SCHEMA[:posts].where_at(:author, :city, 'tokyo')

busy = SCHEMA[:users].group(:city).count(:people).having(:people, :gt, 1).order(:people, :desc)
adults = SCHEMA[:users].where(:age, :gte, 18).union(SCHEMA[:users].where_null(:age))
```

`where` takes an order comparison wherever the attribute type carries an order, and a complement
wherever the type is a plain set — over a nullable column `NOT (x = 3)` is three-valued, so the
complement is refused there and `where_null` / `where_present` eliminate the `A + 1` explicitly.

`in_tokyo` and `posted_from_tokyo` answer with different objects, and that is the whole of what
`where_at` is for. `follow` is composition, so it yields *users* — which makes "posts whose author
lives in tokyo" unsayable with it, because the posts were the thing being asked about.
`where_at(path, field, …)` is the pullback `f*(S)`: the subobject of the **carrier** whose image
under the path satisfies the predicate. It emits the same join and reads the other side of the span.
`where_along` takes a path of more than one hop. Neither is a fourth primitive — it is `where`,
formed along a path, and phase one is still composition, subobject, image.

An order has to be a function of the set, and `A + 1` holds a point no `?` in the schema mentions —
`min`/`max` fold an entirely-nothing fibre to it. The backends had three answers there (`DB.memory`
raised, sqlite sorted nothings first, postgres last), so the placement is stated rather than inherited:
**`nothing` sorts after every element of `A`, in both directions**, emitted as `NULLS LAST` on every
ordering term (SQLite 3.30 or newer). It is not last ascending and first descending, because it is not
an element being ordered — it is the point adjoined to `A`, and reversing the order on `A` cannot reach
it.

A schema is a **finitely presented** category: tables are objects, foreign keys are morphisms, and
`equations:` are path equations — pairs of composites declared equal.

```ruby
Sodalite::DB.schema(
  employees:   { id: :integer, name: :string, manager: Sodalite::DB.fk(:employees),
                 department: Sodalite::DB.fk(:departments) },
  departments: { id: :integer, title: :string },
  equations:   [[:employees, %i[manager department], %i[department]]]
)
```

Declaring none leaves the *free* category on the graph of foreign keys, where no two distinct paths
are ever equal — so "an employee's manager is in their department" cannot be said at all. It is not
sayable to SQL either: a foreign key relates one column to one key, never one path to another, which
is why it belongs to the presentation rather than to the DDL.

An instance is a functor into `Set`, so a dangling foreign key is not a bad row — it is a failure to
be a functor. **Reported, not enforced**, and that is a decision rather than an omission: `insert`
does not check that a foreign key's target exists, `delete` does not check for referrers, and the
DDL emits no `REFERENCES`. An instance can therefore stop being a functor between two writes, and
`functor?` / `violations` are how you ask — on all three models, not the in-memory one alone. The
morphism fails to have a value *at an element*, so `violations` counts per element: two posts pointing
at one absent user are two failures and not one, and the multiplicity is what `violations.size` means.
A path equation has the same standing one layer up, as a condition on the functor once it is one, and
`equation_violations` reports it the same way.

There is no `join` in the query language: `follow` is composition, and the join is what the compiler
emits.

```
SELECT DISTINCT "t1"."name" FROM "posts" "t0" JOIN "users" "t1" ON "t0"."author" = "t1"."id"
WHERE "t0"."title" = ? AND "t1"."city" = ?
```

Every identifier is quoted, so a table called `order` works, and `SELECT DISTINCT` is dropped where
the dedupe is provably redundant — `posted_from_tokyo` above compiles without it, because a pullback
joins along a function and cannot repeat a row of the carrier.

Three models, not a stub and the real thing: `DB.memory` (an instance functor into Set), `DB.sql`
(arrows compiled to SQL text, no driver anywhere near it), and `DB.sequel` (the same arrows lowered
onto Sequel's expression API, which knows dialects and quoting). `test/db_conformance_test.rb` drives
fifty arrow shapes through all three and asserts they agree. That is the upgrade: the fixed world no
longer returns what a test author decided, it computes the same query somewhere cheaper — and a bug
would have to occur in three independent lowerings, identically, to survive.

Sequel is a **backend** here, not a second query language: the arrows are the theory, and dialects,
quoting, and pooling are what Sequel is for. It stays out of the runtime dependencies the same way no
driver is in them — `DB.sequel` takes a database someone else built.

`UPDATE` is the fifth operation, and it exists because four could not change a value safely. With four,
changing one means `SELECT` the row, `DELETE` it, `INSERT` the changed version, inside `atomically` —
which is atomic and, under the READ COMMITTED a plain `BEGIN` gets on postgres, not serialisable. Two
scopes both read `stock = 1`; the second's `DELETE` waits for the first, then re-evaluates its `WHERE`
against a row already gone, deletes nothing, and inserts a row computed from its stale read. The
decrement is lost and the item is oversold. A fifth verb that assigned literals would carry exactly the
same hazard: the problem is not how many statements there are, it is that the new value came from an
earlier read.

```ruby
SHOP = Sodalite::DB.schema(items: { id: :integer, name: :string, stock: :integer })
IN_STOCK = ->(id) { SHOP[:items].where(:id, id).where(:stock, :gt, 0) }

db.update(IN_STOCK.call(1), { stock: Sodalite::DB.add(-1) })   # => 1
db.update(IN_STOCK.call(1), { stock: Sodalite::DB.add(-1) })   # => 0  — this one lost the race
```

```sql
UPDATE "items" SET "stock" = "stock" + ? WHERE "id" = ? AND "stock" > ?
```

The change is a **function of the current value**, and the guard is evaluated **inside the same
statement**, so the engine applies it under its own row lock to whatever the value is by then. The
arrow never sees the value, and the count is how a caller learns it lost — rather than by overselling
and finding out later. `DB.add(delta)` and `DB.set(value)` are the whole vocabulary; a bare value means
`set`, a decrement is `add` of a negative delta, and there is deliberately no expression language, on
the rule that kept `avg` out of the aggregates. An update refuses what a delete refuses, plus a
pullback guard (a join inside `UPDATE` is dialect-bound, so allowing it would push the guard back into
an earlier select — the very thing this removes), an empty change, the carrier's key, and `add` on a
type carrying no addition.

The port widened with it, optionally. `execute(sql, binds) -> rows` is still the whole mandatory port
and every existing adapter works untouched; a connection may *also* answer
`change(sql, binds) -> Integer`, detected with `respond_to?`, and then a change or a deletion is one
statement instead of reading the doomed rows into Ruby to count them. Declaring it is a capability, not
a requirement, and the gem still depends on no driver.

**Staleness is a calculus, not a channel.** The natural request is a push channel — subscribe to a
query, be told when a write invalidates it. This framework cannot have one, and it is the design that
says so rather than the schedule: a registry of live subscriptions has to outlive the request that
registered it and be written by a *different* request, which is exactly what "no global state" and
"no durability" above are the absence of. The NDJSON/SSE streaming below is not that bus either — it
is a *response framing*, one request writing many records down its own connection. So what ships is
the pair of sets a channel would have been built out of, and the broker is yours:

```ruby
query.reads              # Set<Address> — the places this arrow's answer depends on
DB.writes(tag, payload)  # Set<Address> — the places performing that operation dirties
```

> `writes(op)` disjoint from `reads(q)` ⟹ performing `op` cannot have changed `q`'s answer.

An instance is a functor `I : C → Set`, and a functor has two kinds of value — so an address does
too. `Address.elements(:posts)` is the set `I(posts)`; `Address.field(:posts, :title)` is the function
`I(title)`. `INSERT` and `DELETE` change which elements exist and nothing else; `UPDATE` changes where
a map sends them and **cannot** make an element appear or disappear. That is the whole of why this is
worth computing: an update to `posts.title` leaves a query reading only `posts.id` alone.

```ruby
INDEX   = SCHEMA[:posts].follow(:author).select(:name)
depends = INDEX.reads                                                       # => [posts, posts.author, users, users.name]

DB.writes(DB::UPDATE, [SCHEMA[:posts].where(:id, 1), { title: 'renamed' }]) # => [posts.title]  — disjoint, keep the cache
DB.writes(DB::UPDATE, [SCHEMA[:users].where(:id, 1), { name: 'minamorl' }]) # => [users.name]   — meets, drop it
DB.writes(DB::INSERT, [:posts, { id: 2, title: 't', author: 1 }])           # => [posts]        — meets, drop it
```

Both are pure functions of values already in hand — the arrow, and the `(tag, payload)` the caller was
about to hand `io.perform` — so nothing reads the database, nothing is stored, and the question is
askable before the write rather than after. Having the operations *return* what they dirtied would
have widened the fixed signature instead; this way the framework gains a function and no state.

The rule most easily missed is the one that keeps it sound: a query with **no projection** answers
with whole rows, so it reads *every* field of its final carrier, including the ones nobody named.
Without it, an update to an unmentioned column looks harmless while changing the answer.

Two things are then refused on purpose. Precision stops at the column rather than the fibre
(`posts.author`, not `posts.author=2`) because naming the fibres an update dirtied means knowing
which fibres its rows were in *before* the write, and that is a read — read-then-write being the
shape `UPDATE` exists to remove. So false positives are accepted, one-sidedly: a false positive only
wastes work, a false negative serves a stale answer, and the error is taken where it is merely
wasteful. And `ATOMICALLY` refuses to answer rather than answering `[]` — its payload is a berylx
task tree, what a task tree performs is not decidable from the value, and `[]` would claim a scope
dirties nothing, which is the one answer certainly wrong; union the writes of the operations inside
it. The claim is then scoped the way everything else here is: query normalisation may rewrite a path
along a declared equation, so `reads` describes the path the query was normalised *to*, which means
what you wrote on instances satisfying their equations — reported by `equation_violations`, not
enforced.

A transaction is a combinator whose handler runs the subtree, and rollback is what `Err` means to it:

```ruby
Sodalite::DB.atomically(:checkout, reserve >> charge >> confirm)
```

Nobody asks for the rollback. `berylx` short-circuits at the first `Err`, the scope sees it, and the
failure still carries which named task produced it. [The design note](docs/rdbms.md) works through the
category theory, and section 7 names the five places it does not reach — `NULL`, ordering, aggregation,
isolation levels, and schema migration. Isolation levels stay a parameter and not a theorem: `UPDATE`
removes the lost update, which was the part reachable through ordinary use, and not phantoms, write
skew, or the need to choose a level for the workloads that still need one.

## History and storage

A migration step is a functor, so **reversibility is computed rather than promised**:

```ruby
HISTORY = Sodalite::DB.history(
  [:create_table,     :users, { id: :integer, name: :string }],
  [:add_attribute,    :users, :city, :string, 'unknown'],
  [:rename_attribute, :users, :city, :town]
)

HISTORY.schema                 # the composite — nothing is declared twice
HISTORY.reversible_after?(0)   # => true; a drop_attribute would make it false
```

`rename` is an isomorphism, `add_attribute` is injective (the column is the constant default, so the
original projects back out), `drop_attribute` is a projection and forgets. That answer arrives before
a statement runs. All three models carry the history and the conformance suite covers "migrate, then
query".

`after` is the unit, and it is a count of steps along `plan.order` — the *solved* order, the same
number line `rollback!(to:)` indexes. `schema_after`, `spec_after`, and `reversible_after?` all read
it. Counting along the order someone typed would be counting along the one thing here that carries no
meaning.

**The order is solved, not declared.** Each step says what names it requires, provides, and removes,
and those solve into layers — so two branches that each appended a step merge without the index drift
that an ordered ledger turns into a false fingerprint mismatch. The ledger is keyed by the step's
content, and a contradiction (two steps supplying one name, a requirement nobody supplies, a cycle) is
refused at declaration rather than at 3am.

That content address is a normalised, prefix-free serialisation under a `v1` scheme tag, so
permuting the fields of a `create_table` no longer mints a second address for the same step. It also
means **every fingerprint changed**: a database migrated under the older scheme presents a ledger
this code does not recognise, and its rows have to be re-seeded by hand. A history also cannot
*adopt* a database it did not create — the first steps are always the `create_table`s. Both are
[in the migration note](docs/migrations.md#what-this-does-not-decide), with what to do about them.

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

This is a **response framing, not a broadcast bus**: one request writing many records down its own
connection, its state inside its own `Root`, its lifetime ending with the request. Nothing here gives
a second request a handle on the first one's socket, which is why invalidation above is a pair of sets
rather than a feed.

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
