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
    Listener,
    MetadataOptions,
    ReactionOptions,
    SendOptions,
    Transport.ReqClient,
    TypingOptions
  }

  alias Jido.Chat.{FileUpload, Media, Mention, Response}

  # --- Adapter identity ---

  @impl true
  def channel_type, do: :mattermost

  @impl true
  def capabilities do
    %{
      send_message: :native,
      send_file: :native,
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
      webhook: :unsupported,
      verify_webhook: :unsupported,
      initialize: :fallback,
      shutdown: :fallback,
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
  def send_file(channel_id, file, opts \\ []) do
    upload = FileUpload.normalize(file)
    o = SendOptions.new(opts)
    transport_opts = SendOptions.transport_opts(o)

    with {:ok, upload_input} <- upload_input(upload),
         {:ok, upload_result} <-
           transport(o).upload_file(channel_id, upload_input, transport_opts),
         {:ok, file_ids} <- uploaded_file_ids_result(upload_result),
         {:ok, post_result} <-
           transport(o).send_message(
             channel_id,
             upload_caption(upload, opts),
             Keyword.put(transport_opts, :file_ids, file_ids)
           ) do
      {:ok, upload_response(upload, upload_result, post_result, channel_id)}
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
    transport(o).fetch_channel(channel_id, MetadataOptions.transport_opts(o))
  end

  # --- Thread / Message fetch ---

  @impl true
  def fetch_thread(root_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).fetch_thread(root_id, FetchOptions.transport_opts(o))
  end

  @impl true
  def fetch_message(_channel_id, post_id, opts \\ []) do
    o = FetchOptions.new(opts)
    transport(o).fetch_post(post_id, FetchOptions.transport_opts(o))
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

  # --- Listener / ingress ---

  @impl true
  def listener_child_specs(bridge_id, opts) do
    opts = Keyword.put_new(opts, :bridge_id, bridge_id)
    {:ok, [Listener.child_spec(opts)]}
  end

  # --- Private helpers ---

  defp transport(%{transport: mod}) when not is_nil(mod), do: mod
  defp transport(_), do: ReqClient

  defp extract_media(%{"files" => files}) when is_list(files) do
    files
    |> Enum.map(&normalize_file_media/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_media(_), do: []

  defp response_from_post(post, channel_id, status, fallback_post_id \\ nil) do
    Response.new(%{
      external_message_id: map_get(post, ["id", :id]) || fallback_post_id,
      external_room_id: map_get(post, ["channel_id", :channel_id]) || channel_id,
      channel_type: :mattermost,
      status: status,
      raw: post,
      metadata: %{
        root_id: nilify(map_get(post, ["root_id", :root_id]))
      }
    })
  end

  defp normalize_file_media(file) when is_map(file) do
    Media.new(%{
      url: map_get(file, ["link", :link, "permalink", :permalink]),
      filename: map_get(file, ["name", :name]),
      media_type: map_get(file, ["mime_type", :mime_type]),
      size_bytes: map_get(file, ["size", :size]),
      width: map_get(file, ["width", :width]),
      height: map_get(file, ["height", :height]),
      metadata:
        %{
          file_id: map_get(file, ["id", :id]),
          extension: map_get(file, ["extension", :extension])
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
  end

  defp normalize_file_media(_), do: nil

  defp upload_input(%FileUpload{path: path} = upload) when is_binary(path) and path != "" do
    {:ok,
     %{
       path: path,
       filename: upload.filename || Path.basename(path),
       content_type: upload.media_type
     }}
  end

  defp upload_input(%FileUpload{data: data, filename: filename} = upload)
       when is_binary(data) and data != "" and is_binary(filename) and filename != "" do
    {:ok, %{body: data, filename: filename, content_type: upload.media_type}}
  end

  defp upload_input(%FileUpload{data: data}) when is_binary(data) and data != "" do
    {:error, :missing_filename}
  end

  defp upload_input(%FileUpload{url: url}) when is_binary(url) and url != "" do
    {:error, :unsupported_remote_url}
  end

  defp upload_input(_upload), do: {:error, :missing_file_source}

  defp upload_caption(%FileUpload{} = upload, opts) do
    metadata = upload.metadata || %{}

    [
      opts[:caption],
      opts[:text],
      metadata[:caption],
      metadata["caption"],
      metadata[:alt_text],
      metadata["alt_text"],
      metadata[:transcript],
      metadata["transcript"]
    ]
    |> first_present()
    |> Kernel.||("")
  end

  defp first_present(values) do
    Enum.find(values, fn
      value when value in [nil, ""] -> false
      _value -> true
    end)
  end

  defp uploaded_file_ids(upload_result) do
    upload_result
    |> uploaded_file_infos()
    |> Enum.map(&(map_get(&1, ["id", :id]) || &1))
    |> Enum.reject(&is_nil/1)
  end

  defp uploaded_file_ids_result(upload_result) do
    case uploaded_file_ids(upload_result) do
      [] -> {:error, :missing_uploaded_file_id}
      file_ids -> {:ok, file_ids}
    end
  end

  defp uploaded_file_infos(%{"file_infos" => file_infos}) when is_list(file_infos), do: file_infos
  defp uploaded_file_infos(%{file_infos: file_infos}) when is_list(file_infos), do: file_infos
  defp uploaded_file_infos(file_infos) when is_list(file_infos), do: file_infos
  defp uploaded_file_infos(_), do: []

  defp upload_response(%FileUpload{} = upload, upload_result, post_result, channel_id) do
    file_info = upload_result |> uploaded_file_infos() |> List.first()

    Response.new(%{
      external_message_id: map_get(post_result, ["id", :id]),
      external_room_id: map_get(post_result, ["channel_id", :channel_id]) || channel_id,
      timestamp: map_get(post_result, ["create_at", :create_at]),
      channel_type: :mattermost,
      status: :sent,
      raw: post_result,
      metadata:
        %{
          file_id: map_get(file_info, ["id", :id]),
          file_ids: uploaded_file_ids(upload_result),
          filename: map_get(file_info, ["name", :name]) || upload.filename,
          size: map_get(file_info, ["size", :size]) || upload.size_bytes,
          content_type: map_get(file_info, ["mime_type", :mime_type]) || upload.media_type,
          upload_kind: upload.kind,
          delivered_kind: delivered_kind(upload, file_info),
          upload: upload_result
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
  end

  defp delivered_kind(%FileUpload{} = upload, file_info) do
    media_type = map_get(file_info, ["mime_type", :mime_type]) || upload.media_type

    case media_type do
      <<"image/", _::binary>> -> :image
      <<"audio/", _::binary>> -> :audio
      <<"video/", _::binary>> -> :video
      _ -> upload.kind
    end
  end

  defp map_get(nil, _keys), do: nil

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp nilify(v) when v in [nil, ""], do: nil
  defp nilify(v), do: v

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
