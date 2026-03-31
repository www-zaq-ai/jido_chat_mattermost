defmodule Jido.Chat.Mattermost.SendOptions do
  @moduledoc "Options for sending a Mattermost post."

  defstruct thread_id: nil, token: nil, transport: nil, url: nil

  @type t :: %__MODULE__{
          thread_id: String.t() | nil,
          token: String.t() | nil,
          transport: module() | nil,
          url: String.t() | nil
        }

  @doc "Build a `SendOptions` from a keyword list."
  def new(opts \\ []) do
    %__MODULE__{
      thread_id: opts[:thread_id],
      token: opts[:token],
      transport: opts[:transport],
      url: opts[:url]
    }
  end

  @doc "Extract the keyword opts the transport layer needs."
  def transport_opts(%__MODULE__{} = o) do
    []
    |> maybe_put(:thread_id, o.thread_id)
    |> maybe_put(:token, o.token)
    |> maybe_put(:url, o.url)
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: [{k, v} | kw]
end
