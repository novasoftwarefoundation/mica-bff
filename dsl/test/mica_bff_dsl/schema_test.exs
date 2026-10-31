defmodule MicaBffDsl.SchemaTest do
  use ExUnit.Case, async: true

  test "a catalogue is plain data in declaration order" do
    assert MicaBffDsl.Test.Catalogue.__schema__() == %{
             blocks: [
               %{
                 name: :card,
                 fields: [
                   %{name: :title, type: :string, required: true},
                   %{name: :subtitle, type: :string, required: false},
                   %{name: :to, type: :string, required: false}
                 ]
               },
               %{name: :divider, fields: []}
             ]
           }
  end

  test "optional is the default" do
    [{module, _}] = compile!("defblock :a do field :x, :string end")

    assert module.__schema__() == %{
             blocks: [%{name: :a, fields: [%{name: :x, type: :string, required: false}]}]
           }
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
           "field :x has unknown option(s) [:optional]; allowed: [:required]"},
          {~s(defblock :a do field :x, :string, required: "yes" end), 3,
           "field :x: required must be true or false"},
          {"defblock :a do field :x, :string, opts end", 3,
           "field :x: options must be a literal keyword list"}
        ] do
      error = assert_raise CompileError, fn -> compile!(body) end
      assert Exception.message(error) =~ "bad.ex:#{line}: #{message}", body
    end
  end

  defp compile!(body) do
    Code.compile_string(
      """
      defmodule Bad#{System.unique_integer([:positive])} do
        use MicaBffDsl.Schema
      #{body}
      end
      """,
      "bad.ex"
    )
  end
end
