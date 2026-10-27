defmodule Mix.Tasks.Bff.Gen.Elixir do
  @shortdoc "Generates the Elixir block modules from the spec"
  @moduledoc """
      mix bff.gen.elixir --out PATH [--namespace Systems.BFF.Blocks]

  Writes one file per block to PATH, e.g. `core/mica/systems/bff/blocks` in mono.
  Files from an earlier run (they start with the generated header) are removed
  first, so a block removed from the spec disappears from the output too.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [out: :string, namespace: :string])
    out = opts[:out] || Mix.raise("--out is required")
    namespace = opts[:namespace] || "Systems.BFF.Blocks"
    header = MicaBff.Gen.Elixir.header()

    File.mkdir_p!(out)

    for file <- Path.wildcard(Path.join(out, "*.ex")),
        String.starts_with?(File.read!(file), header),
        do: File.rm!(file)

    for {name, source} <- MicaBff.Gen.Elixir.render(MicaBff.Blocks.__schema__(), namespace) do
      path = Path.join(out, name)
      File.write!(path, source)
      Mix.shell().info("* #{path}")
    end
  end
end
