defmodule MicaBff.Spec do
  @moduledoc """
  DSL for the BFF data model. It plays the role an XSD plays for XML: the macros
  define what a valid spec is, a module that `use`s them is the spec itself.

      defmodule MyBlocks do
        use MicaBff.Spec

        defmodel :link do
          field :to, :string, required: true
        end

        defblock :section do
          field :title, :string, required: true
          field :link, :link, required: true
        end
      end

  - `defblock` declares a block the BFF can send and clients can render.
  - `defmodel` declares a nested data type that fields can use.
  - `field` types are a primitive (#{inspect([:string, :integer, :float, :boolean])})
    or the name of a `defmodel` in the same module, never a block: blocks have
    no children, a page is a flat list of blocks.

  Mistakes (unknown type or option, a block used as a field, duplicate name) fail at compile time.
  Generators read `__spec__/0`, never the source.
  """

  @primitives [:string, :integer, :float, :boolean]

  defmacro __using__(_opts) do
    quote do
      import MicaBff.Spec, only: [defblock: 2, defmodel: 2, field: 2, field: 3]
      Module.register_attribute(__MODULE__, :mica_bff_blocks, accumulate: true)
      Module.register_attribute(__MODULE__, :mica_bff_models, accumulate: true)
      @before_compile MicaBff.Spec
    end
  end

  defmacro defblock(name, do: body), do: definition(:mica_bff_blocks, name, body)
  defmacro defmodel(name, do: body), do: definition(:mica_bff_models, name, body)

  defmacro field(name, type, opts \\ []) do
    opts = Keyword.validate!(opts, required: false)

    quote do
      @mica_bff_fields %{
        name: unquote(name),
        type: unquote(type),
        required: unquote(opts[:required])
      }
    end
  end

  defp definition(kind, name, body) do
    quote do
      Module.register_attribute(__MODULE__, :mica_bff_fields, accumulate: true)
      unquote(body)

      Module.put_attribute(__MODULE__, unquote(kind), %{
        name: unquote(name),
        fields: Enum.reverse(Module.get_attribute(__MODULE__, :mica_bff_fields))
      })

      Module.delete_attribute(__MODULE__, :mica_bff_fields)
    end
  end

  defmacro __before_compile__(env) do
    blocks = env.module |> Module.get_attribute(:mica_bff_blocks) |> Enum.reverse()
    models = env.module |> Module.get_attribute(:mica_bff_models) |> Enum.reverse()
    validate!(blocks, models, env)

    quote do
      @doc "The spec as plain data, for generators and validation."
      def __spec__, do: unquote(Macro.escape(%{blocks: blocks, models: models}))
    end
  end

  # Blocks and models share one namespace: both become named types in generated code.
  # Blocks have no children: a page is a flat list of blocks, so no field may hold a block.
  defp validate!(blocks, models, env) do
    fail = fn message -> raise CompileError, file: env.file, description: message end
    definitions = blocks ++ models
    block_names = Enum.map(blocks, & &1.name)
    known_types = @primitives ++ Enum.map(models, & &1.name)

    if dup = duplicate(Enum.map(definitions, & &1.name)),
      do: fail.("#{inspect(dup)} is defined twice")

    for %{name: name, fields: fields} <- definitions do
      if dup = duplicate(Enum.map(fields, & &1.name)),
        do: fail.("#{inspect(name)} has field #{inspect(dup)} twice")

      for %{type: type} = field <- fields, type not in known_types do
        if type in block_names,
          do:
            fail.(
              "#{inspect(name)}.#{field.name} holds block #{inspect(type)}; blocks have no children"
            ),
          else: fail.("#{inspect(name)}.#{field.name} has unknown type #{inspect(type)}")
      end
    end
  end

  defp duplicate(names), do: List.first(names -- Enum.uniq(names))
end
