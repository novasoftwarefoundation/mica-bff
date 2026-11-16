defmodule MicaBff.Gen.Elixir do
  @moduledoc """
  Defines one Elixir module per block at compile time, under the module that uses
  it, the way `Prism.Generator.Phoenix` defines components:

      defmodule Systems.BFF.Blocks do
        use MicaBff.Gen.Elixir, spec: MicaBff.Spec
      end

  This defines `Systems.BFF.Blocks.Section` and so on: a struct with the required
  fields enforced, a typespec, and `to_map/1`, which returns the wire shape
  `%{"type" => ..., "props" => ...}` for any JSON library (mica uses Jason).
  Optional props that are `nil` are left out, as ADR 0001 requires; `""`, `0`,
  `false`, `[]` and `%{}` are values and are sent. An enum prop is an atom in the
  struct and its name on the wire; a list is a list. The module that uses it gets
  `pages/0`, the spec's pages: `[%{name: :home, path: "/bff/page/home"}]`.

  Endpoints and models get modules too. A model (`Systems.BFF.Blocks.Image`) is a
  struct with `to_map/1` and `from_map/1`. An endpoint `save_profile` gets
  `SaveProfile.Request`, whose `from_map/1` checks the JSON object the client sent
  against the spec (`{:ok, struct}`, or `{:error, errors}` with a list of messages
  per field path such as `"photo.url"` or `"tags.0"`), and `SaveProfile.Response`,
  whose `to_map/1` gives the answer's wire shape. Unknown keys are ignored, `null`
  is a missing value, and an enum value the spec doesn't have is an error. The
  module that uses it gets `endpoints/0` (`[%{name: :save_profile, method: :post,
  path: "/bff/endpoint/save_profile"}]`) and `endpoint_error/2`, the body of a
  422. The defined modules call nothing in mica-bff, so an app can depend on it
  with `runtime: false`.
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
    modules = Enum.map(schema.blocks, &block_module(&1, namespace))
    pages = Map.get(schema, :pages, [])
    endpoints = Map.get(schema, :endpoints, [])
    models = Map.new(Map.get(schema, :models, []), &{&1.name, module(namespace, &1.name)})

    records =
      Enum.map(Map.get(schema, :models, []), &record_module(&1, namespace, models)) ++
        Enum.flat_map(endpoints, &endpoint_modules(&1, namespace, models))

    # A compile-time dependency: this module recompiles when the spec changes.
    quote do
      require unquote(spec)

      @doc "The pages the BFF serves, in spec order: each is a GET at its path that returns a flat list of blocks."
      @spec pages() :: [%{name: atom, path: String.t()}]
      def pages, do: unquote(Macro.escape(pages))

      @doc "The BFF's other calls, in spec order: each answers its method at its path."
      @spec endpoints() :: [%{name: atom, method: atom, path: String.t()}]
      def endpoints,
        do: unquote(Macro.escape(Enum.map(endpoints, &Map.take(&1, [:name, :method, :path]))))

      @doc ~S|The body of a 422: `%{"error" => message, "errors" => %{"field" => ["..."]}}`.|
      @spec endpoint_error(String.t(), %{String.t() => [String.t()]}) :: map
      def endpoint_error(message, errors \\ %{}),
        do: %{"error" => message, "errors" => errors}

      unquote(codec())
      unquote_splicing(modules)
      unquote_splicing(records)
    end
  end

  # The wire codec of models, requests and responses, defined on the namespace module
  # so the records call nothing in mica-bff. A field is `{name, key, type, required}`,
  # its type with each model resolved to its module: `{:model, module}`.
  defp codec do
    quote do
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
      defp __encode_value__({:enum, _values}, value), do: Atom.to_string(value)
      defp __encode_value__({:model, module}, value), do: module.to_map(value)

      defp __encode_value__(:blocks, blocks),
        do: Enum.map(blocks, fn %module{} = block -> module.to_map(block) end)

      defp __encode_value__({:list, type}, values),
        do: Enum.map(values, &__encode_value__(type, &1))

      defp __encode_value__(_primitive, value), do: value

      @doc false
      def __decode__(fields, module, map) do
        {values, errors} =
          Enum.reduce(fields, {%{}, %{}}, fn {name, key, type, required}, {values, errors} ->
            case __decode_value__(type, Map.get(map, key)) do
              {:ok, nil} when required -> {values, Map.put(errors, key, ["is required"])}
              {:ok, value} -> {Map.put(values, name, value), errors}
              {:error, nested} -> {values, Map.merge(errors, __at__(key, nested))}
            end
          end)

        if errors == %{}, do: {:ok, struct!(module, values)}, else: {:error, errors}
      end

      defp __decode_value__(_type, nil), do: {:ok, nil}
      defp __decode_value__(:string, value) when is_binary(value), do: {:ok, value}
      defp __decode_value__(:integer, value) when is_integer(value), do: {:ok, value}
      defp __decode_value__(:float, value) when is_number(value), do: {:ok, value / 1}
      defp __decode_value__(:boolean, value) when is_boolean(value), do: {:ok, value}

      defp __decode_value__({:model, module}, value) when is_map(value),
        do: module.from_map(value)

      defp __decode_value__({:enum, values} = type, value) when is_binary(value) do
        case Enum.find(values, &(Atom.to_string(&1) == value)) do
          nil -> __invalid__(type)
          atom -> {:ok, atom}
        end
      end

      defp __decode_value__({:list, type}, values) when is_list(values) do
        {decoded, errors} =
          values
          |> Enum.with_index()
          |> Enum.reduce({[], %{}}, fn {value, index}, {decoded, errors} ->
            case __decode_value__(type, value) do
              {:ok, nil} -> {decoded, Map.put(errors, "#{index}", ["is required"])}
              {:ok, value} -> {[value | decoded], errors}
              {:error, nested} -> {decoded, Map.merge(errors, __at__("#{index}", nested))}
            end
          end)

        if errors == %{}, do: {:ok, Enum.reverse(decoded)}, else: {:error, errors}
      end

      defp __decode_value__(type, _value), do: __invalid__(type)

      defp __invalid__(:string), do: {:error, %{"" => ["must be a string"]}}
      defp __invalid__(:integer), do: {:error, %{"" => ["must be an integer"]}}
      defp __invalid__(:float), do: {:error, %{"" => ["must be a number"]}}
      defp __invalid__(:boolean), do: {:error, %{"" => ["must be true or false"]}}
      defp __invalid__({:model, _module}), do: {:error, %{"" => ["must be an object"]}}
      defp __invalid__({:list, _type}), do: {:error, %{"" => ["must be a list"]}}

      defp __invalid__({:enum, values}),
        do: {:error, %{"" => ["must be one of #{Enum.join(values, ", ")}"]}}

      # "" is the value itself; nested errors get their path below `key`.
      defp __at__(key, errors) do
        Map.new(errors, fn
          {"", messages} -> {key, messages}
          {path, messages} -> {"#{key}.#{path}", messages}
        end)
      end
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

  defp block_module(%{name: name, fields: fields}, namespace) do
    quote do
      defmodule unquote(module(namespace, name)), do: unquote(block_body(name, fields))
    end
  end

  defp record_module(%{name: name, fields: fields}, namespace, models) do
    record(module(namespace, name), "Model `#{name}`.", fields, namespace, models, [
      :to_map,
      :from_map
    ])
  end

  defp endpoint_modules(%{name: name, method: method, path: path} = endpoint, namespace, models) do
    endpoint_module = module(namespace, name)
    call = "#{method |> Atom.to_string() |> String.upcase()} #{path}"

    [
      quote do
        defmodule unquote(endpoint_module),
          do: @moduledoc(unquote("Endpoint `#{name}`: `#{call}`."))
      end,
      record(
        Module.concat(endpoint_module, Request),
        "What the client sends to `#{call}`.",
        endpoint.request,
        namespace,
        models,
        [:from_map]
      ),
      record(
        Module.concat(endpoint_module, Response),
        "What `#{call}` answers.",
        endpoint.response,
        namespace,
        models,
        [:to_map]
      )
    ]
  end

  # A model, request or response: a struct and the codec functions it needs.
  defp record(module, doc, fields, namespace, models, functions) do
    keys = Enum.map(fields, & &1.name)
    required = for %{name: key, required: true} <- fields, do: key
    types = Enum.map(fields, &{&1.name, type(&1, models)})

    codec_fields =
      for %{name: name, type: type, required: required} <- fields,
          do: {name, Atom.to_string(name), codec_type(type, models), required}

    to_map =
      quote do
        @doc "The wire shape, ready for any JSON encoder."
        @spec to_map(t) :: map
        def to_map(%__MODULE__{} = record),
          do: unquote(namespace).__encode__(unquote(Macro.escape(codec_fields)), record)
      end

    from_map =
      quote do
        @doc "Checks a decoded JSON object against the spec."
        @spec from_map(map) :: {:ok, t} | {:error, %{String.t() => [String.t()]}}
        def from_map(map) when is_map(map),
          do: unquote(namespace).__decode__(unquote(Macro.escape(codec_fields)), __MODULE__, map)
      end

    quote do
      defmodule unquote(module) do
        @moduledoc unquote(doc)
        @enforce_keys unquote(required)
        defstruct unquote(keys)

        @type t :: %__MODULE__{unquote_splicing(types)}

        unquote(if :to_map in functions, do: to_map)
        unquote(if :from_map in functions, do: from_map)
      end
    end
  end

  defp codec_type({:list, type}, models), do: {:list, codec_type(type, models)}
  defp codec_type(type, models) when is_map_key(models, type), do: {:model, models[type]}
  defp codec_type(type, _models), do: type

  defp block_body(name, fields) do
    keys = Enum.map(fields, & &1.name)
    required = for %{name: key, required: true} <- fields, do: key
    enums = for %{name: key, type: {:enum, _}} <- fields, do: key
    types = Enum.map(fields, &{&1.name, type(&1)})

    quote do
      @moduledoc unquote("Block `#{name}`.")
      @enforce_keys unquote(required)
      defstruct unquote(keys)

      @type t :: %__MODULE__{unquote_splicing(types)}

      @doc "The wire shape, ready for any JSON encoder."
      @spec to_map(t) :: map
      def to_map(%__MODULE__{} = block),
        do: %{"type" => unquote(to_string(name)), "props" => props(block)}

      # Only the spec's fields: a key put on the struct by hand is never sent.
      defp props(block) do
        for {key, value} <- Map.take(block, unquote(keys)),
            value != nil or key in unquote(required),
            into: %{},
            do: {Atom.to_string(key), wire(key, value)}
      end

      unquote(enum_wire(enums))
      defp wire(_key, value), do: value
    end
  end

  # An enum is an atom in the struct and its name on the wire. Only blocks with an
  # enum get this clause, so the others have no clause that can't match.
  defp enum_wire([]), do: nil

  defp enum_wire(enums) do
    quote do
      defp wire(key, value) when key in unquote(enums) and is_atom(value) and value != nil,
        do: Atom.to_string(value)
    end
  end

  defp type(field, models \\ %{})
  defp type(%{type: type, required: true}, models), do: base_type(type, models)
  defp type(%{type: type}, models), do: quote(do: unquote(base_type(type, models)) | nil)

  defp base_type({:enum, values}, _models),
    do: values |> Enum.reverse() |> Enum.reduce(&quote(do: unquote(&1) | unquote(&2)))

  defp base_type({:list, type}, models), do: quote(do: [unquote(base_type(type, models))])
  defp base_type(:blocks, _models), do: quote(do: [struct()])

  defp base_type(type, models) when is_map_key(models, type),
    do: quote(do: unquote(models[type]).t())

  defp base_type(type, _models), do: @types[type]
end
