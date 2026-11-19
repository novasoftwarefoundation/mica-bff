defmodule MicaBff.Gen.SwiftTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "block and type names Swift or the generated code reserve are refused" do
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
        ],
        schema <- [
          %{blocks: [%{name: name, fields: []}]},
          %{blocks: [], types: [%{name: name, fields: []}]}
        ] do
      assert_raise ArgumentError, ~r/is reserved by Swift or the generated code/, fn ->
        MicaBff.Gen.Swift.generate(schema, "BFF")
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
  test "fixtures decode; a known block always decodes, also with missing or broken props; an unknown one is .unknown",
       %{tmp_dir: dir} do
    fixture = &(Path.join("fixtures", &1) |> File.read!() |> String.trim())
    schema = MicaBff.Spec.__schema__()

    # Tolerant reader: every block in the spec, sent with empty props, is that block.
    empty =
      Enum.map_join(schema.blocks, "\n", fn %{name: name} ->
        ~s|    known("#{name}", #"{"type": "#{name}", "props": {}}"#),|
      end)

    run_swift!(dir, schema, """
    [
    #{empty}
        check("tappable", #"#{fixture.("section_tappable.json")}"#,
              BFF.Block.section(.init(title: "Available studies", body: "Studies you can take part in right now.", to: "/pool/1/marketplace", count: nil, imageUrl: nil))),
        check("plain", #"#{fixture.("section_plain.json")}"#, BFF.Block.section(.init(title: "Studies", body: nil, to: nil, count: nil, imageUrl: nil))),
        check("body only", #"#{fixture.("section_body.json")}"#, BFF.Block.section(.init(title: nil, body: "You have no open studies.", to: nil, count: nil, imageUrl: nil))),
        check("heading", #"#{fixture.("section_heading.json")}"#,
              BFF.Block.section(.init(title: "Marketplace", body: "Studies you can take part in right now.", to: nil, count: 12, imageUrl: "/images/logos/pool/panl_wide.png"))),
        check("section begin", #"#{fixture.("section_begin.json")}"#,
              BFF.Block.sectionBegin(.init(background: "grey6", border: true))),
        check("section end", #"#{fixture.("section_end.json")}"#, BFF.Block.sectionEnd(.init())),
        check("nested groups", #"[{"type": "section_begin", "props": {"border": true}}, {"type": "section_begin", "props": {"background": "tertiary"}}, {"type": "section", "props": {"title": "A"}}, {"type": "section_end", "props": {}}, {"type": "section_end", "props": {}}]"#,
              [BFF.Block.sectionBegin(.init(background: nil, border: true)), .sectionBegin(.init(background: "tertiary", border: nil)),
              .section(.init(title: "A", body: nil, to: nil, count: nil, imageUrl: nil)), .sectionEnd(.init()), .sectionEnd(.init())]),
        check("next best action", #"#{fixture.("next_best_action.json")}"#,
              BFF.Block.nextBestAction(.init(title: "Complete your profile", body: "Researchers need a few details before you can take part.", cta: "Go to profile", to: "/user/account"))),
        check("reward amount", #"#{fixture.("reward_amount.json")}"#,
              BFF.Block.rewardAmount(.init(label: "Approved", tone: .success, amount: "€ 12,50", caption: "You can pay out from € 10,00"))),
        check("advert", #"#{fixture.("advert.json")}"#,
              BFF.Block.advert(.init(title: "Sleep and screens", to: "/promotion/7", imageUrl: "https://images.example.org/sleep.jpg", logoUrl: "/images/logos/uu.png", tags: ["Health", "Media"], info: "Duration: 10 min. | Reward: € 2,00"))),
        check("participation", #"#{fixture.("participation.json")}"#,
              BFF.Block.participation(.init(title: "Sleep and screens", subtitle: "2 days ago", statusLabel: "Awaiting", statusTone: .warning, reward: "Reward € 2,00", to: "/assignment/7"))),
        check("filter", #"#{fixture.("filter.json")}"#,
              BFF.Block.filter(.init(label: "Filter:", options: [.init(label: "All", to: "/bff/page/marketplace?query=sleep", selected: nil), .init(label: "2026", to: "/bff/page/marketplace?query=sleep&year=2026", selected: true), .init(label: "2025", to: "/bff/page/marketplace?query=sleep&year=2025", selected: false)]))),
        check("filter option without its link", #"{"type": "filter", "props": {"options": [{"label": "A"}, {"label": "B", "to": "/b"}, 3]}}"#,
              BFF.Block.filter(.init(label: nil, options: [.init(label: "A", to: nil, selected: nil), .init(label: "B", to: "/b", selected: nil)]))),
        check("search", #"#{fixture.("search.json")}"#,
              BFF.Block.search(.init(name: "query", to: "/bff/page/marketplace?year=2026", placeholder: "Search", value: "sleep"))),
        check("unknown tone", #"{"type": "participation", "props": {"title": "A", "status_tone": "sparkly"}}"#,
              BFF.Block.participation(.init(title: "A", subtitle: nil, statusLabel: nil, statusTone: .neutral, reward: nil, to: nil))),
        check("null prop", #"{"type": "section", "props": {"title": "A", "to": null}}"#,
              BFF.Block.section(.init(title: "A", body: nil, to: nil, count: nil, imageUrl: nil))),
        check("unknown keys", #"{"type": "section", "id": 1, "props": {"title": "A", "icon": "x"}}"#,
              BFF.Block.section(.init(title: "A", body: nil, to: nil, count: nil, imageUrl: nil))),
        check("wrong type for an optional prop", #"{"type": "section", "props": {"title": "Studies", "to": 5}}"#,
              BFF.Block.section(.init(title: "Studies", body: nil, to: nil, count: nil, imageUrl: nil))),
        check("page", #"[{"type": "section", "props": {"title": "A"}}, {"type": "carousel", "props": {}}, {"type": "section"}, {"type": "section", "props": 1}, null, {"type": 3}]"#,
              [BFF.Block.section(.init(title: "A", body: nil, to: nil, count: nil, imageUrl: nil)), .unknown(type: "carousel"),
              .section(.init(title: nil, body: nil, to: nil, count: nil, imageUrl: nil)), .section(.init(title: nil, body: nil, to: nil, count: nil, imageUrl: nil)),
              .unknown(type: ""), .unknown(type: "")]),
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
              BFF.Block.rowItem(.init(default: nil, subTitle: nil, count: nil, ratio: nil, active: nil))),
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
              BFF.Block.badge(.init(tone: nil, status: nil, tags: nil, counts: []))),
        check("elements that don't decode", #"{"type": "badge", "props": {"tone": "success", "tags": ["a", 1, null, {"b": 2}, [3], "c"], "counts": [1, "2", 1.5, 3]}}"#,
              BFF.Block.badge(.init(tone: .success, status: nil, tags: ["a", "c"], counts: [1, 3]))),
        check("wrong type for an optional list", #"{"type": "badge", "props": {"tone": "success", "tags": "a", "counts": []}}"#,
              BFF.Block.badge(.init(tone: .success, status: nil, tags: nil, counts: []))),
        check("wrong type for a required list", #"{"type": "badge", "props": {"tone": "success", "counts": {"a": 1}}}"#,
              BFF.Block.badge(.init(tone: .success, status: nil, tags: nil, counts: nil))),
    ]
    """)
  end

  @tag :swift
  test "a type in a block decodes like a block's props, also without its required fields; a type encodes",
       %{tmp_dir: dir} do
    schema = %{
      blocks: [
        %{
          name: :album,
          fields: [
            %{name: :gallery, type: :gallery, required: true},
            %{name: :extra, type: :image, required: false}
          ]
        }
      ],
      types: [
        %{
          name: :image,
          fields: [
            %{name: :url, type: :string, required: true},
            %{name: :alt_text, type: :string, required: false}
          ]
        },
        %{
          name: :gallery,
          fields: [
            %{name: :name, type: :string, required: true},
            %{name: :cover, type: :image, required: false},
            %{name: :photos, type: {:list, :image}, required: false},
            %{name: :tone, type: {:enum, [:calm, :loud]}, required: false, fallback: :calm}
          ]
        }
      ]
    }

    run_swift!(dir, schema, """
    [
        check("types", #"{"type": "album", "props": {"gallery": {"name": "A", "cover": {"url": "/a.png", "alt_text": "A"}, "photos": [{"url": "/b.png"}, {"alt_text": "no url"}, null, 3], "tone": "sparkly"}, "extra": {"alt_text": "no url"}}}"#,
              BFF.Block.album(.init(gallery: .init(name: "A", cover: .init(url: "/a.png", altText: "A"), photos: [.init(url: "/b.png", altText: nil), .init(url: nil, altText: "no url")], tone: .calm),
                                    extra: .init(url: nil, altText: "no url")))),
        check("a type missing its required fields", #"{"type": "album", "props": {"gallery": {"cover": {"url": "/a.png"}}}}"#,
              BFF.Block.album(.init(gallery: .init(name: nil, cover: .init(url: "/a.png", altText: nil), photos: nil, tone: nil), extra: nil))),
        encodes("type", BFF.Gallery(name: "A", cover: .init(url: "/a.png", altText: nil), photos: [], tone: .loud),
                #"{"cover":{"url":"/a.png"},"name":"A","photos":[],"tone":"loud"}"#),
    ]
    """)
  end

  defp run_swift!(dir, schema, checks) do
    File.write!(Path.join(dir, "BFF.swift"), MicaBff.Gen.Swift.generate(schema, "BFF"))

    File.write!(Path.join(dir, "main.swift"), """
    import Foundation

    func known(_ label: String, _ json: String) -> Bool {
        guard let block = try? JSONDecoder().decode(BFF.Block.self, from: Data(json.utf8)) else {
            print("FAIL \\(label): doesn't decode")
            return false
        }
        if case .unknown = block { print("FAIL \\(label): .unknown"); return false }
        return true
    }

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


    func encodes<T: Encodable>(_ label: String, _ value: T, _ json: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let got = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
        if got == json { return true }
        print("FAIL \\(label): got \\(got ?? "an error")")
        return false
    }

    let results: [Bool] = #{checks}
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
