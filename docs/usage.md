# Using sodalite

A task-indexed guide, in the order the work actually happens. You do not start a service by choosing a
route template; you start by deciding what the data is. So does this guide.

[The design](design.md) says *why* each piece is there. This says what to type. Every snippet runs;
where one is abridged, the working version is named.

**Part I — decide what the data is**

1. [Install and run something](#1-install-and-run-something)
2. [Design the schema](#2-design-the-schema)
3. [How this differs from a domain model](#3-how-this-differs-from-a-domain-model)
4. [Declare a history, not a snapshot](#4-declare-a-history-not-a-snapshot)
5. [Ask questions of it: arrows](#5-ask-questions-of-it-arrows)

**Part II — put it behind HTTP**

6. [Reach the data from a request](#6-reach-the-data-from-a-request)
7. [Declare a route](#7-declare-a-route)
8. [Say what a request looks like](#8-say-what-a-request-looks-like)
9. [Say what a response looks like](#9-say-what-a-response-looks-like)
10. [Fail on purpose](#10-fail-on-purpose)
11. [Store objects](#11-store-objects)

**Part III — run it**

12. [Deploy a schema change](#12-deploy-a-schema-change)
13. [Assemble and boot](#13-assemble-and-boot)
14. [Test](#14-test)
15. [Publish the contract](#15-publish-the-contract)
16. [When it refuses](#16-when-it-refuses)

Three things decide almost everything below:

- **The Rack env never reaches your code.** A route declares its shape; a task receives a frozen value.
- **Every effect goes through a handler map.** No `Time.now`, no database handle reachable from a
  request path except one you supplied — which is why the same service runs against real
  infrastructure or fixed values with no mocks.
- **Whatever can be checked at construction is checked at construction**, not on the one request that
  happens to exercise it.

---

# Part I — decide what the data is

## 1. Install and run something

```ruby
# Gemfile
gem 'sodalite'
```

Ruby 3.2+, tested through 4.0. `zeolite`, `berylx`, and `darkcore` come with it; `rack` and `puma` are
the transport edge. Neither berylx nor darkcore is published yet, so development takes all three
siblings from git — see the root `Gemfile`.

Run what is already there before writing anything:

```sh
bundle install
bundle exec ruby -Ilib examples/minimal.rb              # the smallest thing that runs
bundle exec ruby -Ilib examples/service/app.rb          # a whole service, against a fixed world
bundle exec ruby -Ilib examples/service/migrate.rb plan # the solved migration layers
```

`examples/service/` is the reference. When a snippet here is abridged, that directory has the real one.

## 2. Design the schema

This is where a service begins, so start here even though the framework is a web framework.

```ruby
SCHEMA = Sodalite::DB.schema(
  users: { id: :integer, name: :string, city: :string },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
)
```

That is the whole vocabulary. A table is a set of **attributes** (fields with leaf types) and
**foreign keys** (fields pointing at another table). In the category the schema presents, tables are
objects, foreign keys are morphisms between them, and attributes are morphisms into leaf types. You do
not have to care about that phrasing to use it — but it is why `follow(:author)` composes and why the
integrity rule below is not arbitrary.

**Types**: `:integer`, `:float`, `:number`, `:string`, `:boolean`, `:time`, arrays as `[:string]`,
nested hashes, `Zeolite.enum(:draft, :published)` for a closed set, and refinements such as
`Zeolite.sized(:string, min: 1, max: 64)`. A trailing `?` (`:integer?`) makes the field nullable.

Now the constraints you need before you design anything, because they are not negotiable:

### Every table has a key named `id`

```ruby
Sodalite::DB.schema(users: { uuid: :string, name: :string })
# => SchemaError: users has no key :id
```

The key is always the attribute called `id`. Its **type** is yours — `id: :string` is fine, so UUID
keys work — but the **name** is fixed, and there is no way to pass a different one through
`DB.schema`. **Composite keys do not exist.** If your design needs one, give the table a synthetic
`id` and enforce the pair elsewhere.

### A foreign key is a constraint, and carries the key's type

```ruby
Sodalite::DB::SQL.create_table_statement(SCHEMA.table(:posts))
# => "CREATE TABLE posts (id INTEGER PRIMARY KEY, author INTEGER REFERENCES users(id))"
```

`DB.fk` declares a morphism `posts → users`, and that declaration does three things: it types the
column with **the target's key type**, it emits a real `REFERENCES` constraint, and it makes
`follow(:author)` mean something. If the target is keyed by a string, so is the column:

```ruby
Sodalite::DB.schema(users: { id: :string, … }, posts: { …, author: Sodalite::DB.fk(:users) })
# => "CREATE TABLE posts (id INTEGER PRIMARY KEY, author TEXT REFERENCES users(id))"
```

**SQLite parses `REFERENCES` and does not enforce it unless the connection asks.** Run
`PRAGMA foreign_keys = ON` on the connection you hand in; Postgres and MySQL need nothing. This is a
property of the connection, which is yours, so the framework cannot set it for you.

Why a constraint rather than a convention: an instance of the schema is a functor, and a dangling
foreign key is that functor failing to exist.

```ruby
model.insert(:posts, { id: 1, author: 99 })   # no user 99
model.functor?    # => false
model.violations  # => ["posts.author=99 has no users"]
```

That is not "a bad row". The morphism `author : posts → users` has no value at that element, so the
rows are not a functor at all. Referential integrity is not a rule imposed on rows; it is the
condition for the instance to exist — which is why the database is asked to hold it rather than
trusted to.

`functor?` and `violations` are on the in-memory model only, so the *diagnosis* ("which row, pointing
where") is a test-time affordance while the *enforcement* is the database's job.

**Tables are created in dependency order**, not declaration order, because an inline `REFERENCES`
needs its codomain to exist already. `schema.creation_order` is that order. A cycle of foreign keys
cannot be linearised; those tables keep declaration order, and a strict database will reject them.

### What the DDL does not generate

No indexes. No unique constraints. No check constraints. No cascade — `DELETE` removes rows of the
query's own table and nothing else. `create_table` gives you columns and a primary key, and everything
else is yours.

### What *is* checked, at construction

```ruby
Sodalite::DB.schema(posts: { id: :integer, author: Sodalite::DB.fk(:ghosts) })
# => SchemaError: posts.author points at unknown table :ghosts
```

And on the way in:

```ruby
model.insert(:users, { id: 'x', name: 'mina' })
# => SchemaError: users: /id: expected integer, got string [type_mismatch]
```

A row is checked against the same kind of schema object that types a response body — literally the
same vocabulary — which is why "typed on the way in" and "typed on the way out" are one idea here
rather than two libraries.

`insert` returns the key. A row is a plain Hash with symbol keys:

```ruby
model.insert(:users, { id: 7, name: 'mina', city: 'tokyo' })  # => 7
model.rows(:users).first                                      # => { id: 7, name: "mina", city: "tokyo" }
```

## 3. How this differs from a domain model

If you are used to designing a domain model first, the schema above will feel thin — deliberately, and
the difference is structural rather than stylistic.

**A `DB.schema` is a presentation of a category, and nothing else.** Objects, morphisms, and the
condition for an instance to be a functor. It carries no behavior, no lifecycle, and no identity beyond
the key.

| a domain model has | sodalite gives you |
| --- | --- |
| entities with behavior — `user.suspend!` | rows are Hashes; behavior is a named berylx task |
| aggregates defining a consistency boundary | no aggregates — the boundary is `DB.atomically` around a workflow you name |
| repositories | four verbs, and a "finder" is a **value**: `BY_CITY = ->(c) { SCHEMA[:users].where(:city, c) }` |
| invariants enforced inside the model | shape enforced by the schema; domain rules live in tasks that `reject` |
| a lifecycle or state machine per entity | a berylx workflow; `branch` is the case analysis |
| ubiquitous language expressed as classes | expressed in the names of tables, arrows, and tasks |

**Why it is split this way.** An ORM merges structure and behavior into one object, and the merge is
where the surprises live: a save that fires callbacks, a getter that hits the database, an invariant
that holds only if you went through the right method. Here structure is *data you can fold* — the
schema is a value, and the OpenAPI document is a fold over the routes — and behavior is a composition
of named tasks whose failure carries its state. Neither can quietly become the other.

**Where your domain concepts land, concretely:**

| you have | you write |
| --- | --- |
| a noun with its own identity | a table |
| a relationship | a foreign key, which you then `follow` |
| a derived question ("busiest cities") | a named arrow, built once at load; it is a value, so it cannot go stale relative to the schema — the schema built it |
| a rule ("cannot publish twice") | a task that inspects state and calls `lay.reject(:conflict, …)` |
| a process ("checkout") | a workflow, wrapped in `DB.atomically` if it must be all-or-nothing |
| a value object (money, email) | a refinement on the attribute, checked at the boundary rather than in a constructor |

**What you give up, plainly.** There are no entity objects, so there is no `user.posts` navigation and
nowhere to hang a method that "belongs to" a user. If your domain's complexity really is in per-entity
behavior — deep polymorphism, rich state machines — this framework asks you to express that as
workflows and arrows instead. That is a real cost, not a free win. What you get back is that every
piece of it is a value you can print, fold, compare, and check at boot.

## 4. Declare a history, not a snapshot

The moment after you design a schema, you change it. So declare the history and let the schema be the
composite — nothing is written twice:

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
and those solve into layers:

```sh
bundle exec ruby -Ilib examples/service/migrate.rb plan
```

```
layer 0: create_table(:users, {:id=>:integer, :name=>:string})
layer 1: create_table(:posts, {...}), add_attribute(:users, :city, :string, "unknown")
expansion-only: true
```

`create_table :posts` is declared *last* and lands in layer 1 beside `add_attribute`, because the two
are independent and both need only `users`. Two branches that each appended a step therefore merge
without ceremony: the declaration order changed, the set did not.

Contradictions are refused at declaration — two steps supplying one name, a requirement nobody
supplies, a cycle, or the same step declared twice. Reversibility is computed rather than promised:

```ruby
HISTORY.reversible_to?(0)    # => true
HISTORY.irreversible_steps   # => [] — a drop would appear here
```

## 5. Ask questions of it: arrows

A query is a value built from the schema, not a string and not a method on an entity. Build the ones
your service asks once, at load time:

```ruby
BY_CITY = ->(city) { SCHEMA[:users].where(:city, city).order(:name) }
BUSIEST = SCHEMA[:posts].follow(:author).group(:city).count(:people).order(:people, :desc)
```

Vocabulary: `where`, `where_null` / `where_present`, order comparisons where the attribute type carries
an order, `follow(:fk)` to compose along a foreign key, `group(...).count(...)` / `sum` / `min` / `max`,
`having` (a subobject of the *grouped* relation, which is why it is a different word rather than an
overload), `order(field, :asc | :desc)`, `limit` / `offset`, and `union`.

Comparing to `nil` is refused in every form, because SQL's answer to `x = NULL` is UNKNOWN. Say
`where_null` or `where_present` and mean it.

An unordered result is a **set** (`Relation`); an ordered one is a **sequence** (`Listing`). The
distinction is kept because it is real.

Composition folds correctly, which is the part hand-written SQL usually gets wrong:

```sql
SELECT g.city, COUNT(*) AS people
FROM (SELECT DISTINCT t1.id, t1.city FROM posts t0 JOIN users t1 ON t0.author = t1.id) g
GROUP BY g.city
```

The subquery is the image of the composite. Without it the count would report multiplicities of the
join rather than elements of the image — two different numbers, and only one of them answers "how many
people".

Three models satisfy the same four verbs:

```ruby
Sodalite::DB.memory(SCHEMA, seed)              # rows in Hashes, no database
Sodalite::DB.sql(SCHEMA, connection)           # anything answering execute(sql, binds)
Sodalite::DB.sequel(SCHEMA, Sequel.connect(…)) # dialects, quoting, pooling
```

They are checked against each other, which is what makes the in-memory one usable as the thing your
tests run against rather than a stub returning what a test author decided. **Prefer `DB.sequel` in
production**: it quotes identifiers (a table called `order` works) and spells each dialect correctly.

---

# Part II — put it behind HTTP

## 6. Reach the data from a request

The database is not a set of invented verbs. The signature is fixed and small:

```
SELECT(query)       -> Relation
INSERT(table, row)  -> key
DELETE(query)       -> count
ATOMICALLY(subtree) -> Ok / Err
```

so a task asks for what it wants by tag, and the handler map decides what answers:

```ruby
load_user = Berylx::Task[:load_user] do |lay, io|
  found = io.perform(Sodalite::DB::SELECT, SCHEMA[:users].where(:id, lay[:request].get.params.id))
  found.empty? ? lay.reject(:not_found, 'no such user') : lay[:user].set(found.rows.first)
end
```

Transactions read as a combinator:

```ruby
checkout = Sodalite::DB.atomically(:checkout, reserve >> charge >> confirm)
```

Nobody asks for the rollback. berylx short-circuits at the first `Err`, the scope sees it, and the
failure still carries which named task produced it.

Everything else your service touches — mail, payments, anything — is an application effect:

```ruby
Sodalite::Effects.real(send_mail: Mailer.method(:deliver))   # production
Sodalite::Effects.fixed(send_mail: ->(subject) { subject })  # a test
```

The difference is not "real vs stub" — it is which handlers the framework's *own* IO gets.
`:sodalite_clock`, `:sodalite_id`, `:sodalite_log`, and `:sodalite_contract` go through the same door,
so under `fixed` the clock is frozen, ids are deterministic, and a contract breach raises. A whole
request is reproducible byte for byte. An application tag colliding with a `:sodalite_*` tag raises at
boot.

Cross-cutting concerns are a handler swap, never a callback chain:

```ruby
timed = Sodalite::Effects.around(send_mail: Mailer.method(:deliver)) do |tag, payload, inner|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  inner.call(payload).tap do
    record(tag, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  end
end
```

`around` takes the same application effects `real` and `fixed` take — it builds the whole map rather
than wrapping one you already built — and the block sees every effect, including berylx's own.
Comparing `tag` against `Berylx::EffectTree::TASK` is how an aspect observes each named task by name
(`test/substrate_test.rb` does exactly that).

**A handler you supply must be safe to call from several threads at once.** The app is frozen at boot
and shared across Puma threads; that is the one sharp edge the framework cannot check for you.

## 7. Declare a route

A route is a Ruby literal — no DSL, nothing `instance_eval`ed — so it is data you can read, fold, and
publish.

```ruby
show_user = Sodalite::Route[
  :get, '/users/:id',
  params:    { id: :integer },
  responses: { 200 => { id: :integer, name: :string } },
  run:       load_user >> present_user,
  name:      :show_user
]
```

`run:` is a berylx workflow — named tasks composed with `>>`. Two slots are always there,
`lay[:request]` and `lay[:response]`; anything else is yours.

```ruby
present_user = Berylx::Task[:present_user] do |lay|
  user = lay[:user].get
  lay[:response].set(Sodalite.ok({ id: user[:id], name: user[:name] }))
end
```

Matching is a segment trie built once and frozen. Static segments beat parameters, and there is no
regex language in a template — a template you cannot read is not one you can write. **Wildcards are
not implemented**: there is no `*rest`.

## 8. Say what a request looks like

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
`name:` — that is the whole list. Read a header from the Rack env in a handler if you need one; it will
not be typed for you.

**The body goes through the sieve unchanged**, because JSON already carries types — `"1"` is not an
`Integer` and will not be coerced into one. **Path parameters and query values decode first**, because
a URL carries no types at all and declaring the type is the only way to have one: `"42"` becomes `42`
because the route said `{ id: :integer }`. Text that does not decode is passed through *unchanged*, so
the schema reports the violation rather than the decoder. One error path, not two.

A request that does not fit never becomes one. It is a 400 listing **every** violation, each located by
a JSON Pointer saying which part it came from:

```json
{ "error": { "code": "invalid_request", "message": "request does not fit the declared shape" },
  "violations": [{ "path": "/params/id", "code": "type_mismatch",
                   "message": "expected integer, got string" }] }
```

**`?page=` is a present, empty string**, so an `:integer?` field reports a violation rather than
treating it as absent. That is the honest reading of what was sent. Real clients do send it, so if it
matters, declare `:string?` and convert in a task.

## 9. Say what a response looks like

Per status:

```ruby
responses: {
  200 => { id: :integer, name: :string, avatar: :boolean },
  404 => Sodalite::Errors::SCHEMA
}
```

On the way out the framework generates the JSON and then validates **that JSON** — not a Hash that
resembles it — against the declared schema. What gets checked is what the client will receive.

```ruby
lay[:response].set(Sodalite.ok({ id: 1, name: 'mina', avatar: false }))
lay[:response].set(Sodalite.respond(201, { stored: true }))
```

A response that does not fit is the service breaking its own published contract, so it does not take
the ordinary error path: it performs `:sodalite_contract` and the handler decides the cost. Under
`Effects.fixed` it raises, so drift fails your suite; under `Effects.real` it logs and returns a 500,
so drift does not ship a wrong shape to a client that trusted the contract.

Streaming is the same sieve, one record at a time:

```ruby
lay[:response].set(
  Sodalite.stream(200, { seq: :integer, kind: Zeolite.enum(:tick, :done) }) do |emit, io|
    io.perform(:subscribe).each { |event| emit.call({ seq: event.seq, kind: event.kind }) }
  end
)
```

Each record is validated as it is emitted. The status line is already on the wire by then, so a
malformed record stops the stream and reports through the same contract handler.

## 10. Fail on purpose

```ruby
lay.reject(:not_found, "no user #{id}")
```

The code maps to a status the app declares:

```ruby
ERRORS = { not_found: 404, forbidden: 403, conflict: 409 }.freeze
```

An error the service never named is a 500 whose message stays in the log — an error you did not map is
not one you meant to expose. A failure keeps its state: `Berylx::Err(partial_lay, error)` carries which
named task failed, with what state, and everything earlier steps had established.

## 11. Store objects

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

**A store cannot join a transaction**, and this does not pretend otherwise:

```ruby
Sodalite::Store.saga(:publish, upload >> index >> announce)
```

A write records its inverse; an `Err` in the scope replays the inverses backwards. It is **lax**, and
that is the honest part: compensation cannot unread. Anyone who read between the write and the failure
saw a value that compensation later removed. The name is `saga` and shares no vocabulary with
`atomically` for that reason.

---

# Part III — run it

## 12. Deploy a schema change

**Applying is one explicit command, and never a side effect of boot.**

```ruby
model = Sodalite::DB.sequel(HISTORY.schema, Sequel.connect(ENV.fetch('DATABASE_URL')))
model.migrate!(HISTORY)
```

`examples/service/migrate.rb` is the shape — plan, apply, roll back. A process that serves requests does
not migrate: N processes on M hosts means a boot-time migration has no single writer, and a migration
that runs at boot runs during a *rollback* too, at the one moment nobody wants schema changes.
`migrate!` takes a lock, so the single writer is a mechanism rather than a wish.

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
- An unapplied **contraction** → starts normally. That is the expected state between deploying new code
  and dropping the old shape.
- A ledger holding steps this checkout does not declare → refuses, saying the database is ahead of the
  code.

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

Rolling back walks the inverses and refuses **before the first statement runs** if anything in the
range forgets information:

```ruby
model.rollback!(HISTORY, to: 3)   # keep the first three steps of the solved order
```

`drop_attribute` and `drop_table` have no inverse. Rolling back past one is not a smaller operation —
it is a restore. Take the copy before applying it, because the database will not.

[The full procedure](migrations.md#the-procedure) has the rest, including what is deliberately manual.

## 13. Assemble and boot

One call takes the routes, the capabilities they reach through, the verbs the application invented, and
the statuses it publishes for its own error codes:

```ruby
Sodalite::App.build(
  routes:       ROUTES,
  capabilities: [Sodalite::DB.capability(db, history: HISTORY), Sodalite::Store.capability(objects)],
  effects:      { send_mail: Mailer.method(:deliver) },
  errors:       { not_found: 404, forbidden: 403 },
  world:        :real
)
```

Capabilities compose. A transaction or a saga runs a subtree under a map that is not quite this one, so
each capability is handed a `rebuild` — which is what lets a saga swap the store for a journalled one
while the database capability survives the scope.

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
one lambda per dependency. A check that returns falsy *or raises* is down, and any down check makes the
answer 503.

## 14. Test

Same routes, same router, same sieve, same workflow. Swap the world:

```ruby
def app(db: Sodalite::DB.memory(HISTORY, SEED), objects: Sodalite::Store.memory, world: :fixed)
  Sodalite::App.build(routes: ROUTES, capabilities: [...], world: world)
end

status, _headers, chunks = app.call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/users/1',
                                    'QUERY_STRING' => '')
```

No mocks, because the in-memory database is a *model of the same theory* the SQL one is a model of, not
a stand-in for it. This is also where `functor?` earns its keep: assert it after a workflow and a
dangling foreign key fails the test, since production will not tell you.

Under `world: :fixed` the clock is frozen and a contract breach **raises**, so a response drifting from
its declared schema fails the suite rather than reaching a client.

## 15. Publish the contract

The OpenAPI document is a fold over the routes, so it cannot drift:

```ruby
Sodalite::OpenAPI.document(app, title: 'service', version: '1.0')
```

```sh
bundle exec ruby -Ilib examples/service/app.rb openapi
```

Templates are rewritten to OpenAPI's spelling, enums publish their closed set, `?` becomes nullable and
stays out of `required`, and the statuses the framework itself produces are published with the error
shape actually sent. It does not invent: a refinement's predicate is a Ruby block with no JSON Schema,
so it publishes its own label rather than claiming a wider contract.

## 16. When it refuses

Most refusals happen at construction. That is the design working — but the messages read better with
the reason in hand.

| What you see | What it means |
| --- | --- |
| `SchemaError`: *has no key `:id`* | every table needs an attribute literally named `id`; the type is yours, the name is not |
| `SchemaError`: *points at unknown table* | a `DB.fk` target that no table in the schema provides |
| a constraint violation from the driver | a dangling foreign key reached the database. On SQLite this only appears with `PRAGMA foreign_keys = ON` |
| `SchemaError`: *expected integer, got string* | a row did not fit the table's shape on insert |
| `RouteError`: undeclared template parameter | `/users/:id` without `params: { id: … }`, or the reverse |
| `Router::ConflictError` | two routes could answer one request, or `/users/:id` and `/users/:slug` disagree about what that segment is |
| `RouteError` from `run:` | berylx could not compile the workflow — asked at boot, not on first request |
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

**Not implemented, on purpose or not yet:** indexes, unique and check constraints, composite keys,
cyclic foreign keys, declared headers, wildcard route segments, `functor?` on the SQL models, `Π_F` (folding two tables into one by a product over a shared key), an `empty_as_absent` decode
option, RBS for a whole route, and durability — work that must survive a restart belongs in a durable
engine, not here.
