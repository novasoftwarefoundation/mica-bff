defmodule MicaBff.Schema do
  @moduledoc """
  The schema of the BFF spec, written as a DSL. It plays the role an XSD plays
  for XML: the macros define what a valid spec is, and the modules that `use`
  them (`MicaBff.Types`, `MicaBff.Blocks`, `MicaBff.Markup`, `MicaBff.Pages`) are
  the spec, composed by `MicaBff.Spec`.

      defmodule MyBlocks do
        use MicaBff.Schema, types: MyTypes

        defblock :section do
          field :title, :string, required: true
          field :to, :string, required: true
        end
      end

  `types:` names a module whose types this one's fields may hold, as if they were
  declared here before everything else.

  - `defblock` declares a block the BFF can send and clients can render. Every block
    also has an `id`, next to its type and props, so no field may be named `id`.
  - `field` declares a prop: a snake_case name, a type and `required: true | false`
    (default `false`). A type is a primitive (`:string`, `:integer`, `:float`,
    `:boolean`), an enum (`{:enum, [:accent, :neutral]}`, snake_case values, with
    `fallback:` one of them: what a client makes of a value it doesn't know), a
    declared type (`:filter_option`) or a list of one primitive or declared type
    (`{:list, :string}`). Never a block: blocks have no children, a page is a flat
    list of blocks.
    Two more options, both a literal `"major.minor.patch"` spec version (the git tag
    without its `v`) and left out of `__schema__/0` when unset: `since:` (the version
    that added the field) and `deprecated:` (the version that deprecated it, not
    before `since:`). `fallback:` is in `__schema__/0` only on an enum.
  - `deftype` declares a nested object with fields like a block's. A type's field
    may hold a type declared before it (`field :photo, :image`) or a list of one
    (`{:list, :image}`), so types never form a cycle.
  - `defmarkup` declares a kind of markup: an entry over a stretch of a page's
    blocks, from the block `start` to the block `end`, with fields like a block's
    (`defmarkup :border do end`). `start` and `end` sit next to its kind and props,
    so no field may be named either.
  - `defpage` declares a page the BFF serves: always a GET at `/bff/page/<name>`
    that returns a flat list of blocks (`defpage :home` is `GET /bff/page/home`).
    In its `do` block, `param` declares a query parameter with a snake_case name
    and a primitive type: `param :year, :integer` reads `?year=2025`.

  Every mistake fails at compile time and points at its line: an unknown type or
  option, a name that isn't a snake_case atom, a duplicate name, a block used as
  a field type or named after a primitive, an enum without values or without a
  fallback among them, a list of anything but a primitive or a declared type, a
  type used before it is declared, a `field` outside a `defblock`, `deftype` or
  `defmarkup`, a field named after a key every block (`id`) or markup entry
  (`start`, `end`) has, a
  `param` outside a `defpage` or of a type that isn't a primitive, a declaration
  inside another, and a malformed or out-of-order version. Generators read
  `__schema__/0`, never the source.
  """

  @primitives [:string, :integer, :float, :boolean]

  defmacro __using__(opts) do
    types = Keyword.get(opts, :types)

    quote do
      import MicaBff.Schema,
        only: [
          defblock: 2,
          deftype: 2,
          defmarkup: 2,
          defpage: 1,
          defpage: 2,
          field: 2,
          field: 3,
          param: 2
        ]

      Module.register_attribute(__MODULE__, :mica_bff_blocks, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_types, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_markup, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_pages, accumulate: true)

      # The other module's types, read while this one compiles.
      @mica_bff_external_types unquote(
                                 if types,
                                   do:
                                     quote(
                                       do: Enum.map(unquote(types).__schema__().types, & &1.name)
                                     ),
                                   else: []
                               )
      @before_compile MicaBff.Schema
    end
  end

  defmacro defblock(name, do: body),
    do: record(:defblock, :mica_bff_blocks, name, body, __CALLER__)

  defmacro defmarkup(name, do: body),
    do: record(:defmarkup, :mica_bff_markup, name, body, __CALLER__)

  defmacro deftype(name, do: body),
    do: record(:deftype, :mica_bff_types, name, body, __CALLER__)

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
      unless match?(
               {kind, _} when kind in [:defblock, :deftype, :defmarkup],
               Module.get_attribute(__MODULE__, :mica_bff_open)
             ) do
        MicaBff.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "field #{inspect(unquote(name))} outside a defblock, deftype or defmarkup"
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

  defmacro defpage(name), do: page(name, nil, __CALLER__)
  defmacro defpage(name, do: body), do: page(name, body, __CALLER__)

  defp page(name, body, caller) do
    line = caller.line

    quote do
      MicaBff.Schema.__top_level__!(
        __MODULE__,
        __ENV__.file,
        unquote(line),
        "defpage #{inspect(unquote(name))}"
      )

      Module.put_attribute(__MODULE__, :mica_bff_open, {:defpage, unquote(name)})
      Module.register_attribute(__MODULE__, :mica_bff_params, accumulate: true)
      unquote(body)

      @mica_bff_pages %{
        name: unquote(name),
        line: unquote(line),
        params: Enum.reverse(Module.get_attribute(__MODULE__, :mica_bff_params))
      }

      Module.delete_attribute(__MODULE__, :mica_bff_params)
      Module.delete_attribute(__MODULE__, :mica_bff_open)
    end
  end

  defmacro param(name, type) do
    line = __CALLER__.line

    quote do
      unless match?({:defpage, _}, Module.get_attribute(__MODULE__, :mica_bff_open)) do
        MicaBff.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "param #{inspect(unquote(name))} outside a defpage"
        )
      end

      @mica_bff_params %{name: unquote(name), type: unquote(type), line: unquote(line)}
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  @doc false
  def __top_level__!(module, file, line, what) do
    case Module.get_attribute(module, :mica_bff_open) do
      {kind, name} -> __fail__(file, line, "#{what} inside #{kind} #{inspect(name)}")
      nil -> :ok
    end
  end

  defmacro __before_compile__(env) do
    get = &(env.module |> Module.get_attribute(&1) |> Enum.reverse())
    blocks = get.(:mica_bff_blocks)
    types = get.(:mica_bff_types)
    markup = get.(:mica_bff_markup)
    pages = get.(:mica_bff_pages)
    external = Module.get_attribute(env.module, :mica_bff_external_types)

    # One `seen` across blocks, markup and types: in Swift and Elixir all are types in one
    # namespace.
    seen = validate_records!(blocks, "block", [:id], blocks, types, external, %{}, env.file)

    seen =
      validate_records!(markup, "markup", [:start, :end], blocks, types, external, seen, env.file)

    validate_types!(types, external, seen, env.file)
    validate_pages!(pages, env.file)

    # Line numbers are only for error messages; generators get the plain spec.
    schema = %{
      blocks: Enum.map(blocks, &plain_record/1),
      markup: Enum.map(markup, &plain_record/1),
      pages:
        for %{name: name, params: params} <- pages do
          %{name: name, path: "/bff/page/#{name}", params: plain_fields(params)}
        end,
      types: Enum.map(types, &plain_record/1)
    }

    quote do
      @doc "The spec as plain data (blocks, markup, pages and types), for generators and validation."
      def __schema__, do: unquote(Macro.escape(schema))
    end
  end

  defp plain_record(%{name: name, fields: fields}),
    do: %{name: name, fields: plain_fields(fields)}

  defp plain_fields(fields), do: Enum.map(fields, &Map.delete(&1, :line))

  defp validate_pages!(pages, file) do
    Enum.reduce(pages, MapSet.new(), fn %{name: name, line: line, params: params}, seen ->
      fail = &__fail__(file, line, &1)
      check_name!(name, "page", fail)
      if name in seen, do: fail.("page #{inspect(name)} is defined twice")
      validate_params!(name, params, file)
      MapSet.put(seen, name)
    end)
  end

  # A param is a query parameter: its name is its key in the query, as written.
  defp validate_params!(page, params, file) do
    Enum.reduce(params, MapSet.new(), fn %{name: name, type: type, line: line}, seen ->
      fail = &__fail__(file, line, &1)
      check_name!(name, "param", fail)
      if name in seen, do: fail.("page #{inspect(page)} has param #{inspect(name)} twice")

      unless type in @primitives,
        do: fail.("param #{inspect(name)}: a param is a primitive type, got #{inspect(type)}")

      MapSet.put(seen, name)
    end)
  end

  # Blocks have no children: a page is a flat list of blocks, so no field may hold a block.
  # `reserved` are the keys every block or markup entry has next to its props.
  defp validate_records!(records, kind, reserved, blocks, types, external, seen, file) do
    block_names = Enum.map(blocks, & &1.name)
    # A block may hold any type: no type holds a block, so there is no cycle.
    types = external ++ Enum.map(types, & &1.name)
    allowed = %{blocks: block_names, types: types, all_types: types}

    Enum.reduce(records, seen, fn %{name: name, fields: fields} = record, seen ->
      fail = &__fail__(file, record.line, &1)
      check_record_name!(name, kind, fail)
      validate_fields!(inspect(name), fields, allowed, file)

      for %{name: field, line: line} <- fields, field in reserved do
        __fail__(
          file,
          line,
          "#{kind} #{inspect(name)} can't have field #{inspect(field)}: every #{kind} has it next to its props"
        )
      end

      unique!(
        seen,
        name,
        fail,
        "#{inspect(name)} is defined twice",
        &"the spec has #{inspect(&1)} and #{inspect(name)}, which clients both name #{&2}"
      )
    end)
  end

  # A type holds only types declared before it, so types never form a cycle.
  defp validate_types!(types, external, seen, file) do
    all = external ++ Enum.map(types, & &1.name)

    Enum.reduce(types, {seen, []}, fn %{name: name, fields: fields, line: line}, {seen, before} ->
      fail = &__fail__(file, line, &1)
      check_record_name!(name, "type", fail)
      allowed = %{blocks: [], types: external ++ before, all_types: all}
      validate_fields!(inspect(name), fields, allowed, file)

      seen =
        unique!(
          seen,
          name,
          fail,
          "#{inspect(name)} is defined twice",
          &"the spec has #{inspect(&1)} and #{inspect(name)}, which clients both name #{&2}"
        )

      {seen, [name | before]}
    end)
  end

  defp check_record_name!(name, kind, fail) do
    check_name!(name, kind, fail)

    if name in @primitives,
      do: fail.("#{kind} #{inspect(name)} clashes with the primitive type #{inspect(name)}")
  end

  defp validate_fields!(owner, fields, allowed, file) do
    Enum.reduce(fields, %{}, fn field, seen_fields ->
      fail = &__fail__(file, field.line, &1)
      check_name!(field.name, "field", fail)
      check_type!("#{owner}.#{field.name}", field, allowed, fail)

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

  # `allowed.types` are the declared types a field may hold; `all_types` names every
  # one, to tell one not declared before it apart.
  defp check_type!(at, %{type: type} = field, allowed, fail) do
    element = list_element(type)

    cond do
      type in @primitives ->
        :ok

      match?({:list, element} when element in @primitives, type) ->
        :ok

      match?({:enum, _values}, type) ->
        check_enum!(at, field, fail)

      element in allowed.blocks ->
        fail.("#{at} holds block #{inspect(element)}; blocks have no children")

      element in allowed.types ->
        :ok

      element in allowed.all_types ->
        fail.("#{at} holds type #{inspect(element)}, which isn't declared before it")

      match?({:list, _}, type) ->
        fail.("#{at}: a list holds one primitive or declared type, got #{inspect(element)}")

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
