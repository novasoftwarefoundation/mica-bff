defmodule MicaBff.Pages do
  @moduledoc """
  The pages the BFF serves, half of the spec (`MicaBff.Spec`). A page is a GET
  at `/bff/page/<name>` that returns `{"blocks": [...]}`.
  """
  use MicaBff.Schema

  # The signed-in user's home: their To-dos, with the first few studies of the
  # marketplace and of their history, each followed by a link to the whole list.
  defpage(:home)

  # Every study the user took part in, as `participation` blocks.
  defpage(:history)

  # Every study open to the user in the marketplace, as `advert` blocks.
  defpage(:marketplace)
end
