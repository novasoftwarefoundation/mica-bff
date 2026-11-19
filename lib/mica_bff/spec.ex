defmodule MicaBff.Spec do
  @moduledoc """
  The spec: the types blocks hold (`MicaBff.Types`), the blocks (`MicaBff.Blocks`),
  the markup beside them (`MicaBff.Markup`) and the pages the BFF serves
  (`MicaBff.Pages`). Generators read its `__schema__/0`.
  """

  # Each part holds only its own kind, so its duplicate checks cover the whole spec:
  # a defpage in blocks.ex or a defblock in pages.ex fails to compile here.
  %{blocks: [], markup: [], pages: [], types: types} = MicaBff.Types.__schema__()
  %{blocks: blocks, markup: [], pages: [], types: []} = MicaBff.Blocks.__schema__()
  %{blocks: [], markup: markup, pages: [], types: []} = MicaBff.Markup.__schema__()
  %{blocks: [], markup: [], pages: pages, types: []} = MicaBff.Pages.__schema__()

  # Blocks, markup and types are types in one namespace in the generated code.
  for {name, count} <- Enum.frequencies(Enum.map(blocks ++ markup ++ types, & &1.name)),
      count > 1,
      do: raise(CompileError, description: "#{inspect(name)} is declared twice in the spec")

  @schema %{blocks: blocks, markup: markup, pages: pages, types: types}

  @doc "The spec as plain data (blocks, markup, pages and types), for generators and validation."
  def __schema__, do: @schema
end
