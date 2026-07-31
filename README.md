# Sodalite

[![CI](https://github.com/minamorl/sodalite/actions/workflows/ci.yml/badge.svg)](https://github.com/minamorl/sodalite/actions/workflows/ci.yml)
[![Ruby 3.2+](https://img.shields.io/badge/Ruby-3.2%2B-CC342D.svg)](https://www.ruby-lang.org/)

**A web framework where the request is a value, the world is a parameter, and nothing untyped gets in
or out.**

```ruby
require 'sodalite'

load_user = Berylx::Task[:load_user] do |lay, io|
  user = io.perform(:find_user, lay[:request].get.params.id)
  user ? lay[:user].set(user) : lay.reject(:not_found, 'no such user')
end

present = Berylx::Task[:present] do |lay|
  lay[:response].set(Sodalite.ok({ id: lay[:user].get[:id], name: lay[:user].get[:name] }))
end

show_user = Sodalite::Route[
  :get, '/users/:id',
  params:    { id: :integer },
  query:     { loud: :boolean? },
  responses: { 200 => { id: :integer, name: :string } },
  run:       load_user >> present
]

app = Sodalite::App.new(
  routes:   [show_user],
  handlers: Sodalite::Effects.real(find_user: ->(id) { DB.user(id) }),
  errors:   { not_found: 404 }
)
```

```sh
GET /users/7     -> 200 {"id":7,"name":"mina"}
GET /users/9     -> 404 {"error":{"code":"not_found","message":"no such user"},"violations":[]}
GET /users/abc   -> 400 {"error":{"code":"invalid_request",...},
                         "violations":[{"path":"/params/id","code":"type_mismatch",
                                        "message":"expected integer, got string"}]}
```

## The stack

Nothing in this column is new. The framework is the wiring, and the wiring is the whole claim: each
of these four already refuses to guess, so a request has nowhere left to be vague.

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

## The four properties

**1. The request is a value.** The Rack env does not reach your code. A route declares the shape of
its path parameters, query, and body; what a task receives is a frozen `Data` instance with real
readers. A request that does not fit never becomes one — it is a 400 listing *every* violation, each
located by a JSON Pointer that says which part of the request it came from.

**2. The world is a parameter.** Every effect is `io.perform(tag, payload)`, dispatched through the
handler map the app is running under. The same routes, the same router, the same sieve, the same
workflow — with no database, no clock, and no socket:

```ruby
Sodalite::App.new(routes: ROUTES, handlers: Sodalite::Effects.real(find_user: DB.method(:user)))
Sodalite::App.new(routes: ROUTES, handlers: Sodalite::Effects.fixed(find_user: ->(_id) { { id: 7 } }))
```

The framework's own IO goes through the same door — `:sodalite_clock`, `:sodalite_id`,
`:sodalite_log`, `:sodalite_contract` — so there is no `Time.now` and no `SecureRandom` reachable
from a request path except through a handler you supplied. A whole request is reproducible byte for
byte.

**3. Failure keeps its state.** A route is a berylx workflow, so a failure is
`Err(partial_lay, error)`: which named task failed, with what state, and what the earlier steps had
already established. The client sees the status you declared for that code; the log sees the task
name and the trace. An error you did not map is a 500 whose message does not leak.

**4. Cross-cutting is a handler swap.** Build timing, audit, retry, or dry-run with
`Effects.around`, which wraps the interpreter and passes the wrapped map into `parallel`, `branch`,
and `rescue` subtrees. The route is never rewritten to be observed. No `before_action`, no callback
chain to get the order wrong in.

## What it refuses

- **No DSL.** Routes and schemas are Ruby literals. Nothing is `instance_eval`ed, nothing is
  `method_missing`ed, no class is reopened, no file is autoloaded.
- **No global state.** There is no `Sodalite.configure`. The app is an object, it is given what it
  needs at construction, it freezes itself, and the only per-request state is one `Berylx::Root`.
- **No ORM, no views, no assets, no generators.** This is a framework for services with contracts.
- **No implicit type guessing.** Bodies go through the sieve unchanged; path and query take one
  explicit *declared* decode step, because a URL carries no types and JSON does.
- **No durability.** In-process, like berylx. Work that must survive a restart wants a durable engine.
- **No Rails compatibility.** Rack compatibility at the transport edge, and that is the extent of it.

## Ambiguity is a boot error

Every check that can be made when the app is built is made then, because a route that fails on the
one request that happens to exercise it is a route that fails at 3am.

- A template parameter that is not declared, or a declared parameter not in the template.
- Two routes that could answer the same request.
- Two different parameter names in the same position (`/users/:id` and `/users/:slug`).
- A `run:` that berylx cannot compile.
- An effect tag colliding with a framework or berylx tag.

Matching is a segment trie built once and frozen: static beats parameter, and a static prefix that
dead-ends backtracks rather than shadowing a parameter route that would have matched. Segments are
split before they are percent-decoded, so `%2F` is data inside one segment and never invents a path
separator.

## Streaming

The sieve reads NDJSON and SSE one record at a time; this writes them the same way, validating each
record as it is emitted.

```ruby
lay[:response].set(
  Sodalite.stream(200, { seq: :integer, kind: Zeolite.enum(:tick, :done) }) do |emit, io|
    io.perform(:subscribe).each { |event| emit.call({ seq: event.seq, kind: event.kind }) }
  end
)
```

## Install

```ruby
gem 'sodalite'
```

Ruby 3.2 or newer, tested through Ruby 4.0. Depends on
[zeolite](https://github.com/minamorl/zeolite), [berylx](https://github.com/minamorl/berylx),
[darkcore](https://github.com/minamorl/darkcore-ruby), rack, and puma. Neither berylx nor darkcore is
published yet, so development takes all three siblings from git.

## Documentation

| Guide | What it covers |
| --- | --- |
| [The design](docs/design.md) | Why each layer is there, the two vocabularies, and what is deliberately not built |
| [`examples/service.rb`](examples/service.rb) | A complete service, run twice — against a fixed world in process, and on Puma |

```sh
ruby -Ilib examples/service.rb          # deterministic, no server
ruby -Ilib examples/service.rb serve    # puma on 127.0.0.1:9292
```

## Why "sodalite"

In mineralogy the **sodalite cage** is the structural unit that zeolite frameworks are assembled
from — the β-cage that Zeolite A, X, and Y are built out of. "Framework" is the crystallographic term
for those structures, not a metaphor borrowed for the occasion. This is the framework built on the
sieve, named after the sieve's own building block.

## Development

```sh
bundle install
bundle exec rake        # tests + rubocop
```

## License

MIT.
