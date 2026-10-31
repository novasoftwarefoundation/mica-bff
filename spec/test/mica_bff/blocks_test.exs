defmodule MicaBff.BlocksTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "the block catalogue is plain data in declaration order" do
    assert MicaBff.Blocks.__schema__() == %{
             blocks: [
               %{
                 name: :section,
                 fields: [
                   %{name: :title, type: :string, required: false},
                   %{name: :body, type: :string, required: false},
                   %{name: :to, type: :string, required: false}
                 ]
               }
             ]
           }
  end

  # test/golden holds the output of main at 9feb740, before the DSL was split off.
  # The generators get the catalogue and namespaces from config/config.exs.
  test "the generated Elixir and Swift are byte-identical to test/golden", %{tmp_dir: dir} do
    Mix.Tasks.Bff.Gen.Elixir.run(["--out", Path.join(dir, "elixir")])
    Mix.Tasks.Bff.Gen.Swift.run(["--out", Path.join(dir, "swift")])

    for sub <- ["elixir", "swift"] do
      golden = Path.join("test/golden", sub)
      assert File.ls!(Path.join(dir, sub)) |> Enum.sort() == File.ls!(golden) |> Enum.sort()

      for file <- File.ls!(golden),
          do:
            assert(File.read!(Path.join([dir, sub, file])) == File.read!(Path.join(golden, file)))
    end
  end

  # Every section prop is optional, so the fixtures also check that nil props are left out.
  test "every fixture encodes back to itself through its generated module" do
    ns = "MicaBffTest.Gen#{System.unique_integer([:positive])}"

    for {_file, source} <- MicaBffDsl.Gen.Elixir.generate(MicaBff.Blocks.__schema__(), ns),
        do: Code.compile_string(source)

    for path <- Path.wildcard("fixtures/*.json") do
      %{"type" => type, "props" => props} = fixture = path |> File.read!() |> JSON.decode!()
      module = Module.concat(ns, Macro.camelize(type))
      block = struct!(module, Map.new(props, fn {k, v} -> {String.to_existing_atom(k), v} end))

      assert module.to_map(block) == fixture, path
    end
  end

  # Compiles the generated file with a check program in Swift 6 mode (as next-ios)
  # and decodes the fixtures with JSONDecoder.
  @tag :swift
  test "the fixtures decode in Swift", %{tmp_dir: dir} do
    fixture = &("fixtures/section_#{&1}.json" |> File.read!() |> String.trim())

    File.write!(
      Path.join(dir, "BFF.swift"),
      MicaBffDsl.Gen.Swift.generate(MicaBff.Blocks.__schema__(), "BFF")
    )

    File.write!(Path.join(dir, "main.swift"), """
    import Foundation

    func check(_ label: String, _ json: String, _ expected: BFF.Block) -> Bool {
        do {
            let got = try JSONDecoder().decode(BFF.Block.self, from: Data(json.utf8))
            if got == expected { return true }
            print("FAIL \\(label): got \\(got)")
        } catch {
            print("FAIL \\(label): \\(error)")
        }
        return false
    }

    let results = [
        check("tappable", #"#{fixture.("tappable")}"#,
              .section(.init(title: "Available studies", body: "Studies you can take part in right now.", to: "/pool/1/marketplace"))),
        check("plain", #"#{fixture.("plain")}"#, .section(.init(title: "Studies", body: nil, to: nil))),
        check("body only", #"#{fixture.("body")}"#, .section(.init(title: nil, body: "You have no open studies.", to: nil))),
    ]
    exit(results.allSatisfy { $0 } ? 0 : 1)
    """)

    bin = Path.join(dir, "check")
    sources = [Path.join(dir, "BFF.swift"), Path.join(dir, "main.swift")]

    {out, status} =
      System.cmd("swiftc", ["-swift-version", "6", "-o", bin | sources], stderr_to_stdout: true)

    assert status == 0, out

    {out, status} = System.cmd(bin, [], stderr_to_stdout: true)
    assert status == 0, out
  end
end
