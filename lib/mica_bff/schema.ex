defmodule MicaBff.Schema do
  @moduledoc """
  The schema of the BFF spec, written as a DSL. It plays the role an XSD plays
  for XML: the macros define what a valid spec is, and the modules that `use`
  them (`MicaBff.Blocks`, `MicaBff.Pages`) are the spec, composed by `MicaBff.Spec`.

      defmodule MyBlocks do
        use MicaBff.Schema

        defblock :section do
          field :title, :string, required: true
          field :to, :string, required: true
        end
      end

  - `defblock` declares a block the BFF can send and clients can render.
  - `field` declares a prop: a snake_case name, a type and `required: true | false`
    (default `false`). A type is a primitive (`:string`, `:integer`, `:float`,
    `:boolean`), an enum (`{:enum, [:accent, :neutral]}`, snake_case values, with
    `fallback:` one of them: what a client makes of a value it doesn't know) or a
    list of one primitive (`{:list, :string}`). Never a block: blocks have no
    children, a page is a flat list of blocks.
    Two more options, both a literal `"major.minor.patch"` spec version (the git tag
    without its `v`) and left out of `__schema__/0` when unset: `since:` (the version
    that added the field) and `deprecated:` (the version that deprecated it, not
    before `since:`). `fallback:` is in `__schema__/0` only on an enum.
  - `defpage` declares a page the BFF serves: always a GET at `/bff/page/<name>`
    that returns a flat list of blocks (`defpage :home` is `GET /bff/page/home`).
  - `defmodel` declares a nested object for endpoints, with fields like a block's.
    A model's field may also hold a model declared before it (`field :photo, :image`)
    or a list of one (`{:list, :image}`), so models never form a cycle. Blocks hold
    no models: blocks have no children.
  - `defendpoint` declares any other call: `defendpoint :save_profile, method: :post`
    is `POST /bff/endpoint/save_profile` (`:get`, `:post`, `:put`, `:patch` or `:delete`). Inside it,
    `request do ... end` holds the fields of the JSON object the client sends (a GET
    has none) and `response do ... end` the fields of the JSON object the server
    answers; each is optional and has no fields when left out. Their fields may
    hold models, and a response field may be `:blocks`, a flat list of blocks.

  Every mistake fails at compile time and points at its line: an unknown type or
  option, a name that isn't a snake_case atom, a duplicate name, a block used as
  a field type or named after a primitive, an enum without values or without a
  fallback among them, a list of anything but a primitive or a model, a model used
  before it is declared, a `field` outside a `defblock`, `defmodel`, `request` or
  `response`, a declaration inside another, a `request` or `response` outside a
  `defendpoint` or twice in one, a GET with a request, an unknown method, and a
  malformed or out-of-order version. Generators read `__schema__/0`, never the source.
  """

  @primitives [:string, :integer, :float, :boolean]
  @methods [:get, :post, :put, :patch, :delete]
  # Type names a block or model can't take: a field type would mean two things.
  @type_names @primitives ++ [:blocks]

  defmacro __using__(_opts) do
    quote do
      import MicaBff.Schema,
        only: [
          defblock: 2,
          defmodel: 2,
          defpage: 1,
          defendpoint: 3,
          request: 1,
          response: 1,
          field: 2,
          field: 3
        ]

      Module.register_attribute(__MODULE__, :mica_bff_blocks, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_models, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_pages, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_endpoints, accumulate: true)
      @before_compile MicaBff.Schema
    end
  end

  defmacro defblock(name, do: body),
    do: record(:defblock, :mica_bff_blocks, name, body, __CALLER__)

  defmacro defmodel(name, do: body),
    do: record(:defmodel, :mica_bff_models, name, body, __CALLER__)

  defp record(kind, attribute, name, body, caller) do
    line = caller.line

    quote do
      MicaBff.Schema.__top_level__!(
        __MODULE__,
        __ENV__.file,
        unquote(line),
        "#{unquote(kind)} #{inspect(unquote(name))}"
      )

      Module.put_attribute(__MODULE__, :mica_bff_open, {unquote(kind), unquote(name)})
      Module.register_attribute(__MODULE__, :mica_bff_fields, accumulate: true)
      unquote(body)

      Module.put_attribute(__MODULE__, unquote(attribute), %{
        name: unquote(name),
        line: unquote(line),
        fields: Enum.reverse(Module.get_attribute(__MODULE__, :mica_bff_fields))
      })

      Module.delete_attribute(__MODULE__, :mica_bff_fields)
      Module.delete_attribute(__MODULE__, :mica_bff_open)
    end
  end

  defmacro field(name, type, given_opts \\ []) do
    line = __CALLER__.line
    fail = &__fail__(__CALLER__.file, line, "field #{Macro.to_string(name)}#{&1}")

    unless Keyword.keyword?(given_opts), do: fail.(": options must be a literal keyword list")

    opts =
      case Keyword.validate(given_opts,
             required: false,
             since: nil,
             deprecated: nil,
             fallback: nil
           ) do
        {:ok, opts} ->
          opts

        {:error, unknown} ->
          fail.(
            " has unknown option(s) #{inspect(unknown)}; allowed: [:required, :since, :deprecated, :fallback]"
          )
      end

    unless is_boolean(opts[:required]), do: fail.(": required must be true or false")

    check_version!(:since, opts[:since], fail)
    check_version!(:deprecated, opts[:deprecated], fail)
    check_version_order!(opts[:since], opts[:deprecated], fail)
    # `fallback:` counts when given, even as nil or false, so it fails as not one of the values.
    versions = for key <- [:since, :deprecated], value = opts[key], do: {key, value}

    fallback =
      if Keyword.has_key?(given_opts, :fallback), do: [fallback: opts[:fallback]], else: []

    extras = versions ++ fallback

    quote do
      unless MicaBff.Schema.__fields_open__?(__MODULE__) do
        MicaBff.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "field #{inspect(unquote(name))} outside a defblock, defmodel, request or response"
        )
      end

      @mica_bff_fields %{
        unquote_splicing(extras),
        name: unquote(name),
        type: unquote(type),
        required: unquote(opts[:required]),
        line: unquote(line)
      }
    end
  end

  defmacro defpage(name) do
    line = __CALLER__.line

    quote do
      MicaBff.Schema.__top_level__!(
        __MODULE__,
        __ENV__.file,
        unquote(line),
        "defpage #{inspect(unquote(name))}"
      )

      @mica_bff_pages %{name: unquote(name), line: unquote(line)}
    end
  end

  defmacro defendpoint(name, opts, do: body) do
    line = __CALLER__.line
    fail = &__fail__(__CALLER__.file, line, "defendpoint #{Macro.to_string(name)}#{&1}")

    method =
      with true <- Keyword.keyword?(opts),
           {:ok, opts} <- Keyword.validate(opts, [:method]),
           method when method in @methods <- opts[:method] do
        method
      else
        _ -> fail.(": takes method: one of #{inspect(@methods)}")
      end

    quote do
      MicaBff.Schema.__top_level__!(
        __MODULE__,
        __ENV__.file,
        unquote(line),
        "defendpoint #{inspect(unquote(name))}"
      )

      Module.put_attribute(__MODULE__, :mica_bff_open, {:defendpoint, unquote(name)})
      Module.put_attribute(__MODULE__, :mica_bff_parts, %{})
      unquote(body)

      @mica_bff_endpoints %{
        name: unquote(name),
        method: unquote(method),
        line: unquote(line),
        parts: Module.get_attribute(__MODULE__, :mica_bff_parts)
      }

      Module.delete_attribute(__MODULE__, :mica_bff_parts)
      Module.delete_attribute(__MODULE__, :mica_bff_open)
    end
  end

  defmacro request(do: body), do: part(:request, body, __CALLER__)
  defmacro response(do: body), do: part(:response, body, __CALLER__)

  defp part(kind, body, caller) do
    line = caller.line

    quote do
      MicaBff.Schema.__part__!(__MODULE__, __ENV__.file, unquote(line), unquote(kind))
      Module.put_attribute(__MODULE__, :mica_bff_part, unquote(kind))
      Module.register_attribute(__MODULE__, :mica_bff_fields, accumulate: true)
      unquote(body)

      Module.put_attribute(
        __MODULE__,
        :mica_bff_parts,
        Map.put(
          Module.get_attribute(__MODULE__, :mica_bff_parts),
          unquote(kind),
          Enum.reverse(Module.get_attribute(__MODULE__, :mica_bff_fields))
        )
      )

      Module.delete_attribute(__MODULE__, :mica_bff_fields)
      Module.delete_attribute(__MODULE__, :mica_bff_part)
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  @doc false
  def __top_level__!(module, file, line, what) do
    if open = Module.get_attribute(module, :mica_bff_open),
      do: __fail__(file, line, "#{what} inside #{describe(open)}")
  end

  @doc false
  def __part__!(module, file, line, kind) do
    open = Module.get_attribute(module, :mica_bff_open)
    part = Module.get_attribute(module, :mica_bff_part)

    cond do
      not match?({:defendpoint, _}, open) ->
        __fail__(file, line, "#{kind} outside a defendpoint")

      part ->
        __fail__(file, line, "#{kind} inside #{part}")

      Map.has_key?(Module.get_attribute(module, :mica_bff_parts), kind) ->
        __fail__(file, line, "#{describe(open)} has #{kind} twice")

      true ->
        :ok
    end
  end

  @doc false
  def __fields_open__?(module) do
    Module.get_attribute(module, :mica_bff_part) != nil or
      match?(
        {kind, _} when kind in [:defblock, :defmodel],
        Module.get_attribute(module, :mica_bff_open)
      )
  end

  defp describe({kind, name}), do: "#{kind} #{inspect(name)}"

  defmacro __before_compile__(env) do
    get = &(env.module |> Module.get_attribute(&1) |> Enum.reverse())
    blocks = get.(:mica_bff_blocks)
    models = get.(:mica_bff_models)
    pages = get.(:mica_bff_pages)
    endpoints = get.(:mica_bff_endpoints)

    # One `seen` across blocks, models and endpoints: in Swift and Elixir they are all
    # types in one namespace.
    seen = validate_blocks!(blocks, env.file)
    seen = validate_models!(models, seen, env.file)
    validate_pages!(pages, env.file)
    validate_endpoints!(endpoints, Enum.map(models, & &1.name), seen, env.file)

    # Line numbers are only for error messages; generators get the plain spec.
    schema = %{
      blocks: Enum.map(blocks, &plain_record/1),
      pages: for(page <- pages, do: %{name: page.name, path: "/bff/page/#{page.name}"}),
      models: Enum.map(models, &plain_record/1),
      endpoints:
        for %{name: name, method: method, parts: parts} <- endpoints do
          %{
            name: name,
            method: method,
            path: "/bff/endpoint/#{name}",
            request: plain_fields(Map.get(parts, :request, [])),
            response: plain_fields(Map.get(parts, :response, []))
          }
        end
    }

    quote do
      @doc "The spec as plain data (blocks, pages, models and endpoints), for generators and validation."
      def __schema__, do: unquote(Macro.escape(schema))
    end
  end

  defp plain_record(%{name: name, fields: fields}),
    do: %{name: name, fields: plain_fields(fields)}

  defp plain_fields(fields), do: Enum.map(fields, &Map.delete(&1, :line))

  defp validate_pages!(pages, file) do
    Enum.reduce(pages, MapSet.new(), fn %{name: name, line: line}, seen ->
      fail = &__fail__(file, line, &1)
      check_name!(name, "page", fail)
      if name in seen, do: fail.("page #{inspect(name)} is defined twice")
      MapSet.put(seen, name)
    end)
  end

  # Blocks have no children: a page is a flat list of blocks, so no field may hold a block.
  defp validate_blocks!(blocks, file) do
    block_names = Enum.map(blocks, & &1.name)
    types = %{blocks: block_names, models: nil, all_models: [], blocks_field: false}

    Enum.reduce(blocks, %{}, fn %{name: name, fields: fields} = block, seen ->
      fail = &__fail__(file, block.line, &1)
      check_record_name!(name, "block", fail)
      validate_fields!(inspect(name), fields, types, file)

      unique!(
        seen,
        name,
        fail,
        "#{inspect(name)} is defined twice",
        &"the spec has blocks #{inspect(&1)} and #{inspect(name)}, which clients both name #{&2}"
      )
    end)
  end

  # A model holds only models declared before it, so models never form a cycle.
  defp validate_models!(models, seen, file) do
    all = Enum.map(models, & &1.name)

    {seen, _before} =
      Enum.reduce(models, {seen, []}, fn %{name: name, fields: fields, line: line},
                                         {seen, before} ->
        fail = &__fail__(file, line, &1)
        check_record_name!(name, "model", fail)
        types = %{blocks: [], models: before, all_models: all, blocks_field: false}
        validate_fields!(inspect(name), fields, types, file)
        {unique_type!(seen, name, fail), [name | before]}
      end)

    seen
  end

  defp validate_endpoints!(endpoints, models, seen, file) do
    Enum.reduce(endpoints, seen, fn %{name: name, method: method, parts: parts, line: line},
                                    seen ->
      fail = &__fail__(file, line, &1)
      check_name!(name, "endpoint", fail)

      if method == :get and Map.get(parts, :request, []) != [],
        do: fail.("defendpoint #{inspect(name)}: a GET has no request body")

      for {part, blocks_field} <- [request: false, response: true] do
        types = %{blocks: [], models: models, all_models: models, blocks_field: blocks_field}
        validate_fields!("#{inspect(name)}.#{part}", Map.get(parts, part, []), types, file)
      end

      unique_type!(seen, name, fail)
    end)
  end

  defp unique_type!(seen, name, fail) do
    unique!(
      seen,
      name,
      fail,
      "#{inspect(name)} is defined twice",
      &"the spec has #{inspect(&1)} and #{inspect(name)}, which clients both name #{&2}"
    )
  end

  defp check_record_name!(name, kind, fail) do
    check_name!(name, kind, fail)

    if name in @type_names,
      do: fail.("#{kind} #{inspect(name)} clashes with the type #{inspect(name)}")
  end

  defp validate_fields!(owner, fields, types, file) do
    Enum.reduce(fields, %{}, fn field, seen_fields ->
      fail = &__fail__(file, field.line, &1)
      check_name!(field.name, "field", fail)
      check_type!("#{owner}.#{field.name}", field, types, fail)

      unique!(
        seen_fields,
        field.name,
        fail,
        "#{owner} has field #{inspect(field.name)} twice",
        &"#{owner} has fields #{inspect(&1)} and #{inspect(field.name)}, which clients both name #{&2}"
      )
    end)
  end

  # Clients name things in camelCase (`a_b` is `aB` in Swift), so two names that only
  # differ in underscores would be one name there. `seen` maps client names to names.
  defp unique!(seen, name, fail, twice, clash) do
    [first | rest] = name |> Atom.to_string() |> String.split("_")
    client = first <> Enum.map_join(rest, &String.capitalize/1)

    case Map.fetch(seen, client) do
      {:ok, ^name} -> fail.(twice)
      {:ok, other} -> fail.(clash.(other, client))
      :error -> Map.put(seen, client, name)
    end
  end

  # `types.models` is nil where no model may be held (blocks), else the models a field
  # may hold; `all_models` names every model, to tell one not declared before it apart.
  defp check_type!(at, %{type: type} = field, types, fail) do
    element = list_element(type)

    cond do
      type in @primitives ->
        :ok

      match?({:list, element} when element in @primitives, type) ->
        :ok

      match?({:enum, _values}, type) ->
        check_enum!(at, field, fail)

      type == :blocks and types.blocks_field ->
        :ok

      element in types.blocks ->
        fail.("#{at} holds block #{inspect(element)}; blocks have no children")

      types.models != nil and element in types.models ->
        :ok

      element in types.all_models ->
        fail.("#{at} holds model #{inspect(element)}, which isn't declared before it")

      match?({:list, _}, type) ->
        what = if types.models, do: "one primitive type or a model", else: "one primitive type"
        fail.("#{at}: a list holds #{what}, got #{inspect(element)}")

      true ->
        fail.("#{at} has unknown type #{inspect(type)}")
    end

    if Map.has_key?(field, :fallback) and not match?({:enum, _}, type),
      do: fail.("#{at}: fallback is only for an enum")
  end

  defp list_element({:list, element}), do: element
  defp list_element(type), do: type

  # Values become wire strings and Swift cases; the fallback is what a client shows
  # for a value it doesn't know (ADR 0001).
  defp check_enum!(at, %{type: {:enum, values}} = field, fail) do
    unless is_list(values) and values != [],
      do: fail.("#{at}: an enum needs a list of values, got #{inspect(values)}")

    Enum.reduce(values, %{}, fn value, seen ->
      check_name!(value, "enum value", fail)

      unique!(
        seen,
        value,
        fail,
        "#{at} has enum value #{inspect(value)} twice",
        &"#{at} has enum values #{inspect(&1)} and #{inspect(value)}, which clients both name #{&2}"
      )
    end)

    case Map.fetch(field, :fallback) do
      :error ->
        fail.("#{at}: an enum needs fallback: one of its values")

      {:ok, fallback} ->
        unless fallback in values,
          do: fail.("#{at}: fallback #{inspect(fallback)} is not one of #{inspect(values)}")
    end
  end

  defp check_version!(_key, nil, _fail), do: :ok

  defp check_version!(key, version, fail) do
    unless is_binary(version) and Regex.match?(~r/\A\d+\.\d+\.\d+\z/, version) do
      fail.(~s(: #{key} must be a literal version like "0.2.0", got #{Macro.to_string(version)}))
    end
  end

  defp check_version_order!(nil, _deprecated, _fail), do: :ok
  defp check_version_order!(_since, nil, _fail), do: :ok

  defp check_version_order!(since, deprecated, fail) do
    if version_tuple(deprecated) < version_tuple(since),
      do: fail.(": deprecated #{deprecated} is before since #{since}")
  end

  defp version_tuple(version) do
    version
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  # Names become wire keys and identifiers in generated code. nil, true and false
  # aren't names: nil is a missing prop on the wire, and Swift has no such identifier.
  defp check_name!(name, kind, fail) do
    unless is_atom(name) and name not in [nil, true, false] and
             Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name)),
           do:
             fail.(
               "#{kind} name #{inspect(name)} must be a snake_case atom other than nil, true and false"
             )
  end
end
