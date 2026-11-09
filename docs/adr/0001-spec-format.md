# 0001: Spec format: Elixir DSL for the schema, JSON on the wire

Status: accepted, 2026-10-27 (approved by Melle in mica-bff#1)

## Context

The BFF builds pages out of blocks; the iOS app (later Android and web) renders them. Both sides are generated from one spec, so a change in the spec never waits for hand-written code on either side. The spec covers blocks now, and later pages and endpoints: where a client gets the BFF response for a page, and how forms are submitted.

Old app versions stay installed while the spec keeps changing: new blocks, new properties, changed property types, removed properties. Every layer has its own way of staying robust (Melle, 2026-10-27), and there may be more:

- **App block renderer**: always renders something useful when a block changes: a new type, a new property, a changed property type or a removed property.
- **BFF engine, content negotiation**: the app tells the BFF which spec version it implements; the BFF can give it a different view model, with older blocks it can render.
- **App**: update announcements, optional or forced.

The board asked to research a schema format, with XSD-style contract validation as one candidate.

## Decision

"The spec" is the whole; it has these layers:

| Layer | What | Where |
|---|---|---|
| Schema | What a valid spec is: the DSL (`defblock`, `field`), the primitive types, the rules. The role an XSD plays for XML. | `MicaBff.Schema` |
| Block catalogue | The blocks themselves, written with the schema DSL | `MicaBff.Blocks` |
| Pages | The pages the BFF serves (`defpage`) | `MicaBff.Pages` (amended 2026-11-05) |
| Protocol | The other calls: boot, form submission (`defendpoint`) | later |
| Generated code | Client code, generated from the above; server code, defined from it at compile time | next-ios; mica, by a macro |

Split the spec into two problems (Melle, 2026-10-27):

1. **Data model**: an Elixir DSL with macros. The schema defines what a valid spec is, like an XSD for XML; the modules that use it are the spec, like the XML document: one per kind (`MicaBff.Blocks`, `MicaBff.Pages`), composed by `MicaBff.Spec`, whose `__schema__/0` returns the whole spec as data (amended 2026-11-05).
   - `defblock` (now): a block the BFF sends and clients render.
   - `defpage` (now, amended 2026-11-04): a page the BFF serves. Always a GET that returns `{"blocks": [...]}`, at `/bff/page/<page>`: the path follows from the page name (`defpage :home` → `GET /bff/page/home`), singular because a request fetches one page. `__schema__/0` lists the pages with their paths, and the Elixir macro gives the server `pages/0` on the namespace module, so the BFF serves exactly the spec's pages. The Swift generator doesn't read pages yet; the client's router gets them when it needs to recognise BFF URLs. These requests come from a separate BFF system in mica, not from the existing LiveView routes.
   - `defendpoint` (later): every other call (boot, form submission) with its method, path, request body and response.

   Page and endpoint stay separate concepts. A `kind: :page` next to `:get`/`:post` would mix how a request travels (method) with what it returns: a page is always a GET with blocks, and a form POST can also answer with blocks.

   **Navigation belongs to the client, not the spec.** A block that opens something carries only the destination (`section.to`). The client's router (navigation rules, UC-SENSE-06) decides whether it opens a native page, a BFF page or a web page, and how it is presented. Moving a page between native, BFF and web changes no spec and no block. `defpage` lets the router recognise BFF URLs; nothing in the spec has to point at it.
2. **Serialization**: JSON, with these rules:
   - A block is `{"type": "section", "props": {...}}`. Type and prop names are the snake_case names from the schema; generators map them to each platform's naming.
   - An optional prop that is `nil` is left out by the BFF; `""`, `0`, `false` and empty lists or maps are values and are sent. Clients treat a missing prop and `null` the same.
   - Clients ignore unknown keys, both next to `type`/`props` and inside `props`.
   - An `:integer` prop is a JSON number without a fraction; a `:float` prop accepts any JSON number.
   - A destination such as `section.to` is a path (`/pool/1/marketplace`), resolved against the app's base URL for its environment. How client-only actions (log out) are expressed is decided with the first block that needs one.

**Blocks have no children.** A page is a flat, ordered list of blocks; no block contains another block. A field holds a primitive, never a block, and the DSL rejects it at compile time. This keeps the generated decoding and the renderers flat, and an unknown block type only ever replaces itself with a fallback. The client knows nothing about grouping yet, so there is no header block: a `section` without `to` is a plain line of text. Nesting is revisited when a page needs it; the Pixel core set's typed children are the reference then.

Nested data types (a `defmodel`, e.g. an image with url, width and height) are added when a block needs one.

The Swift generator is a Mix task in this repo. It reads the block catalogue as plain data (`__schema__/0`), not the source. CI regenerates the Swift code and commits it to `next-ios`, which keeps a reviewable diff and builds without depending on this repo.

`mica` depends on this repo at compile time at a pinned ref. A macro defines the block modules while it compiles, and the reviewable diff there is the ref bump.

Amended 2026-11-03: `mica` used to get generated code committed by CI as well. Elixir can read the spec directly, so copying it into `mica` added a PR and no value.

### Compatibility

- The client renders an unknown block type as a fallback block. A known block that fails to decode (for example, a required prop is missing or has the wrong type) is treated the same way: that block becomes a fallback, the rest of the page renders.
- An optional prop that fails to decode (for example, its type changed) is treated as missing: the block still renders without it.
- New blocks and new optional props can be added at any time. A new field on an existing block is always optional, so an older server or a cached page still decodes in a newer client.
- A field is deprecated before it is removed, and removed only after the minimum app version no longer reads it.
- Unknown enum values map to a fallback that the enum declares, once enums exist.
- The spec version is the git tag (`v0.1.0`, …). CI compares the block catalogue with the last tag and fails on a breaking change.
- A field records its versions with `since:` and `deprecated:` (amended 2026-11-05). `mix bff.compat` enforces the rules above in CI; a field that was deprecated in the last tag may be removed without failing. CI only checks that deprecation: "removed only after the minimum app version no longer reads it" stays a human check.
- Every BFF request carries the spec version the app implements, so the BFF can answer with blocks that version can render (content negotiation; part of the protocol, `defpage`/`defendpoint`). It travels in the request header `x-bff-spec` (for example `x-bff-spec: 0.1.0`; amended 2026-11-04). Until the first breaking change the BFF only records it and serves the same blocks to every version.

## Alternatives

| Option | Why not |
|---|---|
| JSON Schema | Standard and validates JSON directly, but expresses no endpoints, and Elixir codegen from it is weak. Generators would fight the schema language instead of reading plain data. |
| TypeSpec / OpenAPI | Good for endpoints, but adds a Node toolchain and a second language to a team that writes Elixir; still needs custom generators for the fallback-tolerant Swift decoding. |
| Protobuf | Binary wire format and its own toolchain; JSON is easier to debug and what the clients already speak. Unknown-field handling is good, but we don't need its size gains. |
| XSD | Validates XML, not JSON. The schema DSL takes over its role: it rejects an invalid spec at compile time, and payloads will be validated against the block catalogue (see below). |

## Consequences

- One language for the spec, the generators and the server; generators get the full spec as data, without parsing a schema language.
- A mistake in the spec fails at compile time and points at its line: an unknown type or option, a name that isn't a snake_case atom, a duplicate name, a block used as a field or named after a primitive, a `field` outside a `defblock`, a `defblock` inside another, a malformed or out-of-order version.
- Payload validation is not built yet. A validator against `__schema__/0`, plus example payloads per block that the generated server and client code must encode and decode, is planned as the contract validation work. Until then the rules above are prose.
- Editing the spec means editing Elixir, also for iOS developers. If that becomes a problem, a docs generator generates the spec as Markdown.
- A consumer that needs a standard schema (Android tooling, external parties) gets one more generator that exports JSON Schema from the same data.
