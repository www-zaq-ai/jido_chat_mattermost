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

  Mattermost ingress uses a persistent WebSocket connection. Start a listener
  via `Jido.Chat.Mattermost.Listener.child_spec/1` with a `sink_mfa` that
  receives normalized `%Incoming{}` structs.
  """

  use Jido.Chat.Adapter

  require Logger

  alias Jido.Chat.Mattermost.{
    DeleteOptions,
    EditOptions,
    FetchOptions,
    MetadataOptions,
    ReactionOptions,
    SendOptions,
    Transport.ReqClient,
    TypingOptions
  }

  alias Jido.Chat.{ChannelInfo, Mention, Response, Thread}

  # --- Adapter identity ---

  @impl true
  def channel_type, do: :mattermost

  @impl true
  def capabilities do
    %{
      initialize: :fallback,
      shutdown: :fallback,
      send_message: :native,
      send_file: :unsupported,
      post_message: :fallback,
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
      open_dm: :native,
      list_threads: :unsupported,
      open_modal: :unsupported,
      open_thread: :native,
      webhook: :unsupported,
      verify_webhook: :unsupported,
      post_channel_message: :fallback,
      stream: :fallback,
      parse_event: :unsupported,
      format_webhook_response: :unsupported
    }
  end

  # --- Incoming payload normalization ---

  @impl true
  def transform_incoming(%{"post" => post} = payload) when is_map(post) do
    text = Map.get(post, "message", "")
    user_id = Map.get(post, "user_id")
    channel_id = Map.get(post, "channel_id")
    post_id = Map.get(post, "id")
    root_id = nilify(Map.get(post, "root_id"))
    metadata = Map.get(post, "metadata", %{})

    channel_type = Map.get(payload, "channel_type")
    channel_display_name = Map.get(payload, "channel_display_name")

    media = extract_media(metadata)
    {was_mentioned, mentions} = extract_mentions(payload, post, text)

    bot_user_id = Application.get_env(:jido_chat_mattermost, :bot_user_id)

    {:ok,
     %{
       text: text,
       external_user_id: user_id,
       author: %{
         user_id: user_id || "",
         user_name: user_id || "",
         is_me: is_binary(user_id) && user_id == bot_user_id
       },
       external_room_id: channel_id,
       external_message_id: post_id,
       external_thread_id: root_id,
       chat_title: channel_display_name,
       chat_type: mattermost_channel_type(channel_type),
       media: media,
       was_mentioned: was_mentioned,
       mentions: mentions,
       raw: payload,
       channel_meta: %{
         adapter_name: :mattermost,
         external_room_id: channel_id,
         external_thread_id: root_id,
         chat_type: mattermost_channel_type(channel_type),
         chat_title: channel_display_name,
         is_dm: channel_type == "D"
       }
     }}
  end

  def transform_incoming(%{"channel_id" => channel_id, "user_id" => user_id} = payload)
      when is_binary(channel_id) and is_binary(user_id) do
    text = Map.get(payload, "text", "")
    post_id = Map.get(payload, "post_id")
    root_id = nilify(Map.get(payload, "root_id"))
    channel_type = Map.get(payload, "channel_type")
    channel_display_name = Map.get(payload, "channel_display_name")

    {:ok,
     %{
       text: text,
       external_user_id: user_id,
       external_room_id: channel_id,
       external_message_id: post_id,
       external_thread_id: root_id,
       chat_title: channel_display_name,
       chat_type: mattermost_channel_type(channel_type),
       media: [],
       was_mentioned: false,
       mentions: [],
       raw: payload,
       channel_meta: %{
         adapter_name: :mattermost,
         external_room_id: channel_id,
         external_thread_id: root_id,
         chat_type: mattermost_channel_type(channel_type),
         chat_title: channel_display_name,
         is_dm: channel_type == "D"
       }
     }}
  end

  def transform_incoming(_payload), do: {:error, :invalid_payload}

  # --- Send / Edit / Delete ---

  @impl true
  def send_message(channel_id, text, opts \\ []) do
    o = SendOptions.new(opts)

    with {:ok, result} <-
           transport(o).send_message(channel_id, text, SendOptions.transport_opts(o)) do
      {:ok, response_from_post(result, channel_id, :sent)}
    end
  end

  @impl true
  def edit_message(channel_id, post_id, text, opts \\ []) do
    o = EditOptions.new(opts)

    with {:ok, result} <-
           transport(o).edit_message(channel_id, post_id, text, EditOptions.transport_opts(o)) do
      {:ok, response_from_post(result, channel_id, :edited, post_id)}
    end
  end

  @impl true
  def delete_message(channel_id, post_id, opts \\ []) do
    o = DeleteOptions.new(opts)
    transport(o).delete_message(channel_id, post_id, DeleteOptions.transport_opts(o))
  end

  # --- Typing ---

  @impl true
  def start_typing(channel_id, opts \\ []) do
    o = TypingOptions.new(opts)
    transport(o).send_typing(channel_id, TypingOptions.transport_opts(o))
  end

  # --- Metadata ---

  @impl true
  def fetch_metadata(channel_id, opts \\ []) do
    o = MetadataOptions.new(opts)

    with {:ok, channel} <-
           transport(o).fetch_channel(channel_id, MetadataOptions.transport_opts(o)) do
      {:ok,
       ChannelInfo.new(%{
         id: stringify(channel["id"] || channel_id),
         name: channel["display_name"] || channel["name"],
         is_dm: channel["type"] == "D",
         member_count: channel["member_count"],
         metadata: channel
       })}
    end
  end

  # --- Thread / Message fetch ---

  @impl true
  def fetch_thread(root_id, opts \\ []) do
    o = FetchOptions.new(opts)

    with {:ok, thread} <- transport(o).fetch_thread(root_id, FetchOptions.transport_opts(o)) do
      {:ok,
       Thread.new(%{
         id: default_thread_id(nil, root_id),
         adapter_name: :mattermost,
         adapter: __MODULE__,
         external_room_id: opts[:channel_id],
         external_thread_id: root_id,
         channel_id: opts[:channel_id],
         metadata: thread
       })}
    end
  end

  @impl true
  def fetch_message(_channel_id, post_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).fetch_post(post_id, FetchOptions.transport_opts(o))
  end

  @impl true
  def open_thread(channel_id, post_id, opts \\ []) do
    o = FetchOptions.new(opts)

    with {:ok, post} <- transport(o).fetch_post(post_id, FetchOptions.transport_opts(o)) do
      external_thread_id = nilify(post["root_id"]) || stringify(post["id"]) || stringify(post_id)

      {:ok,
       Thread.new(%{
         id: default_thread_id(channel_id, external_thread_id),
         adapter_name: :mattermost,
         adapter: __MODULE__,
         external_room_id: channel_id,
         external_thread_id: external_thread_id,
         channel_id: channel_id,
         metadata: %{root_post: post}
       })}
    end
  end

  # --- Reactions ---

  @impl true
  def add_reaction(_channel_id, post_id, emoji, opts \\ []) do
    o = ReactionOptions.new(opts)
    transport(o).add_reaction(post_id, emoji, ReactionOptions.transport_opts(o))
  end

  @impl true
  def remove_reaction(_channel_id, post_id, emoji, opts \\ []) do
    o = ReactionOptions.new(opts)
    user_id = o.user_id || raise ":user_id is required for remove_reaction"
    transport(o).remove_reaction(post_id, emoji, user_id, ReactionOptions.transport_opts(o))
  end

  # --- Message history ---

  @impl true
  def fetch_messages(channel_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).fetch_posts(channel_id, FetchOptions.transport_opts(o))
  end

  @impl true
  def fetch_channel_messages(channel_id, opts \\ []) do
    fetch_messages(channel_id, opts)
  end

  # --- User profile ---

  def get_user(user_id, opts \\ []) do
    o = FetchOptions.new(opts)

    with {:ok, user} <- transport(o).get_user(user_id, FetchOptions.transport_opts(o)) do
      display_name =
        [user["first_name"], user["last_name"]]
        |> Enum.reject(&(is_nil(&1) || &1 == ""))
        |> Enum.join(" ")
        |> case do
          "" -> user["username"]
          name -> name
        end

      {:ok, Map.put(user, "display_name", display_name)}
    end
  end

  # --- DM channel ---

  @doc "Opens or returns the existing DM channel between the bot and a target user."
  def open_dm_channel(bot_user_id, target_user_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).open_dm_channel(bot_user_id, target_user_id, FetchOptions.transport_opts(o))
  end

  @impl true
  def open_dm(target_user_id, opts \\ []) do
    bot_user_id =
      Keyword.get(opts, :bot_user_id) || Application.get_env(:jido_chat_mattermost, :bot_user_id)

    with bot_user_id when is_binary(bot_user_id) and bot_user_id != "" <- bot_user_id,
         {:ok, channel} <- open_dm_channel(bot_user_id, target_user_id, opts),
         channel_id when is_binary(channel_id) and channel_id != "" <- channel["id"] do
      {:ok, channel_id}
    else
      nil -> {:error, :bot_user_id_required}
      "" -> {:error, :bot_user_id_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_dm_channel}
    end
  end

  # --- Listener / ingress ---

  @impl true
  def listener_child_specs(bridge_id, opts) do
    opts = Keyword.put_new(opts, :bridge_id, bridge_id)
    {:ok, [Jido.Chat.Mattermost.Listener.child_spec(opts)]}
  end

  # --- Private helpers ---

  defp transport(%{transport: mod}) when not is_nil(mod), do: mod
  defp transport(_), do: ReqClient

  defp response_from_post(post, channel_id, status, fallback_post_id \\ nil) do
    Response.new(%{
      external_message_id: post["id"] || fallback_post_id,
      external_room_id: post["channel_id"] || channel_id,
      channel_type: :mattermost,
      status: status,
      raw: post,
      metadata: %{
        root_id: nilify(post["root_id"])
      }
    })
  end

  defp default_thread_id(nil, external_thread_id), do: "mattermost:thread:#{external_thread_id}"

  defp default_thread_id(channel_id, external_thread_id),
    do: "mattermost:#{channel_id}:#{external_thread_id}"

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

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)

  defp mattermost_channel_type("D"), do: :dm
  defp mattermost_channel_type("P"), do: :private
  defp mattermost_channel_type("O"), do: :public
  defp mattermost_channel_type(_), do: :channel

  defp extract_mentions(_payload, post, text) do
    bot_name = Application.get_env(:jido_chat_mattermost, :bot_name)
    bot_user_id = Application.get_env(:jido_chat_mattermost, :bot_user_id)

    user_ids =
      post
      |> Map.get("props", %{})
      |> Map.get("mentions", [])
      |> List.wrap()

    was_mentioned =
      (bot_name && String.contains?(text, "@#{bot_name}")) ||
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
