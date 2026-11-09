defmodule MicaBff.Spec do
  @moduledoc """
  The spec: the blocks (`MicaBff.Blocks`) and the pages the BFF serves
  (`MicaBff.Pages`). Generators read its `__schema__/0`.
  """

  # Each half holds only its own kind, so its duplicate checks cover the whole spec:
  # a defpage in blocks.ex or a defblock in pages.ex fails to compile here.
  %{blocks: blocks, pages: []} = MicaBff.Blocks.__schema__()
  %{blocks: [], pages: pages} = MicaBff.Pages.__schema__()
  @schema %{blocks: blocks, pages: pages}

  @doc "The spec as plain data (blocks and pages), for generators and validation."
  def __schema__, do: @schema
end
