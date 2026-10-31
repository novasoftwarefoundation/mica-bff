defmodule MicaBffDsl.Test.Catalogue do
  @moduledoc "A small catalogue for the DSL's own tests: one block with props, one without."
  use MicaBffDsl.Schema

  defblock :card do
    field :title, :string, required: true
    field :subtitle, :string
    field :to, :string
  end

  defblock :divider do
  end
end
