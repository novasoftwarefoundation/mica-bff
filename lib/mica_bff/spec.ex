defmodule MicaBff.Spec do
  @moduledoc """
  The spec: the types blocks hold (`MicaBff.Types`), the blocks (`MicaBff.Blocks`),
  the regions beside them (`MicaBff.Regions`) and the pages the BFF serves
  (`MicaBff.Pages`). Generators read its `__schema__/0`.
  """

  # Each part holds only its own kind, so its duplicate checks cover the whole spec:
  # a defpage in blocks.ex or a defblock in pages.ex fails to compile here.
  types = MicaBff.Schema.only!(MicaBff.Types, :types)
  blocks = MicaBff.Schema.only!(MicaBff.Blocks, :blocks)
  regions = MicaBff.Schema.only!(MicaBff.Regions, :regions)
  pages = MicaBff.Schema.only!(MicaBff.Pages, :pages)

  # Blocks, regions and types are types in one namespace in the generated code.
  for {name, count} <- Enum.frequencies(Enum.map(blocks ++ regions ++ types, & &1.name)),
      count > 1,
      do: raise(CompileError, description: "#{inspect(name)} is declared twice in the spec")

  @schema %{blocks: blocks, regions: regions, pages: pages, types: types}

  @doc "The spec as plain data (blocks, regions, pages and types), for generators and validation."
  def __schema__, do: @schema
end
