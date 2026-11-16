defmodule MicaBff.Endpoints do
  @moduledoc """
  The BFF's calls besides its pages, with the models they use, part of the spec
  (`MicaBff.Spec`). An endpoint is `<method> /bff/endpoint/<name>`: the client
  sends the request's fields as a JSON object (none for a GET), the server answers
  the response's fields as a JSON object. A request that doesn't match the spec is
  answered with 422 and `{"error": "...", "errors": {"<field>": ["..."]}}`.
  """
  use MicaBff.Schema
end
