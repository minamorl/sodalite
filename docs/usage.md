# Using sodalite

A task-indexed guide. [The design](design.md) says *why* each piece is there; this says what to type.

Every snippet here runs. Where one is abridged, the working version is named.

**Contents**

1. [Install and run something](#1-install-and-run-something)
2. [Declare a route](#2-declare-a-route)
3. [Say what a request looks like](#3-say-what-a-request-looks-like)
4. [Say what a response looks like](#4-say-what-a-response-looks-like)
5. [Fail on purpose](#5-fail-on-purpose)
6. [Reach the world](#6-reach-the-world)
7. [Reach a database](#7-reach-a-database)
8. [Store objects](#8-store-objects)
9. [Change the schema](#9-change-the-schema)
10. [Deploy a schema change](#10-deploy-a-schema-change)
11. [Assemble and boot](#11-assemble-and-boot)
12. [Test](#12-test)
13. [Publish the contract](#13-publish-the-contract)
14. [When it refuses](#14-when-it-refuses)

Three things decide almost everything below, so they are worth holding in mind:

- **The Rack env never reaches your code.** A route declares its shape; what a task gets is a frozen
  value with real readers.
- **Every effect goes through a handler map.** There is no `Time.now` and no database handle reachable
  from a request path except one you supplied — which is why the same service runs against real
  infrastructure or fixed values with no mocks.
- **Whatever can be checked at boot is checked at boot.** A route that would fail on the one request
  that exercises it fails at construction instead.

---

## 1. Install and run something

```ruby
# Gemfile
gem 'sodalite'
```

Ruby 3.2+, tested through 4.0. `zeolite`, `berylx`, and `darkcore` come with it; `rack` and `puma`
are the transport edge. Neither berylx nor darkcore is published yet, so development takes all three
siblings from git — see the root `Gemfile`.

Before writing anything, run what is already there:

```sh
bundle install
bundle exec ruby -Ilib examples/minimal.rb            # the smallest thing that runs
bundle exec ruby -Ilib examples/service/app.rb        # a whole service, against a fixed world
bundle exec ruby -Ilib examples/service/app.rb openapi # its published document
bundle exec ruby -Ilib examples/service/boot.rb       # the same service on puma
```

`examples/service/` is the reference. When a snippet here is abridged, that directory has the real one.

---

## 2. Declare a route

A route is a Ruby literal. Nothing is `instance_eval`ed and no DSL is involved, so the route is data
you can read, fold, and publish.

```ruby
require 'sodalite'

show_user = Sodalite::Route[
  :get, '/users/:id',
  params:    { id: :integer },
  responses: { 200 => { id: :integer, name: :string } },
  run:       load_user >> present_user,
  name:      :show_user
]
```

`run:` is a [berylx](https://github.com/minamorl/berylx) workflow — named tasks composed with `>>`.
Each task takes the per-request state (`lay`) and the effect performer (`io`):

```ruby
load_user = Berylx::Task[:load_user] do |lay, io|
  found = io.perform(:find_user, lay[:request].get.params.id)
  found ? lay[:user].set(found) : lay.reject(:not_found, 'no such user')
end

present_user = Berylx::Task[:present_user] do |lay|
  user = lay[:user].get
  lay[:response].set(Sodalite.ok({ id: user[:id], name: user[:name] }))
end
```

Two slots are always there: `lay[:request]` and `lay[:response]`. Anything else is yours.

Matching is a segment trie built once and frozen. Static segments beat parameters, and there is no
regex language in a template — a template you cannot read is not one you can write.

**Wildcards are not implemented.** There is no `*rest`. Static and `:param` cover services; a proxy or
a static-file route would want one, and would have to add it.

---

## 3. Say what a request looks like

Three places, two of them text:

```ruby
Sodalite::Route[
  :put, '/users/:id/avatar',
  params: { id: :integer },                         # path
  query:  { limit: :integer?, loud: :boolean? },    # query string
  body:   { png: Zeolite.sized(:string, min: 1) },  # JSON body
  ...
]
```

**Headers are not declarable.** A route takes `params:`, `query:`, `body:`, `responses:`, `run:`, and
`name:` — that is the whole list, and anything else raises. Read a header from the Rack env in a
handler if you need one; it will not be typed for you.

A trailing `?` means the field may be absent or null.

**The body goes through the sieve unchanged**, because JSON already carries types — `"1"` is not an
`Integer` and will not be coerced into one. **Path parameters and query values decode first**, because a URL
carries no types at all and declaring the type is the only way to have one: `"42"` becomes `42`
because the route said `{ id: :integer }`.

Text that does not decode is passed through *unchanged*, so the schema reports the violation rather
than the decoder. There is one error path, not two.

Available types: `:integer`, `:float`, `:number`, `:string`, `:boolean`, `:time`, arrays as
`[:string]`, nested hashes, `Zeolite.enum(:a, :b)` for a closed set, and refinements like
`Zeolite.sized(:string, min: 1, max: 64)`.

A request that does not fit never becomes one. It is a 400 listing **every** violation, each located
by a JSON Pointer that says which part it came from:

```json
{ "error": { "code": "invalid_request", "message": "request does not fit the declared shape" },
  "violations": [{ "path": "/params/id", "code": "type_mismatch",
                   "message": "expected integer, got string" }] }
```

**`?page=` is a present, empty string**, so an `:integer?` field reports a violation rather than
treating it as absent. That is the honest reading of what was sent. Real clients do send it, so if
that matters, validate as `:string?` and convert in a task.

---

## 4. Say what a response looks like

Per status:

```ruby
responses: {
  200 => { id: :integer, name: :string, avatar: :boolean },
  404 => Sodalite::Errors::SCHEMA
}
```

On the way out the framework generates the JSON and then validates **that JSON** — not a Hash that
resembles it — against the declared schema. What gets checked is what the client will receive.

Build responses with `Sodalite.ok(hash)` or `Sodalite.respond(status, hash)`:

```ruby
lay[:response].set(Sodalite.respond(201, { stored: true }))
```

A response that does not fit is the service breaking its own published contract, so it does not take
the ordinary error path: it performs `:sodalite_contract`, and the handler decides the cost. Under
`Effects.fixed` it raises, so drift fails your suite. Under `Effects.real` it logs and returns a 500,
so drift does not ship a wrong shape to a client that trusted the contract.

---

## 5. Fail on purpose

`lay.reject(code, message)` ends the workflow with a named error:

```ruby
lay.reject(:not_found, "no user #{id}")
```

The code maps to a status the app declares:

```ruby
ERRORS = { not_found: 404, forbidden: 403, conflict: 409 }.freeze
```

An error the service never named is a 500 whose message stays in the log. An error you did not map is
not one you meant to expose.

A failure keeps its state: `Berylx::Err(partial_lay, error)` carries which named task failed, with
what state, and everything the earlier steps had established. That is what reaches the log.

---

## 6. Reach the world

Every effect is `io.perform(tag, payload)`, dispatched through the handler map the app runs under.

```ruby
Sodalite::Effects.real(send_mail: Mailer.method(:deliver))   # production
Sodalite::Effects.fixed(send_mail: ->(subject) { subject })  # a test
```

The difference is not "real vs stub" — it is which handlers the framework's *own* IO gets.
`:sodalite_clock`, `:sodalite_id`, `:sodalite_log`, and `:sodalite_contract` go through the same door,
so under `fixed` the clock is frozen, ids are deterministic, and a contract breach raises. A whole
request is reproducible byte for byte.

`:sodalite_*` tags are the framework's. An application tag that collides raises at boot.

Cross-cutting concerns — timing, audit, retry, dry-run, tracing — are a handler swap, never a callback
chain:

```ruby
timed = Sodalite::Effects.around(send_mail: Mailer.method(:deliver)) do |tag, payload, inner|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  inner.call(payload).tap do
    record(tag, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  end
end
```

`around` takes the same application effects `real` and `fixed` take — it builds the whole map, rather
than wrapping one you already built. The block sees every effect, including berylx's own: comparing
`tag` against `Berylx::EffectTree::TASK` is how an aspect observes each named task by name
(`test/substrate_test.rb` does exactly that).

The wrapped map is passed into `parallel`, `branch`, and `rescue` subtrees, so the route is never
rewritten in order to be observed.

**A handler you supply must be safe to call from several threads at once.** The app is frozen at boot
and shared across Puma threads; that is the one sharp edge the framework cannot check for you.

---

## 7. Reach a database

A database is not a bag of invented verbs. The signature is fixed and small:

```
SELECT(query)       -> Relation
INSERT(table, row)  -> key
DELETE(query)       -> count
ATOMICALLY(subtree) -> Ok / Err
```

So `find_user` stops being an effect and goes back to being a **named arrow** — a value, built once
and reused:

```ruby
SCHEMA  = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
)

BY_CITY = ->(city) { SCHEMA[:users].where(:city, city).order(:name) }
BUSIEST = SCHEMA[:posts].follow(:author).group(:city).count(:people).order(:people, :desc)
```

Used from a task:

```ruby
found = io.perform(Sodalite::DB::SELECT, BY_CITY.call('tokyo'))
found.rows          # => [{ id: 1, name: 'mina', city: 'tokyo' }, ...]
```

Arrow vocabulary: `where` / `where_null` / `where_present`, order comparisons where the attribute type
carries an order, `follow(:fk)` to compose along a foreign key, `group(...).count(...)` /
`sum` / `min` / `max`, `order(field, :asc | :desc)`, `limit` / `offset`, `union`, and `having` (a
subobject of the *grouped* relation, which is why it is a different word rather than an overload).

Comparing to `nil` is refused in every form, because SQL's answer to `x = NULL` is UNKNOWN. Use
`where_null` / `where_present` and say what you meant.

Three models satisfy the same signature:

```ruby
Sodalite::DB.memory(SCHEMA, seed)              # rows in Hashes, no database
Sodalite::DB.sql(SCHEMA, connection)           # anything answering execute(sql, binds)
Sodalite::DB.sequel(SCHEMA, Sequel.connect(…)) # dialects, quoting, pooling
```

They are checked against each other, which is what makes the in-memory one usable as the thing your
tests run against rather than a stub that returns what a test author decided. Prefer `DB.sequel` in
production unless you have a reason not to: it quotes identifiers (a table called `order` works) and
spells each dialect correctly.

Transactions read as a combinator:

```ruby
checkout = Sodalite::DB.atomically(:checkout, reserve >> charge >> confirm)
```

Nobody asks for the rollback. berylx short-circuits at the first `Err`, the scope sees it, and the
failure still carries which named task produced it.

---

## 8. Store objects

A bucket is a partial function `Key ⇀ Object`, and the keys form a poset under the prefix order:

```
PUT(key, bytes, meta) -> key
GET(key)              -> Object or nil
DELETE(key)           -> boolean
LIST(prefix)          -> keys, ordered
```

```ruby
io.perform(Sodalite::Store::PUT, ["avatars/#{id}", bytes])
io.perform(Sodalite::Store::GET, "avatars/#{id}")   # nil is honest: the function is partial
```

`Store.memory`, `Store.filesystem`, and `Store.s3` (over a four-method port `Aws::S3::Client` already
satisfies). A key is not a path: `a/b` is one object, not a directory holding `b`.

**A store cannot join a transaction**, and this does not pretend otherwise. What you get is
compensation:

```ruby
Sodalite::Store.saga(:publish, upload >> index >> announce)
```

A write records its inverse; an `Err` in the scope replays the inverses backwards. It is **lax**, and
that is the honest part: compensation cannot unread. Anyone who read between the write and the failure
saw a value that compensation later removed. The name is `saga` and shares no vocabulary with
`atomically` for that reason.

---

## 9. Change the schema

Declare the history instead of the schema, and the schema is the composite — so nothing is written
twice:

```ruby
HISTORY = Sodalite::DB.history(
  [:create_table,  :users, { id: :integer, name: :string }],
  [:add_attribute, :users, :city, :string, 'unknown'],
  [:create_table,  :posts, { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }]
)

SCHEMA = HISTORY.schema
```

The eight steps:

| step | meaning |
| --- | --- |
| `[:create_table, :t, { field: :type }]` | a new object |
| `[:drop_table, :t]` | forgets an object |
| `[:rename_table, :t, :u]` | an isomorphism |
| `[:add_attribute, :t, :f, :type, default]` | the column is the constant default, so it is injective |
| `[:drop_attribute, :t, :f]` | a projection — forgets |
| `[:rename_attribute, :t, :a, :b]` | an isomorphism |
| `[:merge_tables, [:a, :b], :into, :tag]` | the coproduct; `:tag` records which side each row came from |
| `[:split_table, :t, :tag, { 'a' => :a, 'b' => :b }]` | its decomposition along the tag |

**Add steps by appending. Never edit an applied step** — a step's identity is its content, so editing
one produces a *different* step, and the ledger notices rather than silently re-meaning the old one.

**The order is solved, not declared.** Each step states what names it requires, provides, and removes,
and those solve into layers. Two branches that each appended a step merge without ceremony: the
declaration order changed, the set did not.

```sh
bundle exec ruby -Ilib examples/service/migrate.rb plan
```

```
layer 0: create_table(:users, {:id=>:integer, :name=>:string})
layer 1: create_table(:posts, {...}), add_attribute(:users, :city, :string, "unknown")
expansion-only: true
```

`create_table :posts` is declared *last* and lands in layer 1 beside `add_attribute`, because the two
are independent and both need only `users`.

Contradictions are refused at declaration, not at 3am: two steps supplying one name, a requirement
nobody supplies, a cycle, or the same step declared twice.

Reversibility is computed rather than promised:

```ruby
HISTORY.reversible_to?(0)    # => true
HISTORY.irreversible_steps   # => [] — a drop would appear here
```

---

## 10. Deploy a schema change

**Applying is one explicit command, and never a side effect of boot.**

```ruby
model = Sodalite::DB.sequel(HISTORY.schema, Sequel.connect(ENV.fetch('DATABASE_URL')))
model.migrate!(HISTORY)
```

`examples/service/migrate.rb` is the shape — plan, apply, roll back. A process that serves requests
does not migrate: N processes on M hosts means a boot-time migration has no single writer, and a
migration that runs at boot runs during a *rollback* too, at the one moment nobody wants schema
changes. `migrate!` takes a lock so the single writer is a mechanism rather than a wish.

**Boot verifies and refuses**, in the constructor where the router's checks already are:

```ruby
Sodalite::App.build(
  routes:       ROUTES,
  capabilities: [Sodalite::DB.capability(db, history: HISTORY)],
  errors:       ERRORS,
  world:        :real
)
```

- An unapplied **expansion** → refuses to start. The code wants a column that is not there.
- An unapplied **contraction** → starts normally. That is the expected state between deploying new
  code and dropping the old shape.
- A ledger holding steps this checkout does not declare → refuses, saying the database is ahead of
  the code.

**Which order to deploy in follows from the kind of steps in the release**, and the two tables are not
the same table:

| step | reversible? | expand? |
| --- | --- | --- |
| `create_table` | yes | **yes** |
| `add_attribute` | yes | **yes** |
| `rename_attribute` | yes | no |
| `rename_table` | yes | no |
| `merge_tables` / `split_table` | yes | no |
| `drop_attribute` | no | no |
| `drop_table` | no | no |

A rename is an isomorphism, so it rolls back perfectly — and it still breaks every process running the
old code, because the old presentation is not *included* in the new one under its own names.
Reversibility asks for an inverse; compatibility asks for an inclusion.

- **Expansion-only release**: apply first, then deploy. Old code keeps running the whole time.
- **Release containing a contraction**: deploy first, then apply. The old shape outlives the code that
  used it by one deploy.

Ask, do not assert:

```ruby
HISTORY.plan.expand_only?     # => true
HISTORY.plan.contract_steps   # => the ones that force deploy-first
```

Renaming a column under load is therefore three releases, not one: add the new name and backfill,
deploy code that writes both and reads the new, then drop the old.

Rolling back walks the inverses, and refuses **before the first statement runs** if anything in the
range forgets information:

```ruby
model.rollback!(HISTORY, to: 3)   # keep the first three steps of the solved order
```

`drop_attribute` and `drop_table` have no inverse. Rolling back past one is not a smaller operation —
it is a restore. Take the copy before applying it, because the database will not.

[The full procedure](migrations.md#the-procedure) has the rest, including what is deliberately left
manual.

---

## 11. Assemble and boot

One call takes the routes, the capabilities they reach through, the verbs the application invented,
and the statuses it publishes for its own error codes:

```ruby
Sodalite::App.build(
  routes:       ROUTES,
  capabilities: [Sodalite::DB.capability(db, history: HISTORY), Sodalite::Store.capability(objects)],
  effects:      { send_mail: Mailer.method(:deliver) },
  errors:       { not_found: 404, forbidden: 403 },
  world:        :real
)
```

Capabilities compose. A transaction or a saga runs a subtree under a map that is not quite this one,
so each capability is handed a `rebuild` — which is what lets a saga swap the store for a journalled
one while the database capability survives the scope.

Serving:

```sh
bundle exec ruby -Ilib examples/service/boot.rb   # bundled puma defaults
rackup examples/service/config.ru                 # or any Rack server
```

Threads, not processes. The app is frozen at boot — routes, compiled schemas, generated classes, the
handler map — so every thread shares immutable data and there is nothing to copy.

Liveness and readiness are two questions and two routes:

```ruby
Sodalite.health,
Sodalite.health(path: '/ready', checks: {
  database: ->(io) { io.perform(Sodalite::DB::SELECT, SCHEMA[:users]) },
  objects:  ->(io) { io.perform(Sodalite::Store::LIST, '') }
})
```

Liveness is framework-level. Readiness is not — only the service knows what it needs — so checks are
one lambda per dependency. A check that returns falsy *or raises* is down, and any down check makes
the answer 503.

---

## 12. Test

Same routes, same router, same sieve, same workflow. Swap the world:

```ruby
def app(db: Sodalite::DB.memory(HISTORY, SEED), objects: Sodalite::Store.memory, world: :fixed)
  Sodalite::App.build(routes: ROUTES, capabilities: [...], world: world)
end

status, _headers, chunks = app.call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/users/1',
                                    'QUERY_STRING' => '')
```

No mocks are involved, because the in-memory database is a *model of the same theory* the SQL one is a
model of, not a stand-in for it.

Under `world: :fixed` the clock is frozen and a contract breach **raises**, so a response drifting from
its declared schema fails the suite rather than reaching a client.

---

## 13. Publish the contract

The OpenAPI document is a fold over the routes, so it cannot drift:

```ruby
Sodalite::OpenAPI.document(app, title: 'service', version: '1.0')
```

```sh
bundle exec ruby -Ilib examples/service/app.rb openapi
```

Templates are rewritten to OpenAPI's spelling, enums publish their closed set, `?` becomes nullable
and stays out of `required`, and the statuses the framework itself produces are published with the
error shape actually sent. It does not invent: a refinement's predicate is a Ruby block with no JSON
Schema, so it publishes its own label rather than claiming a wider contract.

---

## 14. When it refuses

Most refusals happen at construction. That is the design working, not a bug — but the messages are
easier to read with the reason in hand.

| What you see | What it means |
| --- | --- |
| `RouteError`: undeclared template parameter | `/users/:id` without `params: { id: … }`, or the reverse |
| `Router::ConflictError` | two routes could answer one request, or `/users/:id` and `/users/:slug` disagree about what that segment is |
| `RouteError` from `run:` | berylx could not compile the workflow — asked at boot rather than on first request |
| `ArgumentError` on an effect tag | an application tag collided with a `:sodalite_*` or berylx tag |
| `MigrationError`: *is declared twice* | the same step appears twice; a step is its content, so the two are one step |
| `MigrationError`: *both provide* | two steps supply the same table or attribute |
| `MigrationError`: *are not provided* | a step needs something no step creates |
| `MigrationError`: *dependency cycle* | the listed steps cannot be placed in any layer |
| `MigrationError`: *database is missing required migrations* | boot verification found an unapplied expansion — apply, then start |
| `MigrationError`: *this checkout is older than the migration ledger* | an old release is starting against a newer database |
| `MigrationError`: *cannot rollback irreversible migrations* | the range contains a drop; nothing ran |
| `MigrationError`: *another migration is running* | the lock is held. If a runner crashed, clear it: `DELETE FROM sodalite_migration_lock` |
| 500 with `contract` in the log | the response did not fit its declared schema under `Effects.real` |
| 400 on `?page=` | an empty query value is present-and-empty, not absent |

**Not implemented, on purpose or not yet:** declared headers, wildcard route segments, `Π_F` (folding two tables into
one by a product over a shared key), an `empty_as_absent` decode option, RBS for a whole route, and
durability — work that must survive a restart belongs in a durable engine, not here.
