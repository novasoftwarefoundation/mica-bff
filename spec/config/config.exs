import Config

# What `mix bff.gen.elixir` and `mix bff.gen.swift` generate from, and the
# namespaces of the generated code in mica and next-ios.
config :mica_bff_dsl,
  spec: MicaBff.Blocks,
  elixir_namespace: "Systems.BFF.Blocks",
  swift_namespace: "BFF"
