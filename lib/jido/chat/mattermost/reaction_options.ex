defmodule Jido.Chat.Mattermost.ReactionOptions do
  @moduledoc "Options for adding/removing Mattermost reactions."

  defstruct user_id: nil, token: nil, transport: nil, url: nil

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          token: String.t() | nil,
          transport: module() | nil,
          url: String.t() | nil
        }

  @doc "Builds reaction options from a keyword list."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      user_id: opts[:user_id],
      token: opts[:token],
      transport: opts[:transport],
      url: opts[:url]
    }
  end

  @doc "Extracts transport options for reaction requests."
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = o) do
    []
    |> maybe_put(:user_id, o.user_id)
    |> maybe_put(:token, o.token)
    |> maybe_put(:url, o.url)
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: [{k, v} | kw]
end
