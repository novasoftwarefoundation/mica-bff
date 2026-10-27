# mica-bff

The spec for the Mica backend for frontend (BFF): the blocks the server sends and the clients render, and the generators that turn the spec into server code (`mica`) and client code (`next-ios`).

- `lib/mica_bff/spec.ex`: the DSL (`defblock`, `defmodel`, `field`)
- `lib/mica_bff/blocks.ex`: the block spec
- `docs/adr/`: decisions, starting with [0001: spec format](docs/adr/0001-spec-format.md)

Blocks travel as JSON: `{"type": "section", "props": {"title": "...", "link": {"to": "/..."}}}`.

```sh
mix test
mix run -e 'IO.inspect(MicaBff.Blocks.__spec__())'
```
