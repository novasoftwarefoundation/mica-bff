defmodule MicaBff.Compat do
  @moduledoc """
  What makes a new spec break clients of an older one (ADR 0001, "Compatibility").
  Takes two `__schema__/0` values and returns one message per violation. Pages are
  not compared, and an older schema may lack `pages`, `types`, `markup`, `since` or
  `deprecated`.

  Breaking: removing a block, markup kind or type, and for the fields of one:
  removing a field that wasn't deprecated in the old schema, changing a field's
  type, making an optional field required, and adding a required field to an
  existing one. Anything else is compatible, also adding or removing an enum's
  values or changing its fallback: a client maps a value it doesn't know to its own
  fallback.
  """

  def breaking_changes(old_schema, new_schema) do
    record_changes(old_schema.blocks, new_schema.blocks, "block") ++
      record_changes(Map.get(old_schema, :markup, []), Map.get(new_schema, :markup, []), "markup") ++
      record_changes(Map.get(old_schema, :types, []), Map.get(new_schema, :types, []), "type")
  end

  defp record_changes(old_records, new_records, kind) do
    new_records = Map.new(new_records, &{&1.name, &1})

    Enum.flat_map(old_records, fn %{name: name, fields: old_fields} ->
      case Map.fetch(new_records, name) do
        {:ok, %{fields: new_fields}} -> field_changes(name, old_fields, new_fields, kind)
        :error -> ["#{name}: #{kind} removed"]
      end
    end)
  end

  defp field_changes(owner, old_fields, new_fields, kind) do
    old_by_name = Map.new(old_fields, &{&1.name, &1})
    new_by_name = Map.new(new_fields, &{&1.name, &1})

    Enum.flat_map(old_fields, &old_field_changes(owner, &1, new_by_name)) ++
      Enum.flat_map(new_fields, &added_field_changes(owner, &1, old_by_name, kind))
  end

  defp old_field_changes(owner, old_field, new_fields) do
    case Map.fetch(new_fields, old_field.name) do
      {:ok, new_field} -> kept_field_changes(owner, old_field, new_field)
      :error -> removed_field_changes(owner, old_field)
    end
  end

  defp kept_field_changes(owner, old_field, new_field) do
    type_changes(owner, old_field, new_field) ++ required_changes(owner, old_field, new_field)
  end

  defp type_changes(_owner, %{type: type}, %{type: type}), do: []
  defp type_changes(_owner, %{type: {:enum, _}}, %{type: {:enum, _}}), do: []

  defp type_changes(owner, old_field, new_field) do
    [
      "#{owner}.#{old_field.name}: type changed from #{inspect(old_field.type)} to #{inspect(new_field.type)}"
    ]
  end

  defp required_changes(owner, %{required: false, name: name}, %{required: true}),
    do: ["#{owner}.#{name}: changed from optional to required"]

  defp required_changes(_owner, _old_field, _new_field), do: []

  defp removed_field_changes(owner, old_field) do
    if Map.get(old_field, :deprecated),
      do: [],
      else: ["#{owner}.#{old_field.name}: removed without being deprecated first"]
  end

  defp added_field_changes(owner, %{required: true, name: name}, old_fields, kind)
       when not is_map_key(old_fields, name),
       do: ["#{owner}.#{name}: new required field on an existing #{kind}"]

  defp added_field_changes(_owner, _new_field, _old_fields, _kind), do: []
end
