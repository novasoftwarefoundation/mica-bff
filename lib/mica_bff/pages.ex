defmodule MicaBff.Pages do
  @moduledoc """
  The pages the BFF serves, half of the spec (`MicaBff.Spec`). A page is a GET
  at `/bff/page/<name>` that returns `{"blocks": [...]}`.
  """
  use MicaBff.Schema

  # The signed-in user's home: their To-dos.
  defpage(:home)
end
