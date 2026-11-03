defmodule MicaBff.Gen.Elixir do
  @moduledoc """
  Defines one Elixir module per block at compile time, under the module that uses
  it, the way `Prism.Generator.Phoenix` defines components:

      defmodule Systems.BFF.Blocks do
        use MicaBff.Gen.Elixir, spec: MicaBff.Blocks
      end

  This defines `Systems.BFF.Blocks.Section` and so on: a struct with the required
  fields enforced, a typespec, and `to_map/1`, which returns the wire shape
  `%{"type" => ..., "props" => ...}` for any JSON library (mica uses Jason).
  Optional props that are `nil` are left out, as ADR 0001 requires; `""`, `0`,
  `false`, `[]` and `%{}` are values and are sent. The defined modules call nothing
  in mica-bff, so an app can depend on it with `runtime: false`.
  """

  @types %{
    string: quote(do: String.t()),
    integer: quote(do: integer()),
    float: quote(do: float()),
    boolean: quote(do: boolean())
  }

  defmacro __using__(opts) do
    spec = spec!(opts[:spec], __CALLER__)
    modules = Enum.map(spec.__schema__().blocks, &block_module(&1, __CALLER__.module))

    # A compile-time dependency: this module recompiles when the spec changes.
    quote do
      require unquote(spec)
      unquote_splicing(modules)
    end
  end

  defp spec!(nil, env) do
    MicaBff.Schema.__fail__(
      env.file,
      env.line,
      "use MicaBff.Gen.Elixir needs spec: MicaBff.Blocks"
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
    message = "spec: #{Macro.to_string(ast)} is not a spec (a module that uses MicaBff.Schema)"
    MicaBff.Schema.__fail__(env.file, env.line, message)
  end

  defp block_module(%{name: name, fields: fields}, namespace) do
    module = Module.concat(namespace, Macro.camelize(to_string(name)))

    quote do
      defmodule unquote(module), do: unquote(block_body(name, fields))
    end
  end

  defp block_body(name, fields) do
    keys = Enum.map(fields, & &1.name)
    required = for %{name: key, required: true} <- fields, do: key
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

      defp props(block) do
        for {key, value} <- Map.from_struct(block),
            value != nil or key in unquote(required),
            into: %{},
            do: {Atom.to_string(key), value}
      end
    end
  end

  defp type(%{type: type, required: true}), do: @types[type]
  defp type(%{type: type}), do: quote(do: unquote(@types[type]) | nil)
end
