defmodule MicaBff.SchemaTest do
  use ExUnit.Case, async: true

  test "a schema is plain data in declaration order" do
    [{module, _}] =
      compile!("""
      defblock :b do field :y, :integer, required: true; field :x, :string end
      defpage :settings
      defregion :part do field :role, {:enum, [:main, :related]}, required: true, fallback: :main end
      defblock :a do end
      defregion :border do end
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
             regions: [
               %{
                 name: :part,
                 fields: [
                   %{
                     name: :role,
                     type: {:enum, [:main, :related]},
                     required: true,
                     fallback: :main
                   }
                 ]
               },
               %{name: :border, fields: []}
             ],
             pages: [
               %{name: :settings, path: "/bff/page/settings", params: []},
               %{name: :home, path: "/bff/page/home", params: []}
             ],
             types: []
           }
  end

  test "a page's params and the types are plain data in declaration order" do
    [{module, _}] =
      compile!("""
      deftype :image do field :url, :string, required: true end
      deftype :gallery do
        field :cover, :image
        field :photos, {:list, :image}
      end
      defpage :marketplace do
        param :year, :integer
        param :query, :string
      end
      """)

    assert module.__schema__() == %{
             blocks: [],
             regions: [],
             pages: [
               %{
                 name: :marketplace,
                 path: "/bff/page/marketplace",
                 params: [%{name: :year, type: :integer}, %{name: :query, type: :string}]
               }
             ],
             types: [
               %{name: :image, fields: [%{name: :url, type: :string, required: true}]},
               %{
                 name: :gallery,
                 fields: [
                   %{name: :cover, type: :image, required: false},
                   %{name: :photos, type: {:list, :image}, required: false}
                 ]
               }
             ]
           }
  end

  test "optional is the default" do
    [{module, _}] = compile!("defblock :a do field :x, :string end")

    assert module.__schema__() == %{
             blocks: [%{name: :a, fields: [%{name: :x, type: :string, required: false}]}],
             regions: [],
             pages: [],
             types: []
           }
  end

  test "a block or type may hold the types of the module named by types:, a block also its own" do
    [{types, _}] = compile!("deftype :option do field :label, :string, required: true end")

    [{module, _}] =
      compile!(
        """
        defblock :filter do
          field :options, {:list, :option}, required: true
          field :default, :choice
        end
        deftype :choice do field :option, :option end
        """,
        types: types
      )

    assert %{
             blocks: [%{fields: [%{type: {:list, :option}}, %{type: :choice}]}],
             types: [%{name: :choice, fields: [%{type: :option}]}]
           } = module.__schema__()
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

  test "an enum keeps its values in order and its fallback; a list keeps its element type" do
    [{module, _}] =
      compile!("""
      defblock :a do
        field :tone, {:enum, [:success, :in_progress, :neutral]}, required: true, fallback: :neutral
        field :tags, {:list, :string}
      end
      """)

    assert [%{fields: fields}] = module.__schema__().blocks

    assert fields == [
             %{
               name: :tone,
               type: {:enum, [:success, :in_progress, :neutral]},
               required: true,
               fallback: :neutral
             },
             %{name: :tags, type: {:list, :string}, required: false}
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
          {"defblock :a do\ndefblock :b do end\nend", 4, "defblock :b inside defblock :a"},
          {"field :x, :string", 3, "field :x outside a defblock, deftype or defregion"},
          {"defblock :SectionHeader do end", 3,
           "block name :SectionHeader must be a snake_case atom"},
          {~s(defblock :a do field "x", :string end), 3,
           ~s(field name "x" must be a snake_case atom)},
          {"defblock :string do end", 3, "block :string clashes with the primitive type :string"},
          {"defblock :a do field :x, :string, optional: true end", 3,
           "field :x has unknown option(s) [:optional]; allowed: [:required, :since, :deprecated, :fallback]"},
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
           "field :x: deprecated 0.9.0 is before since 0.10.0"},
          {"defblock :a do field :x, {:enum, [:a, :b]} end", 3,
           ":a.x: an enum needs fallback: one of its values"},
          {"defblock :a do field :x, {:enum, [:a, :b]}, fallback: :c end", 3,
           ":a.x: fallback :c is not one of [:a, :b]"},
          {"defblock :a do field :x, {:enum, []}, fallback: :a end", 3,
           ":a.x: an enum needs a list of values, got []"},
          {"defblock :a do field :x, {:enum, [:a, :InProgress]}, fallback: :a end", 3,
           "enum value name :InProgress must be a snake_case atom"},
          {"defblock :a do field :x, {:enum, [:a, :a]}, fallback: :a end", 3,
           ":a.x has enum value :a twice"},
          {"defblock :a do field :x, :string, fallback: :a end", 3,
           ":a.x: fallback is only for an enum"},
          {"defblock :a do field :x, {:list, {:list, :string}} end", 3,
           ":a.x: a list holds one primitive or declared type, got {:list, :string}"},
          {"defblock :a do field :x, {:list, {:enum, [:b]}} end", 3,
           ":a.x: a list holds one primitive or declared type, got {:enum, [:b]}"},
          {"defblock :a do field :x, :image end", 3, ":a.x has unknown type :image"},
          {"defblock :a do end\ndefblock :b do field :children, {:list, :a} end", 4,
           ":b.children holds block :a; blocks have no children"},
          # Clients name things in camelCase, where these would be the same name.
          {"defblock :a do field :x, {:enum, [:a1, :a_1]}, fallback: :a1 end", 3,
           ":a.x has enum values :a1 and :a_1, which clients both name a1"},
          {"defblock :a do field :x, {:enum, [:a_b, :a__b]}, fallback: :a_b end", 3,
           ":a.x has enum values :a_b and :a__b, which clients both name aB"},
          {"defblock :a do\nfield :a_1, :string\nfield :a1, :string\nend", 5,
           ":a has fields :a_1 and :a1, which clients both name a1"},
          {"defblock :a_b do end\ndefblock :a__b do end", 4,
           "the spec has :a_b and :a__b, which clients both name aB"},
          # nil, true and false aren't names: nil is a missing prop, and Swift has no such case.
          {"defblock :a do field :x, {:enum, [:a, nil]}, fallback: :a end", 3,
           "enum value name nil must be a snake_case atom other than nil, true and false"},
          {"defblock :a do field :x, {:enum, [true, false]}, fallback: false end", 3,
           "enum value name true must be a snake_case atom other than nil, true and false"},
          {"defblock :a do field nil, :string end", 3,
           "field name nil must be a snake_case atom other than nil, true and false"},
          {"defblock :a do field :x, {:enum, [:a]}, fallback: nil end", 3,
           ":a.x: fallback nil is not one of [:a]"},
          # Types only hold types declared before them, so they never form a cycle.
          {"deftype :a do field :b, :b end\ndeftype :b do end", 3,
           ":a.b holds type :b, which isn't declared before it"},
          {"deftype :a do field :children, {:list, :a} end", 3,
           ":a.children holds type :a, which isn't declared before it"},
          {"deftype :a do field :x, {:list, {:list, :string}} end", 3,
           ":a.x: a list holds one primitive or declared type, got {:list, :string}"},
          # types.ex compiles before blocks.ex, so the message names the rule.
          {"deftype :a do field :x, :section end", 3,
           ":a.x has unknown type :section; a type holds a primitive, an enum, a type declared before it or a list of one, never a block"},
          {"deftype :a do field :x, {:list, :section} end", 3,
           ":a.x: a list holds one primitive or declared type, got :section; a type holds"},
          {"deftype :integer do end", 3,
           "type :integer clashes with the primitive type :integer"},
          {"deftype :a do\ndeftype :b do end\nend", 4, "deftype :b inside deftype :a"},
          {"defblock :a do end\ndeftype :a do end", 4, ":a is defined twice"},
          {"defblock :a_b do end\ndeftype :a__b do end", 4,
           "the spec has :a_b and :a__b, which clients both name aB"},
          # Region kinds: fields like a block's, but never start or end; a block never id.
          {"defregion :a do field :x, :nope end", 3, ":a.x has unknown type :nope"},
          {"defregion :a do\ndefregion :b do end\nend", 4, "defregion :b inside defregion :a"},
          {"defblock :a do end\ndefregion :a do end", 4, ":a is defined twice"},
          {"defblock :a do field :id, :string end", 3,
           "block :a can't have field :id: every block has it next to its props"},
          {"defregion :a do field :start, :string end", 3,
           "region :a can't have field :start: every region has it next to its props"},
          {"defregion :a do field :end, :string end", 3,
           "region :a can't have field :end: every region has it next to its props"},
          # A param is a query parameter of a primitive type, declared in its page.
          {"param :year, :integer", 3, "param :year outside a defpage"},
          {"defblock :a do param :year, :integer end", 3, "param :year outside a defpage"},
          {"defpage :a do field :x, :string end", 3,
           "field :x outside a defblock, deftype or defregion"},
          {"defpage :a do\nparam :year, :integer\nparam :year, :string\nend", 5,
           "page :a has param :year twice"},
          {"defpage :a do param :Year, :integer end", 3,
           "param name :Year must be a snake_case atom"},
          {"defpage :a do param :years, {:list, :integer} end", 3,
           "param :years: a param is a primitive type, got {:list, :integer}"},
          {"defpage :a do param :tone, {:enum, [:a]} end", 3,
           "param :tone: a param is a primitive type, got {:enum, [:a]}"},
          {"defpage :a do defpage :b end", 3, "defpage :b inside defpage :a"}
        ] do
      error = assert_raise CompileError, fn -> compile!(body) end
      assert Exception.message(error) =~ "bad.ex:#{line}: #{message}", body
    end
  end

  test "use with an option other than types fails with the file and line" do
    source =
      "defmodule Bad#{System.unique_integer([:positive])} do\n  use MicaBff.Schema, typez: X\nend\n"

    assert_raise CompileError,
                 ~r/bad\.ex:2: use MicaBff\.Schema has unknown option\(s\) \[:typez\]; allowed: \[:types\]/,
                 fn -> Code.compile_string(source, "bad.ex") end
  end

  test "use with options that aren't a keyword list fails with the file and line" do
    source =
      "defmodule Bad#{System.unique_integer([:positive])} do\n  use MicaBff.Schema, MicaBff.Types\nend\n"

    assert_raise CompileError, ~r/bad\.ex:2: use MicaBff\.Schema takes types: Module/, fn ->
      Code.compile_string(source, "bad.ex")
    end
  end

  test "a part of the spec that declares another kind fails naming what to move" do
    [{module, _}] = compile!("defblock :a do end\ndeftype :option do end")

    message =
      "#{inspect(module)} holds only blocks, but declares :option in types; move it to the module of its kind"

    assert_raise CompileError, ~r/#{Regex.escape(message)}/, fn ->
      MicaBff.Schema.only!(module, :blocks)
    end

    assert [%{name: :a}] =
             MicaBff.Schema.only!(compile!("defblock :a do end") |> hd() |> elem(0), :blocks)
  end

  defp compile!(body, opts \\ []) do
    Code.compile_string(
      """
      defmodule Bad#{System.unique_integer([:positive])} do
        use MicaBff.Schema#{if opts[:types], do: ", types: #{inspect(opts[:types])}"}
      #{body}
      end
      """,
      "bad.ex"
    )
  end
end
