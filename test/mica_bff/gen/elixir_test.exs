defmodule MicaBff.Gen.ElixirTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule Spec do
    use MicaBff.Schema

    defblock :badge do
      field(:label, :string, required: true)
      field(:count, :integer)
    end

    defblock :divider do
    end

    defblock :tagged do
      field(:tone, {:enum, [:success, :in_progress]}, required: true, fallback: :success)
      field(:status, {:enum, [:on, :off]}, fallback: :off)
      field(:tags, {:list, :string})
    end

    deftype :image do
      field(:url, :string, required: true)
      field(:width, :integer)
    end

    deftype :gallery do
      field(:cover, :image, required: true)
      field(:photos, {:list, :image})
      field(:tone, {:enum, [:calm, :loud]}, fallback: :calm)
    end

    defblock :album do
      field(:gallery, :gallery, required: true)
    end

    defpage :search do
      param(:query, :string)
      param(:year, :integer)
      param(:ratio, :float)
      param(:open, :boolean)
    end
  end

  defmodule NotASpec do
  end

  defp compile_use(option) do
    namespace = "MicaBffTest.Use#{System.unique_integer([:positive])}"
    source = "defmodule #{namespace} do\n  use MicaBff.Gen.Elixir#{option}\nend\n"
    {Module.concat([namespace]), Code.compile_string(source, "use_test.exs")}
  end

  defp namespace_for(spec) do
    {namespace, _modules} = compile_use(", spec: #{inspect(spec)}")
    namespace
  end

  defp badge_props(attrs) do
    badge = Module.concat(namespace_for(Spec), Badge)
    badge.to_map(struct!(badge, [id: "badge"] ++ attrs))["props"]
  end

  test "an enum is an atom in the struct and a string on the wire; a list is sent as it is" do
    tagged = Module.concat(namespace_for(Spec), Tagged)

    assert tagged.to_map(
             struct!(tagged, id: "t", tone: :in_progress, status: :on, tags: ["a", "b"])
           ) ==
             %{
               "id" => "t",
               "type" => "tagged",
               "props" => %{"tone" => "in_progress", "status" => "on", "tags" => ["a", "b"]}
             }

    assert tagged.to_map(struct!(tagged, id: "t", tone: :success, tags: [])) ==
             %{"id" => "t", "type" => "tagged", "props" => %{"tone" => "success", "tags" => []}}
  end

  defp block_module(namespace, %{name: name}),
    do: Module.concat(namespace, Macro.camelize(to_string(name)))

  defp field_names(%{fields: fields}), do: fields |> Enum.map(& &1.name) |> Enum.sort()

  defp struct_keys(module),
    do: module |> struct() |> Map.from_struct() |> Map.keys() |> Enum.sort()

  defp runtime_imports(binary) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(binary, [:imports])
    Enum.map(imports, fn {module, _function, _arity} -> Atom.to_string(module) end)
  end

  test "every block, region kind and type gets its module, with its keys and fields as struct keys" do
    {namespace, compiled} = compile_use(", spec: MicaBff.Spec")
    %{blocks: blocks, regions: regions, types: types} = MicaBff.Spec.__schema__()
    expected = [namespace | Enum.map(blocks ++ regions ++ types, &block_module(namespace, &1))]

    assert compiled |> Keyword.keys() |> Enum.sort() == Enum.sort(expected)

    for {records, outer} <- [{blocks, [:id]}, {regions, [:end, :start]}, {types, []}],
        record <- records do
      assert struct_keys(block_module(namespace, record)) ==
               Enum.sort(outer ++ field_names(record))
    end
  end

  # The struct the server builds for a block or region on the wire. An enum prop
  # goes in as an atom and a type as its struct, so their encoding is checked too.
  defp from_wire(ns, wire) do
    %{blocks: blocks, regions: regions, types: types} = MicaBff.Spec.__schema__()
    types = Map.new(types, &{&1.name, block_module(ns, &1)})

    atomize = fn map -> Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end) end

    value = fn
      %{type: {:enum, _}}, v ->
        String.to_existing_atom(v)

      %{type: {:list, t}}, v when is_map_key(types, t) ->
        Enum.map(v, &struct!(types[t], atomize.(&1)))

      %{type: t}, v when is_map_key(types, t) ->
        struct!(types[t], atomize.(v))

      _field, v ->
        v
    end

    {name, outer} =
      case wire do
        %{"type" => type} -> {type, Map.take(wire, ["id"])}
        %{"kind" => kind} -> {kind, Map.take(wire, ["start", "end"])}
      end

    %{fields: fields} = Enum.find(blocks ++ regions, &(to_string(&1.name) == name))
    fields = Map.new(fields, &{to_string(&1.name), &1})
    props = Map.new(wire["props"], fn {k, v} -> {k, value.(fields[k], v)} end)

    struct!(Module.concat(ns, Macro.camelize(name)), atomize.(Map.merge(outer, props)))
  end

  defp fixture(path), do: path |> File.read!() |> JSON.decode!()

  # Every section prop is optional, so the fixtures also check that nil props are left out.
  test "every block fixture encodes back to itself through its module" do
    ns = namespace_for(MicaBff.Spec)

    for path <- Path.wildcard("fixtures/*.json") do
      %module{} = block = from_wire(ns, fixture(path))
      assert module.to_map(block) == fixture(path), path
    end
  end

  test "every page fixture with good markup is the view model of its blocks and markup" do
    ns = namespace_for(MicaBff.Spec)

    for path <- ["fixtures/pages/home.json", "fixtures/pages/home_parts.json"] do
      %{"blocks" => blocks, "markup" => markup} = page = fixture(path)

      assert ns.view_model(
               Enum.map(blocks, &from_wire(ns, &1)),
               Enum.map(markup, &from_wire(ns, &1))
             ) ==
               page,
             path
    end
  end

  # A record that repeats in the data costs only the region on it, never the page.
  test "the view model raises on a bad region and on a region on an id two blocks have, not on the id alone" do
    ns = namespace_for(MicaBff.Spec)
    %{"blocks" => blocks, "markup" => markup} = fixture("fixtures/pages/bad_markup.json")
    blocks = Enum.map(blocks, &from_wire(ns, &1))
    border = Module.concat(ns, Border)
    repeated = blocks ++ [hd(blocks)]

    assert_raise ArgumentError,
                 ~r/bad view model: region from "approved" to "studies" crosses/,
                 fn ->
                   ns.view_model(blocks, Enum.map(markup, &from_wire(ns, &1)))
                 end

    assert %{"blocks" => [%{"id" => "rewards"} | _] = sent, "markup" => [_]} =
             ns.view_model(repeated, [struct!(border, start: "approved", end: "studies")])

    assert length(sent) == 4

    assert_raise ArgumentError,
                 ~r/bad view model: region from "rewards" to "approved": two blocks have id "rewards"/,
                 fn ->
                   ns.view_model(repeated, [struct!(border, start: "rewards", end: "approved")])
                 end
  end

  test "a block's id and a region's start and end must be strings" do
    ns = namespace_for(MicaBff.Spec)
    section = Module.concat(ns, Section)
    border = Module.concat(ns, Border)

    assert_raise ArgumentError, ~r/Section: id must be a string, got nil/, fn ->
      ns.view_model([struct!(section, id: nil)])
    end

    assert_raise ArgumentError, ~r/Border: end must be a string, got 7/, fn ->
      border.to_map(struct!(border, start: "a", end: 7))
    end
  end

  # The rules as fixtures, so every client checks the same cases (the Swift test reads them too).
  # A case gives its whole tree, or for one too deep to write out, the tree's depth.
  test "check and tree follow the markup rules" do
    ns = namespace_for(MicaBff.Spec)

    for %{"name" => name, "ids" => ids, "markup" => markup, "check" => check} = rule <-
          fixture("fixtures/rules/markup.json") do
      regions = Enum.map(markup, &%{kind: &1["kind"], start: &1["start"], end: &1["end"]})
      tree = ns.tree(ids, regions)

      assert ns.check(ids, regions) == if(check, do: {:error, check}, else: :ok), name

      case rule do
        %{"tree" => expected} ->
          assert wire_tree(tree, regions) == expected, name

        %{"depth" => depth} ->
          assert {tree_depth(tree), block_ids(tree)} == {depth, ids}, name
      end
    end
  end

  # Without the limit, the 100,000th region would be 100,000 deep: as deep as a client
  # recursion that overflows a phone's stack.
  test "regions nest at most 32 deep: deeper ones are refused and left out, and every block shows" do
    ns = namespace_for(MicaBff.Spec)
    border = Module.concat(ns, Border)
    section = Module.concat(ns, Section)
    regions = for _ <- 1..100_000, do: struct!(border, start: "a", end: "b")

    tree = ns.tree(["a", "b"], regions)
    assert {tree_depth(tree), block_ids(tree)} == {32, ["a", "b"]}

    assert_raise ArgumentError, ~r/regions would nest 33 deep, more than 32/, fn ->
      ns.view_model([struct!(section, id: "a"), struct!(section, id: "b")], regions)
    end
  end

  # A tree in the fixtures' form: a block is its id, a region is its index in the list.
  defp wire_tree(nodes, regions) do
    Enum.map(nodes, fn
      {:block, id} ->
        id

      {:region, region, children} ->
        %{
          "region" => Enum.find_index(regions, &(&1 == region)),
          "children" => wire_tree(children, regions)
        }
    end)
  end

  defp tree_depth(nodes) do
    nodes
    |> Enum.map(fn
      {:block, _id} -> 0
      {:region, _region, children} -> 1 + tree_depth(children)
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp block_ids(nodes) do
    Enum.flat_map(nodes, fn
      {:block, id} -> [id]
      {:region, _region, children} -> block_ids(children)
    end)
  end

  test "a block's type, a type's types and enums encode as plain JSON objects, nil optionals left out" do
    ns = namespace_for(Spec)
    [album, gallery, image] = Enum.map([Album, Gallery, Image], &Module.concat(ns, &1))

    block =
      struct!(album,
        id: "album",
        gallery:
          struct!(gallery,
            cover: struct!(image, url: "/a.png"),
            photos: [struct!(image, url: "/b.png", width: 10)],
            tone: :loud
          )
      )

    assert album.to_map(block) == %{
             "id" => "album",
             "type" => "album",
             "props" => %{
               "gallery" => %{
                 "cover" => %{"url" => "/a.png"},
                 "photos" => [%{"url" => "/b.png", "width" => 10}],
                 "tone" => "loud"
               }
             }
           }
  end

  test "only nil optional props are left out; nil for a required prop raises, in a block or a type" do
    assert badge_props(label: "x") == %{"label" => "x"}
    assert badge_props(label: "", count: 0) == %{"label" => "", "count" => 0}

    assert_raise ArgumentError, ~r/Badge: required prop label is nil/, fn ->
      badge_props(label: nil)
    end

    ns = namespace_for(Spec)
    [album, gallery] = Enum.map([Album, Gallery], &Module.concat(ns, &1))

    assert_raise ArgumentError, ~r/Gallery: required prop cover is nil/, fn ->
      album.to_map(struct!(album, id: "album", gallery: struct!(gallery, cover: nil)))
    end
  end

  # A server bug fails its page rather than reaching the app as a dropped value.
  test "a list prop that isn't a list, or holds nil, raises, in a block or a type" do
    ns = namespace_for(Spec)

    [tagged, album, gallery, image] =
      Enum.map([Tagged, Album, Gallery, Image], &Module.concat(ns, &1))

    assert_raise ArgumentError, ~r/Tagged: list prop tags is not a list: "a"/, fn ->
      tagged.to_map(struct!(tagged, id: "t", tone: :success, tags: "a"))
    end

    assert_raise ArgumentError, ~r/Tagged: list prop tags holds nil/, fn ->
      tagged.to_map(struct!(tagged, id: "t", tone: :success, tags: ["a", nil]))
    end

    assert_raise ArgumentError, ~r/Gallery: list prop photos holds nil/, fn ->
      cover = struct!(image, url: "/a.png")

      album.to_map(
        struct!(album, id: "album", gallery: struct!(gallery, cover: cover, photos: [nil]))
      )
    end
  end

  test "a block without fields encodes to empty props" do
    divider = Module.concat(namespace_for(Spec), Divider)

    assert divider.to_map(struct!(divider, id: "d")) == %{
             "id" => "d",
             "type" => "divider",
             "props" => %{}
           }
  end

  test "required fields are enforced" do
    badge = Module.concat(namespace_for(Spec), Badge)

    assert_raise ArgumentError, ~r/:label/, fn -> struct!(badge, []) end
  end

  test "a key put on a block that the spec doesn't have is not sent" do
    badge = Module.concat(namespace_for(Spec), Badge)
    block = Map.put(struct!(badge, id: "b", label: "x"), :participant_id, 42)

    assert badge.to_map(block) == %{"id" => "b", "type" => "badge", "props" => %{"label" => "x"}}
  end

  test "an unknown field fails at compile time" do
    source = "%#{inspect(namespace_for(Spec))}.Badge{nope: 1}"

    assert_raise KeyError, fn -> Code.compile_string(source) end
  end

  test "an unknown block fails at compile time" do
    source = "%#{inspect(namespace_for(Spec))}.Nope{}"

    capture_io(:stderr, fn ->
      assert_raise CompileError, fn -> Code.compile_string(source) end
    end)
  end

  test "use without spec fails with the file and line" do
    message = ~r/use_test\.exs:2: use MicaBff\.Gen\.Elixir needs spec: MicaBff\.Spec/

    assert_raise CompileError, message, fn -> compile_use("") end
  end

  test "use with an option other than spec fails with the file and line" do
    message = ~r/use_test\.exs:2: use MicaBff\.Gen\.Elixir has unknown option\(s\) \[:namespace\]/

    assert_raise CompileError, message, fn ->
      compile_use(", spec: MicaBff.Spec, namespace: Systems.BFF.Blocks")
    end
  end

  test "use with a module that is not a spec fails with the file and line" do
    message =
      ~r/use_test\.exs:2: spec: .*NotASpec is not a spec \(a module with __schema__\/0\)/

    assert_raise CompileError, message, fn -> compile_use(", spec: #{inspect(NotASpec)}") end
  end

  test "the module that uses it lists the spec's pages with their params" do
    assert namespace_for(MicaBff.Spec).pages() == MicaBff.Spec.__schema__().pages

    assert namespace_for(Spec).pages() == [
             %{
               name: :search,
               path: "/bff/page/search",
               params: [
                 %{name: :query, type: :string},
                 %{name: :year, type: :integer},
                 %{name: :ratio, type: :float},
                 %{name: :open, type: :boolean}
               ]
             }
           ]
  end

  test "page_params reads a page's declared params, typed; one that is empty or doesn't parse is absent" do
    ns = namespace_for(Spec)

    assert ns.page_params(:search, %{
             "query" => "sleep well",
             "year" => "2025",
             "ratio" => "0.5",
             "open" => "true",
             "other" => "x"
           }) == %{query: "sleep well", year: 2025, ratio: 0.5, open: true}

    assert ns.page_params(:search, %{
             "query" => "",
             "year" => "20x5",
             "ratio" => "a",
             "open" => "yes"
           }) ==
             %{}

    assert ns.page_params(:search, %{"year" => ["2025"]}) == %{}
    assert ns.page_params(:nope, %{"query" => "x"}) == %{}
  end

  test "the defined modules call nothing in mica-bff at runtime" do
    for spec <- [MicaBff.Spec, Spec] do
      {_namespace, compiled} = compile_use(", spec: #{inspect(spec)}")
      imports = Enum.flat_map(compiled, fn {_module, binary} -> runtime_imports(binary) end)

      refute Enum.any?(imports, &String.starts_with?(&1, "Elixir.MicaBff.")), inspect(spec)
    end
  end
end
