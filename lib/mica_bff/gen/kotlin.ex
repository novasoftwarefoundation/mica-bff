defmodule MicaBff.Gen.Kotlin do
  @default_package "bff"
  @default_namespace "BFF"

  @moduledoc """
  Generates one Kotlin file with the spec's types in an `object` (default
  `#{@default_namespace}`; Compose already has a `Border`), in a package (default
  `#{@default_package}`). The Kotlin itself is in `kotlin.kt.eex`.

  The file needs the Kotlin and Java standard libraries only (`java.math` for a
  `BigInteger` or `BigDecimal`): no JSON library, nothing from Android. Decoding
  takes JSON that is already parsed into plain values: `Map`, `List`, `String`,
  `Number`, `Boolean` and `null`. An Android app turns `org.json` into those; a test
  writes them as literals.

  - `sealed interface Block`: one class per block plus `UnknownBlock(type)`.
    `Block.from(value)` never throws: a type this app doesn't know becomes
    `UnknownBlock`, and a known block always decodes, with the props it could read
    (ADR 0001, tolerant reader), so the app never drops a block it can render.
  - One data class per block, every prop nullable with `null` as its default:
    `required` binds the server only. A prop that is missing, `null` or of another
    type becomes `null`; props that aren't an object give the block with every prop
    `null`. A block without props is a plain class whose instances are all equal.
    An `integer` is a `Long`, read from any number without a fraction; a `float` is
    a `Double`. A data class's fields are in spec order, which the compatibility
    rules may change: build one with named arguments and don't destructure it.
  - An enum prop is an `enum class` nested in its block's class, named after the
    field (`tone` is `Tone`), its entries in UPPER_SNAKE; a value the app doesn't know
    decodes to the enum's fallback. A list prop is a `List`; an element that doesn't
    decode is dropped and the rest of the list stays.
  - One data class per type, decoded like a block's props; `from(value)` is `null`
    for a value that isn't an object.
  - `data class Page`: a page as the BFF sends it, `{"blocks": [...], "markup": [...]}`:
    its blocks, each block's id (`null` when it has none) and its markup: a `Region`
    per stretch of blocks, with its `RegionKind`: one class per region kind, decoded
    like a block, plus `UnknownRegion(kind)`. A region without a string `start` and
    `end` is dropped. `Page.tree()` is the nested tree to render (`Node`): it leaves
    out a region of a kind the app doesn't know and one that `Page.check()` refuses,
    also one that would nest regions deeper than `Page.MAX_REGION_DEPTH`, and still
    shows their blocks.
  - snake_case wire names map to camelCase; Kotlin keywords are escaped. Standard
    names are written as `kotlin.String` etc., so a block named `list` or `map`
    can't shadow them inside the namespace.

  Not generated: encoding the types to JSON (a client only reads them), and a
  report of the props a block came without.

  Views stay hand-written in the app: a `when` over `Block` without `else` turns a
  new block in the spec into a build error until it has a view.
  """

  require EEx

  @types %{
    string: {"kotlin.String", "readString"},
    integer: {"kotlin.Long", "readLong"},
    float: {"kotlin.Double", "readDouble"},
    boolean: {"kotlin.Boolean", "readBoolean"}
  }
  # Hard keywords: the ones that can't be an identifier anywhere.
  @keywords ~w(as break class continue do else false for fun if in interface is null object
               package return super this throw true try typealias typeof val var when while)
  # Type names the generated code needs itself. `companion` would be the name of a
  # class's companion object.
  @reserved ~w(Block UnknownBlock Region RegionKind UnknownRegion Node BlockNode RegionNode Page
               Companion)

  EEx.function_from_file(:defp, :template, Path.join(__DIR__, "kotlin.kt.eex"), [:assigns])

  def default_package, do: @default_package
  def default_namespace, do: @default_namespace

  @doc "Returns the Kotlin source for the spec's blocks, region kinds and types."
  @spec generate(map, String.t(), String.t()) :: String.t()
  def generate(
        %{blocks: blocks} = schema,
        package \\ @default_package,
        namespace \\ @default_namespace
      ) do
    types = Map.get(schema, :types, [])
    regions = Map.get(schema, :regions, [])
    type_names = Enum.map(types, & &1.name)
    reserved = [namespace | @reserved]

    named =
      for {kind, records} <- [block: blocks, region: regions, type: types],
          %{name: name} <- records,
          do: {"#{kind} #{inspect(name)}", type_name(name)}

    refuse_clashes!(named, reserved)

    blocks = Enum.map(blocks, &record(&1, namespace, type_names, "Block"))
    regions = Enum.map(regions, &record(&1, namespace, type_names, "RegionKind"))
    types = Enum.map(types, &record(&1, namespace, type_names, nil))
    records = blocks ++ regions ++ types

    # An enum's class is nested in its record's class, so there it shadows these, and
    # the record itself.
    for %{name: record, type: record_type, enums: enums} <- records do
      enums
      |> Enum.map(&{"enum field #{record}.#{&1.field}", &1.type})
      |> refuse_clashes!([record_type | reserved])
    end

    header =
      "// Generated by #{MicaBff.Gen.origin()} (mix bff.gen.kotlin). " <>
        "Do not edit: change the spec in mica-bff and regenerate."

    [
      header: header,
      package: package,
      namespace: namespace,
      blocks: blocks,
      regions: regions,
      classes: Enum.map(records, &indent(&1.source, 4)),
      max_region_depth: MicaBff.Gen.max_region_depth()
    ]
    |> template()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # A block, region kind or type: its class's source, and what decoding it needs.
  defp record(%{name: name, fields: fields}, namespace, types, parent) do
    doc =
      case parent do
        "Block" -> "Block `#{name}`."
        "RegionKind" -> "Region `#{name}`."
        nil -> "Type `#{name}`."
      end

    type = type_name(name)
    conforms = if parent, do: " : #{parent}", else: ""
    fields = Enum.map(fields, &field(&1, namespace, types))
    enums = for %{enum: enum} <- fields, enum, do: enum

    %{
      name: name,
      type: type,
      enums: enums,
      source: Enum.join(class(doc, type, conforms, fields, enums), "\n")
    }
  end

  # A data class needs a property, so a record without fields is a plain class
  # whose instances are all equal.
  defp class(doc, type, conforms, [], _enums) do
    [
      "/** #{doc} */",
      "class #{type}#{conforms} {",
      "    override fun equals(other: kotlin.Any?): kotlin.Boolean = other is #{type}",
      "    override fun hashCode(): kotlin.Int = 0",
      "    override fun toString(): kotlin.String = \"#{type}()\"",
      "",
      "    companion object {",
      "        /** Null for a value that isn't an object. */",
      "        fun from(value: kotlin.Any?): #{type}? = if (value is kotlin.collections.Map<*, *>) #{type}() else null",
      "    }",
      "}"
    ]
  end

  defp class(doc, type, conforms, fields, enums) do
    ["/** #{doc} */", "data class #{type}("] ++
      Enum.map(fields, &"    val #{&1.ident}: #{&1.kotlin_type}? = null,") ++
      [")#{conforms} {"] ++
      Enum.flat_map(enums, &(&1.lines ++ [""])) ++
      [
        "    companion object {",
        "        /**",
        "         * Null for a value that isn't an object. Every field is nullable, also a required",
        "         * one (ADR 0001, tolerant reader): one that is missing or of another type becomes null.",
        "         */",
        "        fun from(value: kotlin.Any?): #{type}? {",
        "            val map = value as? kotlin.collections.Map<*, *> ?: return null",
        "            return #{type}("
      ] ++
      Enum.map(fields, &"                #{&1.ident} = #{&1.decode},") ++
      ["            )", "        }", "    }", "}"]
  end

  defp field(%{name: name, type: type} = field, namespace, types) do
    value = ~s(map["#{name}"])

    {kotlin_type, decode} =
      case type do
        {:enum, _} ->
          {type_name(name), "#{type_name(name)}.from(#{value})"}

        {:list, element} ->
          {element, read} = element_type(element, namespace, types)
          {"kotlin.collections.List<#{element}>", "readList(#{value}) { #{read}(it) }"}

        type ->
          {element, read} = element_type(type, namespace, types)
          {element, "#{read}(#{value})"}
      end

    %{ident: ident(name), kotlin_type: kotlin_type, decode: decode, enum: enum(field)}
  end

  # The Kotlin type and the function that reads it from a plain value.
  defp element_type(type, namespace, types) do
    if type in types do
      type = "#{namespace}.#{type_name(type)}"
      {type, "#{type}.from"}
    else
      @types[type]
    end
  end

  defp enum(%{name: name, type: {:enum, values}, fallback: fallback}) do
    type = type_name(name)
    entries = Enum.map_join(values, ", ", &~s|#{entry(&1)}("#{&1}")|)

    lines = [
      "    enum class #{type}(val wire: kotlin.String) {",
      "        #{entries};",
      "",
      "        companion object {",
      "            /** A value this app doesn't know becomes `#{entry(fallback)}` (ADR 0001); null for one that isn't a string. */",
      "            fun from(value: kotlin.Any?): #{type}? =",
      "                (value as? kotlin.String)?.let { wire -> entries.firstOrNull { it.wire == wire } ?: #{entry(fallback)} }",
      "        }",
      "    }"
    ]

    %{field: name, type: type, lines: lines}
  end

  defp enum(_field), do: nil

  # Refuses a class named as one of `reserved`, and two classes with one name. Names are
  # compared without case: every class is a file of its own (`BFF$SignUp.class`), and where
  # file names ignore case (macOS, Windows) one of two that differ only in case overwrites
  # the other.
  defp refuse_clashes!(classes, reserved) do
    Enum.reduce(classes, %{}, fn {label, type}, seen ->
      key = String.downcase(type)

      reason =
        cond do
          type in reserved ->
            "#{type} is reserved by Kotlin or the generated code"

          taken = Enum.find(reserved, &(String.downcase(&1) == key)) ->
            "#{type} differs only in case from #{taken}, " <>
              "which is reserved by Kotlin or the generated code"

          twin = seen[key] ->
            {twin_label, twin_type} = twin

            "#{type} and #{twin_type} (#{twin_label}) would be one class file " <>
              "where file names ignore case"

          true ->
            nil
        end

      if reason, do: raise(ArgumentError, "#{label} can't be generated in Kotlin: #{reason}")
      Map.put(seen, key, {label, type})
    end)
  end

  defp entry(value), do: value |> to_string() |> String.upcase()

  defp indent(source, spaces) do
    prefix = String.duplicate(" ", spaces)

    source
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> prefix <> line
    end)
  end

  defp type_name(name), do: Macro.camelize(to_string(name))

  defp ident(name) do
    [first | rest] = name |> to_string() |> String.split("_")
    camel = first <> Enum.map_join(rest, &String.capitalize/1)
    if camel in @keywords, do: "`#{camel}`", else: camel
  end
end
