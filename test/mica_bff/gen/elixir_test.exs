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

  defp block_module(namespace, %{name: name}),
    do: Module.concat(namespace, Macro.camelize(to_string(name)))

  defp field_names(%{fields: fields}), do: fields |> Enum.map(& &1.name) |> Enum.sort()

  defp struct_keys(module),
    do: module |> struct() |> Map.from_struct() |> Map.keys() |> Enum.sort()

  defp runtime_imports(binary) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(binary, [:imports])
    Enum.map(imports, fn {module, _function, _arity} -> Atom.to_string(module) end)
  end

  test "every block gets its module, with the block's fields as struct keys" do
    {namespace, compiled} = compile_use(", spec: MicaBff.Spec")
    blocks = MicaBff.Spec.__schema__().blocks
    expected = [namespace | Enum.map(blocks, &block_module(namespace, &1))]

    assert compiled |> Keyword.keys() |> Enum.sort() == Enum.sort(expected)

    for block <- blocks do
      assert struct_keys(block_module(namespace, block)) == field_names(block)
    end
  end

  # Every section prop is optional, so the fixtures also check that nil props are left out.
  test "every fixture encodes back to itself through its module" do
    ns = namespace_for(MicaBff.Spec)

    for path <- Path.wildcard("fixtures/*.json") do
      %{"type" => type, "props" => props} = fixture = path |> File.read!() |> JSON.decode!()
      module = Module.concat(ns, Macro.camelize(type))
      block = struct!(module, Map.new(props, fn {k, v} -> {String.to_existing_atom(k), v} end))

      assert module.to_map(block) == fixture, path
    end
  end

  test "only nil optional props are left out" do
    assert badge_props(label: "x") == %{"label" => "x"}
    assert badge_props(label: "", count: 0) == %{"label" => "", "count" => 0}
    assert badge_props(label: nil) == %{"label" => nil}
  end

  test "a block without fields encodes to empty props" do
    divider = Module.concat(namespace_for(Spec), Divider)

    assert divider.to_map(struct!(divider, [])) == %{"type" => "divider", "props" => %{}}
  end

  test "required fields are enforced" do
    badge = Module.concat(namespace_for(Spec), Badge)

    assert_raise ArgumentError, ~r/:label/, fn -> struct!(badge, []) end
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

  test "use with a module that is not a spec fails with the file and line" do
    message =
      ~r/use_test\.exs:2: spec: .*NotASpec is not a spec \(a module with __schema__\/0\)/

    assert_raise CompileError, message, fn -> compile_use(", spec: #{inspect(NotASpec)}") end
  end

  test "the module that uses it lists the spec's pages; a spec without pages has none" do
    assert namespace_for(MicaBff.Spec).pages() == MicaBff.Spec.__schema__().pages
    assert namespace_for(Spec).pages() == []
  end

  test "the defined modules call nothing in mica-bff at runtime" do
    {_namespace, compiled} = compile_use(", spec: MicaBff.Spec")
    imports = Enum.flat_map(compiled, fn {_module, binary} -> runtime_imports(binary) end)

    refute Enum.any?(imports, &String.starts_with?(&1, "Elixir.MicaBff"))
  end
end
