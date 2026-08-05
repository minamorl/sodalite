# History and storage

Two more boundaries, given the same treatment as the database: a fixed signature, more than one model,
and a conformance check that they are the same thing.

## SQL history: a step is a functor, so reversibility is computed

A schema change is a functor `F : C → D` between presentations, and the data migration is what `F`
induces on instances. Writing `up` and `down` by hand means writing that pair yourself, in two places,
where nothing checks they agree.

Here a step is data and both directions are **derived**:

```ruby
HISTORY = Sodalite::DB.history(
  [:create_table,     :users, { id: :integer, name: :string }],
  [:add_attribute,    :users, :city, :string, 'unknown'],
  [:rename_attribute, :users, :city, :town],
  [:create_table,     :posts, { id: :integer, title: :string, author: Sodalite::DB.fk(:users) }]
)

HISTORY.schema           # the composite — nothing is declared twice
HISTORY.schema_after(2)  # the composite of the first two steps of `plan.order`
```

`after` is the unit, and the unit is a count of steps along the **solved** order — the same number
line `rollback!(to:)` indexes, so a number cannot name one prefix to the reader and another to the
runner. `spec_after`, `schema_after`, and `reversible_after?` all read it that way. Counting along
declaration order would be counting along the one thing in a history that carries no meaning, which is
the whole reason `Plan` exists.

Which makes reversibility a property rather than a promise:

| step | induced map on instances | |
| --- | --- | --- |
| `rename_attribute` / `rename_table` | an isomorphism | reversible |
| `create_table` | adds an empty object | reversible |
| `add_attribute` | injective — the column is the constant default, so the original projects back out | reversible |
| `drop_attribute` | a projection, not injective | **irreversible** |
| `drop_table` | forgets an object | **irreversible** |
| `merge_tables` | `Σ_F`, the coproduct — the discriminator column is the injection tag | reversible |
| `split_table` | the decomposition of that coproduct along the tag | reversible |

```ruby
HISTORY.reversible_after?(0)  # => true
HISTORY.irreversible_steps    # => []
```

That answer arrives **before anything runs**, because losing information is exactly what a
non-injective map does. It is not a warning printed after the rollback failed.

All three models carry the history: the in-memory one transforms rows, the hand-written SQL one
derives DDL text, the Sequel one reshapes through a backend that knows the dialect. The conformance
discipline extends to "migrate, then query" — and it immediately earned its keep again. `ALTER TABLE
ADD COLUMN` leaves existing rows `NULL`, while the induced map says the column is the constant
default, so the models disagreed until the backfill was added. The ledger records each step's
fingerprint, so a migration edited after it ran is caught rather than silently re-meaning something.

The backfill is now the *fallback* rather than the mechanism: the default is declared on the column,
where Postgres 11+ and SQLite fill existing rows out of the schema without touching one, and the
`UPDATE ... WHERE ... IS NULL` that follows is narrowed to the rows still missing a value. That makes
it a no-op wherever the declaration worked and idempotent wherever a migration was interrupted. **On
a backend where the declaration does not fill, it is still one full scan.** Cutting it into key ranges
would need the emitter to know how many rows there are, and it knows the presentation and nothing
about the instance.

`Σ_F` — merging two objects into their coproduct, tagged by which injection each element came
through — is here, and so is its inverse. The two tables must share a shape, which is not a
convenience check: without it the coproduct is not an object of the target schema.

What is still absent is the **right adjoint `Π_F`**: folding two tables into one by a *product* over a
shared key, i.e. a join materialised as a migration. The decomposition is not relabelled `Π` to look
complete.

## The procedure

Everything above answers *what* a migration means. This answers *who applies it,
and when* — the half a computed answer cannot supply, and the half that is
discovered at 3am when it was never written down.

### The history is a set, declared in code, append-only

The steps live in one Ruby literal, and that literal is the ledger of intent.
Adding a migration means appending to it. **Editing an applied step is not an
edit — it is a different step**, because a step's identity is its content, and
the database's ledger says so rather than silently re-meaning the old one.

Two branches that each append merge without ceremony: the declaration order
changed, the set did not, and the order is solved from the set. This is the whole
reason the index is gone. An index-keyed ledger turns an ordinary merge into a
fingerprint mismatch on migrations nobody touched.

Declaring the same step twice is refused at declaration. A step *is* its content,
so the two are one step, and a ledger keyed by content cannot tell them apart.

### The content address, and the one time it changed

"A step's identity is its content" is only as good as the function that computes
it. That function used to be `args.inspect`, and `inspect` renders a Hash in the
order its keys were inserted — so permuting the fields of a `create_table`, a
refactor that changes no meaning, minted a second address for the same step, and
a ledger keyed by address then called an applied step unapplied.

It is now a normalised, prefix-free serialisation carried under a `v1` scheme
tag. A Hash's keys are sorted; an Array's order is kept, because `merge_tables`
takes a *sequence* of sources and which one is the first injection is part of
what the step says; each atom names its kind and its byte length, so `:1`, `'1'`
and `1` are three renderings and no separator can be forged from inside a string;
a value the normaliser has no rendering for raises rather than falling back to
`inspect`. The scheme tag lives inside the digest input rather than beside it, so
a later change to the rules produces visibly different addresses instead of
silently colliding with the old ones.

**Every fingerprint changed.** A database migrated under the old scheme presents
a ledger this code does not recognise: `verify!` sees no fingerprint it declares
and refuses, and `migrate!` would carry every step again against a shape that
already has it. There is no automatic conversion — writing one would mean keeping
the old normalisation in the code to recompute the addresses it produced, and a
scheme tag whose predecessor is still present is not a scheme tag. The recovery
is by hand: read `HISTORY.fingerprints` under this checkout and rewrite the
`fingerprint` column of `sodalite_migrations` to match, step for step, before
starting the new code against that database.

### A history cannot adopt a database it did not create

`Plan#check_unprovided!` refuses a history whose requirements nobody supplies, so
the first steps are always the `create_table`s that bring every object into
being. There is no `assume_table`, no baseline step, and no way to say "this one
is already there".

That is a decision rather than a missing feature. A step asserting that an object
already exists would be a step whose meaning depends on the database rather than
on the history, and every other guarantee here rests on the opposite premise —
that the history is the whole account of what a database is, and the ledger is
where it is recorded. Adopting a database means writing the history that would
have produced it and seeding the ledger by hand, which is the same work as the
scheme change above and has the same shape.

### Applying is one explicit command, and never a side effect of boot

```ruby
Sodalite::DB.sql(HISTORY.schema, connection).migrate!(HISTORY)
```

`examples/service/migrate.rb` is the shape: one command, run once per deploy, by
one runner. A process that serves requests does not migrate.

Two reasons, and only the second is about safety. A service runs N processes on M
hosts, so a boot-time migration has no single writer and "who applied this" has no
answer. And a migration that runs at boot runs during a *rollback* too — at the
one moment nobody wants schema changes.

One step is also one transaction, which is why a model that cannot put DDL in one
is refused outright:

```ruby
Sodalite::DB.sql(HISTORY, connection, transactional_ddl: false).migrate!(HISTORY)
# => MigrationError: Sodalite::DB::Sql cannot migrate!: this database has no
#    transactional DDL, ...
```

The mandatory port is `execute(sql, binds) -> rows` and has nowhere to put the
question — nor does the optional `change(sql, binds) -> Integer` a connection may
also declare, which reports rows affected and not whether DDL rolls back. So the
caller answers it once where the connection is built; `true` is the default
because SQLite and Postgres both have it, and `DB.sequel` answers for itself.
Without the scope, `carry` and `record_step` are two writes with a gap: an
interruption between them leaves the database changed and the ledger silent, and
the next run carries the step again against a shape that already has it. There is
no override keyword, because a refusal an argument can waive is not a refusal —
and what the waiver would buy is exactly the hand recovery it already names.

### The lock has a holder, and clearing it is explicit

`migrate!` takes a lock, so the single writer is a mechanism rather than a wish.
The row carries a token, the holder, and the time it was taken, so a refusal names
the runner that is in the way instead of speculating that one crashed:

```
another migration is running: <host>:<pid> has held the lock since
2026-08-05T05:19:45Z (1204s); if that runner is gone, clear it with
steal_lock!(older_than: <seconds>)
```

A runner that dies mid-migration leaves the lock behind, and clearing it is one
explicit call:

```ruby
model.steal_lock!(older_than: 900)
# => "cleared the migration lock held by <host>:<pid> since 2026-08-05T05:19:45Z (1204s)"
```

(`<host>:<pid>` is what the holding process wrote — `Socket.gethostname` and its
own pid — and the age is real; only those two are substituted here.)

`older_than` is in seconds and has **no default**, because only the caller knows
how long the migration it is about to displace normally takes; a younger lock is
left alone and the refusal says by how much. That is a deliberate choice over a
lease with a timeout: a timeout that expires while the first runner is merely slow
gives you two writers, which is the thing the lock existed to prevent. Making the
caller name the age moves the same judgement to the one place that can make it.

### Boot verifies, and refuses

```ruby
Sodalite::App.build(capabilities: [Sodalite::DB.capability(db, history: HISTORY)], ...)
```

The capability asks the database whether it agrees with the code, at construction
— the same rule the router follows, that a check which can be made at boot is
made at boot rather than on the one request that happens to exercise it. Three
answers:

- **An unapplied expansion → refuse to start.** The code was written against a
  column the database does not have. Starting means serving 500s until someone
  notices.
- **An unapplied contraction → start normally.** The database still has a shape
  this code no longer uses. That is not damage; it is the expected state between
  deploying new code and dropping the old shape.
- **A ledger holding steps this checkout does not declare → refuse.** The
  database is ahead of the code, which means an old release is being started
  against a newer database, and it says exactly that.

**`verify!` reads the ledger and nothing else.** That is the premise all three
answers rest on, and it is worth stating rather than leaving to be discovered:
what a database *is* has one recorded history, and the ledger is where it is
recorded. Nothing reads the catalog, compares a column type, or looks at a row.

So a database someone hand-altered passes. A column added by hand, a table dropped
by hand, a type widened by hand, a row rewritten by hand — none of it is visible
here, and a database can hold every declared fingerprint without having the shape
the history describes.

That is the right default rather than a hole. A check that re-derived the shape
from the catalog would be a second opinion about what the database is, and it
would have to be told which differences are allowed — an unapplied contraction is
a legal difference, and so is an index somebody added on a slow morning. One truth
that can be wrong is better than two that disagree about which of them is.

`create_tables_for_test!` is the same gap approached from the other side. It builds
the whole schema in one shot with **no ledger entries at all**, so `verify!`
refuses the result with *database is missing required migrations* — which is what
the name is for. Anything that boots against `verify!` goes through `migrate!`.

### A release contains expansions, or it contains contractions

Reversibility and deploy-safety are two different questions, and the table is not
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

The rename rows are what the distinction is for. A rename is an isomorphism, so
nothing is lost and it rolls back perfectly — and it still breaks every process
still running the old code, because the old presentation is not *included* in the
new one under its own names. Reversibility asks for an inverse; compatibility
asks for an inclusion. Only `create_table` and `add_attribute` are inclusions.

So the order of a deploy follows from the kind of steps in it:

- **An expansion-only release**: apply first, then deploy. Old code keeps running
  against the new schema the whole time.
- **A release containing a contraction**: deploy first, then apply. The old shape
  outlives the code that used it, by one deploy.

Renaming a column under load is therefore three releases, not one — add the new
name and backfill, deploy code that writes both and reads the new, drop the old.
Nothing here automates that. What it does is make "is this release
expansion-only?" a question with a computed answer, `plan.expand_only?`, instead
of a claim someone made in a pull request.

### Rolling back

```ruby
model.rollback!(HISTORY, to: 3)   # keep the first three steps of the solved order
```

`to:` counts along `plan.order`, which is the same unit `reversible_after?` and
`schema_after` take — so "reversible to 3" and "roll back to 3" name the same
prefix rather than two that happen to coincide.

The inverses are walked in reverse, and the range is checked **before the first
statement runs**: if anything in it forgets information, nothing happens and the
error names every step responsible. The answer was always computable, so letting
it arrive halfway through a rollback would have been a choice rather than a
limitation.

`drop_attribute` and `drop_table` are the steps with no inverse. Rolling back past
one is not a smaller operation — it is a restore. Take the copy before applying
it, because the database will not.

### What this does not decide

- **Clearing a stale lock is manual**, for the reason above. `steal_lock!` is the
  call; deciding what counts as stale is the operator's.
- **The hand-written model's dialect surface is ANSI, and that is a claim about
  quoting rather than about the lock.** The lock is a plain `INSERT ... VALUES`
  now and needs no dialect. What does: every identifier is emitted in ANSI double
  quotes, which SQLite and Postgres read as an identifier and MySQL reads only
  under `ANSI_QUOTES`; and `transactional_ddl:` defaults to `true`, which is right
  for those two and wrong for MySQL, where it must be passed `false` and
  migrations are then refused. `DB.sequel` is the answer to both, which is the
  reason that backend exists.
- **`:boolean` is not usable with the hand-written model.** `sql_type` maps it to
  `TEXT` and the sqlite3 driver will not bind `true` at all. Pre-existing, and
  named here rather than left to be found on an insert.
- **Two things are still read in declaration order.** `History` bootstraps a
  presentation per step before any order exists, so a `rename_table` or
  `split_table` declared *before* the step that creates its object raises
  `KeyError` at construction even though its solved order would be fine. And
  `merge_tables` claims its target with a wildcard, so a later step supplying a
  *new* name under the merged object — `merge` then `add_attribute` — cannot be
  scheduled and comes back as a dependency cycle. Both are the same defect one
  layer below the solver: a fact about a step read off the order it was typed in.
  Declaring the creation first, and adding the attribute to both sources before
  merging, are the ways around them, and they are the same migration.
- **Nothing here schedules anything.** "Apply, then deploy" is a fact about which
  order is safe, not a pipeline. Wiring it into CI is the service's job.

## Object storage: a partial function on a poset, and no transactions

A bucket is a **partial function** `Key ⇀ Object`. That is the whole data model. The keys carry one
piece of structure — they form a **poset under the prefix order** — and `list(prefix)` is the principal
filter `{ k : prefix ≤ k }`. Prefix listing is not a weak query language; it is the only subobject the
order gives you.

```
PUT(key, bytes, meta)  -> key
GET(key)               -> Object or nil     (partial, so nil is honest)
DELETE(key)            -> boolean
LIST(prefix)           -> keys, ordered
```

Three models: `Store.memory` (the partial function, as a Hash), `Store.filesystem` (real IO, real
directory walk), and `Store.s3` over a four-method port that `Aws::S3::Client` already satisfies. The
first two are conformance-checked against each other — a directory tree is not a Hash, so it disagrees
wherever the signature was vague, which is the point. The S3 adapter is **unverified against real S3
here**, and saying so is worth more than a test that mocks the SDK and proves nothing.

The checks that a flat Hash would never have surfaced: a key is not a path (`a/b` is one object, not a
directory holding `b`), `a/b` and `a%2Fb` stay different objects, arbitrary bytes survive, UTF-8 keys
survive, and an empty body is an object rather than an absence.

### There are no transactions, and this does not pretend otherwise

A store cannot join `DB.atomically`. Claiming it can is the classic distributed lie. What
`Store.saga` offers is compensation: a write records its inverse — read before writing, so a new key
is undone by a delete and an overwritten one by restoring the bytes that were there — and an `Err` in
the scope replays the inverses backwards.

```ruby
Sodalite::Store.saga(:publish, upload >> index >> announce)
```

It is **lax**, and the laxness is the honest part: compensation cannot unread. Anyone who read between
the write and the failure saw the value that compensation later removed, and no object store gives you
a way to prevent that. There is a test that asserts exactly this rather than a footnote that mentions
it. The name is `saga` and shares no vocabulary with `atomically` for that reason.

### A saga scope is a handler-map swap, built rather than merged

The scope runs its subtree on a map whose store tags point at the journal — the same mechanism as
everything else here. One subtlety, and berylx warns about it: the map has to be **built** for the
journal, not merged over a finished one. The combinator handlers inside a finished map close over the
map they were constructed with, so a merged copy runs its subtrees on the original bindings and the
journal never sees a write. It is quiet when you get it wrong; the compensation simply does nothing.
