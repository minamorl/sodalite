# The RDBMS boundary, categorically

**Implemented and green.** `lib/sodalite/db/`, `test/db_test.rb`, `test/db_conformance_test.rb`.

Sodalite already says the world is a parameter. Today that world is a bag of lambdas: a route performs
`:find_user`, and a handler map answers it. That works, and it is also the weakest part of the design,
because the bag has no laws. Nothing relates `:find_user` to `:insert_user`. Nothing says the fixed
handlers and the real handlers are two versions of the same thing. A test passes because someone wrote
a stub that happened to return the right shape.

This note works out what the database boundary looks like once that gap is closed, and what the
existing pieces already force. The three-model conformance suite in section 5 is the part that turns the
argument into something a test runner can settle.

## What is already categorical here

Worth being precise, because the answer is "most of it", and the question is only how far to carry it.

- **darkcore** is the free monad over a signature. `bind` grafts structure and carries no algebra; the
  algebra lives in `fold`'s `on_return` and in the handler map. That is the universal property, stated
  as a design rule: a handler map is a natural transformation `F ⟹ M`, and it extends uniquely to
  `Free(F) → M`. "Swap the handler map to choose a category" is not a metaphor in this codebase.
- **berylx** is the Kleisli category of `Result` over `Lay`. `Task : Lay → Result[Lay]`, `>>` is Kleisli
  composition, and short-circuiting is `bind`. The `parallel` split is the real one: `short_circuit` is
  monadic, `accumulate` is applicative — `Validation` accumulates because its `ap` is a lax monoidal
  product rather than a `bind`, which is exactly why darkcore singles it out as its one deliberate
  exception.
- **zeolite** gives objects their types. A schema compiles to a `Data` class; a parse is a partial map
  into it that reports where it failed.

So there is a free structure, a Kleisli category for effects, and a type discipline for values. The
database is the piece that has no theory yet.

## 1. A schema is a category, an instance is a functor

This is Spivak's account, and it is the right starting point because it is about *schemas*, which is
what we lack, rather than about queries, which we could hack.

A schema is a finitely presented category **C**:

- **objects** — tables (`users`, `posts`)
- **morphisms** — foreign keys (`author : posts → users`)
- **attributes** — morphisms into leaf objects (`name : users → String`)
- **path equations** — the integrity constraints, written as equalities between composites

An **instance** is a functor `I : C → Set`. Each table goes to its set of rows; each foreign key goes
to an actual function between those sets. A dangling foreign key is not a bad row, it is a failure to
be a functor.

Which decides how the failures are counted, and it is not a rounding decision. The morphism fails to
have a value **at an element**, so two posts pointing at one absent user are two failures rather than
one: `violations.size` is the number of elements where the functor does not exist, which is what "how
far from being a functor" has to mean. Deduplicating by the missing key would answer a different
question — how many holes there are in the target — and all three models report the multiplicity, on
a sentence that comes from the schema and that all three sort on.

The part that matters for this codebase: **zeolite already supplies the attribute types.** A row type
is a zeolite schema, a row is a generated `Data`, so `I(users)` is a set of `User` values with the same
type discipline as the HTTP boundary. That is not a coincidence to enjoy, it is the reason this is
worth doing here rather than in a general-purpose ORM: one vocabulary types the request, the row, and
the response.

Declaration stays data, in the same posture as everything else:

```ruby
DB = Sodalite::DB.schema(
  users: { id: :integer, name: :string },
  posts: { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }
)
```

**The path equations are real now, and they are what "presented" buys.** Declaring none leaves the
*free* category on the graph of foreign keys, and in a free category no two distinct paths are ever
equal — so the fourth bullet above could be written in the note and not in the schema:

```ruby
PRESENTED = Sodalite::DB.schema(
  employees:   { id: :integer, name: :string, manager: Sodalite::DB.fk(:employees),
                 department: Sodalite::DB.fk(:departments) },
  departments: { id: :integer, title: :string },
  equations:   [[:employees, %i[manager department], %i[department]]]
)
```

Two things follow, and they are different in kind. The first is a constraint SQL's foreign keys
cannot express at all: a foreign key relates one column to one key, never one path to another, so
this has nowhere to live except the presentation. It is **reported, not enforced** — the same
standing as referential integrity, one layer up — and `equation_violations` is how it is asked:

```ruby
model.equation_violations
# => ["employees.id=3: manager.department = 1 but department = 2"]
```

The second is a query normalisation. A trailing run of compositions is rewritten to the shortest path
the equations prove equal to it, so `follow(:manager).follow(:department)` compiles to one join rather
than two. That optimisation is **derived from the schema rather than guessed at**: nothing reads data,
statistics, or a hint — it reads a declared equality between two composites and takes the shorter one.

Which makes the caveat exact rather than nervous. The rewrite is sound relative to the **declared
theory**, which is weaker than sound. An instance that violates the equation answers differently after
it; so does one where a morphism on the longer path has no value at some element, because the longer
path drops that element and the shorter one keeps it. That is precisely the standing of a dangling
foreign key — a failure to be a functor into the presented category — and it is the same bargain,
reported by the same kind of call and enforced by nothing.

## 2. Three phases, because they have three different sets of laws

The first draft of this note said ordering and aggregation live outside a regular category, so they
should be raw SQL. That is true about the category and useless as a design: a service without
`GROUP BY` and `ORDER BY` is not a service.

The mistake was treating "outside the fragment" as "outside the library". They are outside the
*arrow*, which is a different claim. So the pipeline has three phases, held in three different places
in the query rather than mixed into one list of steps:

```
arrow in C     composition / subobject / image     -> Relation, a set
fold           a fold along the fibers of a map    -> Relation of groups
presentation   a total order, then a window on it  -> Listing, a sequence
```

Each phase is optional, their order is fixed, and **all three are covered by the conformance suite** —
the discipline extends rather than stopping at the fragment's edge.

### Phase one: the arrow

| operation | category-theoretic content | SQL |
| --- | --- | --- |
| `follow` | composition in C, then image | `JOIN` … `DISTINCT` |
| `where` | a **subobject** | `WHERE` |
| `where_at` / `where_along` | the **pullback** `f*(S)` | `JOIN` … `WHERE`, read from the other side |
| `select` | **image factorization** | `SELECT DISTINCT` |

Composition, finite limits, and image factorization is a **regular category**. `UNION` needs
coproducts; `NOT` needs Boolean structure, which is where SQL becomes three-valued logic. There is no
`join` in the language: a join is what a compiler emits for a composition, and writing one by hand is
implementing composition by hand.

The pullback is the row that had to be added, and the reason is worth naming because it is not a
convenience. `follow` composes and therefore moves the carrier to the codomain, so "posts whose author
lives in tokyo" was unsayable: the composite yields users, and the posts were the thing being asked
about. For `f : posts → users` and a subobject `S` of users, `f*(S)` is a subobject of *posts*, and
that is what `where_at(:author, :city, 'tokyo')` builds. It emits the same join a composition emits
and leaves the carrier where it was — which side of the span the result is read from is the entire
difference. It is not a fourth primitive: it is `where` formed along a path, and phase one is still
composition, subobject, image.

The dedupe follows from the same fact rather than from a rule about it. `SELECT DISTINCT` is dropped
where it is provably redundant: a pullback join is taken along a *function*, so every element has
exactly one image and the row source cannot repeat a row of the carrier, and with no `follow` at all
the carrier's key in the output already makes the tuples distinct. Only `follow` gives the image
factorization work to do, because only `follow` lands on a codomain whose fibres can hold more than
one element.

### Phase two: the fold

`GROUP BY key` takes the map `key : A → K` and partitions A into its **fibers**. An aggregate is a
fold over each fiber into a **monoid**, and that is not decoration — it says exactly which aggregates
are well behaved:

| aggregate | monoid |
| --- | --- |
| `count` | `(ℕ, +, 0)` |
| `sum` | `(ℕ, +, 0)` |
| `min` / `max` | `(A + 1, min/max, nothing)` — the identity is not in `A`, so it is adjoined |

`avg` is deliberately absent: it is **not a monoid**, because averages do not combine associatively.
Every implementation that offers it computes the pair `(sum, count)` and divides at the end, so write
that pair and keep the division outside the fold, where it belongs. Notice that `min`/`max` adjoin the
same `A + 1` that makes a nullable column honest — the two show up for one reason.

### Phase three: the presentation

An order does not change the set. It chooses a presentation of it — an iso to `{1..n}` — which is why
an ordered query returns a `Listing` and not a `Relation`, and why `Relation` has no `first`. Two
rules fall straight out and both are build errors:

- **A window needs an order.** `LIMIT` without `ORDER BY` is not a function of the set; it is whatever
  the storage engine felt like. Paginating on one is how rows repeat and vanish between pages.
- **An order must be total**, or ties break arbitrarily and the models are free to disagree. So
  the identifying fields are appended, and `total_ordering` is what actually runs.

And one that had to be *decided* rather than derived. The order is on `A + 1`, because that is what a
presentation actually has to order: a nullable column carries the adjoined point outright, and phase
two hands one over unprompted, since `min`/`max` are monoids on `(A + 1, min/max, nothing)` and a fibre
that is entirely nothing folds to the identity. So an ordering meets a value the column's declared type
never mentioned, and the three backends each had an answer of their own there — `DB.memory` raised,
sqlite sorted the nothings first, postgres sorted them last. Two SQL backends disagreeing with each
other is a disagreement about a value, not about cost.

**`nothing` sorts after every element of `A`, in both directions.** Not last ascending and first
descending: it is not an element being ordered, it is the point adjoined to `A`, so the order on `A`
never reaches it and reversing that order cannot move it. One rule, no case analysis, and the emitted
text says which order it is — `NULLS LAST` on every ordering term in both SQL models, which is the
sentence `DB.memory` spells as a comparison that puts `nil` last before the direction is applied.
(`NULLS LAST` needs SQLite 3.30 or newer.) It is also what keeps a window meaning something:
`order(:score, :desc).limit(3)` is the three largest scores rather than a presentation of three
absences of one.

### The write side: an arrow names rows, and a change is a function of their values

Phase one yields a **subobject**, and a subobject is the argument two operations other than `Select`
take. `Delete` removes the rows it names; `Update` applies a change to them. Neither is a fourth
phase — they consume phase one and refuse the other two, because a fold yields groups and a
presentation yields a chosen sequence, and neither of those is a set of rows of the carrier.

What `Update` adds to that refusal is one more, and it is the reason the operation exists rather than a
detail of it: **its guard cannot be a pullback.** A pullback compiles to a join, a join inside an
`UPDATE` is dialect-bound (`UPDATE … FROM` on postgres, another spelling elsewhere, nothing portable),
and the only portable way to allow it is to evaluate the guard in a `SELECT` taken before the
statement — which is exactly the stale read the operation was built to remove. A *composition* is
allowed, because it can be compiled without leaving the statement: the join goes in a subquery and the
statement names its rows by the key that subquery selects.

The change itself is a closed vocabulary, `:set` and `:add`, and the closure is the same discipline as
`avg`'s absence. `:add` names the column on both sides, so the new value is computed by the engine from
whatever the old one is by the time it holds the row:

```sql
UPDATE "items" SET "stock" = "stock" + ? WHERE "id" = ? AND "stock" > ?
```

Two readings follow from `A + 1` and from what a count can honestly mean, and all three models agree on
both. **`:add` on a `nothing` leaves the `nothing`, and the row still counts**: `+ delta` is a function
on `A`, and exactly one extension of it to `A + 1` leaves the coproduct alone — the identity on the
adjoined point, which is fixed because there is no element there to add to. It is what SQL computes
unaided, since `NULL + 1` is `NULL`, so no model needs a special case. And **the count is rows the
change was applied to**, not rows whose value came out different: `add(0)` is the identity on a value
and still a change applied to a row, and rows-applied-to is the number a compiling model can report
without reading values back to compare them.

### What the conformance suite caught

The first version of the grouped SQL folded straight over the join. It was wrong, and nothing about
the SQL looked wrong:

```ruby
posts.follow(:author).group(:city).count(:people)
# memory: tokyo=1  (mina)          <- the image: a set of users
# sql:    tokyo=2                  <- the pullback: one row per post
```

`follow` is composition **followed by image factorization**, so it yields a set. A SQL `JOIN` yields
the pullback, which keeps one row per pair — so folding over the join counts multiplicities of the
join rather than elements of the image. The image has to be materialised before the fold:

```sql
SELECT "g"."city", COUNT(*) AS "people"
FROM (SELECT DISTINCT "t1"."id", "t1"."name", "t1"."city"
      FROM "posts" "t0" JOIN "users" "t1" ON "t0"."author" = "t1"."id") "g"
GROUP BY "g"."city"
```

This is the whole argument for checking one model against another, arriving on the first extension
after it was written — back when there were two of them. One model alone would have been
self-consistently wrong.

Every identifier the compiler emits is quoted, in both SQL models, so a schema is free to name an
object `order` or an attribute `select`. Values were never the exposure — they are bound — but a
reserved word interpolated bare is broken SQL, and refusing the name would be the model deciding what
the schema is allowed to say.

## 3. The effect signature should be the relational theory, not the application's verbs

This is the actual change, and everything else follows from it.

Today:

```ruby
handlers = Sodalite::Effects.real(find_user: ->(id) { ... }, insert_user: ->(name) { ... })
```

The signature is whatever verbs the app invented. There are no equations, so a handler map is a model
of nothing in particular.

Instead, let the database part of the signature be fixed and small:

```
Select(Query[A])            -> Relation[A]
Insert(Table, Row)          -> Key
Update(Subobject, Delta)    -> Count
Delete(Subobject)           -> Count
```

Now a handler map for these four is a **model of the relational theory over C**. `find_user` stops
being an effect and becomes what it always was — a named query, i.e. an arrow in C, built once and
reused. Application verbs remain available for things that genuinely are effects (send mail, charge a
card); they just stop being how you reach your own data.

**That shape is what got built, `Delta` included.** The code shipped three of these four first —
`Select`, `Insert`, `Delete`, with the scope of section 4 as a tag of its own — and `Update` arrived
last, long after, which makes it worth saying that the proposal is not being ticked off but
vindicated. The row that reads
`Update(Subobject, Delta) -> Count` had already decided three things that the four-operation spelling
of "change a value" gets wrong, and they are the three that matter:

- the first argument is a **subobject**, not a key list, so the guard is part of the operation rather
  than the result of an earlier query;
- the second is a **`Delta`**, not a `Row`. A row is the new value; a delta is a *function of the old
  one*. That distinction is the whole difference between an update that is safe under READ COMMITTED
  and one that is not, and it was written down before anything depended on it;
- the answer is a `Count`, which is what makes losing a race observable.

Section 7.4 works through why a `Row` there would not have been enough. The vocabulary that
`Delta` became is closed — `DB.add(delta)` and `DB.set(value)`, with a bare value meaning `:set` — on
the same rule that keeps `avg` out of phase two: what is offered is what carries a law. `add` with a
signed operand is one arrow rather than two spellings of one, so there is one thing to check, one to
compile, and one for three models to agree about.

The signature the code exports adds the scope, so it is five tags rather than four
(`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `ATOMICALLY`) — and the fifth is the subject of the next
section rather than a query at all.

The payoff is in the next two sections, and it is the only reason to bother.

## 4. A transaction is a combinator handler, and rollback is what `Err` means to it

A transaction is not a query. It is not about data, it is about a *scope in time*, so it belongs to the
effect layer.

berylx already has this shape. `Parallel`, `Branch`, and `Rescue` are nodes whose payload is
`[node, focus]` — inspectable data — and whose handler runs the subtree with the same handler map. A
transaction is the same pattern:

> open a transaction, run the subtree under the same map, commit on `Ok`, roll back on `Err`.

And it composes with what berylx already guarantees. A sequence short-circuits at the first `Err`, so
the transaction handler receives `Err(partial_lay, error)` — which means the rollback already knows
**which named task failed and with what state**. That is a saga's compensation data, arriving for free,
because failure was never allowed to degrade into an exception.

Nested scopes map to savepoints. Dry-run is a handler that never commits. An audit aspect built with
`Effects.around` sees the transaction boundary because `around` propagates into subtrees.

**One measured constraint.** `Berylx::EffectTree.compile` is a closed `case` over
`Task / Sequence / Parallel / Branch / Rescue / Catch`; an application cannot add a seventh node type
from outside. But `EffectTree.run(node, focus, handlers:)` is public, so a handler *can* run a berylx
node with the same map. So:

- **Prototype** with an ordinary effect whose payload is a berylx node —
  `io.perform(:atomically, [sub_workflow, lay])` — and the handler calls `EffectTree.run`. Zero berylx
  changes.
- **Promote** to a real combinator (`Berylx::Atomic`) only if it earns it. That touches berylx's
  `compile` and `berylx.spec`, so it is a converter-and-human-gate change, not an ad-hoc edit.

Do not skip to the second step. The surface is nicer, and nicer is not a reason to move a pin.

## 5. Three models of one theory — where this stops being philosophy

With a fixed signature, the interesting handlers are not stubs. What was written here as two is three
in the code, and the names are these:

- `DB.sql(schema, connection)` — the hand-written model. `Select` compiles the arrow to SQL text and
  binds, with no driver anywhere near it; the mandatory port is one method,
  `execute(sql, binds) -> rows`. A connection may *also* answer `change(sql, binds) -> Integer`, the
  rows a statement affected — the one thing `execute` structurally cannot report. It is asked with
  `respond_to?` rather than configured, so it is a capability a connection declares rather than a
  requirement placed on every connection: existing adapters keep working untouched, and the gem still
  depends on no driver. Where it is declared, a change or a deletion is one statement carrying its own
  guard; where it is not, the count is measured over the same guard inside one scope.
- `DB.sequel(schema, database)` — the same arrows lowered onto Sequel's expression API, which knows
  dialects, quoting, pooling, and type mapping. A backend, not a second query language.
- `DB.memory(schema, seed)` — an instance functor `I : C → Set`, sets of rows, where `Select` is
  evaluated by *computing the pullbacks and subobjects in Set*.

All three are models of the same finitely presented theory. So a test is no longer "we faked the answer";
it is "we ran the same query in a different model". The upgrade in what determinism *means* is the
whole point:

> before: the fixed world returns what the test author decided it should return
> after: the fixed world computes the same query somewhere cheaper

And it yields a runnable claim rather than a stated one: **across all three phases, the three models
agree.** Fifty arrow shapes, evaluated in all three, asserted equal. A bug would have to occur in
three independent lowerings, identically, to survive. That is a conformance
suite in exactly the sense spec-system already uses — the same posture as `equiv:ruby:check`, and the
same posture as feeding emitted RBS back to the real `RBS::Parser` instead of asserting on strings.

A framework that claims "the world is a parameter" should be able to *check* that its worlds are the
same world. This one does: `test/db_conformance_test.rb` is that check, and it runs in the ordinary
suite rather than in a nightly job somebody stops reading.

## 6. What this refuses

- **No object-relational mapping.** A row is a plain Hash with symbol keys — no identity, no
  behaviour, nothing to reopen. It is *typed on the way in*, against the same zeolite schema that
  types a response body, and `Relation#typed` is the door back to a generated `Data` when a caller
  wants one. What is deliberately absent is the object that owns the row.
- **No lazy loading.** `post.author.posts` is traversal wearing attribute clothing, and it is how N+1
  becomes invisible. Path composition is written down because composition in C is written down.
- **No identity map, no dirty tracking, no session.** Those exist to reconcile mutable objects with a
  database. There are no mutable objects here.
- **No ambient connection.** The pool is a handler's captured state, so "which database" is the same
  knob as "which world" — one mechanism, not two.
- **No query DSL beyond what the structure justifies.** `having` exists and is a different word from
  `where` because a grouped relation is a different set. Window functions, recursive CTEs, and
  arbitrary expressions are not offered; beyond them, declared raw SQL with a typed result.
- **No expression language in a change.** `:set` and `:add` are the two things a change may be, and a
  decrement is `add` of a negative delta rather than a second arrow. Widening that would be inventing
  a small language whose laws nobody stated, in three models that would then have to agree about it.

## 7. Where the analogy breaks, said out loud

A design that oversells category theory is worse than one that never mentions it. Five places it does
not reach:

1. **`NULL`.** It is not `Maybe` and not a subobject; it is three-valued logic where `NULL = NULL` is
   unknown. Honest treatment: a nullable column is a map into `A + 1`, and elimination must be
   explicit. Comparisons that would silently go three-valued should be a build error, the way an
   ambiguous route is.
2. **Ordering and `LIMIT`.** Not limits or colimits — they need a linear order. Implemented as phase
   three, and typed as such: an ordered query returns a `Listing`, not a `Relation`. Where the theory
   stops short is the adjoined point: `A + 1` has an element the column's declared type does not
   mention, phase two produces one unprompted, and nothing says where it goes. That had to be decided
   rather than derived, and it is — `nothing` sorts after every element of `A`, in both directions —
   because the alternative was two SQL backends disagreeing with each other about a value.
3. **Aggregation.** `GROUP BY` is a fold along the fibers of a map `A → K`. Implemented as phase two,
   and restricted to the aggregates that are monoids, which is why `avg` is not offered.
4. **Isolation levels.** No algebra makes `REPEATABLE READ` true. The transaction handler is sound
   *within* an isolation level, which is a parameter and not a theorem. That is still the honest
   statement, and the update surface is where the gap stopped being abstract: it was reachable through
   ordinary use, by ordinary code that had done nothing wrong. Changing a value with four operations
   means `Select`, `Delete`, `Insert` inside `Atomically`, which is atomic and, under the READ
   COMMITTED a plain `BEGIN` gets on postgres, not serialisable — two scopes read `stock = 1`, the
   second's `Delete` blocks until the first commits, then re-evaluates its guard against a row that is
   already gone, removes nothing, and inserts a value computed from a read taken before any of that
   happened. The decrement is lost. **What closes the reachable part is not a stronger isolation level
   but a smaller operation.** A change expressed as a function of the current value, guarded inside the
   one statement that applies it, never held a value for a concurrent scope to invalidate: there is no
   earlier read, so there is nothing to have read too early. Which is also why an `Update` taking a
   `Row` would have bought nothing — the hazard is in where the new value came from, not in how many
   statements carry it. The general question stays open, and stays a parameter: this removes the lost
   update, not phantoms, not write skew, and not the need to choose a level for the workloads that
   still need one.
5. **`Σ_F ⊣ Δ_F ⊣ Π_F` in full.** The adjoint triple is about migration between schemas, and the
   useful half of it is built (see `docs/migrations.md`): a step is a functor and both directions are
   derived, so *reversibility is computed*. `Σ_F` is built too — `merge_tables` is the coproduct, the
   discriminator column is its injection tag, and `split_table` is the decomposition along that tag,
   which makes eight step shapes rather than six. What is still absent is the right adjoint `Π_F`:
   folding two tables into one by a *product* over a shared key, a join materialised as a migration.
   The decomposition is not relabelled `Π` to look complete.

## 8. The seam this closes

Sodalite's request path is

```
HTTP text -> sieve -> Data -> workflow -> Data -> sieve -> HTTP text
```

and the database path would be

```
Data -> query -> Relation -> Data
```

with the **same `Data` classes**, because the schema that types a response and the schema that types a
row are the same kind of object.

Which suggests the sharper statement, and the thing to aim at:

> The API contract and the database schema are two presentations, and the service is a functor between
> them.

A route publishing `{ id:, name: }` drawn from `users` is a choice of arrow in C followed by a
projection. If that is *declared* rather than hand-written, then the query and the published shape come
from one source and cannot drift — which is the same guarantee the response contract already gives at
the HTTP boundary, extended one layer down.

That is the target. The order to get there is section 3, then 5, then 4 — signature first, conformance
second, transactions third — because each one is worth having even if the next never lands.
