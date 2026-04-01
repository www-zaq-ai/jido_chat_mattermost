defmodule Jido.Chat.Mattermost.Listener do
  @moduledoc """
  Supervisor-compatible entry point for the Mattermost WebSocket listener.

  Returned by `Jido.Chat.Mattermost.Adapter.listener_child_specs/2` when
  ingress mode is `"websocket"`. Starts a `WebSocket.Client` that connects
  to the Mattermost real-time events API and forwards `posted` events to
  the configured sink MFA.

  ## Required opts

    * `:url`        — Mattermost base URL (e.g. `"https://mattermost.example.com"`)
    * `:token`      — bot bearer token
    * `:sink_mfa`   — `{module, function, base_args}` called on each incoming message

  ## Optional opts

    * `:bot_user_id`  — filters out the bot's own messages
    * `:bot_name`     — used for mention detection
    * `:channel_ids`  — list of channel IDs to process; defaults to `:all`
    * `:bridge_id`    — used to name the process (allows multiple instances)
  """

  alias Jido.Chat.Mattermost.WebSocket.Client

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :bridge_id, :default)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts) do
    uri = build_ws_uri(Keyword.fetch!(opts, :url))

    state = %{
      token: Keyword.fetch!(opts, :token),
      bot_user_id: Keyword.get(opts, :bot_user_id),
      bot_name: Keyword.get(opts, :bot_name),
      channel_ids: Keyword.get(opts, :channel_ids, :all),
      sink_mfa: Keyword.fetch!(opts, :sink_mfa)
    }

    process_name = process_name(Keyword.get(opts, :bridge_id))

    Fresh.start_link(uri, Client, state, name: {:local, process_name})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_ws_uri(url) do
    url
    |> String.replace(~r/^https:\/\//, "wss://")
    |> String.replace(~r/^http:\/\//, "ws://")
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v4/websocket")
  end

  defp process_name(nil), do: __MODULE__
  defp process_name(bridge_id), do: :"#{__MODULE__}.#{bridge_id}"
end
