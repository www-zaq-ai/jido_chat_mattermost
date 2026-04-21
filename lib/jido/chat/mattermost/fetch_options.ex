defmodule Jido.Chat.Mattermost.FetchOptions do
  @moduledoc "Options for fetching Mattermost posts / history."

  defstruct limit: 60,
            before: nil,
            after: nil,
            direction: :desc,
            token: nil,
            transport: nil,
            url: nil

  @type t :: %__MODULE__{
          limit: pos_integer(),
          before: String.t() | nil,
          after: String.t() | nil,
          direction: :asc | :desc,
          token: String.t() | nil,
          transport: module() | nil,
          url: String.t() | nil
        }

  @doc "Builds fetch options from a keyword list."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      limit: opts[:limit] || 60,
      before: opts[:before],
      after: opts[:after],
      direction: opts[:direction] || :desc,
      token: opts[:token],
      transport: opts[:transport],
      url: opts[:url]
    }
  end

  @doc "Extracts transport options for fetch requests."
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = o) do
    []
    |> maybe_put(:limit, o.limit)
    |> maybe_put(:before, o.before)
    |> maybe_put(:after, o.after)
    |> maybe_put(:token, o.token)
    |> maybe_put(:url, o.url)
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: [{k, v} | kw]
end
