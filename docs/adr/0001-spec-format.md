# 0001: Spec format: Elixir DSL for the data model, JSON on the wire

Status: proposed, 2026-10-27

## Context

The BFF builds pages out of blocks; the iOS app (later Android and web) renders them. Both sides are generated from one spec, so a change in the spec never waits for hand-written code on either side. The spec covers blocks now, and later pages and endpoints: where a client gets the BFF response for a page, and how forms are submitted.

Old app versions stay installed, so the spec has to make compatibility checkable: additions never break a client, a client renders an unknown block type as a fallback block and ignores unknown properties.

The board asked to research a schema format, with XSD-style contract validation as one candidate.

## Decision

Split the spec into two problems (Melle, 2026-10-27):

1. **Data model**: an Elixir DSL with macros. The macros define what a valid spec is, like an XSD for XML; the module that uses them (`MicaBff.Blocks`) is the spec, like the XML document.
   - `defblock` (now): a block the BFF sends and clients render.
   - `defpage` (later): a place a client can navigate to. Always a GET that returns a list of blocks; something can point at it (`section.to`, deep links) and navigation rules apply to it. The DSL expands it to an endpoint, so generated code has one list of endpoints and one network client.
   - `defendpoint` (later): every other call (boot, form submission) with its method, path, request body and response.

   Page and endpoint stay separate concepts. A `kind: :page` next to `:get`/`:post` would mix how a request travels (method) with what it is for (navigation): a page is always a GET, and a form POST can also answer with blocks.
2. **Serialization**: JSON. A block is `{"type": "section", "props": {...}}`. Keys are snake_case; generators map them to each platform's naming.

**Blocks have no children.** A page is a flat, ordered list of blocks; no block contains another block. A field holds a primitive, never a block, and the DSL rejects it at compile time. This keeps the generated decoding and the renderers flat, and an unknown block type only ever replaces itself with a fallback. Grouping (a section header followed by its sections) is expressed by order on the page. Nesting is revisited when a page needs it; the Pixel core set's typed children are the reference then.

Nested data types (a `defmodel`, e.g. an image with url, width and height) are added when a block needs one. A link to a page is not one: `section.to` is a page path for now and becomes a checked reference to a `defpage`.

The generators are Mix tasks in this repo. They read the spec as plain data (`__spec__/0`), not the source. CI regenerates the code and commits it to `mica` (server) and `next-ios` (client), so each repo keeps a reviewable diff and builds without depending on this repo.

## Alternatives

| Option | Why not |
|---|---|
| JSON Schema | Standard and validates JSON directly, but expresses no endpoints, and Elixir codegen from it is weak. Generators would fight the schema language instead of reading plain data. |
| TypeSpec / OpenAPI | Good for endpoints, but adds a Node toolchain and a second language to a team that writes Elixir; still needs custom generators for the fallback-tolerant Swift decoding. |
| Protobuf | Binary wire format and its own toolchain; JSON is easier to debug and what the clients already speak. Unknown-field handling is good, but we don't need its size gains. |
| XSD | Validates XML, not JSON. The DSL takes over its role: the macros reject an invalid spec at compile time, and the spec validates payloads in tests. |

## Consequences

- One language for the spec, the generators and the server; generators get the full spec as data, without parsing a schema language.
- A mistake in the spec (unknown type, a block used as a field, duplicate name, unknown option) fails at compile time.
- Editing the spec means editing Elixir, also for iOS developers. If that becomes a problem, a docs generator renders the spec as Markdown.
- A consumer that needs a standard schema (Android tooling, external parties) gets one more generator that exports JSON Schema from the same data.
- Compatibility rules (additions only, deprecate before removing) can be enforced by comparing the spec with the last tagged version in CI.
