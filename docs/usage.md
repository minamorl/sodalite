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

**`:boolean` does not work with `DB.sql`.** `sql_type` has no boolean, so the column is declared
`TEXT`, and the sqlite3 driver refuses to bind `true` at all — `RuntimeError: can't prepare
TrueClass`, on the insert rather than at construction. `DB.memory` and `DB.sequel` both take it,
because one stores Ruby values and the other lets a backend that knows its dialect do the mapping.
This is not new and it is not a plan; it is where the hand-written emitter stops, and the way around
it is to use `DB.sequel` or to spell the field as an enum of two strings.

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

### `DB.fk` is not a database constraint

This is the one that will surprise you, so it is here rather than in a footnote:

```ruby
Sodalite::DB::SQL.create_table_statement(SCHEMA.table(:posts))
# => "CREATE TABLE \"posts\" (\"id\" INTEGER PRIMARY KEY, \"title\" TEXT, \"author\" INTEGER)"
```

No `REFERENCES`. The generated DDL emits a bare column of the target's key type. `DB.fk` declares a
morphism in *your* schema — it is what makes `follow(:author)` mean something and what types the
column — and it does **not** ask the database to enforce anything.

What integrity means here instead: an instance of the schema is a functor, and a dangling foreign key
is that functor failing to exist.

```ruby
model.insert(:posts, { id: 1, title: 'hi', author: 99 })   # no user 99
model.functor?    # => false
model.violations  # => ["posts.author=99 has no users"]
```

That is not "a bad row". The morphism `author : posts → users` has no value at that element, so the
rows are not a functor at all. Referential integrity is not a rule imposed on rows; it is the
condition for the instance to exist.

`functor?` and `violations` are on **all three models** — `DB.memory` intersects sets, `DB.sql` and
`DB.sequel` each ask the database for the anti-join in one statement — and the sentence they answer
with comes from the schema, so three models cannot report one broken morphism in three wordings. All
three sort on that sentence, so the list is comparable across models rather than across key types that
need not be comparable to each other.

**`violations` counts per element, not per missing key.** Two posts pointing at the absent user 99 are
two failures of the functor and not one, so `violations.size` is `2` and the sentence appears twice.
The morphism fails to have a value *at an element*, and the multiplicity is what "how far from being a
functor" means — deduplicating it would answer a different question.

### Referential integrity is a diagnostic, not an invariant

This is the decision, and it is worth stating rather than leaving you to infer it from the absence of
an error:

- `insert` does not check that a foreign key's target exists.
- `delete` does not check whether anything points at the row it removes.
- The DDL emits no `REFERENCES`, so the database will not check either.

So an instance can stop being a functor between two writes, and nothing stops it. `functor?` is how
you ask, when you ask. Guarding the writes instead would impose a constraint the schema does not
declare, and would turn something an instance *is* into something a model enforces on its behalf —
which is a different object, and a slower one.

What follows from that, practically: assert `functor?` in tests, where it costs nothing and a
dangling key fails the suite. In production it is a query you run when you want the answer, not a
guarantee you inherit. If you want the database to hold the line, add `REFERENCES` yourself and
accept that the DDL sodalite generates is then not the whole story for your database.

### Path equations, the constraint a foreign key cannot carry

A schema is a **finitely presented** category, and `equations:` is the presentation's other half:
pairs of composites out of one object, declared equal.

```ruby
PRESENTED = Sodalite::DB.schema(
  employees:   { id: :integer, name: :string, manager: Sodalite::DB.fk(:employees),
                 department: Sodalite::DB.fk(:departments) },
  departments: { id: :integer, title: :string },
  equations:   [[:employees, %i[manager department], %i[department]]]
)
# every employee is in their manager's department
```

Declare none and the schema is the *free* category on the graph of foreign keys, where no two
distinct paths are ever equal — which is what every schema was before this, so leaving `equations:`
off changes nothing. A foreign key relates one column to one key, never one path to another, so this
constraint has nowhere to live in the DDL either.

An equation is judged the moment it is declared. Sides that arrive at different objects, a morphism
that does not exist, a source table that does not — each is a `SchemaError` at construction, because
an equation about morphisms that are not there is not a constraint that fails later, it is a sentence
about some other category. The empty path is allowed and means the identity: `[:employees, %i[manager],
[]]` says every employee is their own manager.

It buys two things. The first is the constraint itself, reported the same way integrity is:

```ruby
model.satisfies_equations?  # => false
model.equation_violations   # => ["employees.id=3: manager.department = 1 but department = 2"]
```

Reported, not enforced, for the same reason and with the same standing. `insert` does not check it
and no `CHECK` is emitted.

The second is a query normalisation **derived from the schema rather than guessed at** — no
statistics, no hints, no data read. A trailing run of compositions is rewritten to the shortest path
the equations prove equal to it, so under `PRESENTED` this

```ruby
PRESENTED[:employees].follow(:manager).follow(:department)
```

compiles to one join instead of two:

```sql
SELECT DISTINCT "t1"."id", "t1"."title" FROM "employees" "t0"
JOIN "departments" "t1" ON "t0"."department" = "t1"."id"
```

**The caveat, plainly: the rewrite is sound relative to the *declared theory*, which is weaker than
sound.** An instance that violates the equation answers differently after the rewrite than it would
have before. So does one where a morphism on the longer path has no value at some element, because
the longer path drops that element and the shorter one keeps it. That is the exact standing of a
dangling foreign key — a failure to be a functor into the presented category — and it is the same
bargain: the presentation is believed, `equation_violations` is what tells you the instance stopped
deserving it.

### What the DDL does generate, and what it does not

**Foreign key columns are indexed.** `follow` and the pullback both compile to `JOIN target ON
source.fk = target.key`, so a morphism's column sits on the probe side of a join by construction —
the index follows from declaring the morphism rather than from a slow morning afterwards. It is named
`index_<table>_on_<field>` by one rule that both SQL-backed models read, so they cannot disagree
about what an index is called, and it is emitted on creation *and* carried across a `rename_table` —
which matters because SQLite and Postgres both keep an index across `RENAME TO` under the name it was
created with, leaving the renamed object holding a name nothing can compute again. (`DB.memory` has
no DDL and therefore no indexes; there is nothing there for one to speed up.)

```ruby
Sodalite::DB::SQL.index_statements(SCHEMA.table(:posts))
# => [["CREATE INDEX \"index_posts_on_author\" ON \"posts\" (\"author\")", []]]
```

Nothing else. No index you declare yourself — there is no vocabulary for one, because an index that
does not follow from an arrow would be tuning, and tuning is not a presentation. No unique
constraints, no check constraints, no cascade — `DELETE` removes rows of the query's own table and
nothing else. `create_table` gives you columns, a primary key, and the indexes your morphisms asked
for; everything else is yours.

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
| repositories | five operations, and a "finder" is a **value**: `BY_CITY = ->(c) { SCHEMA[:users].where(:city, c) }` |
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
layer 1: add_attribute(:users, :city, :string, "unknown"), create_table(:posts, {:id=>:integer, :title=>:string, :author=>#<data Sodalite::DB::FK target=:users>})
expansion-only: true
```

`create_table :posts` is declared *last* and lands in layer 1 beside `add_attribute`, because the two
are independent and both need only `users`. Two branches that each appended a step therefore merge
without ceremony: the declaration order changed, the set did not. Inside a layer the steps are sorted
by fingerprint, which is why `add_attribute` prints first — a tie-break that is a function of content
means two runners flatten the same layers into the same order.

Contradictions are refused at declaration — two steps supplying one name, a requirement nobody
supplies, a cycle, or the same step declared twice. Reversibility is computed rather than promised:

```ruby
HISTORY.reversible_after?(0)   # => true
HISTORY.irreversible_steps     # => [] — a drop would appear here
```

`after` is a count of steps along `plan.order`, the solved order — the same number line
`rollback!(to:)` indexes, so the two cannot disagree about which prefix of the history a number
names. `schema_after` and `spec_after` read it the same way.

### A history cannot adopt a database it did not create

Every step declares what it requires, and the solver refuses a history whose requirements nobody
supplies:

```ruby
Sodalite::DB.history([:add_attribute, :users, :city, :string, 'unknown'])
# => MigrationError: requirements [:users] are not provided for
#    add_attribute(:users, :city, :string, "unknown")
```

So the first steps of any history are always the `create_table`s that bring every object into being.
There is no road from a database sodalite did not create — no `assume_table`, no baseline step, no
way to declare "this already exists". That is a design decision and not an oversight: a step that
asserted an object was already there would be a step whose meaning depends on the database rather
than on the history, and the whole ledger is built on the other premise. Adopting an existing
database means writing the history that would have produced it and seeding the ledger by hand.

### Two ordering defects, both one layer below the solver

The solved order is not the whole story. Two things are still read in **declaration** order, and both
raise where the solved order would have been fine:

- **`History` bootstraps its presentations by declaring them in sequence.** `Plan` needs a
  presentation per step *before* any order exists, so that one fold runs in declaration order. A
  `rename_table` or `split_table` written *before* the step that creates the object it operates on
  raises `KeyError: key not found: :users` at construction. Declare the creation first and it is
  fine. Ordinary steps are unaffected — `add_attribute` before the `create_table` of an unrelated
  table is exactly the case the solver exists for.
- **`merge_tables` claims its target with a wildcard.** It provides `people.*` rather than the fields
  it actually produces, so a later step that supplies a *new* name under the merged object cannot be
  scheduled: `merge_tables` then `add_attribute` on the merged table is refused as a
  `migration dependency cycle`. Adding the attribute to *both sources first* and then merging works,
  and is the same migration.

## 5. Ask questions of it: arrows

A query is a value built from the schema, not a string and not a method on an entity. Build the ones
your service asks once, at load time:

```ruby
BY_CITY = ->(city) { SCHEMA[:users].where(:city, city).order(:name) }
BUSIEST = SCHEMA[:posts].follow(:author).group(:city).count(:people).order(:people, :desc)
```

Vocabulary: `where`, `where_null` / `where_present`, order comparisons where the attribute type carries
an order, `follow(:fk)` to compose along a foreign key, `where_at` / `where_along` to filter along one
without following it, `group(...).count(...)` / `sum` / `min` / `max`, `having` (a subobject of the
*grouped* relation, which is why it is a different word rather than an overload),
`order(field, :asc | :desc)`, `limit` / `offset`, and `union`.

Comparing to `nil` is refused in every form, because SQL's answer to `x = NULL` is UNKNOWN. Say
`where_null` or `where_present` and mean it.

An unordered result is a **set** (`Relation`); an ordered one is a **sequence** (`Listing`). The
distinction is kept because it is real.

**`nothing` sorts after every element, in both directions.** An order has to be a function of the set,
and a nullable column carries the adjoined point outright — `min`/`max` fold a fibre that is entirely
nothing to it, so an ordering can meet a value no `?` in the schema mentioned. The backends had three
answers there and none of them was about cost: `DB.memory` raised, sqlite sorted nothings first,
postgres sorted them last. So the placement is stated rather than inherited, and it is *not* last
ascending and first descending — `nothing` is not an element being ordered, it is the point adjoined to
`A`, so reversing the order on `A` cannot move it.

```ruby
PLAYERS = Sodalite::DB.schema(players: { id: :integer, name: :string, score: :integer? })
# scores 5, 9, and one player who has none — the same two lines in all three models
model.select(PLAYERS[:players].order(:score)).map { |row| row[:score] }        # => [5, 9, nil]
model.select(PLAYERS[:players].order(:score, :desc)).map { |row| row[:score] } # => [9, 5, nil]
```

Both SQL models say it as `NULLS LAST` on every ordering term, which needs **SQLite 3.30 or newer**.
It is also what keeps a window meaning something: `order(:score, :desc).limit(3)` is the three largest
scores, not a presentation of three absences of one.

### `follow` moves the carrier; `where_at` does not

The question "which posts were written by someone in tokyo?" cannot be asked with `follow`, and the
reason is structural rather than a missing feature. `follow` is composition, so it moves the carrier
to the codomain: what comes back is *users*, and the posts were the thing being asked about.

```ruby
SCHEMA[:posts].follow(:author).where(:city, 'tokyo')   # => users
SCHEMA[:posts].where_at(:author, :city, 'tokyo')       # => posts
```

`where_at(path, field, …)` is the pullback. For a morphism `f : posts → users` and a subobject `S` of
users, `f*(S)` is a subobject of *posts* — the elements whose image under `f` lands in `S`. It emits
the same `JOIN` a composition emits and leaves the carrier where it was; which side of the span you
read is the whole difference. `where_along(%i[post author], …)` does the same along a path of more
than one hop.

It is `where` formed along a path, not a fourth primitive — phase one is still composition,
subobject, image. **An element whose morphism has no value is dropped**, in all three models: the
join has no row for it, so it is not in the subobject. That element is not silently lost, it is
already reported by `violations` as the dangling key it is.

Composition folds correctly, which is the part hand-written SQL usually gets wrong:

```sql
SELECT "g"."city", COUNT(*) AS "people"
FROM (SELECT DISTINCT "t1"."id", "t1"."name", "t1"."city"
      FROM "posts" "t0" JOIN "users" "t1" ON "t0"."author" = "t1"."id") "g"
GROUP BY "g"."city"
```

The subquery is the image of the composite. Without it the count would report multiplicities of the
join rather than elements of the image — two different numbers, and only one of them answers "how many
people".

Three models satisfy the same five operations:

```ruby
Sodalite::DB.memory(SCHEMA, seed)              # rows in Hashes, no database
Sodalite::DB.sql(SCHEMA, connection)           # anything answering execute(sql, binds)
Sodalite::DB.sequel(SCHEMA, Sequel.connect(…)) # dialects, pooling, type mapping
```

They are checked against each other, which is what makes the in-memory one usable as the thing your
tests run against rather than a stub returning what a test author decided.

**The mandatory port is still one method.** `execute(sql, binds) -> rows` is the whole of what
`DB.sql` requires, the gem depends on no driver, and every adapter written against it keeps working. A
connection may *also* answer `change(sql, binds) -> Integer` — how many rows the statement affected —
and `DB.sql` asks with `respond_to?` rather than taking a flag, so declaring it is a capability rather
than a requirement and there is nothing for a caller to get wrong. Where it is declared, a change or a
deletion is one statement:

```ruby
def change(sql, binds) = (execute(sql, binds); @db.changes)
```

```
# execute only                          # execute + change
BEGIN                                   UPDATE "items" SET "stock" = "stock" + ? WHERE "stock" > ?
SELECT COUNT(*) FROM "items" WHERE …
UPDATE "items" SET "stock" = …
COMMIT
```

Both answer `2`. Without `change` the count has to be *measured*, and measured before the statement,
because a change moves rows out of the subobject that named them — `stock = stock - 1` under
`stock > 0` is exactly that — with both readings in one scope so nothing can move a row between them.
A deletion is the same trade: with `change` it is one `DELETE` carrying the guard and no doomed row is
read at all; without it, the keys go out chunked and what left is measured against them.

**Prefer `DB.sequel` in production.** Both SQL models quote every identifier they emit, so a table
called `order` works in either; what is left is what a backend is for. Sequel spells `OFFSET` without
`LIMIT` per dialect rather than as one integer both accept, hands the driver its own placeholders,
maps `:boolean` to a type the driver can bind, and answers `transactional_ddl?` for itself instead of
being told. `DB.sql` is kept because three models checked against each other is a stronger claim than
two, and because it is the only one that shows what the compilation actually is.

### Deciding whether an answer went stale — a calculus, not a channel

A cache wants to know one thing: *may this answer still be used?* The obvious shape for that is a
push channel — subscribe to a query, get told when a write touches it. **This framework cannot have
one, and the reason is the design rather than the schedule.** A registry of live subscriptions has to
outlive the request that registered them and be written by a different request entirely, which is
process-global mutable state; there is no `Sodalite.configure`, the app freezes itself at boot, and
the only per-request state is one `Berylx::Root` that dies with the request. A subscription bus is
exactly the thing those three properties are the absence of.

The NDJSON and SSE streaming below is not that bus and should not be mistaken for it. A stream is a
**response framing** — one request writing many records down its own connection, with its state
inside its own `Root`. Nothing about it lets a *second* request reach the first one's socket.

So what is offered is the calculus, and a broker built on it is yours. Two pure functions, both
computed from values already in hand:

```ruby
DB = Sodalite::DB        # the shorthand every sample in this section is run under

query.reads              # Set<Address> — the places this arrow's answer depends on
DB.writes(tag, payload)  # Set<Address> — the places performing that operation dirties
```

with one property, and it is the whole point:

> if `writes(op)` is disjoint from `reads(q)`, performing `op` cannot have changed `q`'s answer.

Neither reads the database and neither remembers anything. `writes` takes exactly the `(tag, payload)`
pair you were about to hand `io.perform`, so the question is askable *before* the operation runs.

Both answer a frozen `Set`; every `# =>` below shows it as `to_a.sort`, because `Address` carries a
total order so that one set has one rendering and two of them compare as text in a test failure.

#### Two kinds of address, and why the split earns its keep

```ruby
DB::Address.elements(:posts)       # which elements the object has
DB::Address.field(:posts, :title)  # where one map out of the object sends them
```

That split is the reason any of this is worth having. An insert or a delete changes **which elements
exist** and nothing else. An update changes **where a map sends them** and cannot make an element
appear or disappear. A foreign key and an attribute are the same kind of thing here — both are maps
out of the object — so nothing about this is special-cased for references.

```ruby
DB.writes(DB::INSERT, [:posts, { id: 1, title: 'hello', author: 1 }])  # => [posts]
DB.writes(DB::DELETE, SCHEMA[:posts].where(:id, 1))                    # => [posts]
DB.writes(DB::UPDATE, [SCHEMA[:posts].where(:id, 1), { title: 'x' }])  # => [posts.title]
DB.writes(DB::SELECT, SCHEMA[:posts])                                  # => []
```

An `INSERT` names the object's elements and *not* the fields the row filled in, which is tighter and
still sound: every arrow over an object reads that object's elements, so naming them is enough. A
`DELETE` names the elements of the **carrier**, not of the root — a delete through a composition
removes elements of the codomain, which is the thing `confirm_carrier:` makes you say out loud. And
an `UPDATE` names the fields the changes name and *not* the elements, so an update to `posts.title`
leaves a query reading only `posts.id` alone. That is the case a scheme addressed at the table gets
wrong, and the case that makes the calculus worth computing.

#### The rule most easily missed: no projection means every field

A query with no `select` answers with **whole rows**, so it reads every map out of its final carrier
— including the ones nobody named:

```ruby
SCHEMA[:posts].select(:id).reads   # => [posts, posts.id]
SCHEMA[:posts].reads               # => [posts, posts.author, posts.id, posts.title]
```

Without that rule the calculus is unsound: an update to a column the arrow never mentioned would look
harmless while changing the answer it hands back. A fold has the same shape one layer on — a fold
cannot follow a projection, so `group(:city).count(:people)` reads the whole row of `users` too.

What contributes nothing is as deliberate. `having` names a fold's own output, which is computed here
rather than stored, so there is no place in the instance for it to name; a window chooses how much of
an order to hand back and consults no map to do it; an ordering on a fold's output names no place for
the same reason `having` does not.

```ruby
plain = SCHEMA[:users].group(:city).count(:people)
busy  = plain.having(:people, :gt, 1).order(:people, :desc).limit(3)
plain.reads == busy.reads   # => true
```

#### Composition, pullback, and the object each step is spoken against

`reads` walks the same steps the compiler walks, and agrees with it about the one thing that is easy
to get backwards: which object a step is spoken against. `follow` is composition and moves the
carrier; `where_at` emits the same join and leaves the carrier where it was.

```ruby
SCHEMA[:posts].follow(:author).select(:name).reads
# => [posts, posts.author, users, users.name]
SCHEMA[:posts].where_at(:author, :city, 'tokyo').select(:id).reads
# => [posts, posts.author, posts.id, users, users.city]
```

Every object the walk touches contributes its elements — the root, the codomain of every composition,
and every object a pullback path hops through. What a join reads of the object it lands on is that
object's elements and the morphism that reached it, not the target's key that the `ON` clause names.
That is sound rather than merely short: an update of a key is refused, so only an insert or a delete
can move one, and both dirty that object's elements, which is already in the set.

#### A worked example, end to end

Against the `SCHEMA` from section 2, an index of the names that have posted:

```ruby
model = DB.memory(SCHEMA, users: [{ id: 1, name: 'mina', city: 'tokyo' }],
                          posts: [{ id: 1, title: 'hello', author: 1 }])

INDEX   = SCHEMA[:posts].follow(:author).select(:name)
depends = INDEX.reads                          # => [posts, posts.author, users, users.name]
cache   = {}
fill    = -> { cache[:index] ||= model.select(INDEX).to_a }

fill.call                                      # => [{ name: "mina" }]

# a write that cannot have touched it
retitle = [SCHEMA[:posts].where(:id, 1), { title: 'rewritten' }]
DB.writes(DB::UPDATE, retitle)                 # => [posts.title]
depends.disjoint?(DB.writes(DB::UPDATE, retitle))  # => true
model.update(*retitle)
fill.call                                      # => [{ name: "mina" }]   — still valid, not recomputed

# a write that did
rename = [SCHEMA[:users].where(:id, 1), { name: 'minamorl' }]
DB.writes(DB::UPDATE, rename)                  # => [users.name]
depends.disjoint?(DB.writes(DB::UPDATE, rename))   # => false
cache.delete(:index)
model.update(*rename)
fill.call                                      # => [{ name: "minamorl" }]
```

An insert into `posts` meets it too, and through the other kind of address:

```ruby
insert = [:posts, { id: 2, title: 't', author: 1 }]
DB.writes(DB::INSERT, insert)                  # => [posts]
depends.disjoint?(DB.writes(DB::INSERT, insert))   # => false
```

`INDEX` starts at `posts`, so it reads the elements of `posts`, and an insert is exactly a change to
which elements there are. The broker is those lines: a set, a `disjoint?`, and whatever storage you
were already using.

#### Why the granularity stops at the column

Fibre granularity — `posts.author=2` rather than `posts.author` — would be strictly more precise.
A query reading `where(:author, 1)` is genuinely not stale when an update moves rows from author 2 to
author 3, and this calculus says it might be:

```ruby
mine = SCHEMA[:posts].where(:author, 1).select(:id)
mine.reads                                                                # => [posts, posts.author, posts.id]
moved = DB.writes(DB::UPDATE, [SCHEMA[:posts].where(:author, 2), { author: 3 }])
moved                                                                     # => [posts.author]
mine.reads.disjoint?(moved)                                               # => false
# a false positive: no row of author 1 moved, and the calculus cannot see that
```

It is refused because it **cannot be computed purely**. Naming the fibres an update dirtied means
knowing which fibres the matched rows were in *before* the write, and that is a read — read-then-write
being the exact shape `UPDATE` exists to remove. And the guard need not be an equality at all:
`where(:stock, :gte, 1)` names no fibre to be dirtied.

So the false positives are accepted, deliberately and on one side. A false positive rebuilds something
that did not need rebuilding; a false negative serves a stale answer. The error is taken on the side
that is only wasteful.

#### `ATOMICALLY` is refused, and specifically not answered with the empty set

```ruby
DB.writes(DB::ATOMICALLY, [:checkout, workflow])
# => WritesError: a scope does not say what it writes — its payload is a berylx workflow, a task
#    tree, and what a task tree performs is not decidable from the value; union the writes of the
#    operations composed inside it, because the empty set would claim the scope dirties nothing and
#    that is the one answer certainly wrong
```

A scope's payload is a task tree, and what a task tree performs is not a function of the value. The
empty set would be a claim that the scope dirties nothing — the one answer certainly wrong — so it
refuses instead. Union the writes of the operations you composed inside it. A tag that is not one of
the five refuses for the same reason: nothing is known about it, and nothing known is not `[]`.

#### Why it takes `(tag, payload)` rather than being a return value

The other way to get this answer is to have the operations *report* what they dirtied. That widens
the effect signature, which is fixed at five and is the thing three models agree about. Computing it
from the same payload the caller was going to perform means the framework gains a **function and no
state**, and the question can be asked before the write rather than after it.

#### The limit, stated plainly

A schema may be **finitely presented**, and query normalisation rewrites a path using a declared
equation. `reads` then describes the path the query was normalised *to*:

```ruby
COMPANY = {
  employees:   { id: :integer, name: :string, manager: DB.fk(:employees),
                 department: DB.fk(:departments) },
  departments: { id: :integer, title: :string }
}
PRESENTED = DB.schema(**COMPANY, equations: [[:employees, %i[manager department], %i[department]]])
FREE      = DB.schema(**COMPANY)

PRESENTED[:employees].follow(:manager).follow(:department).select(:title).reads
# => [departments, departments.title, employees, employees.department]
#    no employees.manager — the equation rewrote the path away
FREE[:employees].follow(:manager).follow(:department).select(:title).reads
# => [departments, departments.title, employees, employees.department, employees.manager]
```

That is consistent rather than broken: every model evaluates the **normalised** arrow, so the set
describes exactly the answer that was computed. What scopes it is that the normalised arrow means
what you wrote only on an instance that satisfies its declared equations. On one that does not, the
two schemas above answer the same written query differently, and only the second is affected by an
update to `manager`:

```ruby
seed = { employees:   [{ id: 1, name: 'a', manager: 2, department: 10 },
                       { id: 2, name: 'b', manager: 2, department: 20 }],
         departments: [{ id: 10, title: 'eng' }, { id: 20, title: 'ops' }] }

DB.memory(PRESENTED, seed).equation_violations
# => ["employees.id=1: manager.department = 20 but department = 10"]
DB.memory(PRESENTED, seed).select(PRESENTED[:employees].follow(:manager).follow(:department).select(:title)).to_a
# => [{ title: "eng" }, { title: "ops" }]
DB.memory(FREE, seed).select(FREE[:employees].follow(:manager).follow(:department).select(:title)).to_a
# => [{ title: "ops" }]
```

That is the standing referential integrity already has here — **reported, not enforced** — so the
property holds for instances that are functors satisfying their equations, and `functor?` /
`violations` / `equation_violations` are how you ask whether yours is one. Nothing about `reads`
detects a violating instance on its own; it is a scoped claim rather than an unconditional one.

---

# Part II — put it behind HTTP

## 6. Reach the data from a request

The database is not a set of invented verbs. The signature is fixed and small:

```
SELECT(query)          -> Relation
INSERT(table, row)     -> key
UPDATE(query, changes) -> count
DELETE(query)          -> count
ATOMICALLY(subtree)    -> Ok / Err
```

so a task asks for what it wants by tag, and the handler map decides what answers:

```ruby
load_user = Berylx::Task[:load_user] do |lay, io|
  found = io.perform(Sodalite::DB::SELECT, SCHEMA[:users].where(:id, lay[:request].get.params.id))
  found.empty? ? lay.reject(:not_found, 'no such user') : lay[:user].set(found.rows.first)
end
```

### Changing a value is `UPDATE`, and the reason is not convenience

Four operations can already change a value: `SELECT` the row, `DELETE` it, `INSERT` the changed
version, inside `atomically`. That is atomic, and atomic is not enough. A plain `BEGIN` on postgres is
READ COMMITTED, so two scopes both read `stock = 1`; the second's `DELETE` blocks until the first
commits, then re-evaluates its `WHERE` against a row that is already gone, removes nothing, and inserts
a row computed from the read it took before any of that happened. One decrement is lost and the item is
oversold.

A fifth operation that only assigned literals would carry the same hazard, because the hazard is not
the number of statements — it is where the new value came from. `SET stock = 0` computed that `0` from
a read taken earlier, and the row it lands on need not be the row that was read. What removes it is
writing the change as a **function of the current value**, with the guard evaluated **inside the same
statement**:

```ruby
SHOP = Sodalite::DB.schema(
  items:  { id: :integer, name: :string, stock: :integer },
  orders: { id: :integer, item: Sodalite::DB.fk(:items) }
)
IN_STOCK = ->(id) { SHOP[:items].where(:id, id).where(:stock, :gt, 0) }

reserve = Berylx::Task[:reserve] do |lay, io|
  taken = io.perform(Sodalite::DB::UPDATE,
                     [IN_STOCK.call(lay[:item].get), { stock: Sodalite::DB.add(-1) }])
  taken.zero? ? lay.reject(:sold_out, 'nothing left to reserve') : lay[:taken].set(taken)
end
```

Run twice against one unit of stock — the same two lines from `DB.memory` and from `DB.sql`:

```
Ok  taken=1
Err sold_out: nothing left to reserve
```

```sql
UPDATE "items" SET "stock" = "stock" + ? WHERE "id" = ? AND "stock" > ?
```

The `0` is the point. A caller learns it lost the race *from the count*, rather than by reading the row
back and finding stock below zero. The engine evaluates `stock > 0` while it holds the row and computes
`stock + (-1)` from whatever the value is by then, so there is no earlier read for either scope to have
acted on. The arrow never sees the value, which is what leaves nothing for it to have seen too early.
(`DB.memory` reaches the same place by a different route — it names the rows and applies the change
under one monitor — which is why the two print the same two lines.)

**The vocabulary is closed.** `DB.add(delta)` and `DB.set(value)`, and a bare value in the changes Hash
means `:set` — `{ state: 'sold' }` and `{ state: DB.set('sold') }` are one change. There is no
`subtract`: a decrement is `add` of a negative delta, which leaves one operation to check, one to
compile, and one for three models to agree about. It is deliberately not an expression language, on the
rule that kept `avg` out of the aggregates — what is offered is what carries a law.

**What an update refuses**, all of it when the call is made and before any statement is emitted:

| refusal | why |
| --- | --- |
| everything a deletion refuses — a projection, a fold, a coproduct, a window | an update names rows of the carrier, and none of those is a subobject of them |
| a composition that moved the carrier, unless `confirm_carrier:` says so | the rows are the codomain's, which is almost never what was meant |
| a **pullback** guard (`where_at` / `where_along`) | a join inside `UPDATE` is dialect-bound, so evaluating that guard means an earlier `SELECT` — the lost update this exists to remove |
| an empty change | the identity; a statement that changes nothing is not an operation on rows |
| the carrier's **key** | identity is not a value to reassign, so the models would no longer agree about which row they changed |
| `:add` on a column whose type carries no addition | strings have concatenation, which is a different monoid; times have a difference and no sum |

A *composition* is allowed where a pullback is not, and the difference is that it can be compiled
without leaving the statement: the join goes in a subquery and the update names its rows by the key
that subquery selects.

```ruby
model.update(SHOP[:orders].where(:id, 10).follow(:item),
             { stock: Sodalite::DB.add(-1) }, confirm_carrier: :items)
# UPDATE "items" SET "stock" = "stock" + ? WHERE "id" IN (
#   SELECT "t1"."id" FROM "orders" "t0" JOIN "items" "t1" ON "t0"."item" = "t1"."id"
#   WHERE "t0"."id" = ?)
```

Two semantics all three models agree on, and both come up in ordinary use:

- **`:add` on a `nothing` leaves the `nothing`, and the row still counts.** A nullable column is a map
  into `A + 1`; `+ delta` is a function on `A`; exactly one extension of it to `A + 1` leaves the
  coproduct alone — `+ delta` on `A`, the identity on the adjoined point, which is fixed because there
  is no element there to add to. It is also what SQL computes unaided, since `NULL + 1` is `NULL`, so
  no model needs a special case. Reading the nothing as zero would invent an element the instance never
  recorded.
- **The count is rows the change was applied to**, not rows whose value came out different.
  `DB.add(0)` counts its row. Anything else would mean reading values back to compare them, and it is
  what a SQL `UPDATE` reports on its own.

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

**One step is one transaction, so a database without transactional DDL is refused.** `DB.sql` cannot
ask its port whether DDL survives a rollback — `execute(sql, binds) -> rows` has nowhere to put the
question — so the caller answers once, where the connection is built:

```ruby
Sodalite::DB.sql(HISTORY, connection, transactional_ddl: false).migrate!(HISTORY)
# => MigrationError: Sodalite::DB::Sql cannot migrate!: this database has no transactional DDL,
#    so a step would be carried outside a transaction and an interruption could leave the schema
#    changed with nothing in the ledger, ...
```

`true` is the default, because SQLite and Postgres both have it; a model over MySQL says `false` and
is refused both `migrate!` and `rollback!` rather than left to half-apply a step. There is no
override keyword, because a refusal that an argument can waive is not a refusal. `DB.sequel` answers
the question for itself and is never asked.

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

### `verify!` reads the ledger and nothing else

That is the premise the three answers above rest on, and it should be said out loud rather than
inferred: what a database *is* has one recorded history, and the ledger is it. Nothing reads the
catalog, compares column types, or looks at a single row.

The consequence is that **a database someone hand-altered passes**. A column added by hand, a table
dropped by hand, a type widened by hand, a row rewritten by hand — none of it is visible to `verify!`,
so a database can hold the right fingerprints and not have the shape the history describes.

That is the right default rather than a gap left open. A boot check that re-derived the shape from the
catalog would be a second opinion about what the database is, and it would have to be told which
differences are allowed — because an unapplied contraction is a legal difference, and so is an index
somebody added on a slow morning. One truth that can be wrong beats two that disagree.

`create_tables_for_test!` is the same gap from the other side: it builds the whole schema in one shot
with **no ledger entries at all**, so `verify!` refuses the result with *database is missing required
migrations*. That is exactly why it is named that way. Anything that boots goes through `migrate!`.

### Every fingerprint changed, so an older ledger is not recognised

A step's identity is its content, and the ledger is keyed by the content address. That address is now
a normalised, prefix-free serialisation under a `v1` scheme tag: a Hash's keys are sorted, an Array's
order is kept, each atom names its kind and its byte length, and the scheme tag is inside the digest
input rather than beside it. It replaces `args.inspect`, which rendered a Hash in insertion order and
therefore minted a second address whenever someone permuted the fields of a `create_table` — a
refactor that changes no meaning, turning an applied step into an unapplied one.

The price of fixing that is paid once, and it is not small: **every fingerprint changed.** A database
migrated under the old scheme presents a ledger this code does not recognise. `verify!` sees a ledger
with no fingerprint it declares and refuses, and `migrate!` would carry every step again against a
shape that already has it.

There is no automatic conversion, because writing one would mean keeping the old normalisation around
to recompute the addresses it produced, and a scheme tag whose predecessor is still in the code is not
a scheme tag. The recovery is to re-seed the ledger by hand: compute `HISTORY.fingerprints` under this
checkout and rewrite the `fingerprint` column of `sodalite_migrations` to match, step for step, before
starting the new code against it.

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

### What `add_attribute` costs, and where it stops being free

The induced map on instances says the column is the constant default, while `ALTER TABLE ADD COLUMN`
leaves existing rows `NULL`, so something has to fill them. The default is therefore declared in the
DDL, where Postgres 11+ and SQLite give existing rows their value by reading the schema rather than by
touching a row:

```
ALTER TABLE "users" ADD COLUMN "city" TEXT DEFAULT 'unknown'
UPDATE "users" SET "city" = ? WHERE "city" IS NULL
```

The `UPDATE` is the fallback, narrowed to the rows still missing a value — which makes it a no-op
wherever the declaration already worked, and safe to run again after an interrupted migration.

**On a backend where the declaration does not fill, it is one full scan**, under a lock, and on a
table large enough to be worth migrating that is the whole cost of the migration. Cutting it into key
ranges would need the emitter to know how many rows there are, and it knows the presentation and
nothing about the instance. So the limit is honest: `add_attribute` is an expansion and it is cheap on
the two backends named above; anywhere else, measure before you apply it to a large table.

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
dangling foreign key fails the test. It exists on all three models, so the same assertion is
available against a real database — but nothing calls it for you, in a test or in production, which
is what makes writing it down worth the line.

A suite that wants a real database and has no history to build one from asks for the shape directly:

```ruby
Sodalite::DB.sql(SCHEMA, connection).create_tables_for_test!
Sodalite::DB.sequel(SCHEMA, database).create_tables_for_test!
```

Tables, primary keys, and the indexes the morphisms asked for, in one shot — and **no ledger entries**,
which is why it says `for_test`. A database built this way is refused by `verify!`, so it cannot become
the way something boots by accident.

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
| `MigrationError`: *another migration is running* | the lock is held, and the message names the holder and how long it has held it |
| `MigrationError`: *has no transactional DDL* | `transactional_ddl: false`; a step could be half-applied with nothing in the ledger, so nothing ran |
| `MigrationError`: *requirements … are not provided* | a history with no `create_table` for an object it operates on; there is no way to adopt an existing database |
| `KeyError`: *key not found* from `DB.history` | a `rename_table` or `split_table` declared before the step that creates its object; presentations bootstrap in declaration order |
| `SchemaError`: *arrives at* / *has no morphism* | a path equation whose sides land on different objects, or that names a morphism the schema does not have |
| `QueryError`: *has no morphism … to pull back along* | a `where_at` / `where_along` path that is not a path in the schema |
| `QueryError`: *needs a subobject of …* | `delete` or `update` through a projection, a fold, a coproduct, or a window |
| `QueryError`: *would change rows of …* | a composition moved the carrier; pass `confirm_carrier:` to mean it |
| `QueryError`: *cannot be guarded by a pullback* | an update guarded by `where_at` / `where_along`; the guard has to be evaluated inside the statement, and a join there is not portable |
| `QueryError`: *needs a change* | an empty changes Hash, which is the identity |
| `QueryError`: *is the identity of a row, not a value to reassign* | a change of the carrier's key |
| `QueryError`: *carries no addition* | `DB.add` on a column whose type has no sum |
| `WritesError`: *a scope does not say what it writes* | `ATOMICALLY` handed to `DB.writes`; what a task tree performs is not a function of its value, so union the operations inside it |
| `WritesError`: *is not one of the five operations* | a tag `DB.writes` knows nothing about, and nothing known is not the empty set |
| 500 with `contract` in the log | the response did not fit its declared schema under `Effects.real` |
| 400 on `?page=` | an empty query value is present-and-empty, not absent |

Clearing a stale lock is explicit and never automatic — a lock that lets go of itself after a timeout
is not a lock:

```ruby
# a lock old enough to be stale — it goes, and the receipt says whose it was
model.steal_lock!(older_than: 900)
# => "cleared the migration lock held by <host>:<pid> since 2026-08-05T05:19:45Z (1204s)"

# a lock younger than that — it stays, and the refusal says by how much
model.steal_lock!(older_than: 900)
# => MigrationError: the migration lock is 12s old, which is younger than the 900s asked for,
#    so it was left alone; <host>:<pid> may still be working
```

`older_than` is in seconds and has no default, because only the caller knows how long the migration it
is about to displace normally takes. The lock row carries the holder and the acquisition time, so both
the refusal and the receipt name a runner instead of speculating that one crashed. (`<host>:<pid>` and
the timestamp are what the running process wrote; the wording around them is verbatim.)

**Not implemented, on purpose or not yet:** database-level foreign key constraints, unique and check
constraints, indexes beyond the one each foreign key column gets, composite keys, declared headers,
wildcard route segments, `Π_F` (folding two tables into one by a product over a shared key), an
`empty_as_absent` decode option, RBS for a whole route, a cache or an invalidation *channel* (the
calculus is offered, the broker is yours — see "Deciding whether an answer went stale" above), and
durability — work that must survive a restart belongs in a durable engine, not here.
