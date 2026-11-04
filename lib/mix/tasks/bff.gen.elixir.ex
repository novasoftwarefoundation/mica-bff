defmodule Mix.Tasks.Bff.Gen.Elixir do
  @default_namespace MicaBff.Gen.Elixir.default_namespace()

  @shortdoc "Generates the Elixir block modules from the spec"
  @moduledoc """
      mix bff.gen.elixir --out PATH [--namespace #{@default_namespace}]

  Writes one file per block to PATH, e.g. `core/mica/systems/bff/blocks` in mono,
  and `_spec.ex` with the namespace module, whose `pages/0` lists the spec's pages.
  Files from an earlier run are removed first, so a block removed from the spec
  disappears from the output too. A hand-written file is never overwritten.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [out: :string, namespace: :string])
    out = opts[:out] || Mix.raise("--out is required")
    namespace = opts[:namespace] || @default_namespace

    File.mkdir_p!(out)

    for file <- Path.wildcard(Path.join(out, "*.ex")),
        MicaBff.Gen.generated?(file),
        do: File.rm!(file)

    for {name, source} <- MicaBff.Gen.Elixir.generate(MicaBff.Blocks.__schema__(), namespace),
        do: MicaBff.Gen.write!(Path.join(out, name), source)
  end
end
