defmodule Jido.Chat.Mattermost.WebSocket.Client do
  @moduledoc """
  Fresh-based WebSocket client for Mattermost event ingestion.

  This is the hot path — must return in ~1-2ms per frame. All heavy
  work (ChatBridge routing, PendingQuestions, gap resolution) is
  offloaded to a job worker enqueued here.

  The caller is responsible for providing `oban_worker` (a module with a
  `new/1` function that builds a job struct) and `enqueue_fn` (a 1-arity
  function that enqueues the job, e.g. `&Oban.insert/1`).

  ## Flow

      Mattermost WS frame
        → handle_in/2 (decode + filter, ~1ms)
          → enqueue_fn.(oban_worker.new(payload))
            → IncomingWebSocketWorker.perform/1 (async, durable)
  """

  use Fresh

  require Logger

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    auth =
      Jason.encode!(%{
        seq: 1,
        action: "authentication_challenge",
        data: %{token: state.token}
      })

    Logger.info("[Mattermost WS] Connected bridge_id=#{state.bridge_id}, sending auth")
    {:reply, [{:text, auth}], state}
  end

  @impl Fresh
  def handle_in({:text, data}, state) do
    try do
      case Jason.decode(data) do
        {:ok, %{"event" => "posted"} = event} ->
          handle_posted(event, state)
          {:ok, state}

        {:ok, _event} ->
          {:ok, state}

        {:error, reason} ->
          Logger.warning("[Mattermost WS] JSON decode failed reason=#{inspect(reason)}")
          {:ok, state}
      end
    rescue
      e ->
        Logger.warning("[Mattermost WS] Exception in handle_in: #{Exception.message(e)}")
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl Fresh
  def handle_disconnect(code, reason, state) do
    Logger.warning(
      "[Mattermost WS] Disconnected bridge_id=#{state.bridge_id} " <>
        "code=#{inspect(code)} reason=#{inspect(reason)}, reconnecting"
    )

    {:reconnect, state}
  end

  defp handle_posted(%{"data" => data}, state) do
    channel_type = Map.get(data, "channel_type")

    with {:ok, post} <- decode_post(data),
         true <- not_bot?(post, state),
         true <- in_tracked_channel?(post, channel_type, state) do
      enqueue_job(post, state)
    end
  end

  defp decode_post(%{"post" => post_json}) when is_binary(post_json) do
    Jason.decode(post_json)
  end

  defp decode_post(_), do: {:error, :missing_post}

  defp not_bot?(post, %{bot_user_id: bot_user_id}) when is_binary(bot_user_id) do
    post["user_id"] != bot_user_id
  end

  defp not_bot?(_post, _state), do: true

  # DM ("D") and group DM ("G") channels are always tracked — their IDs are
  # dynamic and never registered in the retrieval_channels allowlist.
  defp in_tracked_channel?(_post, channel_type, _state) when channel_type in ["D", "G"], do: true
  defp in_tracked_channel?(_post, _channel_type, %{channel_ids: :all}), do: true

  defp in_tracked_channel?(post, _channel_type, %{channel_ids: channel_ids})
       when is_list(channel_ids) do
    post["channel_id"] in channel_ids
  end

  defp in_tracked_channel?(_post, _channel_type, _state), do: true

  defp enqueue_job(post, state) do
    payload = %{
      "config_id" => state.config_id,
      "bridge_id" => state.bridge_id,
      "post" => post
    }

    job = apply(state.oban_worker, :new, [payload])

    case state.enqueue_fn.(job) do
      {:ok, _} ->
        Logger.info(
          "[Mattermost WS] Posted event enqueued post_id=#{post["id"]} " <>
            "root_id=#{inspect(post["root_id"])}"
        )

      {:error, reason} ->
        Logger.error("[Mattermost WS] Failed to enqueue job reason=#{inspect(reason)}")
    end
  end
end
