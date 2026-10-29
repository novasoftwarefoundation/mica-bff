defmodule Mix.Tasks.Bff.Gen.Swift do
  @shortdoc "Generates the Swift block types from the spec"
  @moduledoc """
      mix bff.gen.swift --out PATH [--namespace BFF]

  Writes `PATH/<namespace>.swift`, e.g. `Next/BFF/BFF.swift` in next-ios, with
  every block as a `Decodable` type. A hand-written file is never overwritten.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [out: :string, namespace: :string])
    out = opts[:out] || Mix.raise("--out is required")
    namespace = opts[:namespace] || "BFF"

    File.mkdir_p!(out)
    source = MicaBff.Gen.Swift.generate(MicaBff.Blocks.__schema__(), namespace)
    MicaBff.Gen.write!(Path.join(out, "#{namespace}.swift"), source)
  end
end
