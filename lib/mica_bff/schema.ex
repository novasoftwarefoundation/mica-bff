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

  Every mistake fails at compile time and points at its line: an unknown type or
  option, a name that isn't a snake_case atom, a duplicate name, a block used as
  a field type or named after a primitive, an enum without values or without a
  fallback among them, a list of anything but a primitive, a `field` outside a
  `defblock`, a `defblock` or `defpage` inside a `defblock`, and a malformed or
  out-of-order version. Generators read `__schema__/0`, never the source.
  """

  @primitives [:string, :integer, :float, :boolean]

  defmacro __using__(_opts) do
    quote do
      import MicaBff.Schema, only: [defblock: 2, defpage: 1, field: 2, field: 3]
      Module.register_attribute(__MODULE__, :mica_bff_blocks, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_pages, accumulate: true)
      @before_compile MicaBff.Schema
    end
  end

  defmacro defblock(name, do: body) do
    line = __CALLER__.line

    quote do
      if open = Module.get_attribute(__MODULE__, :mica_bff_open_block) do
        MicaBff.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "defblock #{inspect(unquote(name))} inside defblock #{inspect(open)}; blocks have no children"
        )
      end

      Module.put_attribute(__MODULE__, :mica_bff_open_block, unquote(name))
      Module.register_attribute(__MODULE__, :mica_bff_fields, accumulate: true)
      unquote(body)

      @mica_bff_blocks %{
        name: unquote(name),
        line: unquote(line),
        fields: Enum.reverse(Module.get_attribute(__MODULE__, :mica_bff_fields))
      }

      Module.delete_attribute(__MODULE__, :mica_bff_fields)
      Module.delete_attribute(__MODULE__, :mica_bff_open_block)
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
      unless Module.get_attribute(__MODULE__, :mica_bff_open_block) do
        MicaBff.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "field #{inspect(unquote(name))} outside a defblock"
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
      if open = Module.get_attribute(__MODULE__, :mica_bff_open_block) do
        MicaBff.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "defpage #{inspect(unquote(name))} inside defblock #{inspect(open)}"
        )
      end

      @mica_bff_pages %{name: unquote(name), line: unquote(line)}
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  defmacro __before_compile__(env) do
    blocks = env.module |> Module.get_attribute(:mica_bff_blocks) |> Enum.reverse()
    pages = env.module |> Module.get_attribute(:mica_bff_pages) |> Enum.reverse()
    validate!(blocks, env.file)
    validate_pages!(pages, env.file)

    # Line numbers are only for error messages; generators get the plain spec.
    schema = %{
      blocks:
        for block <- blocks do
          %{name: block.name, fields: Enum.map(block.fields, &Map.delete(&1, :line))}
        end,
      pages: for(page <- pages, do: %{name: page.name, path: "/bff/page/#{page.name}"})
    }

    quote do
      @doc "The spec as plain data (blocks and pages), for generators and validation."
      def __schema__, do: unquote(Macro.escape(schema))
    end
  end

  defp validate_pages!(pages, file) do
    Enum.reduce(pages, MapSet.new(), fn %{name: name, line: line}, seen ->
      fail = &__fail__(file, line, &1)
      check_name!(name, "page", fail)
      if name in seen, do: fail.("page #{inspect(name)} is defined twice")
      MapSet.put(seen, name)
    end)
  end

  # Blocks have no children: a page is a flat list of blocks, so no field may hold a block.
  defp validate!(blocks, file) do
    block_names = Enum.map(blocks, & &1.name)

    Enum.reduce(blocks, %{}, fn %{name: name, fields: fields} = block, seen ->
      fail = &__fail__(file, block.line, &1)
      check_name!(name, "block", fail)

      if name in @primitives,
        do: fail.("block #{inspect(name)} clashes with the primitive type #{inspect(name)}")

      Enum.reduce(fields, %{}, fn field, seen_fields ->
        fail = &__fail__(file, field.line, &1)
        check_name!(field.name, "field", fail)
        check_type!(name, field, block_names, fail)

        unique!(
          seen_fields,
          field.name,
          fail,
          "#{inspect(name)} has field #{inspect(field.name)} twice",
          &"#{inspect(name)} has fields #{inspect(&1)} and #{inspect(field.name)}, which clients both name #{&2}"
        )
      end)

      unique!(
        seen,
        name,
        fail,
        "#{inspect(name)} is defined twice",
        &"the spec has blocks #{inspect(&1)} and #{inspect(name)}, which clients both name #{&2}"
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

  defp check_type!(block, %{name: name, type: type} = field, block_names, fail) do
    at = "#{inspect(block)}.#{name}"

    cond do
      type in @primitives ->
        :ok

      match?({:list, element} when element in @primitives, type) ->
        :ok

      match?({:enum, _values}, type) ->
        check_enum!(at, field, fail)

      block_type(type) in block_names ->
        fail.("#{at} holds block #{inspect(block_type(type))}; blocks have no children")

      match?({:list, _}, type) ->
        fail.("#{at}: a list holds one primitive type, got #{inspect(elem(type, 1))}")

      true ->
        fail.("#{at} has unknown type #{inspect(type)}")
    end

    if Map.has_key?(field, :fallback) and not match?({:enum, _}, type),
      do: fail.("#{at}: fallback is only for an enum")
  end

  defp block_type({:list, block}), do: block
  defp block_type(block), do: block

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
