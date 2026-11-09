defmodule MicaBff.Gen.ElixirTest do
  use ExUnit.Case, async: true

  setup_all do
    namespace = "MicaBffTest.Gen#{System.unique_integer([:positive])}"

    for {_file, source} <- MicaBff.Gen.Elixir.generate(MicaBff.Spec.__schema__(), namespace),
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
    {_file, source} = List.keyfind(MicaBff.Gen.Elixir.generate(schema, ns), "badge.ex", 0)
    [{badge, _}] = Code.compile_string(source)

    assert_raise ArgumentError, ~r/:label/, fn -> struct!(badge, []) end
  end

  test "an enum is an atom in the struct and a string on the wire; a list is sent as it is" do
    schema = %{
      blocks: [
        %{
          name: :badge,
          fields: [
            %{
              name: :tone,
              type: {:enum, [:success, :in_progress]},
              required: true,
              fallback: :success
            },
            %{name: :status, type: {:enum, [:on, :off]}, required: false, fallback: :off},
            %{name: :tags, type: {:list, :string}, required: false}
          ]
        }
      ]
    }

    ns = "MicaBffTest.Types#{System.unique_integer([:positive])}"
    {_file, source} = List.keyfind(MicaBff.Gen.Elixir.generate(schema, ns), "badge.ex", 0)
    [{badge, _}] = Code.compile_string(source)

    assert badge.to_map(struct!(badge, tone: :in_progress, status: :on, tags: ["a", "b"])) ==
             JSON.decode!(
               ~s({"type": "badge", "props": {"tone": "in_progress", "status": "on", "tags": ["a", "b"]}})
             )

    assert badge.to_map(struct!(badge, tone: :success, tags: [])) ==
             JSON.decode!(~s({"type": "badge", "props": {"tone": "success", "tags": []}}))
  end

  test "the namespace module lists the spec's pages", %{namespace: ns} do
    assert Module.concat([ns]).pages() == MicaBff.Spec.__schema__().pages
  end

  test "a catalogue beyond inspect's limit is generated whole" do
    pages = for i <- 1..100, do: %{name: :"page_#{i}", path: "/bff/page/page_#{i}"}
    fields = for i <- 1..100, do: %{name: :"field_#{i}", type: :string, required: true}
    schema = %{pages: pages, blocks: [%{name: :wide, fields: fields}]}

    ns = "MicaBffTest.Large#{System.unique_integer([:positive])}"

    for {_file, source} <- MicaBff.Gen.Elixir.generate(schema, ns),
        do: Code.compile_string(source)

    assert Module.concat([ns]).pages() == pages
    wide = struct!(Module.concat(ns, Wide), Map.new(fields, &{&1.name, "x"}))
    assert map_size(Map.from_struct(wide)) == 100
  end
end
