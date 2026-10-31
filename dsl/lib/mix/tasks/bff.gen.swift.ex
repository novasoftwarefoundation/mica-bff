defmodule Mix.Tasks.Bff.Gen.Swift do
  @shortdoc "Generates the Swift block types from a catalogue"
  @moduledoc """
      mix bff.gen.swift --out PATH [--spec MODULE] [--namespace NAMESPACE]

  Writes `PATH/NAMESPACE.swift` with every block of the catalogue MODULE (a
  module that uses `MicaBffDsl.Schema`) as a `Decodable` type under the Swift
  namespace NAMESPACE. Without `--spec` or `--namespace`, they come from the
  project's config:

      config :mica_bff_dsl, spec: MyApp.Blocks, swift_namespace: "Blocks"

  A hand-written file is never overwritten.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    %{out: out, schema: schema, namespace: namespace} =
      MicaBffDsl.Gen.parse_args!(args, :swift_namespace)

    File.mkdir_p!(out)
    source = MicaBffDsl.Gen.Swift.generate(schema, namespace)
    MicaBffDsl.Gen.write!(Path.join(out, "#{namespace}.swift"), source)
  end
end
