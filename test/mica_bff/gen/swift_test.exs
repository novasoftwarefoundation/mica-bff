defmodule MicaBff.Gen.SwiftTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "block names Swift or the generated code reserve are refused" do
    for name <- [
          :block,
          :unknown,
          :self,
          :type,
          :protocol,
          :any,
          :swift,
          :coding_keys,
          :lossy_list
        ] do
      assert_raise ArgumentError, ~r/is reserved by Swift or the generated code/, fn ->
        MicaBff.Gen.Swift.generate(%{blocks: [%{name: name, fields: []}]}, "BFF")
      end
    end
  end

  test "enum fields whose type would shadow Swift, the generated code or the namespace are refused" do
    for {name, namespace} <- [self: "BFF", coding_keys: "BFF", api: "Api"] do
      schema = %{
        blocks: [
          %{
            name: :badge,
            fields: [%{name: name, type: {:enum, [:a]}, required: false, fallback: :a}]
          }
        ]
      }

      assert_raise ArgumentError, ~r/is reserved by Swift or the generated code/, fn ->
        MicaBff.Gen.Swift.generate(schema, namespace)
      end
    end
  end

  # Compiles the generated file with a check program in Swift 6 mode (as next-ios)
  # and decodes payloads with JSONDecoder.
  @tag :swift
  test "fixtures decode, and bad blocks become .unknown without failing the page", %{
    tmp_dir: dir
  } do
    tappable = "fixtures/section_tappable.json" |> File.read!() |> String.trim()
    plain = "fixtures/section_plain.json" |> File.read!() |> String.trim()
    body = "fixtures/section_body.json" |> File.read!() |> String.trim()

    run_swift!(dir, MicaBff.Spec.__schema__(), """
    [
        check("tappable", #"#{tappable}"#,
              BFF.Block.section(.init(title: "Available studies", body: "Studies you can take part in right now.", to: "/pool/1/marketplace"))),
        check("plain", #"#{plain}"#, BFF.Block.section(.init(title: "Studies", body: nil, to: nil))),
        check("body only", #"#{body}"#, BFF.Block.section(.init(title: nil, body: "You have no open studies.", to: nil))),
        check("null prop", #"{"type": "section", "props": {"title": "A", "to": null}}"#,
              BFF.Block.section(.init(title: "A", body: nil, to: nil))),
        check("unknown keys", #"{"type": "section", "id": 1, "props": {"title": "A", "icon": "x"}}"#,
              BFF.Block.section(.init(title: "A", body: nil, to: nil))),
        check("wrong type for an optional prop", #"{"type": "section", "props": {"title": "Studies", "to": 5}}"#,
              BFF.Block.section(.init(title: "Studies", body: nil, to: nil))),
        check("page", #"[{"type": "section", "props": {"title": "A"}}, {"type": "carousel", "props": {}}, {"type": "section"}, {"type": "section", "props": 1}, null, {"type": 3}]"#,
              [BFF.Block.section(.init(title: "A", body: nil, to: nil)), .unknown(type: "carousel"),
              .unknown(type: "section"), .unknown(type: "section"), .unknown(type: ""),
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
              BFF.Block.rowItem(.init(default: "x", subTitle: "y", count: 3, ratio: 1, active: true))),
        check("fraction for an optional integer", #"{"type": "row_item", "props": {"default": "x", "count": 1.5}}"#,
              BFF.Block.rowItem(.init(default: "x", subTitle: nil, count: nil, ratio: nil, active: nil))),
        check("wrong type for a required prop", #"{"type": "row_item", "props": {"default": 1}}"#,
              BFF.Block.unknown(type: "row_item")),
        check("block named bool", #"{"type": "bool", "props": {"x": "y"}}"#, BFF.Block.bool(.init(x: "y"))),
        check("block named decoder", #"{"type": "decoder", "props": {"x": "y"}}"#, BFF.Block.decoder(.init(x: "y"))),
    ]
    """)
  end

  @tag :swift
  test "an unknown enum value becomes the fallback; a list drops the elements that don't decode",
       %{tmp_dir: dir} do
    enum = {:enum, [:success, :in_progress, :default]}

    schema = %{
      blocks: [
        %{
          name: :badge,
          fields: [
            %{name: :tone, type: enum, required: true, fallback: :default},
            %{name: :status, type: enum, required: false, fallback: :success},
            %{name: :tags, type: {:list, :string}, required: false},
            %{name: :counts, type: {:list, :integer}, required: true}
          ]
        }
      ]
    }

    run_swift!(dir, schema, """
    [
        check("all props", #"{"type": "badge", "props": {"tone": "in_progress", "status": "default", "tags": ["a"], "counts": [1, 2]}}"#,
              BFF.Block.badge(.init(tone: .inProgress, status: .default, tags: ["a"], counts: [1, 2]))),
        check("unknown values", #"{"type": "badge", "props": {"tone": "sparkly", "status": "new", "counts": []}}"#,
              BFF.Block.badge(.init(tone: .default, status: .success, tags: nil, counts: []))),
        check("wrong type for an optional enum", #"{"type": "badge", "props": {"tone": "success", "status": 1, "counts": []}}"#,
              BFF.Block.badge(.init(tone: .success, status: nil, tags: nil, counts: []))),
        check("wrong type for a required enum", #"{"type": "badge", "props": {"tone": 1, "counts": []}}"#,
              BFF.Block.unknown(type: "badge")),
        check("elements that don't decode", #"{"type": "badge", "props": {"tone": "success", "tags": ["a", 1, null, {"b": 2}, [3], "c"], "counts": [1, "2", 1.5, 3]}}"#,
              BFF.Block.badge(.init(tone: .success, status: nil, tags: ["a", "c"], counts: [1, 3]))),
        check("wrong type for an optional list", #"{"type": "badge", "props": {"tone": "success", "tags": "a", "counts": []}}"#,
              BFF.Block.badge(.init(tone: .success, status: nil, tags: nil, counts: []))),
        check("wrong type for a required list", #"{"type": "badge", "props": {"tone": "success", "counts": {"a": 1}}}"#,
              BFF.Block.unknown(type: "badge")),
    ]
    """)
  end

  defp run_swift!(dir, schema, checks) do
    File.write!(Path.join(dir, "BFF.swift"), MicaBff.Gen.Swift.generate(schema, "BFF"))

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
    sources = [Path.join(dir, "BFF.swift"), Path.join(dir, "main.swift")]

    {out, status} =
      System.cmd("swiftc", ["-swift-version", "6", "-o", bin | sources], stderr_to_stdout: true)

    assert status == 0, out

    {out, status} = System.cmd(bin, [], stderr_to_stdout: true)
    assert status == 0, out
  end
end
