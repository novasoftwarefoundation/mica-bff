defmodule MicaBff.Gen.ElixirTest do
  use ExUnit.Case, async: true

  setup_all do
    namespace = "MicaBffTest.Gen#{System.unique_integer([:positive])}"

    for {_file, source} <- MicaBff.Gen.Elixir.render(MicaBff.Blocks.__schema__(), namespace),
        do: Code.compile_string(source)

    %{namespace: namespace}
  end

  # Every section prop is optional, so the fixtures also check that nil props are left out.
  test "every fixture encodes back to itself through its generated module", %{namespace: ns} do
    for path <- Path.wildcard("fixtures/*.json") do
      %{"type" => type, "props" => props} = fixture = path |> File.read!() |> JSON.decode!()
      module = Module.concat(ns, Macro.camelize(type))
      block = struct!(module, Map.new(props, fn {k, v} -> {String.to_existing_atom(k), v} end))

      assert module.to_map(block) == fixture, path
    end
  end

  test "required fields are enforced" do
    schema = %{
      blocks: [%{name: :badge, fields: [%{name: :label, type: :string, required: true}]}]
    }

    ns = "MicaBffTest.Required#{System.unique_integer([:positive])}"
    [{_file, source}] = MicaBff.Gen.Elixir.render(schema, ns)
    [{badge, _}] = Code.compile_string(source)

    assert_raise ArgumentError, ~r/:label/, fn -> struct!(badge, []) end
  end
end
