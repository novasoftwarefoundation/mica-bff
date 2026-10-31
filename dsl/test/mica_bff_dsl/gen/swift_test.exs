defmodule MicaBffDsl.Gen.SwiftTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "block names Swift or the generated code reserve are refused" do
    for name <- [:block, :unknown, :self, :type, :protocol, :any, :swift, :coding_keys] do
      assert_raise ArgumentError, ~r/is reserved by Swift or the generated code/, fn ->
        MicaBffDsl.Gen.Swift.generate(%{blocks: [%{name: name, fields: []}]}, "Blocks")
      end
    end
  end

  # Compiles the generated file with a check program in Swift 6 mode and decodes
  # payloads with JSONDecoder.
  @tag :swift
  test "blocks decode, and bad blocks become .unknown without failing the page", %{
    tmp_dir: dir
  } do
    run_swift!(dir, MicaBffDsl.Test.Catalogue.__schema__(), """
    [
        check("all props", #"{"type": "card", "props": {"title": "A", "subtitle": "B", "to": "/c"}}"#,
              Blocks.Block.card(.init(title: "A", subtitle: "B", to: "/c"))),
        check("missing optional props", #"{"type": "card", "props": {"title": "A"}}"#,
              Blocks.Block.card(.init(title: "A", subtitle: nil, to: nil))),
        check("no props", #"{"type": "divider", "props": {}}"#, Blocks.Block.divider(.init())),
        check("null prop", #"{"type": "card", "props": {"title": "A", "to": null}}"#,
              Blocks.Block.card(.init(title: "A", subtitle: nil, to: nil))),
        check("unknown keys", #"{"type": "card", "id": 1, "props": {"title": "A", "icon": "x"}}"#,
              Blocks.Block.card(.init(title: "A", subtitle: nil, to: nil))),
        check("wrong type for an optional prop", #"{"type": "card", "props": {"title": "A", "to": 5}}"#,
              Blocks.Block.card(.init(title: "A", subtitle: nil, to: nil))),
        check("missing required prop", #"{"type": "card", "props": {"subtitle": "B"}}"#,
              Blocks.Block.unknown(type: "card")),
        check("page", #"[{"type": "card", "props": {"title": "A"}}, {"type": "carousel", "props": {}}, {"type": "card"}, {"type": "card", "props": 1}, null, {"type": 3}]"#,
              [Blocks.Block.card(.init(title: "A", subtitle: nil, to: nil)), .unknown(type: "carousel"),
              .unknown(type: "card"), .unknown(type: "card"), .unknown(type: ""),
              .unknown(type: "")]),
    ]
    """)
  end

  @tag :swift
  test "snake_case names, keywords, every primitive type, and blocks named after Swift types",
       %{tmp_dir: dir} do
    schema = %{
      blocks: [
        %{
          name: :row_item,
          fields: [
            %{name: :default, type: :string, required: true},
            %{name: :sub_title, type: :string, required: false},
            %{name: :count, type: :integer, required: false},
            %{name: :ratio, type: :float, required: false},
            %{name: :active, type: :boolean, required: false}
          ]
        },
        # Without qualified names these would shadow Swift.Bool and Swift.Decoder.
        %{name: :bool, fields: [%{name: :x, type: :string, required: true}]},
        %{name: :decoder, fields: [%{name: :x, type: :string, required: true}]}
      ]
    }

    run_swift!(dir, schema, """
    [
        check("all props", #"{"type": "row_item", "props": {"default": "x", "sub_title": "y", "count": 3, "ratio": 1, "active": true}}"#,
              Blocks.Block.rowItem(.init(default: "x", subTitle: "y", count: 3, ratio: 1, active: true))),
        check("fraction for an optional integer", #"{"type": "row_item", "props": {"default": "x", "count": 1.5}}"#,
              Blocks.Block.rowItem(.init(default: "x", subTitle: nil, count: nil, ratio: nil, active: nil))),
        check("wrong type for a required prop", #"{"type": "row_item", "props": {"default": 1}}"#,
              Blocks.Block.unknown(type: "row_item")),
        check("block named bool", #"{"type": "bool", "props": {"x": "y"}}"#, Blocks.Block.bool(.init(x: "y"))),
        check("block named decoder", #"{"type": "decoder", "props": {"x": "y"}}"#, Blocks.Block.decoder(.init(x: "y"))),
    ]
    """)
  end

  defp run_swift!(dir, schema, checks) do
    File.write!(Path.join(dir, "Blocks.swift"), MicaBffDsl.Gen.Swift.generate(schema, "Blocks"))

    File.write!(Path.join(dir, "main.swift"), """
    import Foundation

    func check<T: Decodable & Equatable>(_ label: String, _ json: String, _ expected: T) -> Bool {
        do {
            let got = try JSONDecoder().decode(T.self, from: Data(json.utf8))
            if got == expected { return true }
            print("FAIL \\(label): got \\(got)")
        } catch {
            print("FAIL \\(label): \\(error)")
        }
        return false
    }

    let results = #{checks}
    exit(results.allSatisfy { $0 } ? 0 : 1)
    """)

    bin = Path.join(dir, "check")
    sources = [Path.join(dir, "Blocks.swift"), Path.join(dir, "main.swift")]

    {out, status} =
      System.cmd("swiftc", ["-swift-version", "6", "-o", bin | sources], stderr_to_stdout: true)

    assert status == 0, out

    {out, status} = System.cmd(bin, [], stderr_to_stdout: true)
    assert status == 0, out
  end
end
