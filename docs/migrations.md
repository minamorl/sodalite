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
