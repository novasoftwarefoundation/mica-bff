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
  `pages/0`, the spec's pages: `[%{name: :home, path: "/bff/page/home"}]`. The
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
    modules = Enum.map(schema.blocks, &block_module(&1, __CALLER__.module))
    pages = Map.get(schema, :pages, [])

    # A compile-time dependency: this module recompiles when the spec changes.
    quote do
      require unquote(spec)

      @doc "The pages the BFF serves, in spec order: each is a GET at its path that returns a flat list of blocks."
      @spec pages() :: [%{name: atom, path: String.t()}]
      def pages, do: unquote(Macro.escape(pages))

      unquote_splicing(modules)
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

  defp block_module(%{name: name, fields: fields}, namespace) do
    module = Module.concat(namespace, Macro.camelize(to_string(name)))

    quote do
      defmodule unquote(module), do: unquote(block_body(name, fields))
    end
  end

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

  defp type(%{type: type, required: true}), do: base_type(type)
  defp type(%{type: type}), do: quote(do: unquote(base_type(type)) | nil)

  defp base_type({:enum, values}),
    do: values |> Enum.reverse() |> Enum.reduce(&quote(do: unquote(&1) | unquote(&2)))

  defp base_type({:list, type}), do: quote(do: [unquote(@types[type])])
  defp base_type(type), do: @types[type]
end
