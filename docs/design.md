# Sodalite — the design

**A web framework where the request is a value, the world is a parameter, and nothing untyped gets
in or out.**

A zeolite is a molecular sieve: a mineral whose pore structure admits only molecules that fit its
shape. The gem applies that to JSON. This document is what happens when the same sieve is moved to
the HTTP boundary, and the rest of the request is built on three things that were already here.

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

Nothing in that column is new. The framework is the wiring, and the wiring is the whole claim: each
of these four already refuses to guess, and putting them in a line means a request has nowhere left
to be vague.

## The four properties

**1. The request is a value.** The Rack env does not reach your code. A route declares the shape of
its path parameters, query, and body; what a task receives is a frozen `Data` instance with real
readers. A request that does not fit never becomes one — it is a 400 listing *every* violation,
each located by a JSON Pointer that says which part it came from:

```json
{ "error": { "code": "invalid_request", "message": "request does not fit the declared shape" },
  "violations": [{ "path": "/params/id", "code": "type_mismatch", "message": "expected integer, got string" },
                 { "path": "/body/name", "code": "refinement_failed", "message": "length between 1 and 64 not satisfied by \"\"" }] }
```

**2. The world is a parameter.** Every effect a task performs is `io.perform(tag, payload)`, and the
tag is dispatched through the handler map the app is running under. Production supplies real
handlers; a test supplies fixed ones. The same routes, the same router, the same sieve, the same
workflow — with no database, no clock, and no socket:

```ruby
Sodalite::App.new(routes: ROUTES, handlers: Sodalite::Effects.real(find_user: DB.method(:user)))
Sodalite::App.new(routes: ROUTES, handlers: Sodalite::Effects.fixed(find_user: ->(_id) { { id: 7 } }))
```

This is not a testing convenience bolted on afterwards; it is what darkcore already is. The
framework's own IO goes through the same door — `:sodalite_clock`, `:sodalite_id`, `:sodalite_log`,
`:sodalite_contract` — so there is no `Time.now` and no `SecureRandom` reachable from a request path
except through a handler you supplied. A whole request is reproducible byte for byte.

**3. Failure keeps its state.** A route is a berylx workflow, so a failure is
`Err(partial_lay, error)`: which named task failed, with what state, and everything the earlier steps
had already established. The client sees a status the app declared for that error code; the log sees
the task name and the trace. An error the service never named is a 500 whose message stays in the
log — an error you did not map is not one you meant to expose.

**4. Cross-cutting is a handler swap.** Timing, audit, retry, dry-run, tracing: build them with
`Effects.around`, which wraps the interpreter and passes the wrapped map into `parallel`, `branch`,
and `rescue` subtrees. The route is never rewritten to be observed. There is no `before_action`, no
callback chain to get the order wrong in, and no middleware that has to guess what your controller
meant.

## What it refuses

The point of "堅実" is mostly a list of things not done.

- **No DSL.** Routes and schemas are Ruby literals. Nothing is `instance_eval`ed, nothing is
  `method_missing`ed, no class is reopened, and no file is autoloaded.
- **No global state.** There is no `Sodalite.configure`. The app is an object; what it needs, it
  is given at construction; it freezes itself; and the only per-request state is one `Berylx::Root`.
- **No ORM, no views, no assets, no generators.** This is a framework for services with contracts.
- **No implicit type guessing.** See below — this is the one place the design had to be careful.
- **No durability.** In-process only, like berylx. Work that must survive a restart belongs in a
  durable engine.
- **No Rails compatibility.** Rack compatibility at the transport edge, and that is the extent of it.

## Two vocabularies, because there are two worlds

This is the decision the design turned on.

Zeolite's sieve refuses to coerce across JSON types: `"1"` is not an `Integer`, because a document
that wrote `"1"` had `1` available and chose not to use it. That rule is load-bearing — guessing at
the boundary is how bad data gets in — and a web framework must not quietly relax it.

But a URL carries no types at all. Every path segment and every query value is text, so *declaring*
the type is the only way to have one. Refusing to decode there would make the rule meaningless in
the one place a framework needs it most.

So: two vocabularies, and a seam between them.

- **Bodies** go through the sieve unchanged. JSON already said what it meant.
- **Path parameters, query, and headers** go through `TextSchema`, which applies one explicit,
  declared decode step — `"42"` becomes `42` because the route said `{ id: :integer }` — and then
  hands the result to the ordinary sieve.

Text that does not decode is passed through **unchanged**, so the schema produces the violation, with
the right pointer and the right code. There is one error path, not two, and the sieve's no-coercion
rule is exactly as strict as it was.

`Zeolite.enum` still owns the only door from document text to a `Symbol`, and it can still only emit
symbols the schema already named. A query string cannot grow the symbol table.

## Ambiguity is a boot error

Every check that can be made when the app is built is made then, because a route that fails on the
one request that happens to exercise it is a route that fails at 3am.

- A template parameter that is not declared, or a declared parameter that is not in the template →
  `RouteError`.
- Two routes that could answer the same request → `Router::ConflictError`.
- Two different parameter names in the same position (`/users/:id` and `/users/:slug`) →
  `ConflictError`. One of them is a lie about what that segment is.
- A `run:` that berylx cannot compile → `RouteError`, raised by asking berylx at boot.
- An application effect tag that collides with a framework or berylx tag → `ArgumentError`.

Matching itself is a segment trie built once and frozen: static segments beat parameters, and a
static prefix that dead-ends backtracks rather than shadowing a parameter route that would have
matched. There is no regex language in a route, so a template you cannot read is not a template you
can write. Path segments are split first and percent-decoded second, so `%2F` is data inside one
segment and never invents a path separator.

## Out is the same sieve

A route declares what it publishes per status:

```ruby
responses: { 200 => { id: :integer, name: :string }, 404 => Errors::SCHEMA }
```

On the way out the framework generates the JSON, then validates *that JSON* — not a Hash that
resembles it — against the declared schema. What gets checked is what the client will receive, so
"typed on the way out" is literally true rather than aspirational.

A response that does not fit is the service breaking its own published contract. That is not an
ordinary error, so it does not take an ordinary path: it performs `:sodalite_contract`, and the
handler decides the cost. `Effects.fixed` raises, so drift fails the suite. `Effects.real` logs and
returns a 500, so drift does not ship a wrong shape to a client that trusted the contract.

Error responses are typed too, by the same schema (`Errors::SCHEMA`), so "what does a 400 look like"
has an answer you can read instead of infer.

## The database is a theory, not more verbs

"The world is a parameter" is weakest where the world is a database, because a handler map for
`:find_user` and `:insert_user` is a model of nothing in particular — the verbs are whatever the
application invented, and no equation relates them. `Sodalite::DB` replaces that part of the
signature with a fixed one (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `ATOMICALLY`) over a schema that
is a finitely presented category, so a handler map for those five is a *model of the relational
theory* and the in-memory one is a model rather than a stub. [The RDBMS note](rdbms.md) works it out;
[the migration note](migrations.md) does the same for schema change.

**That signature was four, and widening a fixed signature deserves to be said rather than done
quietly.** The heading is not a count. It says the verbs are not the application's to invent, and
`UPDATE` was not invented: the design note proposed `Update(Subobject, Delta) -> Count` in the same
list as the other three, in the commit that predates the one adding `lib/sodalite/db.rb`, because it
is what the relational theory already names. The four that shipped first were an incomplete model of
the theory, not a smaller theory, and the difference shows in what four could not do safely. Changing
a value with four means `SELECT`, `DELETE`, `INSERT` inside `ATOMICALLY`, which is atomic and not
serialisable under READ COMMITTED, so two scopes decrementing one unit of stock oversell it between
them. A fifth operation that assigned literals would have had the same defect. What does not is a
change written as a function of the value it replaces, with the guard evaluated inside the statement
that applies it — which is exactly the `Delta` the note wrote down, and the reason the vocabulary is
two closed constructors (`set`, `add`) rather than an expression language.

The rule the heading is really about is the one that decided that closure: **what is offered is what
carries a law.** It is the same rule that keeps `avg` out of the aggregates for not being a monoid,
`join` out of the query language for being what a compiler emits, and `subtract` out of the changes
for being `add` of a negative. A sixth operation would need the same argument, and "a caller would
find it convenient" is not that argument.

The rule cuts the other way too, and the invalidation surface is where it did. What was asked for
there was a push channel — subscribe to a query, be told when a write dirties it. What carries a law
is not the channel; it is the pair of sets underneath it, and the law is one line: if the places an
operation dirties are disjoint from the places an answer depends on, that operation cannot have
changed that answer. So the sets are what shipped, as two pure functions, and the channel is
somebody's to build on top. That is not a smaller version of the request. It is the part of it that
is true independently of who is holding the sockets.

Three more decisions there are design-level rather than API-level, and all three belong in this
document because all three are choices about what the framework will and will not hold for you:

- **Integrity is reported, not enforced.** An instance is a functor into `Set`, so a dangling foreign
  key is a failure to be a functor rather than a bad row — but `insert` does not check it, `delete`
  does not check for referrers, and the DDL emits no `REFERENCES`. `functor?` and `violations` answer
  when asked. Enforcing it in the writes would turn something an instance *is* into something a model
  holds on its behalf, which is a different object. The same goes one layer up for path equations and
  `equation_violations`.
- **The ledger is the truth about what a database is.** `verify!` reads it and nothing else, so a
  database someone hand-altered passes, and a history cannot adopt a database it did not create. That
  is one truth that can be wrong rather than two that disagree about which of them is.
- **Invalidation is a calculus, not a channel.** `query.reads` and `DB.writes(tag, payload)` each
  answer a set of addresses, and a caller decides staleness by asking whether the two meet. There is
  no subscription registry and no cache, because a registry must outlive the request that registered
  it and be written by a *different* request — exactly the global mutable state "No global state"
  above rules out — and a cache would be state the framework holds on a caller's behalf, which is the
  objection integrity enforcement gets. Both functions are computed from values already in hand: an
  arrow, and the `(tag, payload)` the caller was about to perform. So the framework gains a function
  and no state, and the question becomes askable before the write rather than after it. [The RDBMS
  note](rdbms.md) section 3.1 works out the two kinds of address, why the precision stops at the
  column, and why a scope refuses to answer at all.

## Streaming, because the sieve already reads streams

Zeolite reads NDJSON and SSE one record at a time. A framework built on it writes them the same way:

```ruby
lay[:response].set(
  Sodalite.stream(200, { seq: :integer, kind: Zeolite.enum(:tick, :done) }) do |emit, io|
    io.perform(:subscribe).each { |event| emit.call({ seq: event.seq, kind: event.kind }) }
  end
)
```

Each record is validated as it is emitted, so a malformed record is caught at the record rather than
after the whole body was generated. The status line is already on the wire by then, so there is no
status left to change: the stream stops at that record and reports through the same contract handler.
An LLM proxy, a log tail, and a change feed are the same shape, and `Zeolite.feed` reads back what
this wrote.

**A stream is a response framing, not a broadcast bus**, and the two are worth telling apart because
from outside they look alike. A stream is one request writing many records down its own connection,
with its state inside its own `Root` and its lifetime ending with the request. Nothing in it gives a
*second* request a handle on the first one's socket, so it is not the substrate a subscription
channel would be built on — which is why the invalidation surface above is a pair of sets rather than
a feed.

## Concurrency

Threads, not processes. The app is frozen at boot — routes, compiled schemas, generated `Data`
classes, and the handler map — so every Puma thread shares immutable data and there is nothing to
copy. berylx `parallel` branches run on their own threads inside a request and inherit the same
frozen map.

The one thing the framework cannot check for you: a handler *you* supply must be safe to call from
several threads at once. That is stated rather than hidden, because it is the only sharp edge left.

## Why this is a separate library

The sieve claims zero runtime dependencies, and that claim is the reason to trust it at a boundary: a
validator that drags in a dependency tree is a larger attack surface than the thing it guards. This
framework needs berylx, darkcore, rack, and puma.

Shipping both from one repository — two gemspecs, one `lib/` — would have kept that claim technically
true while leaving the dependency tree living next to the thing whose whole point is not having one.
The split protected the property by managing it. A separate library removes the tension instead:
`zeolite` goes back to being only the sieve, nothing in that repository knows a framework exists, and
this one depends on it the way any other consumer would.

The name is not decoration. In mineralogy a **sodalite cage** is the structural unit that zeolite
frameworks are assembled from — the β-cage that Zeolite A, X, and Y are built out of. "Framework" is
the crystallographic term for those structures, not a metaphor borrowed for the occasion. This is the
framework built on the sieve, and it is named after the sieve's own building block.

Dependency direction is one-way and stays that way: `sodalite` requires `zeolite`, and `zeolite` must
never learn about `sodalite`.

## Open questions

- **Publishing.** Neither berylx nor darkcore is on rubygems, so `sodalite` cannot be published yet
  either. Development depends on all three siblings by git; the same open question as `q.publish` in
  zeolite's own spec.
- **Wildcard segments.** There is no `*rest` today. Static and `:param` cover services; a proxy or a
  static-file route would want one.
- **Empty query values.** `?page=` is a present, empty string, so an `:integer?` field reports a
  violation rather than treating it as absent. That is the honest reading of what was sent, but real
  clients do send it, and a declared `empty_as_absent` decode option may be warranted.
- **RBS for a whole route.** `schema.to_rbs` already emits signatures for the generated classes. A
  route could emit the signature of its own handler — request type in, response type out — so
  `steep` checks the tasks against the contract, not just the values.
- **~~OpenAPI.~~** Answered: the framework ships the fold. `Sodalite::OpenAPI.document(app, …)` is
  derived from `app.routes` rather than maintained beside them, so there is no second set of
  annotations to keep in sync and nothing to drift.
