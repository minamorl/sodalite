# sodalite review policy (coding standards for iolite)

`sodalite` is a Ruby ≥3.2 web framework gem: puma for transport, zeolite (the sieve) at both
boundaries, berylx for the workflow, darkcore for effects. Its whole claim is that each of those
four already refuses to guess, so a request has nowhere left to be vague — which means the damage
model is not "a bug in a feature" but "a guarantee quietly stopped holding". The characteristic
failure here is a change that passes `bundle exec rake`, ships, and only shows up as an
unreproducible request, a data race under Puma threads, a 500 at 3am that should have been a boot
refusal, or a migration ledger that disagrees with the database.

Four properties define this library. **A change that weakens any of them is a redesign, not a
patch**, and must be reported as such even when the code is correct on its own terms:

1. The request is a value — the Rack env never reaches a task.
2. The world is a parameter — every effect goes through the handler map.
3. Failure keeps its state — `Berylx::Err(partial_lay, error)` maps to a declared status.
4. Cross-cutting is a handler swap — `Effects.around`, never a callback chain or middleware.

---

## 0. Highest priority

Apply these three to every diff before anything else.

- **Any literal `Time.now`, `Time.new`, `Date.today`, `SecureRandom.*`, `Random`, `rand`, `$stderr`,
  `puts`, `Logger`, `Socket`, `Process.pid`, `ENV`, or file/network IO added under `lib/sodalite/`
  on a request path.** Request paths are `App#call` and everything it reaches: `lib/sodalite/app.rb`,
  `render.rb`, `request.rb`, `response.rb`, `route.rb`, `router.rb`, `text.rb`, `health.rb`,
  `store.rb`, `db.rb` and the query/relation side of `lib/sodalite/db/`. The framework's own IO is
  already routed through `Sodalite::Effects::CLOCK` / `ID` / `LOG` / `CONTRACT`
  (`lib/sodalite/effects.rb:12-17`). Anything else is a reproducibility break: the same request stops
  being byte-for-byte reproducible from `Effects.fixed`, and the caller who supplied a fixed world
  silently gets a real one.
- **Any new mutable state reachable from the frozen app.** `App#initialize` ends in `freeze`
  (`lib/sodalite/app.rb:52`); `Router`, `Route`, `Renderer`, and `TextSchema` all freeze themselves
  too. A memoization `@cache ||=`, a lazily-populated Hash, a module-level `@@` or `ARRAY <<`
  accumulator, a `Struct` field written during `call` — each is a data race across Puma threads, not
  a performance win. Per-request state is one `Berylx::Root` and nothing else.
- **Any check moved out of a constructor into `call`.** Every check that can be made at boot is made
  at boot. Turning a boot refusal into a request-time error converts "the server will not start"
  into "production returns 500 on the one request that exercises it".

---

## 1. The world is a parameter — and the suite does not fully enforce this

Read this section before assuming a test will catch a violation.

**There is no static test that greps `lib/` for `Time.now`.** The enforcement is behavioural and
partial: `test/substrate_test.rb:39` (`test_the_whole_request_is_reproducible_from_fixed_handlers`)
builds the same app twice under `Effects.fixed` and asserts the two Rack triples are equal, and
`Sodalite::Effects.check` (`lib/sodalite/effects.rb:99-104`) raises when an application tag collides
with a reserved one. A literal `Time.now` that never reaches the response body — in a log line, a
cache key, a header, an ID, a metric — passes the whole suite. **So you are the check.** Report the
literal call itself, with the concrete scenario: two identical requests under `Effects.fixed` now
produce different output / a test that pinned `now:` now sees wall-clock time.

Rules:

- New framework-level IO gets a new `:sodalite_*` tag in `Effects::RESERVED` and a handler in both
  `Effects.defaults` and `Effects.fixed`. A tag added to `defaults` but not to `fixed` means the
  fixed world raises `KeyError` on a path the real world serves — flag the asymmetry.
- Do not accept "it's only in the error path" or "it's only for logging". Logging is
  `io.perform(Effects::LOG, …)`; see `Renderer#log_failure` (`lib/sodalite/render.rb:82-89`).
- A handler a caller supplies must be thread-safe. `Effects.fixed` guards its own counter and log
  with a `Mutex` (`lib/sodalite/effects.rb:41-51`); a new stateful default handler without one is a
  race under `parallel`.

**Precedent — do not report these.** `lib/sodalite/db/ledger.rb` uses `SecureRandom.hex` (line 37),
`Socket.gethostname`/`Process.pid` (line ~77), and `Time.now.utc` (lines 72, 83). This is deliberate
and commented in place: the migration runner is outside request paths, a lock row needs a real
holder and a real age, and a migration lock that could be faked by a fixed clock would not be a lock.
`Effects.defaults` itself contains `Time.now.utc` and `SecureRandom.uuid` — that is the door, not a
violation.

## 2. Frozen at boot, one `Berylx::Root` per request

- Flag any `attr_writer`, `attr_accessor`, or `def something=` added to `App`, `Router`, `Route`,
  `Renderer`, `TextSchema`, `Response`, or `Stream`. These are frozen; a writer either raises
  `FrozenError` in production or reveals that someone removed a `freeze`.
- Flag any removal of a `freeze` call, and any `.dup`/`.clone` introduced to work around one — the
  dup is usually the shared-state bug arriving by another route.
- `Router::Node` (`lib/sodalite/router.rb:22-32`) is mutable *during construction only* and the
  `Router` freezes at line 40. A `Node` mutated from `match`/`descend` is a threading bug: two
  concurrent requests walking the trie would see a half-written node.
- `Berylx::Root[request:, response:]` (`lib/sodalite/app.rb:77`) is the only per-request state. State
  smuggled into an instance variable, a thread-local, a `Fiber` storage slot, or a constant Hash keyed
  by request id is the same defect wearing a different hat — report it with the interleaving that
  breaks it.
- `parallel` branches run on their own threads and inherit the same frozen map
  (`test/substrate_test.rb:110`). A capability that becomes stateful breaks `parallel`, not just
  `call`.

## 3. Two vocabularies, one error path — and out is the same sieve

Bodies pass through the sieve unchanged, because JSON carries types. Path parameters, query, and
headers decode through `TextSchema` (`lib/sodalite/text.rb`) *before* the sieve, because a URL carries
none. The seam between them is load-bearing.

- **Never add coercion to the sieve** to make a route convenient. `"1"` is not an `Integer` in a JSON
  body; a document that wrote `"1"` had `1` available and chose not to use it. A diff that relaxes
  this to unblock one route relaxes it for every boundary the sieve guards.
- **Text that does not decode is passed through unchanged**, so the *schema* produces the violation
  with the right pointer and code. `TextSchema.leaf_decoder` returns the original `text` when the
  decoder answers `MISS` (`lib/sodalite/text.rb:85-93`). A diff that makes the decoder raise, return
  `nil`, or build its own `Zeolite::Violation` grows a second error path: the client stops getting
  `/query/page` with `type_mismatch` and starts getting an unlocated 400 or a 500. Both changes look
  like error handling being improved.
- Adding a decoder to `TextSchema::DECODERS` is fine and expected when a new leaf type appears. Note
  that `:time` is deliberately `IDENTITY` (line 28) — the sieve parses it from the String. Do not
  "fix" that.
- **Out is the same sieve.** `Renderer#response` generates JSON and validates *that JSON*
  (`lib/sodalite/render.rb:24-27`, `check` at 54-60). Flag any change that compares a Hash to a schema
  instead, or that skips `check` when the body "obviously" fits, or that caches the check result per
  route. What is checked has to be what the client receives, or "typed on the way out" stops being
  literally true.
- **A contract breach is not an ordinary error.** It performs `Effects::CONTRACT` with an
  `Effects::Breach` so the handler decides the cost — `Effects.fixed` raises `ContractError` so drift
  fails the suite, `Effects.real` logs and returns 500 so drift does not ship a wrong shape. A diff
  that raises directly, or returns a plain 500 without performing the tag, deletes the suite's only
  signal that a service drifted from its published contract.
- Streaming keeps this shape: records are validated one at a time as they are emitted
  (`lib/sodalite/response.rb:49-58`) and a broken record `throw`s to stop the stream, because the
  status line is already on the wire. Do not "optimise" that into validating the whole body first —
  that reintroduces the buffering the stream exists to avoid.

## 4. Everything checkable is checked at boot

These are the boot refusals. Each one is a production 500 the moment it moves to request time.

- Undeclared/mismatched template params → `RouteError` (`Route#check_params_match_template!`,
  `lib/sodalite/route.rb:85-93`).
- An uncompilable `run:` → `RouteError`, raised by asking berylx at boot (`Route#check_runnable!`,
  lines 97-101).
- Two routes that could answer the same request → `Router::ConflictError` (`lib/sodalite/router.rb:77-83`).
- Two different parameter names in one position (`/users/:id` and `/users/:slug`) → `ConflictError`
  (lines 88-91). One of them is a lie about what that segment is.
- An application effect tag colliding with `:sodalite_*` → `ArgumentError` (`Effects.check`).
- An unapplied *expansion*, or a ledger holding steps this checkout does not declare → refuse to
  start (`DB.capability` → `verify!`, `lib/sodalite/db.rb:159-162`, `db/ledger.rb#verify!`).

Report as a defect: downgrading any of these to a warning, a `Kernel#warn`, a logged message, or a
skip-if-configured; making any of them opt-in; or adding a keyword that waives one. A refusal an
argument can waive is not a refusal. New checks belong in the constructor, not in `call`.

Path handling is also a boot-and-parse invariant: `Router#split` splits on `/` **first** and
percent-decodes **second** (`lib/sodalite/router.rb:57-59`). Reversing that order lets `%2F` invent a
path separator and cross into another route's namespace — report it as a routing/authorization break,
not a style change. Likewise `Route#parse_template` admits only `[:static, text]` and `[:param, name]`
(lines 62-68); a regex or wildcard segment added to the template language is a design change.

## 5. Capabilities compose through `Effects.assemble`, never by merging over a finished map

`Effects.assemble` (`lib/sodalite/effects.rb:78-85`) hands each capability a `rebuild` lambda that
re-derives the **whole** map with one capability swapped. This is the failure that looks like it
works, so read scope code carefully:

- The combinator handlers inside a finished map close over the map they were built with. A nested
  `handlers.merge(store: journalled_store)` runs the subtree on the *original* bindings. Shallow tests
  pass — the top-level tag is right — and the subtree silently runs against stale handlers. For a
  saga that means the journal never sees a write and compensation does nothing, quietly
  (`docs/migrations.md`, "A saga scope is a handler-map swap, built rather than merged"). Flag any
  `merge` applied to an already-assembled handler map, or any scope that constructs handlers itself
  instead of calling `rebuild`.
- A capability's `effects(rebuild)` must keep returning a flat tag→lambda Hash. `DB::Capability`
  (`lib/sodalite/db.rb:129-149`) and the store capability are the shape to match; a capability that
  returns a nested Hash breaks `reduce(effects) { |all, c| all.merge(c.effects(rebuild)) }`.
- `test/assembly_test.rb:35` and `:52` are the regression: a saga or transaction scope must keep the
  *other* capabilities. A change that narrows `rebuild` to the swapped capability drops the database
  handlers inside a saga.
- A store cannot join `DB.atomically`, and `Store.saga` is deliberately **lax** — compensation cannot
  unread. Do not report the laxness as a bug, and do report any diff that renames `saga` to
  `transaction`, or that claims atomicity across the store and the database.

## 6. A migration is a set, and the order is solved

`lib/sodalite/db/migration.rb`, `db/plan.rb`, `db/ledger.rb`, `docs/migrations.md`.

- **Never reintroduce an index as the ledger key.** A step's identity is its content — a normalised,
  prefix-free serialisation under the `v1` scheme tag, digested in `Step#fingerprint`
  (`db/migration.rb`, `FINGERPRINT_SCHEME`). This is not decoration: an index-keyed ledger turned an
  ordinary two-branch merge into a fingerprint mismatch on migrations nobody touched. Flag any
  position/index/timestamp/`declared_at` sneaking into the ledger key or the digest input.
- **Do not change the fingerprint input casually, and never fall back to `inspect`.** The address was
  `args.inspect` once; `inspect` renders a Hash in insertion order, so permuting the fields of a
  `create_table` — a refactor that changes no meaning — minted a second address and a ledger keyed by
  address then called an applied step unapplied. If a diff touches `normalise` or
  `FINGERPRINT_SCHEME`, say plainly that **every fingerprint changes**, `verify!` will refuse every
  existing database, and there is no automatic conversion — recovery is rewriting the `fingerprint`
  column of `sodalite_migrations` by hand. A change to the rules without bumping the scheme tag is
  worse: addresses collide silently with those computed under the old rules.
- **`to:` and `reversible_after?` count along `plan.order`, not declaration order.** `schema_after`,
  `spec_after`, `reversible_after?`, and `rollback!(to:)` must all index the same solved number line
  (`Ledger#ordered_steps` returns `history.plan.order`). A diff that indexes the declaration array
  makes "reversible to 3" and "roll back to 3" name two different prefixes.
- **Applying is one explicit command with a lock; boot verifies and never migrates.** Flag anything
  that calls `migrate!` from `App.build`, a capability, a Rack `config.ru`, an initializer, or a
  `at_exit`. A service runs N processes on M hosts, so a boot-time migration has no single writer —
  and it also runs during a *rollback*, at the one moment nobody wants schema changes.
- One step is one transaction: `apply_step` reads first, then wraps `carry` + `record_step` in
  `migration_scope` (`db/ledger.rb`). The lock stays **outside** that scope — rows written inside
  would roll back with it and release a lock the failed step never let go of. Flag any diff that moves
  `claim_lock`/`release_lock` inside, or that splits `carry` and `record_step` across two scopes.
- `refuse_untransactional_ddl!` has no override keyword, and `steal_lock!(older_than:)` has no
  default. Adding either is a reportable weakening: a lease that expires while the first runner is
  merely slow gives you two writers, which is what the lock existed to prevent.
- `verify!` reads the ledger and **nothing else**. Do not report "it should also check the catalog" —
  that is a deliberate decision (one truth that can be wrong beats two that disagree). Do report a
  diff that *adds* catalog introspection to `verify!`.
- Expansion (`create_table`, `add_attribute`) and reversibility are different sets
  (`EXPAND_STEPS` vs `INJECTIVE_STEPS` in `db/migration.rb`). A rename is reversible and **not** an
  expansion. Code that conflates them makes `plan.expand_only?` answer the wrong deploy question, and
  the visible failure is old processes 500ing against a renamed column during a rolling deploy.

## 7. Packaging, dependency direction, and derived artefacts

- **`sodalite` requires `zeolite`; `zeolite` must never learn this library exists.** They are separate
  repositories precisely to protect zeolite's zero-runtime-dependency claim. Flag any suggestion (in
  code or comment) that a fix belongs upstream in zeolite in a way that would make it aware of routes,
  Rack, or sodalite types. `Zeolite.enum` remains the only door from document text to a `Symbol` — a
  query string must not be able to grow the symbol table.
- **`spec.files` in `sodalite.gemspec` is an explicit `Dir[...]` allowlist**: `lib/**/*.rb`,
  `docs/**/*.md`, `README.md`, `LICENSE`, `AGENTS.md`. A new source file outside `lib/`, or a non-`.rb`
  file inside `lib/` (a template, a `.yml`, a data table), is **silently absent from the built gem
  while `gem build sodalite.gemspec` still passes and the whole test suite is green**, because tests
  run from the checkout. The failure is `LoadError` for the first user who installs the gem. Flag any
  new file that `spec.files` will not match, or a `require_relative` pointing outside `lib/`.
- **The OpenAPI document is derived, never maintained.** `Sodalite::OpenAPI.document` folds over
  `app.routes` (`lib/sodalite/openapi.rb`); there is no committed `openapi.json` and there must not be
  one. Report: a static document added to the repo, a per-route annotation hash, a `route.openapi_hack`
  keyword, or a special case keyed on a route name inside `openapi.rb`. If a shape is not readable
  from the route's declaration, the answer is to declare it, not to annotate the document.
- CI (`.github/workflows/ci.yml`) runs `bundle exec rake test`, `bundle exec rubocop`, and
  `gem build sodalite.gemspec` on Ruby **3.2, 3.3, 3.4, and 4.0**, `fail-fast: false`. Flag any API
  used that is newer than the 3.2 floor (`spec.required_ruby_version`, `TargetRubyVersion` in
  `.rubocop.yml`): `Data.define` and pattern matching are fine, but e.g. a 3.4-only method or a
  `it`-block parameter breaks the 3.2 leg only. Also flag reliance on a default gem that Ruby 4.0
  dropped — `logger` is already declared in the `Gemfile` for exactly this reason.
- `test/puma_test.rb` is the **only** suite that binds a socket (ephemeral port, real Puma launcher,
  10s boot timeout) and is therefore the most likely flake source. Report any diff that skips it,
  guards it behind an env var, or shortens `BOOT_TIMEOUT` — it is the only real-transport coverage in
  the repo, and without it the streaming path is never exercised over a real connection. Fixing a
  flake by making the boot wait more robust is fine; deleting the coverage is not.

## 8. Settled convention here — refute findings that object to these

If a finding is really an objection to one of these, it is a false positive:

- Long doc comments carrying design rationale in prose. That is how this repo records *why*.
- `Data.define` with a `self.[]` constructor (`Route`, `Response`, `Refusal`, `Breach`, `Step`), and
  `private_constant` for internals.
- Keyword-argument-heavy constructors. `Metrics/ParameterLists` sets `CountKeywordArgs: false`
  deliberately (`.rubocop.yml`).
- Short parameter names `fk`, `io`, `id`, `as`, `db`, `to` — allowlisted in `.rubocop.yml` with a
  written reason. `to:` is migration vocabulary, not a missing `target_version`.
- No DSL, no `Sodalite.configure`, no autoloading, no `method_missing`, no reopened classes.
  Proposing any of them is proposing a different framework.
- Integrity is *reported*, not enforced: `insert` does not check foreign keys, `delete` does not check
  referrers, the DDL emits no `REFERENCES`, and `functor?`/`violations`/`equation_violations` answer
  when asked. Documented in `docs/design.md`. Do not report the missing enforcement.
- The DB signature is five operations (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `ATOMICALLY`) and is
  closed. "A caller would find it convenient" is explicitly not an argument for a sixth; what is
  offered is what carries a law (`avg` is out for not being a monoid, `join` for being what a compiler
  emits, `subtract` for being `add` of a negative). Report a *widening* of the signature; do not
  report its narrowness.
- `Π_F` (join-as-migration) is genuinely absent and deliberately not relabelled. `:boolean` is
  unusable with the hand-written SQL model, and the hand-written dialect surface is ANSI. All three
  are named in `docs/migrations.md` — do not re-report them as discoveries.

## Severity

- **Critical** — a data race under Puma threads (mutable state reachable from the frozen app); a
  migration change that alters fingerprints, keys the ledger by index, or lets a serving process
  migrate; a `verify!`/boot refusal downgraded to a warning; a nested-map merge in a saga or
  transaction scope; percent-decode reordered before path split.
- **High** — literal `Time.now`/`SecureRandom`/logger IO on a request path; a boot check moved into
  `call`; coercion added to the sieve or a second error path grown in the decoder; the response
  contract validating a Hash instead of the JSON; a contract breach turned into a plain 500; a new
  source file that `spec.files` will not ship.
- **Medium** — a fixed/real handler-map asymmetry; a capability returning a non-flat effects Hash;
  a hand-maintained OpenAPI annotation; a Ruby-version floor violation that breaks only the 3.2 leg;
  weakening `test/puma_test.rb`.
- Anything that weakens one of the four properties: report it at **High or above regardless of the
  local quality of the code**, and say explicitly that it is a redesign rather than a patch.

## Appendix: source files this policy is derived from

- `AGENTS.md` — the four properties, the repository rules, the commands, the note that
  `test/puma_test.rb` is the one suite needing a socket.
- `docs/design.md` — the four properties in full, "what it refuses", the two vocabularies, out-is-the-
  same-sieve, the database-as-theory argument, concurrency, dependency direction, open questions.
- `docs/migrations.md` — the solved order, the content address and the one time it changed, the
  procedure (one explicit command, a lock with a holder, boot verifies and refuses), the
  expand/reversible tables, the saga's built-not-merged map.
- `lib/sodalite/effects.rb` — reserved tags, `real`/`fixed`/`defaults`, `assemble` + `rebuild`,
  `around`, `check`.
- `lib/sodalite/app.rb` — freeze at boot, the sieve-in path, `Berylx::Root` per request, refusals.
- `lib/sodalite/render.rb`, `response.rb` — the sieve-out path, `Effects::CONTRACT`, `Stream`.
- `lib/sodalite/text.rb` — `TextSchema`, `MISS`, pass-through on failed decode.
- `lib/sodalite/route.rb`, `router.rb` — boot checks, the segment trie, split-then-unescape.
- `lib/sodalite/db.rb`, `db/migration.rb`, `db/plan.rb`, `db/ledger.rb` — the five operations,
  `Capability`, `Step#fingerprint`, `Plan#solve`, `migrate!`/`rollback!`/`verify!`, the lock.
- `lib/sodalite/openapi.rb` — the derived document.
- `test/substrate_test.rb`, `test/assembly_test.rb`, `test/puma_test.rb` — what the suite does and
  does not enforce.
- `sodalite.gemspec`, `Gemfile`, `Rakefile`, `.rubocop.yml`, `.github/workflows/ci.yml` — packaging,
  the Ruby matrix, the allowlisted cop exceptions.
