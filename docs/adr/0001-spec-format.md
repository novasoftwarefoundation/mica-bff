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
| Schema | What a valid spec is: the DSL (`defblock`, `deftype`, `defregion`, `field`, `defpage`, `param`), the field types (primitives, enums, declared types, lists of a primitive or declared type), the rules. The role an XSD plays for XML. | `MicaBff.Schema` |
| Types | The nested data types blocks hold (`deftype`) | `MicaBff.Types` (amended 2026-11-17) |
| Block catalogue | The blocks themselves, written with the schema DSL | `MicaBff.Blocks` |
| Regions | The region kinds that group a page's blocks (`defregion`) | `MicaBff.Regions` (amended 2026-11-19, 2026-11-20) |
| Pages | The pages the BFF serves, with their query parameters (`defpage`, `param`) | `MicaBff.Pages` (amended 2026-11-05, 2026-11-17) |
| Protocol | The other calls, such as a form's POST (`defendpoint`) | later |
| Generated code | Client code, generated from the above; server code, defined from it at compile time | next-ios; mica, by a macro |

Split the spec into two problems (Melle, 2026-10-27):

1. **Data model**: an Elixir DSL with macros. The schema defines what a valid spec is, like an XSD for XML; the modules that use it are the spec, like the XML document: one per kind (`MicaBff.Types`, `MicaBff.Blocks`, `MicaBff.Regions`, `MicaBff.Pages`), composed by `MicaBff.Spec`, whose `__schema__/0` returns the whole spec as data (amended 2026-11-05, 2026-11-17, 2026-11-19).
   - `defblock` (now): a block the BFF sends and clients render.
   - `defregion` (now, amended 2026-11-19): a region kind; a region covers a stretch of a page's blocks, with typed fields like a block's (`defregion :part do field :role, ... end`). See "Markup" below.
   - `deftype` (now, amended 2026-11-17): a nested data type a block's field holds, such as a filter's option. A type is a JSON object of its fields, never on a page by itself and without a fallback of its own: one that doesn't decode is treated as any prop that doesn't decode. A type's field may hold a type declared before it or a list of one, so types never form a cycle.
   - `defpage` (now, amended 2026-11-04, 2026-11-19): a page the BFF serves. Always a GET that returns its view model, `{"blocks": [...], "markup": [...]}`, at `/bff/page/<page>`: the path follows from the page name (`defpage :home` → `GET /bff/page/home`), singular because a request fetches one page. `__schema__/0` lists the pages with their paths, and the Elixir macro gives the server `pages/0` on the namespace module, so the BFF serves exactly the spec's pages. The Swift generator doesn't read pages yet; the client's router gets them when it needs to recognise BFF URLs. These requests come from a separate BFF system in mica, not from the existing LiveView routes.
     A page declares its query parameters with `param`, a snake_case name and a primitive type (amended 2026-11-17): `defpage :marketplace do param :year, :integer end` reads `?year=2025`. The BFF renders the whole page for those parameters; nothing is loaded later. The Elixir macro gives the server `page_params/2`, which reads them from a request typed, and leaves out one that is empty or doesn't parse, as if absent, so a stale link still opens the page. Clients don't read params: the server builds every link with them.
   - `defendpoint` (later): every other call, such as a form's POST, with its method, path, request body and response.

   Page and endpoint stay separate concepts. A `kind: :page` next to `:get`/`:post` would mix how a request travels (method) with what it returns: a page is always a GET with blocks, and a form POST can also answer with blocks.

   **Navigation belongs to the client, not the spec.** A block that opens something carries only the destination (`section.to`). The client's router (navigation rules, UC-SENSE-06) decides whether it opens a native page, a BFF page or a web page, and how it is presented. Moving a page between native, BFF and web changes no spec and no block. `defpage` lets the router recognise BFF URLs; nothing in the spec has to point at it.
2. **Serialization**: JSON, with these rules:
   - A block is `{"id": "study-7", "type": "section", "props": {...}}`. Type and prop names are the snake_case names from the schema; generators map them to each platform's naming. The `id` (amended 2026-11-19) is a string the server picks from what the block shows (`"study-#{assignment.id}"`), the same for as long as the page shows the same thing. Ids should be unique on a page, but only regions need them to be: an id two blocks have can't be the start or end of a region, and both blocks still show. So a record that repeats in the data costs the region on it, never the page. The server's encoder raises on a block without an id; a client treats it as optional, like a prop, and a block without one can't be the start or end of a region.
   - A region is `{"kind": "border", "start": "rewards", "end": "pending", "props": {...}}` (amended 2026-11-19): the ids of the first and last block it covers, both included, and its kind's props, under the rules for a block's props.
   - An optional prop that is `nil` is left out by the BFF; `""`, `0`, `false` and empty lists or maps are values and are sent. A required prop is never `nil`, a list prop is always a list and a list never holds `nil`: the server's encoder raises instead (amended 2026-11-17, 2026-11-20). Raising fails the page the block is on (a 500 from mono's `PageController`), on purpose: a server bug shows in dev, tests and the logs, instead of reaching the app as a prop or element it silently drops. Clients treat a missing prop and `null` the same.
   - Clients ignore unknown keys: next to `type`/`props`, inside `props` and next to `blocks`/`markup`.
   - An `:integer` prop is a JSON number without a fraction; a `:float` prop accepts any JSON number.
   - An enum prop (`{:enum, [:success, :in_progress]}`, amended 2026-11-09) is the value's snake_case name as a JSON string (`"in_progress"`). A list prop (`{:list, :string}`, amended 2026-11-09) is a JSON array of that primitive.
   - A destination such as `section.to` is a path (`/pool/1/marketplace`), resolved against the app's base URL for its environment. How client-only actions (log out) are expressed is decided with the first block that needs one.
   - Filtering is going to the same page with the filter applied (amended 2026-11-17). A `filter` block's options carry their links (`/bff/page/marketplace?year=2025&query=sleep`), built by the server with the page's other parameters kept; a `search` block carries the link without its own parameter and the parameter's `name`, and the client adds the typed text, as the user types with a pause. The client loads the link in place of the page it shows, without a new screen.

**Blocks have no children.** A page is a flat, ordered list of blocks; no block contains another block. A field holds a primitive, an enum, a declared type or a list of a primitive or declared type (amended 2026-11-09, 2026-11-17), never a block or a list of blocks, and the DSL rejects that at compile time. This keeps the renderers flat, and an unknown block type only ever replaces itself with a fallback. Grouping is regions only (amended 2026-11-19), kept beside the blocks rather than placed between them.

The Swift generator is a Mix task in this repo. It reads the block catalogue as plain data (`__schema__/0`), not the source. CI regenerates the Swift code and commits it to `next-ios`, which keeps a reviewable diff and builds without depending on this repo.

`mica` depends on this repo at compile time at a pinned ref. A macro defines the block modules while it compiles, and the reviewable diff there is the ref bump.

Amended 2026-11-09: `mica` used to get generated code committed by CI as well. Elixir can read the spec directly, so copying it into `mica` added a PR and no value.

### Markup

Amended 2026-11-19 (Flux 10504699741). Before, `section_begin` and `section_end` grouped the blocks between them (mica-bff#14): markers in the content list that show nothing, which every client rebuilt into groups with a stack and prose rules for a stray end and groups left open, and which moving or removing a block could leave unbalanced.

Amended 2026-11-20: an entry is called a region, and a kind a region kind (`defregion`, `MicaBff.Regions`); the wire key stays `markup`.

A page's view model has two parts: its **content**, the flat list of blocks under `blocks`, each with an `id`; and its **markup**, a list of regions beside them, each covering the blocks from `start` to `end` by id, never by position. Inserting, removing or moving a block never shifts the regions over the other blocks.

- All regions nest, of every kind, as in XML: two regions share no block, or one covers all of the other. Regions over the same stretch nest in list order, the first outermost. So a view model's markup is always one well-formed tree, which a client renders top down.
- Crossing regions are refused, for example a background over the end of one border and the start of the next.
- The server never sends a bad region: building a view model (`view_model/2`) raises on a region whose `start` or `end` is no block's id or an id two blocks have, one that ends before it starts, and one that crosses a region before it. A check names an id as it is, between plain double quotes, so every client gives the same reason.
- A client leaves out a region that fails those checks, and a region of a kind it doesn't know, and still shows the blocks and the regions inside it.
- A kind names what a stretch means (`part`, with its `role`: the main part or a related one) or how it looks (`border`, `background`), when the look itself is what the server wants. Each client turns a meaning into layout that suits its screen: a phone shows the parts one after the other; a wider screen may show a related part as a sidebar or behind a tab. The server sends the same view model to every device.

The rules are part of the format, so they are generated, with the fixtures in `fixtures/rules/markup.json` as their tests for every client: `check` (`:ok`, or why not) and `tree` (the nested tree a client renders, leaving out what `check` refuses), in the Elixir namespace module and on the Swift `Page`. A tree's items are nodes: a node is a block, or a region with the nodes it covers. Nodes exist only in the generated code, never on the wire or in the schema. Editing regions with the blocks (moving a boundary to a neighbour when its block is removed, splitting a region that would cross into pieces) is added when a server first edits a view model after building it.

`section_begin` and `section_end` stay in the catalogue while an app version that groups with them is supported, and a client keeps grouping with them as long as a server sends them. A server stops sending them once it sends regions: from then on, an app that groups only with the markers shows that page's blocks ungrouped, in the same order. `border` and `background` replace them: `section_begin` with `border: true` is a `border` region, with `background` a `background` region, over the blocks up to its `section_end`. They are removed under the rule for a removed field: after the minimum app version no longer reads them.

### Compatibility

- **Tolerant reader** (Melle, amended 2026-11-17, 2026-11-20): `required` binds the server only. Clients treat every prop as optional and always render something for a block type they know, even if it looks rough, so a slip the server doesn't catch, or an older app, never makes content disappear; one the encoder catches fails the page (see Serialization). The generated Swift has every prop optional. Before, a known block with a required prop missing or of the wrong type became a fallback, which is how untitled adverts disappeared from the app (mono#2084).
- The client renders an unknown block type as a fallback block; the rest of the page renders.
- A prop that fails to decode (for example, its type changed) is treated as missing: the block still renders without it. Props that aren't an object give the block with every prop missing.
- New blocks and new optional props can be added at any time. A new field on an existing block is always optional, so an older server or a cached page still decodes in a newer client.
- A field is deprecated before it is removed, and removed only after the minimum app version no longer reads it.
- An enum declares a fallback, one of its values (amended 2026-11-09): a client maps a value it doesn't know to it, so adding or removing an enum's values is not a breaking change. A value of another JSON type is a value that doesn't decode, as for any prop.
- A list element that doesn't decode (a changed type, `null`) is dropped; the rest of the list stays (amended 2026-11-09). Changing a list's element type is a breaking change.
- The spec version is the git tag (`v0.2.0`, …), the version in `mix.exs` and the one an app sends as `x-bff-spec`. The first tag is `v0.2.0` (amended 2026-11-20): 0.1.0 was never tagged and covers everything before it, also the tolerant reader and markup. CI compares the blocks, region kinds and types with the last tag and fails on a breaking change. A type's and a region kind's fields follow the rules for a block's fields, and removing a type or region kind is a breaking change (amended 2026-11-17, 2026-11-19).
- A client that doesn't know regions ignores the `markup` key and a block's `id`, and shows the blocks flat, as it skips the `section_begin` and `section_end` markers it doesn't know (amended 2026-11-19). New region kinds can be added at any time: a client ignores a region of a kind it doesn't know and still renders the blocks and the regions inside it.
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
- A mistake in the spec fails at compile time and points at its line: an unknown type or option, a name that isn't a snake_case atom, a duplicate name, a block used as a field or named after a primitive, an enum without values or without a fallback among them, a list of anything but a primitive, a `field` outside a `defblock`, a `defblock` inside another, a malformed or out-of-order version.
- Payload validation is not built yet. A validator against `__schema__/0`, plus example payloads per block that the generated server and client code must encode and decode, is planned as the contract validation work. Until then the rules above are prose.
- Editing the spec means editing Elixir, also for iOS developers. If that becomes a problem, a docs generator generates the spec as Markdown.
- A consumer that needs a standard schema (Android tooling, external parties) gets one more generator that exports JSON Schema from the same data.
