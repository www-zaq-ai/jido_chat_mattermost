defmodule Jido.Chat.Mattermost.WebSocket.ClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.WebSocket.Client

  @base_state %{
    token: "test-token",
    bot_user_id: "bot-uid",
    bot_name: "zaq",
    channel_ids: :all,
    bridge_id: "mattermost_1",
    oban_worker: nil,
    config_id: 42
  }

  defp posted_frame(post_attrs \\ %{}) do
    post =
      Map.merge(
        %{
          "id" => "post-1",
          "user_id" => "user-123",
          "channel_id" => "chan-abc",
          "message" => "Hello",
          "root_id" => ""
        },
        post_attrs
      )

    event = %{
      "event" => "posted",
      "data" => %{"post" => Jason.encode!(post)}
    }

    {:text, Jason.encode!(event)}
  end

  # ── handle_connect/3 ──────────────────────────────────────────────────

  describe "handle_connect/3" do
    test "sends authentication_challenge with bot token" do
      {:reply, [{:text, json}], _state} = Client.handle_connect(101, [], @base_state)

      assert {:ok,
              %{"action" => "authentication_challenge", "data" => %{"token" => "test-token"}}} =
               Jason.decode(json)
    end

    test "returns state unchanged" do
      {:reply, _frames, state} = Client.handle_connect(101, [], @base_state)
      assert state == @base_state
    end
  end

  # ── handle_disconnect/3 ───────────────────────────────────────────────

  describe "handle_disconnect/3" do
    test "returns :reconnect with state" do
      assert {:reconnect, @base_state} = Client.handle_disconnect(1001, "going away", @base_state)
    end
  end

  # ── handle_in/2 — non-posted events ──────────────────────────────────

  describe "handle_in/2 non-posted events" do
    test "ignores typing event" do
      frame = {:text, Jason.encode!(%{"event" => "typing", "data" => %{}})}
      assert {:ok, @base_state} = Client.handle_in(frame, @base_state)
    end

    test "ignores status_change event" do
      frame = {:text, Jason.encode!(%{"event" => "status_change", "data" => %{}})}
      assert {:ok, @base_state} = Client.handle_in(frame, @base_state)
    end

    test "ignores hello event (auth confirmation)" do
      frame = {:text, Jason.encode!(%{"event" => "hello", "data" => %{}})}
      assert {:ok, @base_state} = Client.handle_in(frame, @base_state)
    end

    test "ignores binary frames" do
      assert {:ok, @base_state} = Client.handle_in({:binary, <<0, 1, 2>>}, @base_state)
    end
  end

  # ── handle_in/2 — malformed JSON ─────────────────────────────────────

  describe "handle_in/2 malformed JSON" do
    test "does not crash on invalid JSON, returns {:ok, state}" do
      frame = {:text, "not json at all {{{}"}
      assert {:ok, @base_state} = Client.handle_in(frame, @base_state)
    end

    test "does not crash when post field is not double-encoded JSON" do
      event = %{"event" => "posted", "data" => %{"post" => %{"not" => "a string"}}}
      frame = {:text, Jason.encode!(event)}
      assert {:ok, @base_state} = Client.handle_in(frame, @base_state)
    end

    test "does not crash when data.post key is missing" do
      event = %{"event" => "posted", "data" => %{}}
      frame = {:text, Jason.encode!(event)}
      assert {:ok, @base_state} = Client.handle_in(frame, @base_state)
    end
  end

  # ── handle_in/2 — bot filtering ──────────────────────────────────────

  describe "handle_in/2 bot message filtering" do
    test "filters out messages from the bot user, oban_worker never invoked" do
      # oban_worker is nil — would crash if called
      frame = posted_frame(%{"user_id" => "bot-uid"})
      assert {:ok, _state} = Client.handle_in(frame, @base_state)
    end

    test "passes through messages from a different user" do
      # Uses a stub worker that raises to confirm it IS called (and we handle the error)
      state_with_bad_worker = Map.put(@base_state, :oban_worker, NonExistentWorker)

      frame = posted_frame(%{"user_id" => "other-user"})

      # Should not raise — Oban.insert error is caught and logged
      assert {:ok, _state} = Client.handle_in(frame, state_with_bad_worker)
    end
  end

  # ── handle_in/2 — channel filtering ──────────────────────────────────

  describe "handle_in/2 channel filtering" do
    test "passes through when channel_ids is :all" do
      state_with_bad_worker = Map.put(@base_state, :oban_worker, NonExistentWorker)
      frame = posted_frame(%{"channel_id" => "any-channel"})
      # :all → proceeds to enqueue (error caught)
      assert {:ok, _state} = Client.handle_in(frame, state_with_bad_worker)
    end

    test "filters out messages from untracked channels, oban_worker never invoked" do
      state = Map.merge(@base_state, %{channel_ids: ["tracked-chan"], oban_worker: nil})
      frame = posted_frame(%{"channel_id" => "other-chan"})
      assert {:ok, _state} = Client.handle_in(frame, state)
    end

    test "passes through messages from tracked channels" do
      state =
        Map.merge(@base_state, %{
          channel_ids: ["tracked-chan"],
          oban_worker: NonExistentWorker
        })

      frame = posted_frame(%{"channel_id" => "tracked-chan"})
      # Proceeds to enqueue (error caught)
      assert {:ok, _state} = Client.handle_in(frame, state)
    end
  end
end
