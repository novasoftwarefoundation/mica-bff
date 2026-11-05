defmodule MicaBff.CompatTest do
  use ExUnit.Case, async: true

  import MicaBff.Compat, only: [breaking_changes: 2]

  defp schema(blocks) do
    %{
      blocks: for({name, fields} <- blocks, do: %{name: name, fields: fields}),
      pages: []
    }
  end

  defp field(name, opts \\ []) do
    Map.merge(%{name: name, type: :string, required: false}, Map.new(opts))
  end

  test "identical schemas have no breaking changes" do
    current = schema(section: [field(:title, required: true), field(:to)])
    assert breaking_changes(current, current) == []
  end

  test "removing a block breaks, adding one doesn't, even with required fields" do
    small = schema(section: [])
    big = schema(section: [], card: [field(:title, required: true)])

    assert breaking_changes(big, small) == ["card: block removed"]
    assert breaking_changes(small, big) == []
  end

  test "a block can't be deprecated into removal: only its fields carry deprecated" do
    old = schema(section: [field(:title, deprecated: "0.2.0")])
    assert breaking_changes(old, schema([])) == ["section: block removed"]
  end

  test "removing a field breaks unless the old schema deprecated it" do
    new = schema(section: [])

    assert breaking_changes(schema(section: [field(:title)]), new) ==
             ["section.title: removed without being deprecated first"]

    assert breaking_changes(schema(section: [field(:title, deprecated: "0.2.0")]), new) == []
  end

  test "deprecating in the new schema doesn't excuse a removal elsewhere" do
    old = schema(section: [field(:title), field(:to)])
    new = schema(section: [field(:to, deprecated: "0.2.0")])

    assert breaking_changes(old, new) == ["section.title: removed without being deprecated first"]
  end

  test "changing a type breaks, in both directions" do
    string = schema(section: [field(:title)])
    integer = schema(section: [field(:title, type: :integer)])

    assert breaking_changes(string, integer) ==
             ["section.title: type changed from :string to :integer"]

    assert breaking_changes(integer, string) ==
             ["section.title: type changed from :integer to :string"]
  end

  test "optional to required breaks, required to optional doesn't" do
    optional = schema(section: [field(:title)])
    required = schema(section: [field(:title, required: true)])

    assert breaking_changes(optional, required) ==
             ["section.title: changed from optional to required"]

    assert breaking_changes(required, optional) == []
  end

  test "a new field on an existing block must be optional" do
    old = schema(section: [])

    assert breaking_changes(old, schema(section: [field(:title, required: true)])) ==
             ["section.title: new required field on an existing block"]

    assert breaking_changes(old, schema(section: [field(:title)])) == []
  end

  test "adding or removing since and deprecated doesn't break" do
    plain = schema(section: [field(:title)])
    versioned = schema(section: [field(:title, since: "0.1.0", deprecated: "0.2.0")])

    assert breaking_changes(plain, versioned) == []
    assert breaking_changes(versioned, plain) == []
  end

  test "reordering blocks and fields doesn't break" do
    old = schema(section: [field(:title), field(:to)], card: [])
    new = schema(card: [], section: [field(:to), field(:title)])

    assert breaking_changes(old, new) == []
  end

  test "an old schema without pages compares on its blocks" do
    old = %{blocks: [%{name: :section, fields: [field(:title)]}]}

    assert breaking_changes(old, schema(section: [field(:title)])) == []
    assert breaking_changes(old, schema([])) == ["section: block removed"]
  end

  test "pages are not compared" do
    old = %{blocks: [], pages: [%{name: :home, path: "/bff/page/home"}]}
    assert breaking_changes(old, schema([])) == []
  end

  test "every violation gets its own message" do
    old = schema(section: [field(:title), field(:to)], card: [])
    new = schema(section: [field(:title, type: :integer, required: true)])

    assert breaking_changes(old, new) == [
             "section.title: type changed from :string to :integer",
             "section.title: changed from optional to required",
             "section.to: removed without being deprecated first",
             "card: block removed"
           ]
  end
end
