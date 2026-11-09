defmodule Mix.Tasks.Bff.Gen.Swift do
  @default_namespace MicaBff.Gen.Swift.default_namespace()

  @shortdoc "Generates the Swift block types from the spec"
  @moduledoc """
      mix bff.gen.swift --out PATH [--namespace #{@default_namespace}]

  Writes `PATH/<namespace>.swift`, e.g. `Next/BFF/#{@default_namespace}.swift` in next-ios,
  with every block as a `Decodable` type. A hand-written file is never overwritten.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [out: :string, namespace: :string])
    out = opts[:out] || Mix.raise("--out is required")
    namespace = opts[:namespace] || @default_namespace

    File.mkdir_p!(out)
    source = MicaBff.Gen.Swift.generate(MicaBff.Spec.__schema__(), namespace)
    MicaBff.Gen.write!(Path.join(out, "#{namespace}.swift"), source)
  end
end
