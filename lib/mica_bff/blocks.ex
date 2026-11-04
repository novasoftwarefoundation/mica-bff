defmodule MicaBff.Blocks do
  @moduledoc """
  The spec: every block the BFF can send and every client can render, and the
  pages the BFF serves. On the wire a block is `{"type": "section", "props": {...}}`,
  and a page is `{"blocks": [...]}`.
  """
  use MicaBff.Schema

  # The signed-in user's home: their To-dos.
  defpage(:home)

  # Plain text: an optional title and an optional body. With `to` it is tappable:
  # the client shows a chevron and opens `to` on tap. `to` is a path, resolved
  # against the app's base URL; the client's router decides what opens it
  # (native page, BFF page or web page) and how it is presented.
  defblock :section do
    field(:title, :string)
    field(:body, :string)
    field(:to, :string)
  end

  defblock :card do
    field(:title, :string)
    field(:cta, :string)
    field(:body, :string)
    field(:to, :string)
  end
end
