defmodule MicaBff.Gen.Elixir do
  @moduledoc """
  Defines one Elixir module per block and type at compile time, under the module
  that uses it, the way `Prism.Generator.Phoenix` defines components:

      defmodule Systems.BFF.Blocks do
        use MicaBff.Gen.Elixir, spec: MicaBff.Spec
      end

  This defines `Systems.BFF.Blocks.Section` and so on: a struct with the required
  fields enforced, a typespec, and `to_map/1`, which returns the wire shape
  `%{"type" => ..., "props" => ...}` for any JSON library (mica uses Jason).
  Optional props that are `nil` are left out, as ADR 0001 requires; `""`, `0`,
  `false`, `[]` and `%{}` are values and are sent. An enum prop is an atom in the
  struct and its name on the wire; a list is a list. A type
  (`Systems.BFF.Blocks.FilterOption`) is a struct whose `to_map/1` gives a plain
  JSON object, and a block's prop holds its struct.

  The module that uses it gets `pages/0`, the spec's pages with their params
  (`[%{name: :home, path: "/bff/page/home", params: []}]`), and `page_params/2`,
  which reads a page's params from the request's query parameters. The defined
  modules call nothing in mica-bff, so an app can depend on it with `runtime: false`.
  """

  @types %{
    string: quote(do: String.t()),
    integer: quote(do: integer()),
    float: quote(do: float()),
    boolean: quote(do: boolean())
  }

  defmacro __using__(opts) do
    opts = options!(opts, __CALLER__)
    spec = spec!(opts[:spec], __CALLER__)
    schema = spec.__schema__()
    namespace = __CALLER__.module
    pages = Enum.map(Map.get(schema, :pages, []), &Map.put_new(&1, :params, []))
    types = Map.get(schema, :types, [])
    type_modules = Map.new(types, &{&1.name, module(namespace, &1.name)})

    records =
      Enum.map(types, &record(&1, "Type", namespace, type_modules, :to_map)) ++
        Enum.map(schema.blocks, &record(&1, "Block", namespace, type_modules, :block))

    # A compile-time dependency: this module recompiles when the spec changes.
    quote do
      require unquote(spec)

      @doc "The pages the BFF serves, in spec order: each is a GET at its path that returns a flat list of blocks."
      @spec pages() :: [%{name: atom, path: String.t(), params: [%{name: atom, type: atom}]}]
      def pages, do: unquote(Macro.escape(pages))

      @doc """
      The params of `page` in `query`, a request's query parameters, by name and typed:
      `page_params(:marketplace, %{"year" => "2025"})` is `%{year: 2025}`. One the page
      doesn't declare, one that is empty and one that doesn't parse are left out, as if
      absent: a stale link still opens the page.
      """
      @spec page_params(atom, %{String.t() => term}) :: %{atom => term}
      def page_params(page, query) when is_map(query) do
        case Enum.find(pages(), &(&1.name == page)) do
          %{params: params} ->
            for %{name: name, type: type} <- params,
                {:ok, value} <- [__param__(type, Map.get(query, Atom.to_string(name)))],
                into: %{},
                do: {name, value}

          nil ->
            %{}
        end
      end

      defp __param__(_type, ""), do: :error
      defp __param__(:string, value) when is_binary(value), do: {:ok, value}
      defp __param__(:boolean, "true"), do: {:ok, true}
      defp __param__(:boolean, "false"), do: {:ok, false}

      defp __param__(:integer, value) when is_binary(value) do
        case Integer.parse(value) do
          {integer, ""} -> {:ok, integer}
          _ -> :error
        end
      end

      defp __param__(:float, value) when is_binary(value) do
        case Float.parse(value) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
      end

      defp __param__(_type, _value), do: :error

      # Encodes the fields of a block or type. A field is `{name, key, type, required}`,
      # its type with each declared type resolved to its module: `{:type, module}`.
      @doc false
      def __encode__(fields, record) do
        Enum.reduce(fields, %{}, fn {name, key, type, required}, map ->
          case Map.fetch!(record, name) do
            nil when not required -> map
            value -> Map.put(map, key, __encode_value__(type, value))
          end
        end)
      end

      defp __encode_value__(_type, nil), do: nil

      defp __encode_value__({:enum, _values}, value) when is_atom(value),
        do: Atom.to_string(value)

      defp __encode_value__({:type, module}, value), do: module.to_map(value)

      defp __encode_value__({:list, type}, values),
        do: Enum.map(values, &__encode_value__(type, &1))

      defp __encode_value__(_primitive, value), do: value

      unquote_splicing(records)
    end
  end

  defp options!(opts, env) do
    case Keyword.keyword?(opts) && Keyword.validate(opts, [:spec]) do
      {:ok, opts} ->
        opts

      {:error, unknown} ->
        message =
          "use MicaBff.Gen.Elixir has unknown option(s) #{inspect(unknown)}; allowed: [:spec]"

        MicaBff.Schema.__fail__(env.file, env.line, message)

      false ->
        MicaBff.Schema.__fail__(
          env.file,
          env.line,
          "use MicaBff.Gen.Elixir takes spec: MicaBff.Spec"
        )
    end
  end

  defp spec!(nil, env) do
    MicaBff.Schema.__fail__(
      env.file,
      env.line,
      "use MicaBff.Gen.Elixir needs spec: MicaBff.Spec"
    )
  end

  defp spec!(ast, env) do
    spec = Macro.expand(ast, env)
    if spec?(spec), do: spec, else: not_a_spec!(ast, env)
  end

  defp spec?(spec) do
    is_atom(spec) and match?({:module, _}, Code.ensure_compiled(spec)) and
      function_exported?(spec, :__schema__, 0)
  end

  defp not_a_spec!(ast, env) do
    message = "spec: #{Macro.to_string(ast)} is not a spec (a module with __schema__/0)"
    MicaBff.Schema.__fail__(env.file, env.line, message)
  end

  defp module(namespace, name), do: Module.concat(namespace, Macro.camelize(to_string(name)))

  # A block or type: a struct and its `to_map/1`. Only the spec's fields are encoded:
  # a key put on the struct by hand is never sent.
  defp record(%{name: name, fields: fields}, kind, namespace, type_modules, shape) do
    keys = Enum.map(fields, & &1.name)
    required = for %{name: key, required: true} <- fields, do: key
    types = Enum.map(fields, &{&1.name, type(&1, type_modules)})

    codec_fields =
      Macro.escape(
        for %{name: name, type: type, required: required} <- fields,
            do: {name, Atom.to_string(name), codec_type(type, type_modules), required}
      )

    encoded = quote(do: unquote(namespace).__encode__(unquote(codec_fields), record))

    wire =
      case shape do
        :block ->
          quote(do: %{"type" => unquote(Atom.to_string(name)), "props" => unquote(encoded)})

        :to_map ->
          encoded
      end

    quote do
      defmodule unquote(module(namespace, name)) do
        @moduledoc unquote("#{kind} `#{name}`.")
        @enforce_keys unquote(required)
        defstruct unquote(keys)

        @type t :: %__MODULE__{unquote_splicing(types)}

        @doc "The wire shape, ready for any JSON encoder."
        @spec to_map(t) :: map
        def to_map(%__MODULE__{} = record), do: unquote(wire)
      end
    end
  end

  defp codec_type({:list, type}, types), do: {:list, codec_type(type, types)}
  defp codec_type(type, types) when is_map_key(types, type), do: {:type, types[type]}
  defp codec_type(type, _types), do: type

  defp type(%{type: type, required: true}, types), do: base_type(type, types)
  defp type(%{type: type}, types), do: quote(do: unquote(base_type(type, types)) | nil)

  defp base_type({:enum, values}, _types),
    do: values |> Enum.reverse() |> Enum.reduce(&quote(do: unquote(&1) | unquote(&2)))

  defp base_type({:list, type}, types), do: quote(do: [unquote(base_type(type, types))])

  defp base_type(type, types) when is_map_key(types, type),
    do: quote(do: unquote(types[type]).t())

  defp base_type(type, _types), do: @types[type]
end
