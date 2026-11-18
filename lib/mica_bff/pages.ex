defmodule MicaBff.Pages do
  @moduledoc """
  The pages the BFF serves, part of the spec (`MicaBff.Spec`). A page is a GET at
  `/bff/page/<name>` that returns `{"blocks": [...]}`, with its params as query
  parameters.
  """
  use MicaBff.Schema

  # The signed-in user's home: their To-dos, with the first few studies of the
  # marketplace and of their history, each followed by a link to the whole list.
  defpage(:home)

  # Every study the user took part in, as `participation` blocks.
  defpage(:history)

  # Every study open to the user in the marketplace, as `advert` blocks: those
  # published in `year` whose title has every word of `query`.
  defpage :marketplace do
    param(:year, :integer)
    param(:query, :string)
  end
end
