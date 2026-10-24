defmodule Jido.Chat.Mattermost.WebSocket.Client do
  @moduledoc """
  Fresh-based WebSocket client for Mattermost event ingestion.

  On each `posted` event the raw Mattermost payload map is forwarded to the
  configured sink via MFA dispatch. The sink receives the raw payload and is
  responsible for dispatching it through `Jido.Chat.Adapter.transform_incoming/2`
  (adapter_module, payload) to normalize into `%Jido.Chat.Incoming{}`.

      apply(module, function, extra_args ++ [payload, sink_opts])

  `reaction_added` and `reaction_removed` events are forwarded as a normalized
  `%Jido.Chat.EventEnvelope{event_type: :reaction}` instead of a raw map, since
  `transform_incoming/2` has no reaction representation to normalize into.

  ## Flow

      Mattermost WS frame
        → handle_in/2 (decode + filter, ~1ms)
          → posted:   raw payload map (post + channel metadata)
          → reaction: %Jido.Chat.EventEnvelope{event_type: :reaction}
          → apply(sink_module, sink_fun, sink_args ++ [payload, sink_opts])
  """

  use Fresh

  alias Jido.Chat.EventEnvelope
  alias Jido.Chat.Mattermost.Adapter

  require Logger

  @doc "Returns the current Mattermost WebSocket authentication status."
  @spec auth_status(pid(), timeout()) :: {:ok, :ok | :pending | :unknown} | {:error, term()}
  def auth_status(pid, timeout \\ 5_000) when is_pid(pid) do
    ref = make_ref()
    monitor_ref = Process.monitor(pid)

    send(pid, {:auth_status, self(), ref})

    receive do
      {^ref, status} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, status}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :timeout}
    end
  end

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    state = Map.put(state, :auth_status, :pending)

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
    case Jason.decode(data) do
      {:ok, event} when is_map(event) ->
        handle_event(event, state)

      {:error, reason} ->
        Logger.warning("[Mattermost WS] JSON decode failed reason=#{inspect(reason)}")
        {:ok, state}
    end
  rescue
    e ->
      Logger.warning("[Mattermost WS] Exception in handle_in: #{Exception.message(e)}")
      {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl Fresh
  def handle_error(error, _state) do
    {:close, {:transport_failed, error}}
  end

  @impl Fresh
  def handle_info({:auth_status, from}, state) when is_pid(from) do
    send(from, {:auth_status, Map.get(state, :auth_status, :unknown)})
    {:ok, state}
  end

  def handle_info({:auth_status, from, ref}, state) when is_pid(from) do
    send(from, {ref, Map.get(state, :auth_status, :unknown)})
    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl Fresh
  def handle_disconnect(code, reason, state) do
    Logger.warning(
      "[Mattermost WS] Disconnected bridge_id=#{state.bridge_id} " <>
        "code=#{inspect(code)} reason=#{inspect(reason)}, reconnecting"
    )

    {:reconnect, state}
  end

  defp handle_event(event, state) do
    case classify_auth_status(event) do
      {:ok, :authenticated} ->
        {:ok, Map.put(state, :auth_status, :ok)}

      {:error, reason} ->
        exit({:auth_failed, reason})

      :not_auth ->
        handle_non_auth_event(event, state)
    end
  end

  defp handle_non_auth_event(%{"event" => "posted"} = event, state) do
    state =
      case handle_posted(event, state) do
        :dispatched -> auth_success_fallback(state)
        _ignored -> state
      end

    {:ok, state}
  end

  defp handle_non_auth_event(%{"event" => reaction_event} = event, state)
       when reaction_event in ["reaction_added", "reaction_removed"] do
    state =
      case handle_reaction(event, reaction_event == "reaction_added", state) do
        :dispatched -> auth_success_fallback(state)
        _ignored -> state
      end

    {:ok, state}
  end

  defp handle_non_auth_event(_event, state), do: {:ok, state}

  defp classify_auth_status(%{"seq_reply" => 1} = event) do
    cond do
      auth_success?(event) -> {:ok, :authenticated}
      auth_failure?(event) -> {:error, auth_failure_reason(event)}
      true -> :not_auth
    end
  end

  defp classify_auth_status(%{"seq_reply" => "1"} = event),
    do: classify_auth_status(Map.put(event, "seq_reply", 1))

  defp classify_auth_status(_event), do: :not_auth

  defp auth_success?(event) do
    event
    |> Map.get("status")
    |> normalize_status()
    |> Kernel.==(:ok)
  end

  defp auth_failure?(event) do
    Map.has_key?(event, "error") or normalize_status(Map.get(event, "status")) == :error
  end

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      "ok" -> :ok
      "success" -> :ok
      "fail" -> :error
      "failed" -> :error
      "error" -> :error
      _ -> :unknown
    end
  end

  defp normalize_status(:ok), do: :ok
  defp normalize_status(:success), do: :ok
  defp normalize_status(:error), do: :error
  defp normalize_status(:fail), do: :error
  defp normalize_status(:failed), do: :error
  defp normalize_status(_status), do: :unknown

  defp auth_failure_reason(%{"error" => error}), do: error
  defp auth_failure_reason(%{"status" => status}), do: status
  defp auth_failure_reason(_event), do: :authentication_failed

  defp auth_success_fallback(%{auth_status: :ok} = state), do: state
  defp auth_success_fallback(state), do: Map.put(state, :auth_status, :ok)

  defp handle_posted(%{"data" => data}, state) do
    channel_type = Map.get(data, "channel_type")

    with {:ok, post} <- decode_post(data),
         true <- not_bot?(post, state),
         true <- in_tracked_channel?(post, channel_type, state) do
      emit_event(data, post, state)
    else
      _ -> :ignored
    end
  end

  defp decode_post(%{"post" => post_json}) when is_binary(post_json) do
    Jason.decode(post_json)
  end

  defp decode_post(_), do: {:error, :missing_post}

  # Mattermost nests the reaction as a JSON string under `data.reaction`, the
  # same way it nests posts, and only carries the channel on the broadcast.
  defp handle_reaction(event, added, state) do
    data = Map.get(event, "data") || %{}
    channel_id = broadcast_channel_id(event)

    with {:ok, reaction} <- decode_reaction(data),
         true <- valid_reaction?(reaction, channel_id),
         post <- reaction_as_post(reaction, channel_id),
         true <- not_bot?(post, state),
         true <- tracked_reaction_channel?(channel_id, Map.get(data, "channel_type"), state) do
      emit_reaction_event(event, reaction, channel_id, added, state)
    else
      _ -> :ignored
    end
  end

  defp decode_reaction(%{"reaction" => reaction_json}) when is_binary(reaction_json) do
    case Jason.decode(reaction_json) do
      {:ok, reaction} when is_map(reaction) -> {:ok, reaction}
      {:ok, _other} -> {:error, :invalid_reaction}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_reaction(%{"reaction" => reaction}) when is_map(reaction), do: {:ok, reaction}

  defp decode_reaction(_), do: {:error, :missing_reaction}

  defp valid_reaction?(reaction, channel_id) do
    Enum.all?(
      [channel_id, reaction["post_id"], reaction["user_id"], reaction["emoji_name"]],
      &(is_binary(&1) and byte_size(&1) > 0)
    )
  end

  defp tracked_reaction_channel?(_channel_id, _channel_type, %{channel_ids: :all}),
    do: true

  defp tracked_reaction_channel?(channel_id, channel_type, %{channel_ids: ids} = state)
       when is_list(ids) do
    channel_id in ids or direct_reaction_channel?(channel_id, channel_type, state)
  end

  defp tracked_reaction_channel?(_channel_id, _channel_type, _state), do: false

  defp direct_reaction_channel?(_channel_id, type, _state) when type in ["D", "G"],
    do: true

  defp direct_reaction_channel?(channel_id, nil, state) do
    # Reaction broadcasts omit channel_type. Resolve it even when this is the
    # first event after startup/reconnect; no preceding post or cache is needed.
    case Adapter.fetch_metadata(channel_id, Map.get(state, :metadata_opts, [])) do
      {:ok, %{metadata: %{"id" => ^channel_id, "type" => type}}} when type in ["D", "G"] ->
        true

      _ ->
        false
    end
  rescue
    # Malformed metadata and transport exceptions must not grant eligibility or
    # expose credentials through the outer frame handler's exception logging.
    _ -> false
  end

  defp direct_reaction_channel?(_channel_id, _type, _state), do: false

  # Lets reactions reuse the bot and tracked-channel filters built for posts.
  defp reaction_as_post(reaction, channel_id) do
    %{"user_id" => Map.get(reaction, "user_id"), "channel_id" => channel_id}
  end

  defp broadcast_channel_id(event) do
    event
    |> Map.get("broadcast", %{})
    |> case do
      broadcast when is_map(broadcast) -> Map.get(broadcast, "channel_id")
      _ -> nil
    end
  end

  defp emit_reaction_event(event, reaction, channel_id, added, state) do
    post_id = Map.get(reaction, "post_id")
    user_id = Map.get(reaction, "user_id")
    emoji = Map.get(reaction, "emoji_name")
    thread_id = "mattermost:#{channel_id}"

    envelope =
      EventEnvelope.new(%{
        adapter_name: :mattermost,
        event_type: :reaction,
        thread_id: thread_id,
        channel_id: channel_id,
        message_id: post_id,
        payload: %{
          adapter_name: :mattermost,
          thread_id: thread_id,
          channel_id: channel_id,
          message_id: post_id,
          emoji: emoji,
          added: added,
          user: %{user_id: user_id},
          raw: reaction,
          metadata: %{channel_id: channel_id}
        },
        raw: event,
        metadata: %{source: :websocket, ws_event: Map.get(event, "event")}
      })

    sink_opts = Keyword.put(state.sink_opts, :transport, "websocket")
    invoke_sink(state.sink_mfa, envelope, sink_opts)

    Logger.info(
      "[Mattermost WS] Reaction event dispatched post_id=#{post_id} " <>
        "emoji=#{inspect(emoji)} added=#{added}"
    )

    :dispatched
  end

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

  defp emit_event(data, post, state) do
    payload = %{
      "post" => post,
      "channel_type" => Map.get(data, "channel_type"),
      "channel_display_name" => Map.get(data, "channel_display_name")
    }

    sink_opts = Keyword.put(state.sink_opts, :transport, "websocket")
    invoke_sink(state.sink_mfa, payload, sink_opts)

    Logger.info(
      "[Mattermost WS] Posted event dispatched post_id=#{post["id"]} " <>
        "root_id=#{inspect(post["root_id"])}"
    )

    :dispatched
  end

  defp invoke_sink({module, function, extra_args}, incoming, sink_opts) do
    apply(module, function, extra_args ++ [incoming, sink_opts])
  end
end
