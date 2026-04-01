defmodule Jido.Chat.Mattermost.WebSocket.Client do
  @moduledoc """
  Real-time WebSocket client for the Mattermost Events API.

  Connects to `wss://{url}/api/v4/websocket`, authenticates with a bearer token,
  and forwards `posted` events to a configured sink MFA.

  Reconnects automatically with exponential backoff (managed by Fresh).

  ## State keys

    * `:token`        — Mattermost bot bearer token
    * `:bot_user_id`  — bot's Mattermost user ID (used to filter own messages)
    * `:bot_name`     — bot's display name (used for mention detection)
    * `:channel_ids`  — list of channel IDs to process, or `:all`
    * `:sink_mfa`     — `{module, function, base_args}` called with incoming appended
  """

  use Fresh

  require Logger

  alias Jido.Chat.Mattermost.Adapter

  # ---------------------------------------------------------------------------
  # Fresh callbacks
  # ---------------------------------------------------------------------------

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Logger.info("[Mattermost WS] Connected — authenticating")

    auth =
      Jason.encode!(%{
        "seq" => 1,
        "action" => "authentication_challenge",
        "data" => %{"token" => state.token}
      })

    {:reply, [{:text, auth}], state}
  end

  @impl Fresh
  def handle_in({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, %{"event" => "posted"} = event} ->
        handle_posted(event, state)

      {:ok, %{"status" => "OK", "seq_reply" => 1}} ->
        Logger.info("[Mattermost WS] Authenticated successfully")

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Mattermost WS] Failed to decode frame: #{inspect(reason)}")
    end

    {:ok, state}
  end

  @impl Fresh
  def handle_disconnect(code, reason, state) do
    Logger.warning("[Mattermost WS] Disconnected code=#{inspect(code)} reason=#{inspect(reason)} — reconnecting")
    {:reconnect, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp handle_posted(%{"data" => data}, state) do
    with raw_post when is_binary(raw_post) <- Map.get(data, "post"),
         {:ok, post} <- Jason.decode(raw_post),
         true <- should_process?(post, state),
         payload = build_payload(post, data),
         opts = [bot_name: state.bot_name, bot_user_id: state.bot_user_id],
         {:ok, incoming} <- Adapter.transform_incoming(payload, opts) do
      call_sink(state.sink_mfa, incoming)
    else
      false ->
        :skip

      error ->
        Logger.debug("[Mattermost WS] Skipping posted event: #{inspect(error)}")
        :skip
    end
  end

  defp should_process?(post, state) do
    user_id = Map.get(post, "user_id")
    channel_id = Map.get(post, "channel_id")

    not_bot = is_nil(state.bot_user_id) or user_id != state.bot_user_id

    in_channel =
      case state.channel_ids do
        :all -> true
        ids when is_list(ids) -> channel_id in ids
      end

    not_bot and in_channel
  end

  defp build_payload(post, data) do
    %{
      "post" => post,
      "channel_type" => Map.get(data, "channel_type"),
      "channel_display_name" => Map.get(data, "channel_display_name"),
      "sender_name" => Map.get(data, "sender_name"),
      "token" => nil
    }
  end

  defp call_sink({mod, fun, args}, incoming) do
    apply(mod, fun, args ++ [incoming])
  rescue
    e ->
      Logger.error("[Mattermost WS] Sink error: #{Exception.message(e)}")
  end
end
