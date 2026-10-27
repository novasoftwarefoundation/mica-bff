# mica-bff

The spec for the Mica backend for frontend (BFF): the blocks the server sends and the clients render, and the generators that turn the spec into server code (`mica`) and client code (`next-ios`).

- `lib/mica_bff/schema.ex`: the schema, written as a DSL (`defblock`, `field`)
- `lib/mica_bff/blocks.ex`: the block catalogue
- `lib/mix/tasks/bff.gen.elixir.ex`: generates the Elixir block modules for mica
- `fixtures/`: example payloads; generated code must encode them back exactly
- `docs/adr/`: decisions, starting with [0001: spec format](docs/adr/0001-spec-format.md)

Blocks travel as JSON: `{"type": "section", "props": {"title": "...", "to": "/..."}}`.

```sh
mix test
mix run -e 'IO.inspect(MicaBff.Blocks.__schema__())'

# one module per block (struct + to_map/1), e.g. Systems.BFF.Blocks.Section
mix bff.gen.elixir --out ../mono/core/mica/systems/bff/blocks
```
