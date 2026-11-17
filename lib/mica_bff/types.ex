defmodule MicaBff.Types do
  @moduledoc """
  The nested objects blocks hold, part of the spec (`MicaBff.Spec`). On the wire a
  type is a JSON object of its fields.
  """
  use MicaBff.Schema

  # One choice of a `filter`, shown as a chip with `label`. `to` is the page with this
  # choice applied; `selected` marks the choice in effect.
  deftype :filter_option do
    field(:label, :string, required: true)
    field(:to, :string, required: true)
    field(:selected, :boolean)
  end
end
