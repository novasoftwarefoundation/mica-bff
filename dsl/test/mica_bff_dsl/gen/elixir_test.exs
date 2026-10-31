defmodule MicaBffDsl.Gen.ElixirTest do
  use ExUnit.Case, async: true

  setup_all do
    namespace = "MicaBffDslTest.Gen#{System.unique_integer([:positive])}"

    for {_file, source} <-
          MicaBffDsl.Gen.Elixir.generate(MicaBffDsl.Test.Catalogue.__schema__(), namespace),
        do: Code.compile_string(source)

    %{card: Module.concat(namespace, Card), divider: Module.concat(namespace, Divider)}
  end

  test "to_map/1 returns the wire shape and leaves out nil props", %{card: card, divider: divider} do
    for {block, wire} <- [
          {struct!(card, title: "A", subtitle: "B", to: "/c"),
           %{"type" => "card", "props" => %{"title" => "A", "subtitle" => "B", "to" => "/c"}}},
          {struct!(card, title: "A"), %{"type" => "card", "props" => %{"title" => "A"}}},
          # Empty values are values: only nil is left out.
          {struct!(card, title: "", subtitle: ""),
           %{"type" => "card", "props" => %{"title" => "", "subtitle" => ""}}},
          {struct!(divider), %{"type" => "divider", "props" => %{}}}
        ] do
      assert block.__struct__.to_map(block) == wire
    end
  end

  test "required fields are enforced", %{card: card} do
    assert_raise ArgumentError, ~r/:title/, fn -> struct!(card, []) end
  end
end
