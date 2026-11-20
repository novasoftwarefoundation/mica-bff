defmodule MicaBff.Gen.Elixir do
  @moduledoc """
  Defines one Elixir module per block, region kind and type at compile time, under
  the module that uses it, the way `Prism.Generator.Phoenix` defines components:

      defmodule Systems.BFF.Blocks do
        use MicaBff.Gen.Elixir, spec: MicaBff.Spec
      end

  This defines `Systems.BFF.Blocks.Section` and so on: a struct with the required
  fields enforced, a typespec, and `to_map/1`, which returns the wire shape
  `%{"id" => ..., "type" => ..., "props" => ...}` for any JSON library (mica uses
  Jason). Every block has an `id`, a string the page picks that stays the same while
  it shows the same thing; `to_map/1` raises when it isn't a string. A region kind
  (`Systems.BFF.Blocks.Border`) is a struct with `start` and `end`, the ids of the
  first and last block it covers, and `to_map/1` gives
  `%{"kind" => ..., "start" => ..., "end" => ..., "props" => ...}`.
  Optional props that are `nil` are left out, as ADR 0001 requires; `""`, `0`,
  `false`, `[]` and `%{}` are values and are sent. A required prop that is `nil`,
  a list prop that isn't a list and a list with `nil` in it raise `ArgumentError` in
  `to_map/1`: clients treat every prop as optional, so only the server keeps props
  right (tolerant reader), and a server bug fails its page instead of reaching the
  app as a missing prop. An enum prop is an atom in the
  struct and its name on the wire; a list is a list. A type
  (`Systems.BFF.Blocks.FilterOption`) is a struct whose `to_map/1` gives a plain
  JSON object, and a block's prop holds its struct.

  The module that uses it gets `pages/0`, the spec's pages with their params
  (`[%{name: :home, path: "/bff/page/home", params: []}]`), `page_params/2`,
  which reads a page's params from the request's query parameters, and the rules of
  a page's markup, its list of regions: `view_model/2`, the page on the wire, which
  raises on a bad region; `check/2`, why a region is bad; and `tree/2`, the nested
  tree a client renders. The
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
          Map.get(schema, :regions, []),
          &record(&1, "Region", namespace, type_modules, :region)
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
      # Only the server keeps props right, so a nil required prop, a list prop that
      # isn't a list and a nil in a list raise here.
      @doc false
      def __encode__(fields, %module{} = record) do
        Enum.reduce(fields, %{}, fn {name, key, type, required}, map ->
          case {Map.fetch!(record, name), type} do
            {nil, _type} when required ->
              raise ArgumentError, "#{inspect(module)}: required prop #{name} is nil"

            {nil, _type} ->
              map

            {value, {:list, _element}} when not is_list(value) ->
              raise ArgumentError,
                    "#{inspect(module)}: list prop #{name} is not a list: #{inspect(value)}"

            {value, type} ->
              if match?({:list, _element}, type) and nil in value,
                do: raise(ArgumentError, "#{inspect(module)}: list prop #{name} holds nil")

              Map.put(map, key, __encode_value__(type, value))
          end
        end)
      end

      defp __encode_value__({:enum, _values}, value) when is_atom(value),
        do: Atom.to_string(value)

      defp __encode_value__({:type, module}, value), do: module.to_map(value)

      defp __encode_value__({:list, type}, values),
        do: Enum.map(values, &__encode_value__(type, &1))

      defp __encode_value__(_primitive, value), do: value

      # The keys a block (`id`) or region (`start`, `end`) has next to its props:
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
      blocks in page order and the regions beside them. Raises `ArgumentError` when a
      region is bad (`check/2`): the server never sends a bad region.
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
      `:ok` when the regions in `markup` hold for the blocks with `ids`, in page order,
      or `{:error, reason}` for the first region that doesn't: one whose `start` or
      `end` is no block's id or an id two blocks have, one that ends before it starts,
      one that crosses a region before it, or one that would make regions nest deeper
      than #{unquote(MicaBff.Gen.max_region_depth())}. Regions nest as in XML: two regions
      share no block, or one covers all of the other. Two blocks with one id are fine as
      long as no region names that id.
      """
      @spec check([String.t() | nil], [map]) :: :ok | {:error, String.t()}
      def check(ids, markup) do
        positions = __positions__(ids)

        markup
        |> Enum.reduce_while([], fn region, kept ->
          case __keep__(positions, kept, region) do
            {:ok, kept} -> {:cont, kept}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:error, reason} -> {:error, reason}
          _kept -> :ok
        end
      end

      @doc """
      The nested tree a client renders for the blocks with `ids`, in page order, and
      the regions in their `markup`: `{:block, id}` and `{:region, region, children}`.
      Regions over the same stretch nest in list order, the first outermost. Like a
      client, it leaves out a region that `check/2` refuses, and the blocks it covers
      still show.
      """
      @spec tree([String.t() | nil], [map]) :: [{:block, String.t() | nil} | {:region, map, list}]
      def tree(ids, markup) do
        positions = __positions__(ids)

        kept =
          Enum.reduce(markup, [], fn region, kept ->
            case __keep__(positions, kept, region) do
              {:ok, kept} -> kept
              {:error, _reason} -> kept
            end
          end)

        # Outermost first: by start, the longest first, then in list order (a stable sort).
        spans =
          kept
          |> Enum.reverse()
          |> Enum.map(fn {region, first, last, _depth} -> {region, first, last} end)
          |> Enum.sort_by(fn {_region, first, last} -> {first, -last} end)

        __tree__(ids, 0, spans)
      end

      defp __tree__([], _position, _spans), do: []

      defp __tree__(ids, position, [{region, position, last} | spans]) do
        {inside, outside} =
          Enum.split_while(spans, fn {_region, first, _last} -> first <= last end)

        {covered, rest} = Enum.split(ids, last - position + 1)

        [
          {:region, region, __tree__(covered, position, inside)}
          | __tree__(rest, last + 1, outside)
        ]
      end

      defp __tree__([id | ids], position, spans),
        do: [{:block, id} | __tree__(ids, position + 1, spans)]

      # Where each id is on the page; `:duplicate` for an id two blocks have. A block
      # without an id has none.
      defp __positions__(ids) do
        ids
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn
          {id, position}, positions when is_binary(id) ->
            Map.update(positions, id, position, fn _position -> :duplicate end)

          _block, positions ->
            positions
        end)
      end

      defp __position__(positions, id) do
        case Map.fetch(positions, id) do
          {:ok, :duplicate} -> {:error, ~s(two blocks have id "#{id}")}
          {:ok, position} -> {:ok, position}
          :error -> {:error, ~s("#{id}" is no block's id)}
        end
      end

      # `kept` with `region` added, newest first, when it nests with them and keeps every
      # region within the depth limit; or why not. A kept region is
      # `{region, first, last, depth}`. The regions around the new one set its depth; the
      # ones it goes around get one deeper (one over the same stretch before it is around it).
      defp __keep__(positions, kept, %{start: start, end: stop} = region) do
        with {:ok, first, last} <- __span__(positions, kept, region) do
          inside? = fn {_region, a, b, _depth} ->
            first <= a and b <= last and {a, b} != {first, last}
          end

          around = Enum.count(kept, fn {_region, a, b, _depth} -> a <= first and last <= b end)

          deepest =
            Enum.max([around + 1 | for({_r, _a, _b, d} = k <- kept, inside?.(k), do: d + 1)])

          if deepest > unquote(MicaBff.Gen.max_region_depth()) do
            {:error,
             ~s(region from "#{start}" to "#{stop}": regions would nest #{deepest} deep, more than #{unquote(MicaBff.Gen.max_region_depth())})}
          else
            deeper =
              Enum.map(kept, fn {r, a, b, d} = k ->
                if inside?.(k), do: {r, a, b, d + 1}, else: k
              end)

            {:ok, [{region, first, last, around + 1} | deeper]}
          end
        end
      end

      # The positions a region covers, when it nests with the regions `kept` before it.
      # Ids are quoted as they are, as every client writes them.
      defp __span__(positions, kept, %{start: start, end: stop}) do
        name = ~s(region from "#{start}" to "#{stop}")

        with {:ok, first} <- __position__(positions, start),
             {:ok, last} <- __position__(positions, stop),
             :ok <- if(last < first, do: {:error, "it ends before it starts"}, else: :ok),
             # The first crossed region in list order, as every client reports it.
             nil <- kept |> Enum.reverse() |> Enum.find(&__crosses__(&1, first, last)) do
          {:ok, first, last}
        else
          {:error, reason} ->
            {:error, "#{name}: #{reason}"}

          {%{start: crossed_start, end: crossed_stop}, _first, _last, _depth} ->
            {:error, ~s(#{name} crosses the region from "#{crossed_start}" to "#{crossed_stop}")}
        end
      end

      defp __crosses__({_region, a, b, _depth}, first, last),
        do: (a < first and first <= b and b < last) or (first < a and a <= last and last < b)

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

  # A block, region kind or type: a struct and its `to_map/1`. Only the spec's fields
  # are encoded: a key put on the struct by hand is never sent.
  defp record(%{name: name, fields: fields}, kind, namespace, type_modules, shape) do
    # The keys next to the props, and the key that names the block or region kind.
    {outer, named} =
      case shape do
        :block -> {[:id], "type"}
        :region -> {[:start, :end], "kind"}
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
