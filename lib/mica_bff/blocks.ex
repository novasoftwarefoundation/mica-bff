defmodule MicaBff.Blocks do
  @moduledoc """
  The block spec: every block the BFF can send and every client can render.
  On the wire a block is `{"type": "section", "props": {...}}`.
  """
  use MicaBff.Spec

  defmodel :link do
    # Path of the page to open, e.g. "/assignment/12". How it is presented
    # (tab, over the tabs, external) is up to the client's navigation rules.
    field(:to, :string, required: true)
  end

  defblock :section_header do
    field(:title, :string, required: true)
  end

  # A line of text with a chevron; tapping it opens `link`.
  defblock :section do
    field(:title, :string, required: true)
    field(:link, :link, required: true)
  end
end
