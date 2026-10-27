defmodule MicaBff.Schema do
  @moduledoc """
  The schema of the BFF spec, written as a DSL. It plays the role an XSD plays
  for XML: the macros define what a valid block catalogue is, and a module that
  `use`s them (`MicaBff.Blocks`) is the catalogue.

      defmodule MyBlocks do
        use MicaBff.Schema

        defblock :section do
          field :title, :string, required: true
          field :to, :string, required: true
        end
      end

  - `defblock` declares a block the BFF can send and clients can render.
  - `field` declares a prop: a snake_case name, a primitive type (`:string`,
    `:integer`, `:float`, `:boolean`) and `required: true | false` (default
    `false`). Never a block: blocks have no children, a page is a flat list of blocks.

  Every mistake fails at compile time and points at its line: an unknown type or
  option, a name that isn't a snake_case atom, a duplicate name, a block used as
  a field type or named after a primitive, a `field` outside a `defblock`, and a
  `defblock` inside another one. Generators read `__schema__/0`, never the source.
  """

  @primitives [:string, :integer, :float, :boolean]

  defmacro __using__(_opts) do
    quote do
      import MicaBff.Schema, only: [defblock: 2, field: 2, field: 3]
      Module.register_attribute(__MODULE__, :mica_bff_blocks, accumulate: true)
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

  defmacro field(name, type, opts \\ []) do
    line = __CALLER__.line
    fail = &__fail__(__CALLER__.file, line, "field #{Macro.to_string(name)}#{&1}")

    unless Keyword.keyword?(opts), do: fail.(": options must be a literal keyword list")

    opts =
      case Keyword.validate(opts, required: false) do
        {:ok, opts} ->
          opts

        {:error, unknown} ->
          fail.(" has unknown option(s) #{inspect(unknown)}; allowed: [:required]")
      end

    unless is_boolean(opts[:required]), do: fail.(": required must be true or false")

    quote do
      unless Module.get_attribute(__MODULE__, :mica_bff_open_block) do
        MicaBff.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "field #{inspect(unquote(name))} outside a defblock"
        )
      end

      @mica_bff_fields %{
        name: unquote(name),
        type: unquote(type),
        required: unquote(opts[:required]),
        line: unquote(line)
      }
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  defmacro __before_compile__(env) do
    blocks = env.module |> Module.get_attribute(:mica_bff_blocks) |> Enum.reverse()
    validate!(blocks, env.file)

    # Line numbers are only for error messages; generators get the plain catalogue.
    schema = %{
      blocks:
        for block <- blocks do
          %{name: block.name, fields: Enum.map(block.fields, &Map.delete(&1, :line))}
        end
    }

    quote do
      @doc "The block catalogue as plain data, for generators and validation."
      def __schema__, do: unquote(Macro.escape(schema))
    end
  end

  # Blocks have no children: a page is a flat list of blocks, so no field may hold a block.
  defp validate!(blocks, file) do
    block_names = Enum.map(blocks, & &1.name)

    Enum.reduce(blocks, MapSet.new(), fn %{name: name, fields: fields} = block, seen ->
      fail = &__fail__(file, block.line, &1)
      check_name!(name, "block", fail)

      if name in @primitives,
        do: fail.("block #{inspect(name)} clashes with the primitive type #{inspect(name)}")

      if name in seen, do: fail.("#{inspect(name)} is defined twice")

      Enum.reduce(fields, MapSet.new(), fn field, seen_fields ->
        fail = &__fail__(file, field.line, &1)
        check_name!(field.name, "field", fail)

        if field.name in seen_fields,
          do: fail.("#{inspect(name)} has field #{inspect(field.name)} twice")

        cond do
          field.type in @primitives ->
            :ok

          field.type in block_names ->
            fail.(
              "#{inspect(name)}.#{field.name} holds block #{inspect(field.type)}; blocks have no children"
            )

          true ->
            fail.("#{inspect(name)}.#{field.name} has unknown type #{inspect(field.type)}")
        end

        MapSet.put(seen_fields, field.name)
      end)

      MapSet.put(seen, name)
    end)
  end

  # Names become wire keys and identifiers in generated code.
  defp check_name!(name, kind, fail) do
    unless is_atom(name) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name)),
      do: fail.("#{kind} name #{inspect(name)} must be a snake_case atom")
  end
end
