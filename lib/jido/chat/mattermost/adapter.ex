defmodule Jido.Chat.Mattermost.Adapter do
  @moduledoc """
  `Jido.Chat.Adapter` implementation for Mattermost.

  Uses the Mattermost REST API v4 via the injectable `Jido.Chat.Mattermost.Transport`
  behaviour.  The default transport is `Jido.Chat.Mattermost.Transport.ReqClient`.

  ## Configuration

  Set globally via application env:

      config :jido_chat_mattermost,
        url: "https://mattermost.example.com",
        token: "your-bot-token"

  Or pass per-call via `opts`:

      Adapter.send_message(channel_id, text, token: "...", url: "...")

  ## Ingress

  Mattermost uses outgoing webhooks — no persistent socket worker is needed.
  Configure your Mattermost server to POST to your app's HTTP endpoint, then
  call `transform_incoming/1` on the raw payload.
  """

  @behaviour Jido.Chat.Adapter

  alias Jido.Chat.{ChannelMeta, EventEnvelope, Incoming, Mention, WebhookRequest, WebhookResponse}
  alias Jido.Chat.Mattermost.Transport.ReqClient

  # --- Adapter identity ---

  @impl true
  def channel_type, do: :mattermost

  @impl true
  def capabilities do
    %{
      send_message: :native,
      edit_message: :native,
      delete_message: :native,
      start_typing: :native,
      fetch_metadata: :native,
      fetch_thread: :native,
      fetch_message: :native,
      add_reaction: :native,
      remove_reaction: :native,
      fetch_messages: :native,
      fetch_channel_messages: :native,
      post_ephemeral: :unsupported,
      open_dm: :unsupported,
      list_threads: :unsupported,
      open_modal: :unsupported,
      webhook: :fallback,
      verify_webhook: :native,
      initialize: :fallback,
      shutdown: :fallback,
      post_channel_message: :fallback,
      stream: :fallback,
      parse_event: :native,
      format_webhook_response: :native
    }
  end

  # --- Incoming payload normalization ---

  @impl true
  def transform_incoming(payload) when is_map(payload) do
    post = Map.get(payload, "post", %{})

    text = Map.get(post, "message", "")
    user_id = Map.get(post, "user_id")
    channel_id = Map.get(post, "channel_id")
    post_id = Map.get(post, "id")
    root_id = Map.get(post, "root_id")
    channel_type = Map.get(payload, "channel_type")
    channel_display_name = Map.get(payload, "channel_display_name")
    metadata = Map.get(post, "metadata", %{})

    media = extract_media(metadata)
    {was_mentioned, mentions} = extract_mentions(payload, post, text)

    incoming =
      Incoming.new(%{
        text: text,
        external_user_id: user_id,
        external_room_id: channel_id,
        external_message_id: post_id,
        external_thread_id: nilify(root_id),
        chat_title: channel_display_name,
        chat_type: mattermost_channel_type(channel_type),
        media: media,
        was_mentioned: was_mentioned,
        mentions: mentions,
        raw: payload,
        channel_meta: %ChannelMeta{
          adapter_name: :mattermost,
          external_room_id: channel_id,
          external_thread_id: nilify(root_id),
          chat_type: mattermost_channel_type(channel_type),
          chat_title: channel_display_name,
          is_dm: channel_type == "D"
        }
      })

    {:ok, incoming}
  end

  def transform_incoming(_payload), do: {:error, :invalid_payload}

  # --- Send / Edit / Delete ---

  @impl true
  def send_message(channel_id, text, opts \\ []) do
    transport(opts).send_message(channel_id, text, transport_opts(opts))
  end

  @impl true
  def edit_message(channel_id, post_id, text, opts \\ []) do
    transport(opts).edit_message(channel_id, post_id, text, transport_opts(opts))
  end

  @impl true
  def delete_message(channel_id, post_id, opts \\ []) do
    transport(opts).delete_message(channel_id, post_id, transport_opts(opts))
  end

  # --- Typing ---

  @impl true
  def start_typing(channel_id, opts \\ []) do
    transport(opts).send_typing(channel_id, transport_opts(opts))
  end

  # --- Metadata ---

  @impl true
  def fetch_metadata(channel_id, opts \\ []) do
    transport(opts).fetch_channel(channel_id, transport_opts(opts))
  end

  # --- Thread / Message fetch ---

  @impl true
  def fetch_thread(root_id, opts \\ []) do
    transport(opts).fetch_thread(root_id, transport_opts(opts))
  end

  @impl true
  def fetch_message(_channel_id, post_id, opts \\ []) do
    transport(opts).fetch_post(post_id, transport_opts(opts))
  end

  # --- Reactions ---

  @impl true
  def add_reaction(_channel_id, post_id, emoji, opts \\ []) do
    transport(opts).add_reaction(post_id, emoji, transport_opts(opts))
  end

  @impl true
  def remove_reaction(_channel_id, post_id, emoji, opts \\ []) do
    user_id = opts[:user_id] || raise ":user_id is required for remove_reaction"
    transport(opts).remove_reaction(post_id, emoji, user_id, transport_opts(opts))
  end

  # --- Message history ---

  @impl true
  def fetch_messages(channel_id, opts \\ []) do
    transport(opts).fetch_posts(channel_id, transport_opts(opts))
  end

  @impl true
  def fetch_channel_messages(channel_id, opts \\ []) do
    fetch_messages(channel_id, opts)
  end

  # --- Listener / ingress ---

  @impl true
  def listener_child_specs(_bridge_id, opts) do
    mode = get_in(opts, [:ingress, :mode]) || get_in(opts, [:settings, :mode]) || "webhook"

    case mode do
      "webhook" ->
        # Mattermost delivers events via outgoing webhook HTTP POST.
        # No persistent socket or listener process is needed — the host
        # application handles the HTTP endpoint.
        {:ok, []}

      other ->
        {:error, {:unsupported_ingress_mode, other}}
    end
  end

  # --- Event parsing ---

  @impl true
  def parse_event(%WebhookRequest{payload: payload}, opts),
    do: parse_event(payload, opts)

  def parse_event(payload, _opts) when is_map(payload) do
    post = Map.get(payload, "post", %{})

    cond do
      Map.has_key?(payload, "command") ->
        {:ok,
         EventEnvelope.new(%{
           adapter_name: :mattermost,
           event_type: :slash_command,
           channel_id: Map.get(payload, "channel_id"),
           payload: payload,
           raw: payload
         })}

      Map.has_key?(payload, "post") ->
        {:ok,
         EventEnvelope.new(%{
           adapter_name: :mattermost,
           event_type: :message,
           thread_id: nilify(Map.get(post, "root_id")),
           channel_id: Map.get(post, "channel_id"),
           message_id: Map.get(post, "id"),
           payload: payload,
           raw: payload
         })}

      true ->
        {:ok, :noop}
    end
  end

  def parse_event(_payload, _opts), do: {:ok, :noop}

  # --- Webhook response formatting ---

  @impl true
  def format_webhook_response(result, _opts) do
    case result do
      {:ok, text} when is_binary(text) ->
        WebhookResponse.accepted(%{"text" => text, "response_type" => "in_channel"})

      {:ok, %{"text" => _} = body} ->
        WebhookResponse.accepted(body)

      :ok ->
        WebhookResponse.accepted()

      {:error, reason} ->
        WebhookResponse.error(500, inspect(reason))

      _ ->
        WebhookResponse.accepted()
    end
  end

  # --- Webhook verification ---

  @impl true
  def verify_webhook(%WebhookRequest{payload: payload}, opts),
    do: verify_webhook(payload, opts)

  def verify_webhook(payload, opts) when is_map(payload) do
    expected = opts[:token] || Application.get_env(:jido_chat_mattermost, :token)

    case Map.get(payload, "token") do
      ^expected when not is_nil(expected) -> :ok
      _ -> {:error, :invalid_webhook_token}
    end
  end

  def verify_webhook(_payload, _opts), do: {:error, :invalid_payload}

  # --- Private helpers ---

  defp transport(opts), do: opts[:transport] || ReqClient

  defp transport_opts(opts) do
    Keyword.take(opts, [:token, :url, :thread_id, :user_id, :limit, :before, :after])
  end

  defp extract_media(%{"files" => files}) when is_list(files) do
    Enum.map(files, fn file ->
      %Jido.Chat.Media{
        url: Map.get(file, "link") || Map.get(file, "permalink"),
        filename: Map.get(file, "name"),
        media_type: Map.get(file, "mime_type")
      }
    end)
  end

  defp extract_media(_), do: []

  defp nilify(v) when v in [nil, ""], do: nil
  defp nilify(v), do: v

  defp mattermost_channel_type("D"), do: :dm
  defp mattermost_channel_type("P"), do: :private
  defp mattermost_channel_type("O"), do: :public
  defp mattermost_channel_type(_), do: :channel

  defp extract_mentions(payload, post, text) do
    bot_name = Application.get_env(:jido_chat_mattermost, :bot_name)
    bot_user_id = Application.get_env(:jido_chat_mattermost, :bot_user_id)
    trigger_word = Map.get(payload, "trigger_word", "")

    user_ids =
      post
      |> Map.get("props", %{})
      |> Map.get("mentions", [])
      |> List.wrap()

    was_mentioned =
      (bot_name && String.contains?(text, "@#{bot_name}")) ||
        (trigger_word != "" && String.contains?(text, trigger_word)) ||
        (bot_user_id && bot_user_id in user_ids) ||
        user_ids != []

    mentions =
      Enum.map(user_ids, fn uid ->
        %Mention{
          user_id: uid,
          is_self: uid == bot_user_id,
          mention_text: "@#{uid}"
        }
      end)

    {was_mentioned, mentions}
  end
end
