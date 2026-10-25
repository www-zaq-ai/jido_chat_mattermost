defmodule Jido.Chat.Mattermost.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Adapter, ChannelInfo, FileUpload, Media, Mention, PostPayload, Response, Thread}
  alias Jido.Chat.Mattermost.Adapter, as: MattermostAdapter
  alias Jido.Chat.Mattermost.Test.RecordingTransport

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
    def download_file(file_id, opts) do
      send(self(), {:download_file, file_id, opts})

      case file_id do
        "missing" -> {:error, {404, "not found"}}
        _file_id -> {:ok, "mattermost file bytes"}
      end
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

  describe "retained media validation and upload cases" do
    test "invalid media references fail before contacting the transport" do
      for reference <- [nil, 42, [], "ftp://example.com/file", "https://example.com"] do
        assert {:error, :invalid_media_reference} =
                 MattermostAdapter.fetch_media(reference, transport: RecordingTransport)

        refute_received {:transport_call, _, _}
      end
    end

    test "URL-only media maps and structs fall back to the Mattermost file URL" do
      url = "https://chat.example.com/api/v4/files/file_123"
      Process.put({RecordingTransport, :download_file}, {:ok, "bytes"})

      for reference <- [%{url: url}, %{"url" => url}, Media.new(%{url: url})] do
        assert {:ok, "bytes"} =
                 MattermostAdapter.fetch_media(reference, transport: RecordingTransport)

        assert_receive {:transport_call, :download_file, ["file_123", _]}
      end
    end

    test "incoming media ignores malformed entries but retains valid attachments" do
      payload = %{
        "post" => %{
          "id" => "p1",
          "channel_id" => "c1",
          "user_id" => "u1",
          "message" => "files",
          "metadata" => %{"files" => [nil, 42, "invalid", %{"id" => "file_123", "name" => "valid.txt"}]}
        }
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert [%Media{filename: "valid.txt", url: "mattermost://file/file_123"}] = incoming.media
    end

    test "file metadata without identity does not fabricate a download URL" do
      payload = %{
        "post" => %{
          "id" => "p1",
          "channel_id" => "c1",
          "user_id" => "u1",
          "message" => "files",
          "metadata" => %{"files" => [%{"name" => "unknown.txt"}]}
        }
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert [%Media{url: nil, filename: "unknown.txt"}] = incoming.media
    end

    test "empty or malformed upload results prevent a post from being sent" do
      upload = FileUpload.new(%{kind: :file, data: "bytes", filename: "file.bin"})

      for result <- [%{}, %{"file_infos" => []}, %{"file_infos" => "invalid"}] do
        Process.put({RecordingTransport, :upload_file}, {:ok, result})

        assert {:error, :missing_uploaded_file_id} =
                 MattermostAdapter.send_file("c1", upload, transport: RecordingTransport)

        assert_receive {:transport_call, :upload_file, ["c1", _, _]}
        refute_received {:transport_call, :send_message, _}
      end
    end

    test "uploaded image, audio, and video MIME types determine delivered kind" do
      for {mime, expected} <- [{"image/png", :image}, {"audio/ogg", :audio}, {"video/mp4", :video}] do
        upload = FileUpload.new(%{kind: :file, data: "bytes", filename: "attachment.bin"})
        file = %{"id" => "f1", "mime_type" => mime}
        Process.put({RecordingTransport, :upload_file}, {:ok, %{"file_infos" => [file]}})
        Process.put({RecordingTransport, :send_message}, {:ok, %{"id" => "p1"}})

        assert {:ok, response} =
                 MattermostAdapter.send_file("c1", upload, transport: RecordingTransport)

        assert response.metadata.delivered_kind == expected
        assert response.metadata.upload_kind == :file
        assert response.metadata.content_type == mime
      end
    end
  end

  describe "additional adapter contracts" do
    setup do
      {:ok,
       opts: [
         transport: RecordingTransport,
         url: "https://chat.example.com",
         token: "test-token"
       ]}
    end

    test "capability matrix is coherent" do
      assert :ok = Adapter.validate_capabilities(MattermostAdapter)
      assert MattermostAdapter.channel_type() == :mattermost
    end

    test "editing forwards credentials and normalizes the response", %{opts: opts} do
      post = %{"id" => "p1", "message" => "updated"}
      Process.put({RecordingTransport, :edit_message}, {:ok, post})

      assert {:ok, %Response{} = response} =
               MattermostAdapter.edit_message("c1", "p1", "updated", opts)

      assert response.status == :edited
      assert response.external_message_id == "p1"
      assert response.external_room_id == "c1"
      assert response.raw == post
      assert_receive {:transport_call, :edit_message, ["c1", "p1", "updated", forwarded]}
      assert Map.new(forwarded) == Map.new(Keyword.delete(opts, :transport))
    end

    test "editing preserves transport errors", %{opts: opts} do
      Process.put({RecordingTransport, :edit_message}, {:error, :forbidden})
      assert {:error, :forbidden} = MattermostAdapter.edit_message("c1", "p1", "text", opts)
    end

    test "delete and typing forward identifiers, credentials, and results", %{opts: opts} do
      for {callback, args, transport_callback, result} <- [
            {:delete_message, ["c1", "p1"], :delete_message, {:ok, %{"id" => "p1"}}},
            {:start_typing, ["c1"], :send_typing, :ok}
          ],
          expected <- [result, {:error, :forbidden}] do
        Process.put({RecordingTransport, transport_callback}, expected)
        assert apply(MattermostAdapter, callback, args ++ [opts]) == expected
        assert_receive {:transport_call, ^transport_callback, forwarded}
        assert Enum.drop(forwarded, -1) == args
        assert Map.new(List.last(forwarded)) == Map.new(Keyword.delete(opts, :transport))
      end
    end

    test "thread fetching normalizes identity and metadata and preserves errors", %{opts: opts} do
      metadata = %{"posts" => %{"root" => %{"id" => "root"}}}
      Process.put({RecordingTransport, :fetch_thread}, {:ok, metadata})
      assert {:ok, %Thread{} = thread} = MattermostAdapter.fetch_thread("root", opts ++ [channel_id: "c1"])
      assert thread.id == "mattermost:thread:root"
      assert thread.external_thread_id == "root"
      assert thread.external_room_id == "c1"
      assert thread.metadata == metadata
      assert_receive {:transport_call, :fetch_thread, ["root", forwarded]}
      assert forwarded[:token] == "test-token"
      assert forwarded[:url] == opts[:url]
      Process.put({RecordingTransport, :fetch_thread}, {:error, :not_found})
      assert {:error, :not_found} = MattermostAdapter.fetch_thread("root", opts)
    end

    test "user display names handle full, partial, and absent names", %{opts: opts} do
      for {first, last, expected} <- [
            {"Ada", "Lovelace", "Ada Lovelace"},
            {"Ada", nil, "Ada"},
            {nil, "Lovelace", "Lovelace"},
            {"", "", "ada"},
            {nil, nil, "ada"}
          ] do
        user = %{"id" => "u1", "username" => "ada", "first_name" => first, "last_name" => last}
        Process.put({RecordingTransport, :get_user}, {:ok, user})
        assert {:ok, result} = MattermostAdapter.get_user("u1", opts)
        assert result == Map.put(user, "display_name", expected)
        assert_receive {:transport_call, :get_user, ["u1", forwarded]}
        assert forwarded[:token] == "test-token"
      end

      Process.put({RecordingTransport, :get_user}, {:error, :not_found})
      assert {:error, :not_found} = MattermostAdapter.get_user("u1", opts)
    end

    test "DM creation rejects invalid channels and preserves errors", %{opts: opts} do
      for channel <- [%{}, %{"id" => ""}, %{"id" => 42}] do
        Process.put({RecordingTransport, :open_dm_channel}, {:ok, channel})

        assert {:error, _reason} =
                 MattermostAdapter.open_dm("u1", opts ++ [bot_user_id: "bot"])
      end

      Process.put({RecordingTransport, :open_dm_channel}, {:error, :forbidden})
      assert {:error, :forbidden} = MattermostAdapter.open_dm("u1", opts ++ [bot_user_id: "bot"])
    end

    test "listener specs default the bridge id without replacing an explicit id" do
      for {opts, expected} <- [{[], "default"}, {[bridge_id: "explicit"], "explicit"}] do
        assert {:ok, [spec]} = MattermostAdapter.listener_child_specs("default", opts)
        assert spec.id == {Jido.Chat.Mattermost.Listener, expected}
        assert {Jido.Chat.Mattermost.Listener, :start_link, [forwarded]} = spec.start
        assert forwarded[:bridge_id] == expected
      end
    end
  end

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

    test "message files without links receive adapter-owned references" do
      payload = %{
        "post" => %{
          "id" => "p6",
          "user_id" => "u1",
          "channel_id" => "c1",
          "message" => "see attached",
          "metadata" => %{
            "files" => [
              %{"id" => "file_456", "name" => "report.pdf", "mime_type" => "application/pdf"}
            ]
          }
        },
        "channel_type" => "O"
      }

      assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
      assert [media] = incoming.media
      assert media.url == "mattermost://file/file_456"
      assert media.metadata.file_id == "file_456"
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

  describe "incoming file MIME resolution" do
    for {filename, media_type, kind} <- [
          {"photo.jpg", "image/jpeg", :image},
          {"photo.png", "image/png", :image},
          {"photo.gif", "image/gif", :image},
          {"photo.webp", "image/webp", :image},
          {"report.pdf", "application/pdf", :file}
        ] do
      test "resolves explicit, absent, blank, and invalid MIME for #{filename}" do
        filename = unquote(filename)
        expected_type = unquote(media_type)
        file = %{"id" => "file_123", "name" => filename}

        for metadata <- [
              file,
              Map.put(file, "mime_type", expected_type),
              Map.put(file, "mime_type", nil),
              Map.put(file, "mime_type", " \t "),
              Map.put(file, "mime_type", "not-a-mime"),
              Map.put(file, "mime_type", 123)
            ] do
          media = incoming_file(metadata)
          assert media.kind == unquote(kind)
          assert media.media_type == expected_type
          assert media.filename == filename
          assert media.url == "mattermost://file/file_123"
          assert media.metadata.file_id == "file_123"
        end
      end
    end

    test "valid provider MIME wins over misleading names, extensions, and URLs" do
      for {provider_type, expected_type, kind} <- [
            {" Application/PDF; charset=binary ", "application/pdf", :file},
            {"application/octet-stream", "application/octet-stream", :file},
            {"IMAGE/GIF", "image/gif", :image},
            {"audio/ogg", "audio/ogg", :audio},
            {"video/webm", "video/webm", :video}
          ] do
        media =
          incoming_file(%{
            "name" => "misleading.png",
            "extension" => "jpg",
            "link" => "https://mm.example.com/photo.webp",
            "mime_type" => provider_type
          })

        assert media.media_type == expected_type
        assert media.kind == kind
      end
    end

    test "fallbacks use filename, then file-info extension, then signed URL path" do
      for {file, expected_type} <- [
            {%{"name" => "photo.GIF", "extension" => "png"}, "image/gif"},
            {%{"name" => "extensionless", "extension" => " .PNG "}, "image/png"},
            {%{"name" => "archive.unknown", "extension" => "webp"}, "image/webp"},
            {%{"name" => " ", "link" => " ", "permalink" => "https://mm.example.com/photo.PNG?token=signed"},
             "image/png"},
            {%{name: "extensionless", extension: "JPEG", mime_type: " "}, "image/jpeg"},
            {%{"name" => "unknown", "extension" => "unknown", "link" => "https://mm.example.com/photo.webp?q=1"},
             "image/webp"}
          ] do
        media = incoming_file(file)
        assert media.kind == :image
        assert media.media_type == expected_type
      end
    end

    test "blank links retain private download references and raw file metadata" do
      file = %{"id" => "file_123", "name" => " ", "link" => " ", "permalink" => "", "extension" => " .PNG "}
      media = incoming_file(file)
      assert media.filename == nil
      assert media.url == "mattermost://file/file_123"
      assert media.metadata == %{file_id: "file_123", extension: " .PNG "}
    end

    test "unknown files receive neither a MIME nor an image default" do
      for value <- [nil, "", " \n ", "invalid", %{}] do
        media = incoming_file(%{"id" => "unknown", "name" => "archive.unknown", "mime_type" => value})
        assert media.kind == :file
        assert media.media_type == nil
      end
    end
  end

  defp incoming_file(file) do
    payload = %{
      "post" => %{
        "id" => "post_123",
        "user_id" => "u1",
        "channel_id" => "c1",
        "message" => "attachment",
        "metadata" => %{"files" => [file]}
      }
    }

    assert {:ok, incoming} = MattermostAdapter.transform_incoming(payload)
    assert [media] = incoming.media
    assert incoming.raw == payload
    media
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
      assert caps.fetch_media == :native
      assert caps.post_message == :fallback
      assert caps.open_dm == :native
      assert caps.open_thread == :native

      assert :ok = Jido.Chat.Adapter.validate_capabilities(MattermostAdapter)
    end
  end

  describe "fetch_media/2" do
    test "downloads raw IDs and adapter-owned references" do
      assert {:ok, "mattermost file bytes"} =
               MattermostAdapter.fetch_media("file_123", fake_opts())

      assert_received {:download_file, "file_123", _opts}

      assert {:ok, "mattermost file bytes"} =
               MattermostAdapter.fetch_media("mattermost://file/file_456", fake_opts())

      assert_received {:download_file, "file_456", _opts}
    end

    test "downloads normalized media and Mattermost API URLs" do
      media = Media.new(%{url: "mattermost://file/file_789", metadata: %{file_id: "file_789"}})

      assert {:ok, "mattermost file bytes"} = MattermostAdapter.fetch_media(media, fake_opts())
      assert_received {:download_file, "file_789", _opts}

      assert {:ok, "mattermost file bytes"} =
               MattermostAdapter.fetch_media(
                 "https://mattermost.example.com/api/v4/files/file_abc",
                 fake_opts()
               )

      assert_received {:download_file, "file_abc", _opts}
    end

    test "rejects invalid references and propagates transport errors" do
      assert {:error, :invalid_media_reference} =
               MattermostAdapter.fetch_media("https://example.com/private.txt", fake_opts())

      assert {:error, :invalid_media_reference} = MattermostAdapter.fetch_media(%{}, fake_opts())
      assert {:error, {404, "not found"}} = MattermostAdapter.fetch_media("missing", fake_opts())
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
