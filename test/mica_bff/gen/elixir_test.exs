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

    defmodel :image do
      field(:url, :string, required: true)
      field(:width, :integer)
    end

    defmodel :profile do
      field(:name, :string, required: true)
      field(:photo, :image)
      field(:photos, {:list, :image})
      field(:tone, {:enum, [:calm, :loud]}, fallback: :calm)
      field(:ratio, :float)
      field(:active, :boolean)
    end

    defendpoint :save_profile, method: :post do
      request do
        field(:profile, :profile, required: true)
        field(:tags, {:list, :string})
      end

      response do
        field(:profile, :profile, required: true)
        field(:blocks, :blocks)
      end
    end

    defendpoint :sign_out, method: :delete do
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
  # An enum prop goes in as an atom, as the server sets it, so its encoding is checked too.
  test "every fixture encodes back to itself through its module" do
    ns = namespace_for(MicaBff.Spec)
    %{blocks: blocks} = MicaBff.Spec.__schema__()

    for path <- Path.wildcard("fixtures/*.json") do
      %{"type" => type, "props" => props} = fixture = path |> File.read!() |> JSON.decode!()
      %{fields: fields} = Enum.find(blocks, &(to_string(&1.name) == type))
      enums = for %{name: name, type: {:enum, _}} <- fields, do: to_string(name)
      module = Module.concat(ns, Macro.camelize(type))

      block =
        struct!(
          module,
          Map.new(props, fn {k, v} ->
            {String.to_existing_atom(k), if(k in enums, do: String.to_existing_atom(v), else: v)}
          end)
        )

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

  test "the module that uses it lists the spec's pages; a spec without pages has none" do
    assert namespace_for(MicaBff.Spec).pages() == MicaBff.Spec.__schema__().pages
    assert namespace_for(Spec).pages() == []
  end

  test "the module that uses it lists the spec's endpoints with their method and path" do
    assert namespace_for(Spec).endpoints() == [
             %{name: :save_profile, method: :post, path: "/bff/endpoint/save_profile"},
             %{name: :sign_out, method: :delete, path: "/bff/endpoint/sign_out"}
           ]
  end

  test "the defined modules call nothing in mica-bff at runtime" do
    for spec <- [MicaBff.Spec, Spec] do
      {_namespace, compiled} = compile_use(", spec: #{inspect(spec)}")
      imports = Enum.flat_map(compiled, fn {_module, binary} -> runtime_imports(binary) end)

      refute Enum.any?(imports, &String.starts_with?(&1, "Elixir.MicaBff.")), inspect(spec)
    end
  end

  describe "endpoints" do
    setup do
      ns = namespace_for(Spec)

      %{
        ns: ns,
        request: Module.concat([ns, SaveProfile, Request]),
        response: Module.concat([ns, SaveProfile, Response]),
        profile: Module.concat(ns, Profile),
        image: Module.concat(ns, Image)
      }
    end

    test "a request that matches the spec becomes structs: enums as atoms, a float from any number, unknown keys ignored",
         %{request: request, profile: profile, image: image} do
      body = %{
        "profile" => %{
          "name" => "Ann",
          "photo" => %{"url" => "/a.png", "width" => 10},
          "photos" => [%{"url" => "/b.png", "unknown" => 1}],
          "tone" => "loud",
          "ratio" => 1,
          "active" => false
        },
        "tags" => [],
        "unknown" => "x"
      }

      assert request.from_map(body) ==
               {:ok,
                struct!(request,
                  profile:
                    struct!(profile,
                      name: "Ann",
                      photo: struct!(image, url: "/a.png", width: 10),
                      photos: [struct!(image, url: "/b.png", width: nil)],
                      tone: :loud,
                      ratio: 1.0,
                      active: false
                    ),
                  tags: []
                )}
    end

    test "null is a missing value: fine when optional, an error when required",
         %{request: request, profile: profile} do
      assert request.from_map(%{"profile" => %{"name" => "Ann", "photo" => nil}, "tags" => nil}) ==
               {:ok, struct!(request, profile: struct!(profile, name: "Ann"))}

      assert request.from_map(%{}) == {:error, %{"profile" => ["is required"]}}
      assert request.from_map(%{"profile" => nil}) == {:error, %{"profile" => ["is required"]}}
    end

    test "every mistake in a request gets a message at its field's path", %{request: request} do
      body = %{
        "profile" => %{
          "name" => 1,
          "photo" => "x",
          "photos" => [%{"url" => "/a.png"}, %{}, nil, 3],
          "tone" => "sparkly",
          "ratio" => "1",
          "active" => "yes"
        },
        "tags" => ["a", 2]
      }

      assert request.from_map(body) ==
               {:error,
                %{
                  "profile.name" => ["must be a string"],
                  "profile.photo" => ["must be an object"],
                  "profile.photos.1.url" => ["is required"],
                  "profile.photos.2" => ["is required"],
                  "profile.photos.3" => ["must be an object"],
                  "profile.tone" => ["must be one of calm, loud"],
                  "profile.ratio" => ["must be a number"],
                  "profile.active" => ["must be true or false"],
                  "tags.1" => ["must be a string"]
                }}

      assert request.from_map(%{"profile" => [], "tags" => "a"}) ==
               {:error, %{"profile" => ["must be an object"], "tags" => ["must be a list"]}}
    end

    test "a response encodes models, lists of models, enums and blocks, and leaves out nil optional fields",
         %{ns: ns, response: response, profile: profile, image: image} do
      badge = Module.concat(ns, Badge)

      answer =
        struct!(response,
          profile:
            struct!(profile,
              name: "Ann",
              photos: [struct!(image, url: "/b.png")],
              tone: :loud,
              active: false
            ),
          blocks: [struct!(badge, label: "x")]
        )

      assert response.to_map(answer) == %{
               "profile" => %{
                 "name" => "Ann",
                 "photos" => [%{"url" => "/b.png"}],
                 "tone" => "loud",
                 "active" => false
               },
               "blocks" => [%{"type" => "badge", "props" => %{"label" => "x"}}]
             }
    end

    test "an endpoint without fields has an empty request and response", %{ns: ns} do
      request = Module.concat([ns, SignOut, Request])
      response = Module.concat([ns, SignOut, Response])

      assert request.from_map(%{"anything" => 1}) == {:ok, struct!(request, [])}
      assert response.to_map(struct!(response, [])) == %{}
    end

    test "endpoint_error is the body of a 422", %{ns: ns} do
      assert ns.endpoint_error("Check your profile", %{"profile.name" => ["is required"]}) ==
               %{
                 "error" => "Check your profile",
                 "errors" => %{"profile.name" => ["is required"]}
               }

      assert ns.endpoint_error("Not allowed") == %{"error" => "Not allowed", "errors" => %{}}
    end
  end
end
