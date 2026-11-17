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
    badge.to_map(struct!(badge, attrs))["props"]
  end

  test "an enum is an atom in the struct and a string on the wire; a list is sent as it is" do
    tagged = Module.concat(namespace_for(Spec), Tagged)

    assert tagged.to_map(struct!(tagged, tone: :in_progress, status: :on, tags: ["a", "b"])) ==
             %{
               "type" => "tagged",
               "props" => %{"tone" => "in_progress", "status" => "on", "tags" => ["a", "b"]}
             }

    assert tagged.to_map(struct!(tagged, tone: :success, tags: [])) ==
             %{"type" => "tagged", "props" => %{"tone" => "success", "tags" => []}}
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

  test "every block and type gets its module, with its fields as struct keys" do
    {namespace, compiled} = compile_use(", spec: MicaBff.Spec")
    %{blocks: blocks, types: types} = MicaBff.Spec.__schema__()
    expected = [namespace | Enum.map(blocks ++ types, &block_module(namespace, &1))]

    assert compiled |> Keyword.keys() |> Enum.sort() == Enum.sort(expected)

    for record <- blocks ++ types do
      assert struct_keys(block_module(namespace, record)) == field_names(record)
    end
  end

  # Every section prop is optional, so the fixtures also check that nil props are left out.
  # An enum prop goes in as an atom and a type as its struct, as the server sets them,
  # so their encoding is checked too.
  test "every fixture encodes back to itself through its module" do
    ns = namespace_for(MicaBff.Spec)
    %{blocks: blocks, types: types} = MicaBff.Spec.__schema__()
    types = Map.new(types, &{&1.name, block_module(ns, &1)})

    type! = fn module, map ->
      struct!(module, Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end))
    end

    value = fn
      %{type: {:enum, _}}, v -> String.to_existing_atom(v)
      %{type: {:list, t}}, v when is_map_key(types, t) -> Enum.map(v, &type!.(types[t], &1))
      %{type: t}, v when is_map_key(types, t) -> type!.(types[t], v)
      _field, v -> v
    end

    for path <- Path.wildcard("fixtures/*.json") do
      %{"type" => type, "props" => props} = fixture = path |> File.read!() |> JSON.decode!()
      %{fields: fields} = Enum.find(blocks, &(to_string(&1.name) == type))
      fields = Map.new(fields, &{to_string(&1.name), &1})
      module = Module.concat(ns, Macro.camelize(type))

      block =
        struct!(
          module,
          Map.new(props, fn {k, v} -> {String.to_existing_atom(k), value.(fields[k], v)} end)
        )

      assert module.to_map(block) == fixture, path
    end
  end

  test "a block's type, a type's types and enums encode as plain JSON objects, nil optionals left out" do
    ns = namespace_for(Spec)
    [album, gallery, image] = Enum.map([Album, Gallery, Image], &Module.concat(ns, &1))

    block =
      struct!(album,
        gallery:
          struct!(gallery,
            cover: struct!(image, url: "/a.png"),
            photos: [struct!(image, url: "/b.png", width: 10)],
            tone: :loud
          )
      )

    assert album.to_map(block) == %{
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
      album.to_map(struct!(album, gallery: struct!(gallery, cover: nil)))
    end
  end

  test "a block without fields encodes to empty props" do
    divider = Module.concat(namespace_for(Spec), Divider)

    assert divider.to_map(struct!(divider, [])) == %{"type" => "divider", "props" => %{}}
  end

  test "required fields are enforced" do
    badge = Module.concat(namespace_for(Spec), Badge)

    assert_raise ArgumentError, ~r/:label/, fn -> struct!(badge, []) end
  end

  test "a key put on a block that the spec doesn't have is not sent" do
    badge = Module.concat(namespace_for(Spec), Badge)
    block = Map.put(struct!(badge, label: "x"), :participant_id, 42)

    assert badge.to_map(block) == %{"type" => "badge", "props" => %{"label" => "x"}}
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
