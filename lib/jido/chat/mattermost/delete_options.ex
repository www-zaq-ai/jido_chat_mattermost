defmodule Jido.Chat.Mattermost.DeleteOptions do
  @moduledoc "Options for deleting a Mattermost post."

  defstruct token: nil, transport: nil, url: nil

  @type t :: %__MODULE__{
          token: String.t() | nil,
          transport: module() | nil,
          url: String.t() | nil
        }

  @doc "Builds delete options from a keyword list."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      token: opts[:token],
      transport: opts[:transport],
      url: opts[:url]
    }
  end

  @doc "Extracts transport options for delete requests."
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = o) do
    []
    |> maybe_put(:token, o.token)
    |> maybe_put(:url, o.url)
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: [{k, v} | kw]
end
