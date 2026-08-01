# The RDBMS boundary, categorically

**Implemented and green.** `lib/sodalite/db/`, `test/db_test.rb`, `test/db_conformance_test.rb`.

Sodalite already says the world is a parameter. Today that world is a bag of lambdas: a route performs
`:find_user`, and a handler map answers it. That works, and it is also the weakest part of the design,
because the bag has no laws. Nothing relates `:find_user` to `:insert_user`. Nothing says the fixed
handlers and the real handlers are two versions of the same thing. A test passes because someone wrote
a stub that happened to return the right shape.

This note works out what the database boundary looks like once that gap is closed, and what the
existing pieces already force. The two-model conformance suite in section 5 is the part that turns the
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
| `select` | **image factorization** | `SELECT DISTINCT` |

Composition, finite limits, and image factorization is a **regular category**. `UNION` needs
coproducts; `NOT` needs Boolean structure, which is where SQL becomes three-valued logic. There is no
`join` in the language: a join is what a compiler emits for a composition, and writing one by hand is
implementing composition by hand.

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
- **An order must be total**, or ties break arbitrarily and the two models are free to disagree. So
  the identifying fields are appended, and `total_ordering` is what actually runs.

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
SELECT g.city, COUNT(*) AS people
FROM (SELECT DISTINCT t1.id, t1.name, t1.city FROM posts t0 JOIN users t1 ON t0.author = t1.id) g
GROUP BY g.city
```

This is the whole argument for the two-model check, arriving on the first extension after it was
written. One model alone would have been self-consistently wrong.

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

## 5. Two models of one theory — where this stops being philosophy

With a fixed signature, the interesting handlers are not stubs:

- `DB.postgres(pool)` — the real model. `Select` compiles the arrow to SQL.
- `DB.memory(seed)` — an instance functor `I : C → Set`, literally sets of zeolite `Data` values, where
  `Select` is evaluated by *computing the pullbacks and subobjects in Set*.

Both are models of the same finitely presented theory. So a test is no longer "we faked the answer";
it is "we ran the same query in a different model". The upgrade in what determinism *means* is the
whole point:

> before: the fixed world returns what the test author decided it should return
> after: the fixed world computes the same query somewhere cheaper

And it yields a runnable claim rather than a stated one: **on the regular fragment, the two models
agree.** Generate arrows in the fragment, evaluate in both, assert equality. That is a conformance
suite in exactly the sense spec-system already uses — the same posture as `equiv:ruby:check`, and the
same posture as feeding emitted RBS back to the real `RBS::Parser` instead of asserting on strings.

A framework that claims "the world is a parameter" should be able to *check* that its two worlds are
the same world. Right now it cannot. This is how it could.

## 6. What this refuses

- **No object-relational mapping.** Rows are zeolite `Data`: frozen, typed, no identity, no behaviour.
- **No lazy loading.** `post.author.posts` is traversal wearing attribute clothing, and it is how N+1
  becomes invisible. Path composition is written down because composition in C is written down.
- **No identity map, no dirty tracking, no session.** Those exist to reconcile mutable objects with a
  database. There are no mutable objects here.
- **No ambient connection.** The pool is a handler's captured state, so "which database" is the same
  knob as "which world" — one mechanism, not two.
- **No query DSL beyond what the structure justifies.** `having` exists and is a different word from
  `where` because a grouped relation is a different set. Window functions, recursive CTEs, and
  arbitrary expressions are not offered; beyond them, declared raw SQL with a typed result.

## 7. Where the analogy breaks, said out loud

A design that oversells category theory is worse than one that never mentions it. Five places it does
not reach:

1. **`NULL`.** It is not `Maybe` and not a subobject; it is three-valued logic where `NULL = NULL` is
   unknown. Honest treatment: a nullable column is a map into `A + 1`, and elimination must be
   explicit. Comparisons that would silently go three-valued should be a build error, the way an
   ambiguous route is.
2. **Ordering and `LIMIT`.** Not limits or colimits — they need a linear order. Implemented as phase
   three, and typed as such: an ordered query returns a `Listing`, not a `Relation`.
3. **Aggregation.** `GROUP BY` is a fold along the fibers of a map `A → K`. Implemented as phase two,
   and restricted to the aggregates that are monoids, which is why `avg` is not offered.
4. **Isolation levels.** No algebra makes `REPEATABLE READ` true. The transaction handler is sound
   *within* an isolation level, which is a parameter and not a theorem. Say so where it is chosen.
5. **`Σ_F ⊣ Δ_F ⊣ Π_F` in full.** The adjoint triple is about migration between schemas, and the
   useful half of it is now built (see `docs/migrations.md`): a step is a functor and both directions
   are derived, so *reversibility is computed*. What is still absent is the general `Σ`/`Π` — merging
   and splitting tables — which needs the adjoints proper rather than the six step shapes offered.

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
