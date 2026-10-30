# Swift tests need swiftc. CI must have it, so they are only skipped locally.
ExUnit.start(
  exclude: if(System.find_executable("swiftc") || System.get_env("CI"), do: [], else: [:swift])
)
