defmodule MicaBff.Markup do
  @moduledoc """
  The kinds of markup a page can have, part of the spec (`MicaBff.Spec`). A page is
  its blocks plus markup beside them: each entry covers the blocks from `start` to
  `end`, both included, by their ids. On the wire an entry is
  `{"kind": "border", "start": "rewards", "end": "pending", "props": {...}}`.

  All markup nests, as in XML: two entries share no block, or one covers all of the
  other; entries over the same stretch nest in list order, the first outermost. The
  server never sends markup that doesn't (`view_model/2` raises), and a client leaves
  out an entry that doesn't and still shows the blocks. A client ignores a kind it
  doesn't know, and still renders the blocks and the markup inside it.

  A kind names what a stretch means (`part`) or how it looks (`border`,
  `background`); each client turns a meaning into layout that suits its screen.
  """
  use MicaBff.Schema

  # A line around the blocks it covers, as a card.
  defmarkup :border do
  end

  # A colour token from the design (`grey6`, `primarylight`) behind the blocks it
  # covers. A client draws a token it doesn't know as none.
  defmarkup :background do
    field(:color, :string, required: true)
  end

  # A top-level part of the page: the main part, or a part related to it. A phone
  # shows the parts one after the other; a wider screen may show a related part
  # beside the main one, as a sidebar, or behind a tab.
  defmarkup :part do
    field(:role, {:enum, [:main, :related]}, required: true, fallback: :main)
  end
end
