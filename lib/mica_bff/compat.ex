defmodule MicaBff.Compat do
  @moduledoc """
  What makes a new block catalogue break clients of an older one (ADR 0001,
  "Compatibility"). Takes two `__schema__/0` values and returns one message per
  violation. Pages are not compared, and an older schema may lack `pages`,
  `since` or `deprecated`.

  Breaking: removing a block, removing a field that wasn't deprecated in the old
  schema, changing a field's type, making an optional field required, and adding
  a required field to an existing block. Anything else is compatible, also
  adding or removing an enum's values or changing its fallback: a client maps a
  value it doesn't know to its own fallback.
  """

  def breaking_changes(old_schema, new_schema) do
    new_blocks = Map.new(new_schema.blocks, &{&1.name, &1})
    Enum.flat_map(old_schema.blocks, &block_changes(&1, new_blocks))
  end

  defp block_changes(old_block, new_blocks) do
    case Map.fetch(new_blocks, old_block.name) do
      {:ok, new_block} -> field_changes(old_block, new_block)
      :error -> ["#{old_block.name}: block removed"]
    end
  end

  defp field_changes(old_block, new_block) do
    old_fields = Map.new(old_block.fields, &{&1.name, &1})
    new_fields = Map.new(new_block.fields, &{&1.name, &1})

    Enum.flat_map(old_block.fields, &old_field_changes(old_block.name, &1, new_fields)) ++
      Enum.flat_map(new_block.fields, &added_field_changes(new_block.name, &1, old_fields))
  end

  defp old_field_changes(block, old_field, new_fields) do
    case Map.fetch(new_fields, old_field.name) do
      {:ok, new_field} -> kept_field_changes(block, old_field, new_field)
      :error -> removed_field_changes(block, old_field)
    end
  end

  defp kept_field_changes(block, old_field, new_field) do
    type_changes(block, old_field, new_field) ++ required_changes(block, old_field, new_field)
  end

  defp type_changes(_block, %{type: type}, %{type: type}), do: []
  defp type_changes(_block, %{type: {:enum, _}}, %{type: {:enum, _}}), do: []

  defp type_changes(block, old_field, new_field) do
    [
      "#{block}.#{old_field.name}: type changed from #{inspect(old_field.type)} to #{inspect(new_field.type)}"
    ]
  end

  defp required_changes(block, %{required: false, name: name}, %{required: true}),
    do: ["#{block}.#{name}: changed from optional to required"]

  defp required_changes(_block, _old_field, _new_field), do: []

  defp removed_field_changes(block, old_field) do
    if Map.get(old_field, :deprecated),
      do: [],
      else: ["#{block}.#{old_field.name}: removed without being deprecated first"]
  end

  defp added_field_changes(block, %{required: true, name: name}, old_fields)
       when not is_map_key(old_fields, name),
       do: ["#{block}.#{name}: new required field on an existing block"]

  defp added_field_changes(_block, _new_field, _old_fields), do: []
end
