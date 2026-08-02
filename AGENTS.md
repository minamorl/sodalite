# AGENTS.md

## Project

Sodalite is a web framework on four pieces that already refuse to guess: puma (transport), zeolite
(the sieve at both boundaries), berylx (named tasks over focused state), darkcore (effects as tagged
values). Four properties define it; a change that weakens any of them is a redesign, not a patch:

1. **The request is a value.** The Rack env never reaches a task. A route declares the shape of its
   params, query, and body; what does not fit is a 400 listing every violation, each located by a
   pointer that says which part of the request it came from.
2. **The world is a parameter.** Every effect goes through the handler map — the framework's own IO
   included. A literal `Time.now`, `SecureRandom`, or logger call on a request path breaks
   reproducibility, and there is a test that says so.
3. **Failure keeps its state.** `Berylx::Err(partial_lay, error)` maps to a declared status; the
   failed task name and trace go to the log; an unmapped error is a 500 that does not leak.
4. **Cross-cutting is a handler swap.** `Effects.around`, never a callback chain or a middleware that
   rewrites a route.

Read `docs/design.md` before changing the design.

## Repository rules

- **Dependency direction is one-way.** `sodalite` requires `zeolite`. `zeolite` must never learn that
  this library exists, and its zero-runtime-dependency claim is why the two are separate repositories
  rather than two gemspecs in one.
- **Two vocabularies, one error path.** Bodies go through the sieve unchanged, because JSON carries
  types. Path, query, and headers decode through `TextSchema` *before* the sieve, because a URL
  carries none. Text that does not decode is passed through **unchanged** so the schema — not the
  decoder — reports the violation. Do not add coercion to the sieve to make a route convenient, and
  do not grow a second error path in the decoder.
- **Everything checkable is checked at boot.** Undeclared template params, route conflicts, two
  parameter names in one position, an uncompilable `run:`, colliding effect tags. A new check belongs
  in the constructor, not in `call`.
- **Out is the same sieve.** The response contract validates the JSON the client will actually
  receive, not a Hash that resembles it. Do not "optimise" that into a Hash comparison.
- **A contract breach is not an ordinary error.** It performs `:sodalite_contract` so the handler
  decides the cost — raise under `fixed`, logged 500 under `real`. Do not turn it into a plain 500.
- **The app is frozen at boot** and shared across Puma threads. Nothing may become mutable shared
  state. Per-request state is one `Berylx::Root` and nothing else.
- **`:sodalite_*` tags are the framework's.** Application tags that collide raise; keep it that way.
- **Capabilities compose through `Effects.assemble`, not by nesting one map inside another.** A scope
  (a transaction, a saga) is handed `rebuild` and re-derives the *whole* map with one capability
  swapped. Merging over a finished map is the failure that looks like it works: the combinator
  handlers inside close over the map they were built with, so the subtree runs on the old bindings.
- **The OpenAPI document is derived, never maintained.** If a shape is not readable from the route's
  declaration, the answer is to declare it, not to annotate the document.

## Commands

```sh
bundle install
bundle exec rake              # tests + rubocop
bundle exec rake test
bundle exec rubocop
ruby -Ilib examples/service/app.rb          # the whole service, against a fixed world
ruby -Ilib examples/service/app.rb openapi  # its published document
ruby -Ilib examples/service/boot.rb         # the same service on puma
ruby -Ilib examples/minimal.rb              # the smallest thing that runs
```

`test/puma_test.rb` boots real Puma on an ephemeral port; it is the one suite that needs a socket.

## Before handing off

Run tests, rubocop, and `gem build sodalite.gemspec`.
