defmodule MicaBff.SpecTest do
  use ExUnit.Case, async: true

  test "the spec keeps declaration order and field options" do
    assert %{
             models: [%{name: :link, fields: [%{name: :to, type: :string, required: true}]}],
             blocks: [
               %{name: :section_header, fields: [%{name: :title}]},
               %{name: :section, fields: [%{name: :title}, %{name: :link, type: :link}]}
             ]
           } = MicaBff.Blocks.__spec__()
  end

  test "mistakes fail at compile time" do
    for {body, message} <- [
          {"defblock :a do field :x, :nope end", ":a.x has unknown type :nope"},
          {"defblock :a do field :x, :string end\ndefmodel :a do end", ":a is defined twice"},
          {"defblock :a do field :x, :string end\ndefblock :b do field :child, :a end",
           ":b.child holds block :a; blocks have no children"},
          {"defblock :a do field :x, :string end\ndefmodel :m do field :child, :a end",
           ":m.child holds block :a; blocks have no children"},
          {"defblock :a do field :x, :string\nfield :x, :integer end", ":a has field :x twice"}
        ] do
      assert_raise CompileError, ~r/#{Regex.escape(message)}/, fn ->
        Code.compile_string("""
        defmodule Bad#{System.unique_integer([:positive])} do
          use MicaBff.Spec
          #{body}
        end
        """)
      end
    end

    assert_raise ArgumentError, ~r/unknown keys \[:optional\]/, fn ->
      Code.compile_string("""
      defmodule Bad#{System.unique_integer([:positive])} do
        use MicaBff.Spec
        defblock :a do field :x, :string, optional: true end
      end
      """)
    end
  end
end
