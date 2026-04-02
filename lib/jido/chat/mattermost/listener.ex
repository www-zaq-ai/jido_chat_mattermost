defmodule Jido.Chat.Mattermost.Listener do
  @moduledoc """
  Supervisor-compatible entry point for the Mattermost WebSocket listener.

  Converts the config URL to a `wss://` URI and starts a Fresh-based
  WebSocket client. Each instance is uniquely identified by `bridge_id`
  so multiple Mattermost configs can coexist in the same node.
  """

  require Logger

  alias Jido.Chat.Mattermost.WebSocket.Client

  def child_spec(opts) do
    bridge_id = Keyword.fetch!(opts, :bridge_id)

    %{
      id: {__MODULE__, bridge_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    uri = build_ws_uri(url)

    state = %{
      token: Keyword.fetch!(opts, :token),
      bot_user_id: Keyword.get(opts, :bot_user_id),
      bot_name: Keyword.get(opts, :bot_name),
      channel_ids: Keyword.get(opts, :channel_ids, :all),
      bridge_id: Keyword.fetch!(opts, :bridge_id),
      oban_worker: Keyword.fetch!(opts, :oban_worker),
      enqueue_fn: Keyword.fetch!(opts, :enqueue_fn),
      config_id: Keyword.fetch!(opts, :config_id)
    }

    Logger.info(
      "[Mattermost Listener] Starting WebSocket connection bridge_id=#{state.bridge_id} uri=#{uri}"
    )

    Fresh.start_link(uri, Client, state, [])
  end

  defp build_ws_uri(url) do
    url
    |> String.replace(~r/^https:\/\//, "wss://")
    |> String.replace(~r/^http:\/\//, "ws://")
    |> Kernel.<>("/api/v4/websocket")
  end
end
