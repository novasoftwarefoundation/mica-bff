defmodule Mix.Tasks.Bff.Gen.Elixir do
  @shortdoc "Generates the Elixir block modules from a catalogue"
  @moduledoc """
      mix bff.gen.elixir --out PATH [--spec MODULE] [--namespace NAMESPACE]

  Writes one file per block of the catalogue MODULE (a module that uses
  `MicaBffDsl.Schema`) to PATH, each defining `NAMESPACE.<Block>`. Without
  `--spec` or `--namespace`, they come from the project's config:

      config :mica_bff_dsl, spec: MyApp.Blocks, elixir_namespace: "MyApp.Blocks.Generated"

  Files from an earlier run are removed first, so a block removed from the spec
  disappears from the output too. A hand-written file is never overwritten.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    %{out: out, schema: schema, namespace: namespace} =
      MicaBffDsl.Gen.parse_args!(args, :elixir_namespace)

    File.mkdir_p!(out)

    for file <- Path.wildcard(Path.join(out, "*.ex")),
        MicaBffDsl.Gen.generated?(file),
        do: File.rm!(file)

    for {name, source} <- MicaBffDsl.Gen.Elixir.generate(schema, namespace),
        do: MicaBffDsl.Gen.write!(Path.join(out, name), source)
  end
end
