# Used by "mix format". The schema DSL is exported, so a spec project formats
# it without parentheses with `import_deps: [:mica_bff_dsl]`.
schema_dsl = [defblock: 2, field: 2, field: 3]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: schema_dsl,
  export: [locals_without_parens: schema_dsl]
]
