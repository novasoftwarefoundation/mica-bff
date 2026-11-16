defmodule MicaBff.Spec do
  @moduledoc """
  The spec: the blocks (`MicaBff.Blocks`), the pages the BFF serves
  (`MicaBff.Pages`), and its other calls with the models they use
  (`MicaBff.Endpoints`). Generators read its `__schema__/0`.
  """

  # Each part holds only its own kind, so its duplicate checks cover the whole spec:
  # a defpage in blocks.ex or a defblock in pages.ex fails to compile here.
  %{blocks: blocks, pages: [], models: [], endpoints: []} = MicaBff.Blocks.__schema__()
  %{blocks: [], pages: pages, models: [], endpoints: []} = MicaBff.Pages.__schema__()
  %{blocks: [], pages: [], models: models, endpoints: endpoints} = MicaBff.Endpoints.__schema__()

  # Blocks, models and endpoints are types in one namespace in the generated code.
  for {name, count} <- Enum.frequencies(Enum.map(blocks ++ models ++ endpoints, & &1.name)),
      count > 1,
      do:
        raise(CompileError,
          description: "#{inspect(name)} is both a block and a model or endpoint"
        )

  @schema %{blocks: blocks, pages: pages, models: models, endpoints: endpoints}

  @doc "The spec as plain data (blocks, pages, models and endpoints), for generators and validation."
  def __schema__, do: @schema
end
