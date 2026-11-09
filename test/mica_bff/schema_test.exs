defmodule MicaBff.SchemaTest do
  use ExUnit.Case, async: true

  test "a schema is plain data in declaration order" do
    [{module, _}] =
      compile!("""
      defblock :b do field :y, :integer, required: true; field :x, :string end
      defpage :settings
      defblock :a do end
      defpage :home
      """)

    assert module.__schema__() == %{
             blocks: [
               %{
                 name: :b,
                 fields: [
                   %{name: :y, type: :integer, required: true},
                   %{name: :x, type: :string, required: false}
                 ]
               },
               %{name: :a, fields: []}
             ],
             pages: [
               %{name: :settings, path: "/bff/page/settings"},
               %{name: :home, path: "/bff/page/home"}
             ]
           }
  end

  test "optional is the default" do
    [{module, _}] = compile!("defblock :a do field :x, :string end")

    assert module.__schema__() == %{
             blocks: [%{name: :a, fields: [%{name: :x, type: :string, required: false}]}],
             pages: []
           }
  end

  test "since and deprecated are in the schema when set and absent when not" do
    [{module, _}] =
      compile!("""
      defblock :a do
        field :both, :string, since: "0.2.0", deprecated: "0.10.0"
        field :same, :string, since: "0.2.0", deprecated: "0.2.0"
        field :old, :string, required: true, deprecated: "0.3.0"
        field :new, :string, since: "0.2.0"
        field :plain, :string
      end
      """)

    assert [%{fields: fields}] = module.__schema__().blocks

    assert fields == [
             %{name: :both, type: :string, required: false, since: "0.2.0", deprecated: "0.10.0"},
             %{name: :same, type: :string, required: false, since: "0.2.0", deprecated: "0.2.0"},
             %{name: :old, type: :string, required: true, deprecated: "0.3.0"},
             %{name: :new, type: :string, required: false, since: "0.2.0"},
             %{name: :plain, type: :string, required: false}
           ]
  end

  # The body starts at line 3 of bad.ex.
  test "mistakes fail at compile time and point at their line" do
    for {body, line, message} <- [
          {"defblock :a do field :x, :nope end", 3, ":a.x has unknown type :nope"},
          {"defblock :a do end\ndefblock :a do end", 4, ":a is defined twice"},
          {"defblock :a do\nfield :x, :string\nfield :x, :integer\nend", 5,
           ":a has field :x twice"},
          {"defblock :a do end\ndefblock :b do field :child, :a end", 4,
           ":b.child holds block :a; blocks have no children"},
          {"defblock :a do\ndefblock :b do end\nend", 4,
           "defblock :b inside defblock :a; blocks have no children"},
          {"field :x, :string", 3, "field :x outside a defblock"},
          {"defblock :SectionHeader do end", 3,
           "block name :SectionHeader must be a snake_case atom"},
          {~s(defblock :a do field "x", :string end), 3,
           ~s(field name "x" must be a snake_case atom)},
          {"defblock :string do end", 3, "block :string clashes with the primitive type :string"},
          {"defblock :a do field :x, :string, optional: true end", 3,
           "field :x has unknown option(s) [:optional]; allowed: [:required, :since, :deprecated]"},
          {~s(defblock :a do field :x, :string, required: "yes" end), 3,
           "field :x: required must be true or false"},
          {"defblock :a do field :x, :string, opts end", 3,
           "field :x: options must be a literal keyword list"},
          {"defpage :home\ndefpage :home", 4, "page :home is defined twice"},
          {"defblock :a do defpage :home end", 3, "defpage :home inside defblock :a"},
          {"defpage :Home", 3, "page name :Home must be a snake_case atom"},
          {~s(defblock :a do\nfield :x, :string, since: "v0.2.0"\nend), 4,
           ~s(field :x: since must be a literal version like "0.2.0", got "v0.2.0")},
          {~s(defblock :a do field :x, :string, since: "0.2" end), 3,
           ~s(field :x: since must be a literal version like "0.2.0", got "0.2")},
          {~S(defblock :a do field :x, :string, since: "0.2.0\n" end), 3,
           "field :x: since must be a literal version"},
          {"defblock :a do field :x, :string, since: 2 end", 3,
           ~s(field :x: since must be a literal version like "0.2.0", got 2)},
          {~s(defblock :a do field :x, :string, deprecated: "1.0" end), 3,
           ~s(field :x: deprecated must be a literal version like "0.2.0", got "1.0")},
          {"defblock :a do field :x, :string, deprecated: :soon end", 3,
           ~s(field :x: deprecated must be a literal version like "0.2.0", got :soon)},
          {~s(defblock :a do\nfield :x, :string, since: "0.10.0", deprecated: "0.9.0"\nend), 4,
           "field :x: deprecated 0.9.0 is before since 0.10.0"}
        ] do
      error = assert_raise CompileError, fn -> compile!(body) end
      assert Exception.message(error) =~ "bad.ex:#{line}: #{message}", body
    end
  end

  defp compile!(body) do
    Code.compile_string(
      """
      defmodule Bad#{System.unique_integer([:positive])} do
        use MicaBff.Schema
      #{body}
      end
      """,
      "bad.ex"
    )
  end
end
