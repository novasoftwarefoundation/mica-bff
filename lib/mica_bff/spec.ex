defmodule MicaBff.Spec do
  @moduledoc """
  The spec: the types blocks hold (`MicaBff.Types`), the blocks (`MicaBff.Blocks`),
  the markup beside them (`MicaBff.Markup`) and the pages the BFF serves
  (`MicaBff.Pages`). Generators read its `__schema__/0`.
  """

  # Each part holds only its own kind, so its duplicate checks cover the whole spec:
  # a defpage in blocks.ex or a defblock in pages.ex fails to compile here.
  types = MicaBff.Schema.only!(MicaBff.Types, :types)
  blocks = MicaBff.Schema.only!(MicaBff.Blocks, :blocks)
  markup = MicaBff.Schema.only!(MicaBff.Markup, :markup)
  pages = MicaBff.Schema.only!(MicaBff.Pages, :pages)

  # Blocks, markup and types are types in one namespace in the generated code.
  for {name, count} <- Enum.frequencies(Enum.map(blocks ++ markup ++ types, & &1.name)),
      count > 1,
      do: raise(CompileError, description: "#{inspect(name)} is declared twice in the spec")

  @schema %{blocks: blocks, markup: markup, pages: pages, types: types}

  @doc "The spec as plain data (blocks, markup, pages and types), for generators and validation."
  def __schema__, do: @schema
end
