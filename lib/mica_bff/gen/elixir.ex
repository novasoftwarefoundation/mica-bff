defmodule MicaBff.Gen.Elixir do
  @moduledoc """
  Defines one Elixir module per block, markup kind and type at compile time, under
  the module that uses it, the way `Prism.Generator.Phoenix` defines components:

      defmodule Systems.BFF.Blocks do
        use MicaBff.Gen.Elixir, spec: MicaBff.Spec
      end

  This defines `Systems.BFF.Blocks.Section` and so on: a struct with the required
  fields enforced, a typespec, and `to_map/1`, which returns the wire shape
  `%{"id" => ..., "type" => ..., "props" => ...}` for any JSON library (mica uses
  Jason). Every block has an `id`, a string the page picks that stays the same while
  it shows the same thing; `to_map/1` raises when it isn't a string. A markup kind
  (`Systems.BFF.Blocks.Border`) is a struct with `start` and `end`, the ids of the
  first and last block it covers, and `to_map/1` gives
  `%{"kind" => ..., "start" => ..., "end" => ..., "props" => ...}`.
  Optional props that are `nil` are left out, as ADR 0001 requires; `""`, `0`,
  `false`, `[]` and `%{}` are values and are sent. A required prop that is `nil`
  raises `ArgumentError` in `to_map/1`: clients treat every prop as optional, so only
  the server keeps required props filled (tolerant reader). An enum prop is an atom in the
  struct and its name on the wire; a list is a list. A type
  (`Systems.BFF.Blocks.FilterOption`) is a struct whose `to_map/1` gives a plain
  JSON object, and a block's prop holds its struct.

  The module that uses it gets `pages/0`, the spec's pages with their params
  (`[%{name: :home, path: "/bff/page/home", params: []}]`), `page_params/2`,
  which reads a page's params from the request's query parameters, and the rules of
  markup: `view_model/2`, the page on the wire, which raises on bad markup;
  `check/2`, why markup is bad; and `tree/2`, the nested tree a client renders. The
  defined modules call nothing in mica-bff, so an app can depend on it with
  `runtime: false`.
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
      Enum.map(types, &record(&1, "Type", namespace, type_modules, :type)) ++
        Enum.map(schema.blocks, &record(&1, "Block", namespace, type_modules, :block)) ++
        Enum.map(
          Map.get(schema, :markup, []),
          &record(&1, "Markup", namespace, type_modules, :markup)
        )

    # A compile-time dependency: this module recompiles when the spec changes.
    quote do
      require unquote(spec)

      @doc "The pages the BFF serves, in spec order: each is a GET at its path that returns its view model, blocks and markup."
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
      # Only the server enforces required props, so nil for one raises here.
      @doc false
      def __encode__(fields, %module{} = record) do
        Enum.reduce(fields, %{}, fn {name, key, type, required}, map ->
          case Map.fetch!(record, name) do
            nil when required ->
              raise ArgumentError, "#{inspect(module)}: required prop #{name} is nil"

            nil ->
              map

            value ->
              Map.put(map, key, __encode_value__(type, value))
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

      # The keys a block (`id`) or markup entry (`start`, `end`) has next to its props:
      # always a string, as clients read them.
      @doc false
      def __keys__(keys, %module{} = record) do
        Map.new(keys, fn key ->
          case Map.fetch!(record, key) do
            value when is_binary(value) ->
              {Atom.to_string(key), value}

            value ->
              raise ArgumentError,
                    "#{inspect(module)}: #{key} must be a string, got #{inspect(value)}"
          end
        end)
      end

      @doc """
      The page as it goes on the wire, `%{"blocks" => [...], "markup" => [...]}`: the
      blocks in page order and the markup beside them. Raises `ArgumentError` when the
      markup is bad (`check/2`): the server never sends bad markup.
      """
      @spec view_model([struct], [struct]) :: %{String.t() => [map]}
      def view_model(blocks, markup \\ []) do
        ids = Enum.map(blocks, fn %{id: id} -> id end)

        case check(ids, markup) do
          :ok ->
            %{
              "blocks" => Enum.map(blocks, &__to_map__/1),
              "markup" => Enum.map(markup, &__to_map__/1)
            }

          {:error, reason} ->
            raise ArgumentError, "bad view model: #{reason}"
        end
      end

      defp __to_map__(%module{} = record), do: module.to_map(record)

      @doc """
      `:ok` when `markup` holds for the blocks with `ids`, in page order, or
      `{:error, reason}` for the first thing that doesn't: two blocks with one id, an
      entry whose `start` or `end` is no block's id, one that ends before it starts, or
      one that crosses an entry before it. Markup nests as in XML: two entries share no
      block, or one covers all of the other.
      """
      @spec check([String.t() | nil], [map]) :: :ok | {:error, String.t()}
      def check(ids, markup) do
        positions = __positions__(ids)

        result =
          Enum.reduce_while(markup, [], fn entry, kept ->
            case __span__(positions, kept, entry) do
              {:ok, span} -> {:cont, [span | kept]}
              error -> {:halt, error}
            end
          end)

        case {__duplicates__(ids), result} do
          {[id | _], _} -> {:error, "two blocks have id #{inspect(id)}"}
          {[], {:error, reason}} -> {:error, reason}
          {[], _kept} -> :ok
        end
      end

      @doc """
      The nested tree a client renders for the blocks with `ids`, in page order, and
      their `markup`: `{:block, id}` and `{:markup, entry, children}`. Entries over the
      same stretch nest in list order, the first outermost. Like a client, it leaves out
      an entry that `check/2` refuses, and the blocks it covers still show.
      """
      @spec tree([String.t() | nil], [map]) :: [{:block, String.t() | nil} | {:markup, map, list}]
      def tree(ids, markup) do
        positions = __positions__(ids)

        kept =
          Enum.reduce(markup, [], fn entry, kept ->
            case __span__(positions, kept, entry) do
              {:ok, span} -> [span | kept]
              {:error, _reason} -> kept
            end
          end)

        # Outermost first: by start, the longest first, then in list order (a stable sort).
        spans =
          kept |> Enum.reverse() |> Enum.sort_by(fn {_entry, first, last} -> {first, -last} end)

        __tree__(ids, 0, spans)
      end

      defp __tree__([], _position, _spans), do: []

      defp __tree__(ids, position, [{entry, position, last} | spans]) do
        {inside, outside} =
          Enum.split_while(spans, fn {_entry, first, _last} -> first <= last end)

        {covered, rest} = Enum.split(ids, last - position + 1)

        [
          {:markup, entry, __tree__(covered, position, inside)}
          | __tree__(rest, last + 1, outside)
        ]
      end

      defp __tree__([id | ids], position, spans),
        do: [{:block, id} | __tree__(ids, position + 1, spans)]

      # Ids more than one block has, in page order. A block without an id has none.
      defp __duplicates__(ids), do: Enum.uniq(Enum.reject(ids -- Enum.uniq(ids), &is_nil/1))

      # Where each id is on the page. An id two blocks have points at neither.
      defp __positions__(ids) do
        duplicates = __duplicates__(ids)

        for {id, position} <- Enum.with_index(ids),
            is_binary(id) and id not in duplicates,
            into: %{},
            do: {id, position}
      end

      # The positions an entry covers, when it nests with the entries `kept` before it.
      defp __span__(positions, kept, %{start: start, end: stop} = entry) do
        first = Map.get(positions, start)
        last = Map.get(positions, stop)
        name = "markup from #{inspect(start)} to #{inspect(stop)}"

        crosses? = fn {_entry, a, b} ->
          (a < first and first <= b and b < last) or (first < a and a <= last and last < b)
        end

        cond do
          first == nil ->
            {:error, "#{name}: #{inspect(start)} is no block's id"}

          last == nil ->
            {:error, "#{name}: #{inspect(stop)} is no block's id"}

          last < first ->
            {:error, "#{name}: it ends before it starts"}

          # The first crossed entry in list order, as every client reports it.
          crossed = kept |> Enum.reverse() |> Enum.find(crosses?) ->
            {%{start: crossed_start, end: crossed_stop}, _a, _b} = crossed

            {:error,
             "#{name} crosses the markup from #{inspect(crossed_start)} to #{inspect(crossed_stop)}"}

          true ->
            {:ok, {entry, first, last}}
        end
      end

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

  # A block, markup kind or type: a struct and its `to_map/1`. Only the spec's fields
  # are encoded: a key put on the struct by hand is never sent.
  defp record(%{name: name, fields: fields}, kind, namespace, type_modules, shape) do
    # The keys next to the props, and the key that names the block or markup kind.
    {outer, named} =
      case shape do
        :block -> {[:id], "type"}
        :markup -> {[:start, :end], "kind"}
        :type -> {[], nil}
      end

    keys = outer ++ Enum.map(fields, & &1.name)
    required = outer ++ for %{name: key, required: true} <- fields, do: key

    types =
      Enum.map(outer, &{&1, quote(do: String.t())}) ++
        Enum.map(fields, &{&1.name, type(&1, type_modules)})

    codec_fields =
      Macro.escape(
        for %{name: name, type: type, required: required} <- fields,
            do: {name, Atom.to_string(name), codec_type(type, type_modules), required}
      )

    encoded = quote(do: unquote(namespace).__encode__(unquote(codec_fields), record))

    wire =
      case named do
        nil ->
          encoded

        named ->
          quote do
            Map.merge(unquote(namespace).__keys__(unquote(outer), record), %{
              unquote(named) => unquote(Atom.to_string(name)),
              "props" => unquote(encoded)
            })
          end
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
