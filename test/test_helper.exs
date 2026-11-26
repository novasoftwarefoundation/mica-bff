# Swift tests need swiftc, Kotlin tests kotlinc. CI must have them, so they are only
# skipped locally.
ci? = System.get_env("CI")

ExUnit.start(
  exclude:
    for(
      {tag, compiler} <- [swift: "swiftc", kotlin: "kotlinc"],
      !(System.find_executable(compiler) || ci?),
      do: tag
    )
)
