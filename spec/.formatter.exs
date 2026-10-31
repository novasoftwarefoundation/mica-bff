# Used by "mix format". dsl/ has its own; test/golden holds generated files as they are.
[
  import_deps: [:mica_bff_dsl],
  inputs: ["{mix,.formatter}.exs", "{config,lib}/**/*.{ex,exs}", "test/**/*.exs"]
]
