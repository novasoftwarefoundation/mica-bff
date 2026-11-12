defmodule MicaBff.Blocks do
  @moduledoc """
  Every block the BFF can send and every client can render, half of the spec
  (`MicaBff.Spec`). On the wire a block is `{"type": "section", "props": {...}}`.

  A destination (`to`) or an image (`image_url`, `logo_url`) is a path or an
  absolute URL, resolved against the app's base URL. The client's router decides
  what opens a destination (native page, BFF page or web page) and how it is
  presented.
  """
  use MicaBff.Schema

  # A status colour: Prism's tag tones. A client shows a tone it doesn't know as neutral.
  @tone {:enum, [:accent, :success, :warning, :danger, :neutral]}

  # Plain text: an optional title and an optional body. With `to` it is tappable:
  # the client shows a chevron and opens `to` on tap. With `count` it is a heading
  # with a number next to the title ("History 3"); `image_url` is an image beside
  # it, such as a pool's logo.
  defblock :section do
    field(:title, :string)
    field(:body, :string)
    field(:to, :string)
    field(:count, :integer)
    field(:image_url, :string)
  end

  # The one thing the user should do next, highlighted, with a button (`cta`) that
  # opens `to`.
  defblock :next_best_action do
    field(:title, :string, required: true)
    field(:body, :string)
    field(:cta, :string)
    field(:to, :string)
  end

  # The rewards card: the user's totals per status in one card. Every amount is
  # already formatted by the server ("€ 2,50") and has its status label; the client
  # shows pending as warning, approved as success and rejected as danger. Rejected
  # is left out when there is none. `notes` are lines under the totals, such as a
  # payout being processed or the donated total.
  defblock :rewards do
    field(:title, :string, required: true)
    field(:pending_label, :string, required: true)
    field(:pending_amount, :string, required: true)
    field(:pending_caption, :string)
    field(:approved_label, :string, required: true)
    field(:approved_amount, :string, required: true)
    field(:approved_caption, :string)
    field(:rejected_label, :string)
    field(:rejected_amount, :string)
    field(:notes, {:list, :string})
  end

  # A study in the marketplace: its image, the logo of who runs it, its themes as
  # tags and a line of info ("Duration: 10 min. | Reward: € 2,00"). Opens `to`.
  defblock :advert do
    field(:title, :string, required: true)
    field(:to, :string, required: true)
    field(:image_url, :string)
    field(:logo_url, :string)
    field(:tags, {:list, :string})
    field(:info, :string)
  end

  # A study the user took part in: its status in a tag of `status_tone` and the
  # reward, already formatted ("Reward € 2,50"). Opens `to`.
  defblock :participation do
    field(:title, :string, required: true)
    field(:subtitle, :string)
    field(:status_label, :string)
    field(:status_tone, @tone, fallback: :neutral)
    field(:reward, :string)
    field(:to, :string)
  end
end
