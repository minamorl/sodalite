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

HISTORY.schema          # the composite — nothing is declared twice
HISTORY.schema_at(2)    # a version is how far along the composite a database got
```

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
HISTORY.reversible_to?(0)   # => true
HISTORY.irreversible_steps  # => []
```

That answer arrives **before anything runs**, because losing information is exactly what a
non-injective map does. It is not a warning printed after the rollback failed.

Both models carry the history: the in-memory one transforms rows, the SQL one derives DDL. The
conformance discipline extends to "migrate, then query" — and it immediately earned its keep again.
`ALTER TABLE ADD COLUMN` leaves existing rows `NULL`, while the induced map says the column is the
constant default, so the two models disagreed until the backfill was added. The ledger records each
step's fingerprint, so a migration edited after it ran is caught rather than silently re-meaning
something.

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

`migrate!` takes a lock, so the single writer is a mechanism rather than a wish.
A runner that dies mid-migration leaves the lock behind; the error says so, and
clearing it is a human `DELETE FROM sodalite_migration_lock`. That is a deliberate
choice over a lease with a timeout: a timeout that expires while the first runner
is merely slow gives you two writers, which is the thing the lock existed to
prevent.

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
model.rollback!(HISTORY, to: 3)
```

The inverses are walked in reverse, and the range is checked **before the first
statement runs**: if anything in it forgets information, nothing happens and the
error names every step responsible. The answer was always computable, so letting
it arrive halfway through a rollback would have been a choice rather than a
limitation.

`drop_attribute` and `drop_table` are the steps with no inverse. Rolling back past
one is not a smaller operation — it is a restore. Take the copy before applying
it, because the database will not.

### What this does not decide

- **Clearing a stale lock is manual**, for the reason above.
- **The SQL model's lock targets SQLite and Postgres.** MySQL wants `FROM DUAL`;
  the Sequel model already spells it per dialect, which is the reason that backend
  exists.
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
