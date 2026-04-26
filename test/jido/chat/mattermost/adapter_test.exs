defmodule Jido.Chat.Mattermost.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Adapter, ChannelInfo, FileUpload, Mention, PostPayload, Response, Thread}
  alias Jido.Chat.Mattermost.Adapter, as: MattermostAdapter

  # ---------------------------------------------------------------------------
  # Fake transport — canned responses for all callbacks
  # ---------------------------------------------------------------------------

  defmodule FakeTransport do
    @behaviour Jido.Chat.Mattermost.Transport

    @impl true
    def send_message(channel_id, text, opts) do
      send(self(), {:send_message, channel_id, text, opts})

      {:ok,
       %{
         "id" => "post_123",
         "channel_id" => channel_id,
         "message" => text,
         "root_id" => opts[:thread_id] || "",
         "file_ids" => opts[:file_ids] || []
       }}
    end

    @impl true
    def upload_file(channel_id, file, opts) do
      send(self(), {:upload_file, channel_id, file, opts})

      {:ok,
       %{
         "file_infos" => [
           %{
             "id" => "file_123",
             "name" => file[:filename],
             "mime_type" => file[:content_type],
             "size" => file_size(file)
           }
         ]
       }}
    end

    @impl true
    def edit_message(_channel_id, post_id, text, _opts) do
      {:ok, %{"id" => post_id, "message" => text}}
    end

    @impl true
    def delete_message(_channel_id, post_id, _opts) do
      {:ok, %{"id" => post_id}}
    end

    @impl true
    def add_reaction(post_id, emoji, _opts) do
      {:ok, %{"post_id" => post_id, "emoji_name" => emoji}}
    end

    @impl true
    def remove_reaction(post_id, emoji, user_id, _opts) do
      {:ok, %{"post_id" => post_id, "emoji_name" => emoji, "user_id" => user_id}}
    end

    @impl true
    def fetch_posts(channel_id, opts) do
      {:ok, %{"channel_id" => channel_id, "per_page" => opts[:limit] || 60, "posts" => []}}
    end

    @impl true
    def fetch_post(post_id, _opts) do
      {:ok, %{"id" => post_id, "message" => "hello"}}
    end

    @impl true
    def fetch_thread(root_id, _opts) do
      {:ok, %{"id" => root_id, "posts" => %{}}}
    end

    @impl true
    def fetch_channel(channel_id, _opts) do
      {:ok, %{"id" => channel_id, "display_name" => "test-channel", "type" => "O"}}
    end

    @impl true
    def send_typing(_channel_id, _opts), do: :ok

    @impl true
    def get_user(user_id, _opts) do
      {:ok, %{"id" => user_id, "username" => "test-user"}}
    end

    defp file_size(%{body: body}) when is_binary(body), do: byte_size(body)

    defp file_size(%{path: path}) when is_binary(path) do
      case File.stat(path) do
        {:ok, stat} -> stat.size
        _ -> nil
      end
    end

    defp file_size(_), do: nil

    @impl true
    def open_dm_channel(bot_user_id, target_user_id, _opts) do
      {:ok,
       %{
         "id" => "dm_#{bot_user_id}_#{target_user_id}",
         "type" => "D"
       }}
    end
  end

  defp fake_opts, do: [transport: FakeTransport]

  # ---------------------------------------------------------------------------
  # transform_incoming/1
  # ---------------------------------------------------------------------------

  describe "transform_incoming/1" do
    test "plain message" do
      payload = %{
        "post" => %{
          "id" => "p1",
          "user_id" => "u1",
          "channel_id" => "c1",
          "message" => "hello world",
          "root_id" => ""
        },
        "channel_display_name" => "general",
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.text == "hello world"
      assert incoming.external_user_id == "u1"
      assert incoming.external_room_id == "c1"
      assert incoming.external_message_id == "p1"
      assert incoming.external_thread_id == nil
      assert incoming.chat_title == "general"
      assert incoming.chat_type == :public
      assert incoming.media == []
      assert incoming.was_mentioned == false
    end

    test "thread reply sets external_thread_id" do
      payload = %{
        "post" => %{
          "id" => "p2",
          "user_id" => "u1",
          "channel_id" => "c1",
          "message" => "reply",
          "root_id" => "p1"
        },
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.external_thread_id == "p1"
    end

    test "DM sets chat_type :dm" do
      payload = %{
        "post" => %{
          "id" => "p3",
          "user_id" => "u1",
          "channel_id" => "c_dm",
          "message" => "hey",
          "root_id" => ""
        },
        "channel_type" => "D"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.chat_type == :dm
    end

    test "private channel sets chat_type :private" do
      payload = %{
        "post" => %{
          "id" => "p6",
          "user_id" => "u1",
          "channel_id" => "c1",
          "message" => "hi",
          "root_id" => ""
        },
        "channel_type" => "P"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.chat_type == :private
    end

    test "populates raw with original payload" do
      payload = %{
        "post" => %{
          "id" => "p7",
          "user_id" => "u1",
          "channel_id" => "c1",
          "message" => "hi",
          "root_id" => ""
        },
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.raw == payload
    end

    test "populates channel_meta" do
      payload = %{
        "post" => %{
          "id" => "p8",
          "user_id" => "u1",
          "channel_id" => "c1",
          "message" => "hi",
          "root_id" => ""
        },
        "channel_display_name" => "general",
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.channel_meta.adapter_name == :mattermost
      assert incoming.channel_meta.external_room_id == "c1"
      assert incoming.channel_meta.is_dm == false
      assert incoming.channel_meta.chat_title == "general"
    end

    test "mention via text" do
      payload = %{
        "post" => %{
          "id" => "p4",
          "user_id" => "u2",
          "channel_id" => "c1",
          "message" => "hey @mybot do something",
          "root_id" => "",
          "props" => %{}
        },
        "channel_type" => "O"
      }

      Application.put_env(:jido_chat_mattermost, :bot_name, "mybot")

      try do
        assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
        assert incoming.was_mentioned == true
        assert incoming.mentions == []
      after
        Application.delete_env(:jido_chat_mattermost, :bot_name)
      end
    end

    test "mentions via props are returned as Mention structs" do
      payload = %{
        "post" => %{
          "id" => "p9",
          "user_id" => "u2",
          "channel_id" => "c1",
          "message" => "ping",
          "root_id" => "",
          "props" => %{"mentions" => ["bot_uid"]}
        },
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)

      assert [%Mention{user_id: "bot_uid", mention_text: "@bot_uid"}] =
               incoming.mentions

      assert incoming.was_mentioned == true
    end

    test "message with files populates media list" do
      payload = %{
        "post" => %{
          "id" => "p5",
          "user_id" => "u1",
          "channel_id" => "c1",
          "message" => "see attached",
          "root_id" => "",
          "metadata" => %{
            "files" => [
              %{
                "name" => "photo.png",
                "mime_type" => "image/png",
                "link" => "https://mm.example.com/file/1"
              }
            ]
          }
        },
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert [media] = incoming.media
      assert media.filename == "photo.png"
      assert media.media_type == "image/png"
      assert media.url == "https://mm.example.com/file/1"
    end

    test "flat outgoing-webhook payload is normalised" do
      payload = %{
        "token" => "tok",
        "team_id" => "t1",
        "channel_id" => "c1",
        "channel_name" => "general",
        "user_id" => "u1",
        "user_name" => "alice",
        "post_id" => "p1",
        "text" => "hello from webhook",
        "trigger_word" => "",
        "channel_type" => "O",
        "channel_display_name" => "General"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.text == "hello from webhook"
      assert incoming.external_user_id == "u1"
      assert incoming.external_room_id == "c1"
      assert incoming.external_message_id == "p1"
      assert incoming.external_thread_id == nil
      assert incoming.chat_title == "General"
      assert incoming.chat_type == :public
    end

    test "flat outgoing-webhook thread reply sets external_thread_id" do
      payload = %{
        "token" => "tok",
        "channel_id" => "c1",
        "user_id" => "u1",
        "post_id" => "p2",
        "text" => "reply text",
        "root_id" => "p_root",
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert incoming.external_thread_id == "p_root"
      assert incoming.text == "reply text"
    end

    test "invalid payload returns error" do
      assert {:error, :invalid_payload} = MattermostAdapter.transform_incoming("not a map")
    end
  end

  # ---------------------------------------------------------------------------
  # send_message/3
  # ---------------------------------------------------------------------------

  describe "send_message/3" do
    test "posts to channel and returns a normalized response" do
      assert {:ok, resp} = MattermostAdapter.send_message("c1", "hello", fake_opts())
      assert %Response{} = resp
      assert resp.external_message_id == "post_123"
      assert resp.external_room_id == "c1"
      assert resp.channel_type == :mattermost
    end

    test "thread reply keeps thread metadata on the response" do
      opts = [transport: FakeTransport, thread_id: "p_root"]
      assert {:ok, resp} = MattermostAdapter.send_message("c1", "reply", opts)
      assert %Response{} = resp
      assert resp.external_message_id == "post_123"
      assert resp.metadata.root_id == "p_root"
    end

    test "generic reply routing maps to mattermost root thread id" do
      opts = [transport: FakeTransport, reply_to_id: "p_root"]
      assert {:ok, resp} = MattermostAdapter.send_message("c1", "reply", opts)
      assert %Response{} = resp
      assert resp.metadata.root_id == "p_root"
    end
  end

  describe "adapter capabilities" do
    test "declares explicit compatibility surface with native media upload" do
      caps = MattermostAdapter.capabilities()

      assert caps.send_message == :native
      assert caps.send_file == :native
      assert caps.post_message == :fallback
      assert caps.open_dm == :native
      assert caps.open_thread == :native

      assert :ok = Jido.Chat.Adapter.validate_capabilities(MattermostAdapter)
    end
  end

  describe "send_file/3" do
    test "uploads path-backed files and posts returned file_ids" do
      path =
        Path.join(System.tmp_dir!(), "jido-mattermost-upload-#{System.unique_integer()}.txt")

      File.write!(path, "mattermost path upload\n")

      try do
        upload =
          FileUpload.new(%{
            kind: :file,
            path: path,
            filename: "path-upload.txt",
            media_type: "text/plain",
            metadata: %{caption: "attached path"}
          })

        assert {:ok, response} = MattermostAdapter.send_file("c1", upload, fake_opts())

        assert_received {:upload_file, "c1", file, _opts}
        assert file.path == path
        assert file.filename == "path-upload.txt"
        assert file.content_type == "text/plain"

        assert_received {:send_message, "c1", "attached path", opts}
        assert opts[:file_ids] == ["file_123"]

        assert response.external_message_id == "post_123"
        assert response.external_room_id == "c1"
        assert response.metadata.file_id == "file_123"
        assert response.metadata.upload_kind == :file
      after
        File.rm(path)
      end
    end

    test "uploads byte-backed files" do
      upload =
        FileUpload.new(%{
          kind: :file,
          data: "mattermost bytes upload\n",
          filename: "bytes.txt",
          media_type: "text/plain"
        })

      assert {:ok, response} =
               MattermostAdapter.send_file(
                 "c1",
                 upload,
                 Keyword.put(fake_opts(), :caption, "bytes")
               )

      assert_received {:upload_file, "c1", file, _opts}
      assert file.body == "mattermost bytes upload\n"
      assert file.filename == "bytes.txt"

      assert_received {:send_message, "c1", "bytes", opts}
      assert opts[:file_ids] == ["file_123"]
      assert response.metadata.filename == "bytes.txt"
    end

    test "returns explicit validation errors for incomplete or remote upload input" do
      assert {:error, :missing_filename} =
               MattermostAdapter.send_file(
                 "c1",
                 %FileUpload{kind: :file, data: "mattermost bytes upload\n"},
                 fake_opts()
               )

      assert {:error, :unsupported_remote_url} =
               MattermostAdapter.send_file(
                 "c1",
                 %FileUpload{kind: :file, url: "https://example.com/file.txt"},
                 fake_opts()
               )

      assert {:error, :missing_file_source} =
               MattermostAdapter.send_file(
                 "c1",
                 %FileUpload{kind: :file, filename: "missing.txt"},
                 fake_opts()
               )
    end

    test "core post_message/4 uses canonical single-file fallback" do
      payload =
        PostPayload.new(%{
          text: "canonical mattermost upload",
          files: [
            %{
              kind: :file,
              data: "canonical bytes\n",
              filename: "canonical.txt",
              media_type: "text/plain"
            }
          ]
        })

      assert {:ok, response} =
               Adapter.post_message(MattermostAdapter, "c1", payload, fake_opts())

      assert_received {:upload_file, "c1", file, _opts}
      assert file.filename == "canonical.txt"

      assert_received {:send_message, "c1", "canonical mattermost upload", opts}
      assert opts[:file_ids] == ["file_123"]
      assert response.external_message_id == "post_123"
      assert response.metadata.file_ids == ["file_123"]
    end
  end

  describe "fetch_metadata/2" do
    test "returns normalized channel info" do
      assert {:ok, info} = MattermostAdapter.fetch_metadata("c1", fake_opts())
      assert %ChannelInfo{} = info
      assert info.id == "c1"
      assert info.name == "test-channel"
      assert info.is_dm == false
    end
  end

  describe "open_thread/3" do
    test "returns a normalized thread rooted at the post id" do
      assert {:ok, thread} = MattermostAdapter.open_thread("c1", "post_abc", fake_opts())
      assert %Thread{} = thread
      assert thread.external_room_id == "c1"
      assert thread.external_thread_id == "post_abc"
    end
  end

  describe "open_dm/2" do
    test "returns the DM channel id for a target user" do
      opts = [transport: FakeTransport, bot_user_id: "bot_1"]
      assert {:ok, channel_id} = MattermostAdapter.open_dm("user_2", opts)
      assert channel_id == "dm_bot_1_user_2"
    end

    test "returns an error when bot_user_id is missing" do
      assert {:error, :bot_user_id_required} = MattermostAdapter.open_dm("user_2", fake_opts())
    end
  end

  # ---------------------------------------------------------------------------
  # add_reaction/4 and remove_reaction/4
  # ---------------------------------------------------------------------------

  describe "add_reaction/4" do
    test "returns reaction confirmation" do
      assert {:ok, result} = MattermostAdapter.add_reaction("c1", "post_1", "+1", fake_opts())
      assert result["post_id"] == "post_1"
      assert result["emoji_name"] == "+1"
    end
  end

  describe "remove_reaction/4" do
    test "removes reaction for given user" do
      opts = [transport: FakeTransport, user_id: "u1"]
      assert {:ok, result} = MattermostAdapter.remove_reaction("c1", "post_1", "+1", opts)
      assert result["user_id"] == "u1"
      assert result["emoji_name"] == "+1"
    end

    test "raises when user_id missing" do
      assert_raise RuntimeError, ~r/:user_id is required/, fn ->
        MattermostAdapter.remove_reaction("c1", "post_1", "+1", fake_opts())
      end
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_messages/2 with limit
  # ---------------------------------------------------------------------------

  describe "fetch_messages/2" do
    test "passes limit to transport" do
      opts = [transport: FakeTransport, limit: 25]
      assert {:ok, result} = MattermostAdapter.fetch_messages("c1", opts)
      assert result["per_page"] == 25
    end

    test "defaults to 60 posts" do
      assert {:ok, result} = MattermostAdapter.fetch_messages("c1", fake_opts())
      assert result["per_page"] == 60
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_message/3 (shared post lookup)
  # ---------------------------------------------------------------------------

  describe "fetch_message/3" do
    test "returns the post by id" do
      assert {:ok, post} = MattermostAdapter.fetch_message("c1", "post_abc", fake_opts())
      assert post["id"] == "post_abc"
    end
  end
end
