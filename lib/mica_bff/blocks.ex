defmodule MicaBff.Blocks do
  @moduledoc """
  The block spec: every block the BFF can send and every client can render.
  On the wire a block is `{"type": "section", "props": {...}}`.
  """
  use MicaBff.Spec

  defblock :section_header do
    field(:title, :string, required: true)
  end

  # A line of text with a chevron; tapping it opens the page at `to`.
  # ponytail: plain path for now; becomes a checked page reference once defpage exists.
  defblock :section do
    field(:title, :string, required: true)
    field(:to, :string, required: true)
  end
end
