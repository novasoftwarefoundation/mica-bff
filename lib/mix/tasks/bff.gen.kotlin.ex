defmodule Mix.Tasks.Bff.Gen.Kotlin do
  @default_package MicaBff.Gen.Kotlin.default_package()
  @default_namespace MicaBff.Gen.Kotlin.default_namespace()

  @shortdoc "Generates the Kotlin block types from the spec"
  @moduledoc """
      mix bff.gen.kotlin --out PATH [--package #{@default_package}] [--namespace #{@default_namespace}]

  Writes `PATH/<namespace>.kt`, in the package `--package`, with every block as a class
  decoded from plain values. A hand-written file is never overwritten.
  """
  use Mix.Task

  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args, strict: [out: :string, package: :string, namespace: :string])

    out = opts[:out] || Mix.raise("--out is required")
    package = opts[:package] || @default_package
    namespace = opts[:namespace] || @default_namespace

    File.mkdir_p!(out)
    source = MicaBff.Gen.Kotlin.generate(MicaBff.Spec.__schema__(), package, namespace)
    MicaBff.Gen.write!(Path.join(out, "#{namespace}.kt"), source)
  end
end
