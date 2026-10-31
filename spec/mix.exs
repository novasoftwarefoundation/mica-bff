defmodule MicaBffSpec.MixProject do
  use Mix.Project

  def project do
    [
      app: :mica_bff_spec,
      version: "0.1.0",
      description: "The block catalogue of the Mica BFF",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: [{:mica_bff_dsl, path: "../dsl"}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
