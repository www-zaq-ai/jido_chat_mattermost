defmodule Jido.Chat.Mattermost.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.Adapter

  # ---------------------------------------------------------------------------
  # Fake transport — canned responses for all callbacks
  # ---------------------------------------------------------------------------

  defmodule FakeTransport do
    @behaviour Jido.Chat.Mattermost.Transport

    @impl true
    def send_message(channel_id, text, opts) do
      {:ok,
       %{
         "id" => "post_123",
         "channel_id" => channel_id,
         "message" => text,
         "root_id" => opts[:thread_id] || ""
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
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
        assert {:ok, incoming} = Adapter.transform_incoming(payload)
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
      assert [%Jido.Chat.Mention{user_id: "bot_uid", mention_text: "@bot_uid"}] = incoming.mentions
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

      assert {:ok, incoming} = Adapter.transform_incoming(payload)
      assert [media] = incoming.media
      assert media.filename == "photo.png"
      assert media.media_type == "image/png"
      assert media.url == "https://mm.example.com/file/1"
    end

    test "invalid payload returns error" do
      assert {:error, :invalid_payload} = Adapter.transform_incoming("not a map")
    end
  end

  # ---------------------------------------------------------------------------
  # send_message/3
  # ---------------------------------------------------------------------------

  describe "send_message/3" do
    test "posts to channel and returns post map" do
      assert {:ok, post} = Adapter.send_message("c1", "hello", fake_opts())
      assert post["channel_id"] == "c1"
      assert post["message"] == "hello"
    end

    test "includes root_id for thread replies" do
      opts = [transport: FakeTransport, thread_id: "p_root"]
      assert {:ok, post} = Adapter.send_message("c1", "reply", opts)
      assert post["root_id"] == "p_root"
    end
  end

  # ---------------------------------------------------------------------------
  # add_reaction/4 and remove_reaction/4
  # ---------------------------------------------------------------------------

  describe "add_reaction/4" do
    test "returns reaction confirmation" do
      assert {:ok, result} = Adapter.add_reaction("c1", "post_1", "+1", fake_opts())
      assert result["post_id"] == "post_1"
      assert result["emoji_name"] == "+1"
    end
  end

  describe "remove_reaction/4" do
    test "removes reaction for given user" do
      opts = [transport: FakeTransport, user_id: "u1"]
      assert {:ok, result} = Adapter.remove_reaction("c1", "post_1", "+1", opts)
      assert result["user_id"] == "u1"
      assert result["emoji_name"] == "+1"
    end

    test "raises when user_id missing" do
      assert_raise RuntimeError, ~r/:user_id is required/, fn ->
        Adapter.remove_reaction("c1", "post_1", "+1", fake_opts())
      end
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_messages/2 with limit
  # ---------------------------------------------------------------------------

  describe "fetch_messages/2" do
    test "passes limit to transport" do
      opts = [transport: FakeTransport, limit: 25]
      assert {:ok, result} = Adapter.fetch_messages("c1", opts)
      assert result["per_page"] == 25
    end

    test "defaults to 60 posts" do
      assert {:ok, result} = Adapter.fetch_messages("c1", fake_opts())
      assert result["per_page"] == 60
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_message/3 (shared post lookup)
  # ---------------------------------------------------------------------------

  describe "fetch_message/3" do
    test "returns the post by id" do
      assert {:ok, post} = Adapter.fetch_message("c1", "post_abc", fake_opts())
      assert post["id"] == "post_abc"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_event/2
  # ---------------------------------------------------------------------------

  describe "parse_event/2" do
    test "message payload returns :message EventEnvelope" do
      payload = %{
        "post" => %{"id" => "p1", "channel_id" => "c1", "root_id" => ""},
        "channel_type" => "O"
      }

      assert {:ok, env} = Adapter.parse_event(payload, [])
      assert env.event_type == :message
      assert env.channel_id == "c1"
      assert env.message_id == "p1"
      assert env.adapter_name == :mattermost
    end

    test "slash command payload returns :slash_command EventEnvelope" do
      payload = %{"command" => "/greet", "channel_id" => "c1", "text" => "world"}

      assert {:ok, env} = Adapter.parse_event(payload, [])
      assert env.event_type == :slash_command
      assert env.channel_id == "c1"
    end

    test "thread reply sets thread_id from root_id" do
      payload = %{
        "post" => %{"id" => "p2", "channel_id" => "c1", "root_id" => "p_root"},
        "channel_type" => "O"
      }

      assert {:ok, env} = Adapter.parse_event(payload, [])
      assert env.thread_id == "p_root"
    end

    test "unknown payload returns :noop" do
      assert {:ok, :noop} = Adapter.parse_event(%{"unknown" => "payload"}, [])
    end

    test "WebhookRequest delegates to payload" do
      request = Jido.Chat.WebhookRequest.new(%{
        "post" => %{"id" => "p1", "channel_id" => "c1", "root_id" => ""}
      })

      assert {:ok, env} = Adapter.parse_event(request, [])
      assert env.event_type == :message
    end
  end

  # ---------------------------------------------------------------------------
  # verify_webhook/2
  # ---------------------------------------------------------------------------

  describe "verify_webhook/2" do
    test "accepts matching token" do
      assert :ok = Adapter.verify_webhook(%{"token" => "secret"}, token: "secret")
    end

    test "rejects wrong token" do
      assert {:error, :invalid_webhook_token} =
               Adapter.verify_webhook(%{"token" => "wrong"}, token: "secret")
    end

    test "rejects missing token in payload" do
      assert {:error, :invalid_webhook_token} =
               Adapter.verify_webhook(%{}, token: "secret")
    end

    test "rejects non-map payload" do
      assert {:error, :invalid_payload} = Adapter.verify_webhook("oops", token: "secret")
    end
  end

  # ---------------------------------------------------------------------------
  # listener_child_specs/2
  # ---------------------------------------------------------------------------

  describe "listener_child_specs/2" do
    test "returns empty list for webhook mode" do
      assert {:ok, []} = Adapter.listener_child_specs("bridge_1", ingress: [mode: "webhook"])
    end

    test "returns empty list when mode absent (defaults to webhook)" do
      assert {:ok, []} = Adapter.listener_child_specs("bridge_1", [])
    end

    test "returns error for unsupported mode" do
      assert {:error, {:unsupported_ingress_mode, "socket"}} =
               Adapter.listener_child_specs("bridge_1", ingress: [mode: "socket"])
    end
  end
end
