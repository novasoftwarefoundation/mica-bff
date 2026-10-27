defmodule MicaBff.Blocks do
  @moduledoc """
  The block catalogue: every block the BFF can send and every client can render.
  On the wire a block is `{"type": "section", "props": {...}}`.
  """
  use MicaBff.Schema

  # A line of text. With `to` it is tappable: the client shows that (a chevron)
  # and opens `to` on tap; without `to` it is plain text. `to` is a path, resolved
  # against the app's base URL; the client's router decides what opens it
  # (native page, BFF page or web page) and how it is presented.
  defblock :section do
    field(:title, :string, required: true)
    field(:to, :string)
  end
end
