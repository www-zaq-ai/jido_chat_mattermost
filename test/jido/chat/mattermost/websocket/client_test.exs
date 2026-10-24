defmodule Jido.Chat.Mattermost.WebSocket.ClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.WebSocket.Client

  defmodule ChannelTransport do
    def fetch_channel(channel_id, opts) do
      send(self(), {:fetch_channel, channel_id, opts})

      case Process.get(:channel_result) do
        :raise -> raise "transport failure"
        result -> result
      end
    end
  end

  defp classified_state(result) do
    Process.put(:channel_result, result)

    capturing_sink_state()
    |> Map.put(:channel_ids, ["tracked-chan"])
    |> Map.put(:metadata_opts,
      transport: ChannelTransport,
      url: "https://mattermost.example.com",
      token: "test-token"
    )
  end

  @base_state %{
    token: "test-token",
    bot_user_id: "bot-uid",
    bot_name: "zaq",
    channel_ids: :all,
    bridge_id: "mattermost_1",
    sink_mfa: {__MODULE__, :sink_noop, []},
    sink_opts: []
  }

  def sink_noop(_payload, _opts), do: :ok

  test "capability matrix is coherent" do
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Mattermost.Adapter)
  end

  defp raising_sink_state do
    Map.put(@base_state, :sink_mfa, {__MODULE__, :sink_raise, []})
  end

  def sink_raise(_payload, _opts), do: raise("sink called")

  defp capturing_sink_state do
    Map.put(@base_state, :sink_mfa, {__MODULE__, :sink_capture, []})
  end

  def sink_capture(payload, opts) do
    send(self(), {:sink_called, payload, opts})
    :ok
  end

  defp reaction_frame(event_name, reaction_attrs \\ %{}, overrides \\ %{}) do
    reaction =
      Map.merge(
        %{
          "user_id" => "user-123",
          "post_id" => "post-1",
          "emoji_name" => "thumbsup",
          "create_at" => 1_700_000_000
        },
        reaction_attrs
      )

    event =
      Map.merge(
        %{
          "event" => event_name,
          "data" => %{
            "reaction" => Jason.encode!(reaction)
          },
          "broadcast" => %{"channel_id" => "chan-abc"}
        },
        overrides
      )

    {:text, Jason.encode!(event)}
  end

  defp posted_frame(post_attrs) do
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

      assert {:ok, %{"action" => "authentication_challenge", "data" => %{"token" => "test-token"}}} =
               Jason.decode(json)
    end

    test "marks auth as pending" do
      {:reply, _frames, state} = Client.handle_connect(101, [], @base_state)

      assert state.auth_status == :pending
    end
  end

  # ── handle_in/2 — auth responses ─────────────────────────────────────

  describe "handle_in/2 auth responses" do
    test "marks authentication success" do
      frame = {:text, Jason.encode!(%{"seq_reply" => 1, "status" => "OK"})}

      assert {:ok, state} = Client.handle_in(frame, @base_state)
      assert state.auth_status == :ok
    end

    test "crashes on authentication failure" do
      reason = %{"message" => "invalid token"}
      frame = {:text, Jason.encode!(%{"seq_reply" => 1, "status" => "FAIL", "error" => reason})}

      assert catch_exit(Client.handle_in(frame, @base_state)) == {:auth_failed, reason}
    end

    test "posted event success marks auth as fallback" do
      frame = posted_frame(%{"user_id" => "other-user"})

      assert {:ok, state} = Client.handle_in(frame, @base_state)
      assert state.auth_status == :ok
    end
  end

  # ── handle_error/2 ───────────────────────────────────────────────────

  describe "handle_error/2" do
    test "closes with a standardized transport error reason" do
      error = {:streaming_failed, :closed}

      assert {:close, {:transport_failed, ^error}} = Client.handle_error(error, @base_state)
    end
  end

  # ── handle_info/2 — auth status requests ─────────────────────────────

  describe "handle_info/2 auth status requests" do
    test "replies with the current auth status" do
      ref = make_ref()
      state = Map.put(@base_state, :auth_status, :pending)

      assert {:ok, ^state} = Client.handle_info({:auth_status, self(), ref}, state)
      assert_receive {^ref, :pending}
    end

    test "replies with :unknown when auth status is absent" do
      assert {:ok, @base_state} = Client.handle_info({:auth_status, self()}, @base_state)
      assert_receive {:auth_status, :unknown}
    end

    test "ignores unrelated process messages" do
      assert {:ok, @base_state} = Client.handle_info(:unrelated, @base_state)
    end
  end

  # ── auth_status/2 ────────────────────────────────────────────────────

  describe "auth_status/2" do
    test "requests auth status from a websocket process" do
      pid =
        spawn(fn ->
          receive do
            {:auth_status, from, ref} -> send(from, {ref, :ok})
          end
        end)

      assert {:ok, :ok} = Client.auth_status(pid)
    end

    test "returns standardized process exit reasons" do
      pid =
        spawn(fn ->
          receive do
            {:auth_status, _from, _ref} -> exit({:auth_failed, :invalid_token})
          end
        end)

      assert {:error, {:auth_failed, :invalid_token}} = Client.auth_status(pid)
    end

    test "returns timeout when the process does not reply" do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:error, :timeout} = Client.auth_status(pid, 1)

      send(pid, :stop)
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

  # ── handle_in/2 — reaction events ────────────────────────────────────

  describe "handle_in/2 reaction events" do
    test "dispatches reaction_added as a normalized reaction envelope" do
      frame = reaction_frame("reaction_added")

      assert {:ok, state} = Client.handle_in(frame, capturing_sink_state())
      assert state.auth_status == :ok

      assert_received {:sink_called, %Jido.Chat.EventEnvelope{} = envelope, opts}
      assert envelope.event_type == :reaction
      assert envelope.adapter_name == :mattermost
      assert envelope.channel_id == "chan-abc"
      assert envelope.message_id == "post-1"
      assert envelope.thread_id == "mattermost:chan-abc"
      assert opts[:transport] == "websocket"

      assert %{emoji: "thumbsup", added: true, user: %{user_id: "user-123"}} = envelope.payload
    end

    test "marks reaction_removed as not added" do
      frame = reaction_frame("reaction_removed")

      assert {:ok, _state} = Client.handle_in(frame, capturing_sink_state())

      assert_received {:sink_called, envelope, _opts}
      assert envelope.payload.added == false
      assert envelope.metadata.ws_event == "reaction_removed"
    end

    test "carries the emoji name through unchanged" do
      frame = reaction_frame("reaction_added", %{"emoji_name" => "thumbsdown"})

      assert {:ok, _state} = Client.handle_in(frame, capturing_sink_state())

      assert_received {:sink_called, envelope, _opts}
      assert envelope.payload.emoji == "thumbsdown"
    end

    test "filters out the bot's own reactions" do
      frame = reaction_frame("reaction_added", %{"user_id" => "bot-uid"})

      assert {:ok, _state} = Client.handle_in(frame, capturing_sink_state())

      refute_received {:sink_called, _payload, _opts}
    end

    test "filters out reactions from untracked channels" do
      state =
        capturing_sink_state()
        |> Map.put(:channel_ids, ["tracked-chan"])

      frame =
        reaction_frame("reaction_added", %{}, %{
          "data" => %{
            "reaction" =>
              Jason.encode!(%{
                "user_id" => "user-123",
                "post_id" => "post-1",
                "emoji_name" => "thumbsup"
              }),
            "channel_type" => "O"
          },
          "broadcast" => %{"channel_id" => "other-chan"}
        })

      assert {:ok, _state} = Client.handle_in(frame, state)

      refute_received {:sink_called, _payload, _opts}
    end

    test "always tracks reactions in DM channels" do
      state = classified_state({:ok, %{"id" => "chan-abc", "type" => "D"}})
      frame = reaction_frame("reaction_added")

      assert {:ok, _state} = Client.handle_in(frame, state)

      assert_received {:sink_called, _envelope, _opts}
    end

    test "does not crash when the reaction field is not double-encoded JSON" do
      event = %{
        "event" => "reaction_added",
        "data" => %{"reaction" => %{"not" => "a string"}},
        "broadcast" => %{"channel_id" => "chan-abc"}
      }

      assert {:ok, _state} = Client.handle_in({:text, Jason.encode!(event)}, capturing_sink_state())

      refute_received {:sink_called, _envelope, _opts}
    end

    test "does not crash when the reaction payload is missing" do
      event = %{"event" => "reaction_added", "data" => %{}}

      assert {:ok, @base_state} =
               Client.handle_in({:text, Jason.encode!(event)}, @base_state)
    end

    test "does not crash when the broadcast channel is missing" do
      frame = reaction_frame("reaction_added", %{}, %{"broadcast" => %{}})

      assert {:ok, _state} = Client.handle_in(frame, capturing_sink_state())
      refute_received {:sink_called, _envelope, _opts}
    end
  end

  describe "reaction classification without channel_type" do
    for type <- ["D", "G"],
        post_id <- ["root-post", "reply-post"],
        event <- ["reaction_added", "reaction_removed"] do
      test "#{type} #{post_id} #{event} is delivered first after connect and reconnect" do
        state = classified_state({:ok, %{"id" => "chan-abc", "type" => unquote(type)}})
        frame = reaction_frame(unquote(event), %{"post_id" => unquote(post_id)})
        {:reply, _, state} = Client.handle_connect(101, [], state)

        for connection <- [:initial, :reconnected] do
          state =
            if connection == :reconnected do
              {:reconnect, state} = Client.handle_disconnect(1001, "closed", state)
              {:reply, _, state} = Client.handle_connect(101, [], state)
              state
            else
              state
            end

          assert {:ok, %{auth_status: :ok}} = Client.handle_in(frame, state)
          assert_received {:fetch_channel, "chan-abc", opts}
          assert opts[:url] == "https://mattermost.example.com"
          assert opts[:token] == "test-token"
          assert_received {:sink_called, envelope, sink_opts}
          assert envelope.message_id == unquote(post_id)
          assert envelope.channel_id == "chan-abc"
          assert envelope.payload.added == (unquote(event) == "reaction_added")
          assert sink_opts[:transport] == "websocket"
        end
      end
    end

    test "unlisted shared channels, unknown metadata and failures are rejected" do
      for result <- [
            {:ok, %{"id" => "chan-abc", "type" => "O"}},
            {:ok, %{"id" => "chan-abc", "type" => "P"}},
            {:ok, %{"id" => "chan-abc", "type" => "unknown"}},
            {:ok, %{}},
            {:ok, nil},
            {:ok, []},
            {:ok, %{"id" => "wrong-channel", "type" => "D"}},
            {:error, :timeout},
            :raise
          ] do
        assert {:ok, _} = Client.handle_in(reaction_frame("reaction_added"), classified_state(result))
        assert_received {:fetch_channel, "chan-abc", _}
        refute_received {:sink_called, _, _}
      end
    end

    test "failed lookup does not prevent a later successful lookup" do
      state = classified_state({:error, :timeout})
      frame = reaction_frame("reaction_added")
      assert {:ok, state} = Client.handle_in(frame, state)
      refute_received {:sink_called, _, _}

      state =
        Map.put(state, :metadata_opts, classified_state({:ok, %{"id" => "chan-abc", "type" => "D"}}).metadata_opts)

      assert {:ok, _} = Client.handle_in(frame, state)
      assert_received {:sink_called, _, _}
    end

    test "allowlisted shared roots and replies need no metadata lookup" do
      for post_id <- ["root-post", "reply-post"], event <- ["reaction_added", "reaction_removed"] do
        state = Map.put(classified_state({:error, :unexpected}), :channel_ids, ["chan-abc"])
        assert {:ok, _} = Client.handle_in(reaction_frame(event, %{"post_id" => post_id}), state)
        assert_received {:sink_called, envelope, _}
        assert envelope.message_id == post_id
        assert envelope.payload.added == (event == "reaction_added")
        refute_received {:fetch_channel, _, _}
      end
    end

    test "bot reactions and malformed reaction fields do not trigger lookups" do
      for attrs <- [%{"user_id" => "bot-uid"}, %{"user_id" => nil}, %{"post_id" => ""}, %{"emoji_name" => 7}] do
        assert {:ok, _} =
                 Client.handle_in(reaction_frame("reaction_added", attrs), classified_state({:error, :unexpected}))

        refute_received {:fetch_channel, _, _}
        refute_received {:sink_called, _, _}
      end
    end

    test "explicit direct classifications preserve existing behavior without lookups" do
      for type <- ["D", "G"] do
        frame = reaction_frame("reaction_added")
        {:text, json} = frame
        event = Jason.decode!(json)
        event = put_in(event, ["data", "channel_type"], type)
        assert {:ok, _} = Client.handle_in({:text, Jason.encode!(event)}, classified_state(:raise))
        assert_received {:sink_called, _, _}
        refute_received {:fetch_channel, _, _}
      end
    end

    test "invalid channel IDs and unknown explicit types never grant eligibility" do
      for channel_id <- [nil, "", 123] do
        frame = reaction_frame("reaction_added", %{}, %{"broadcast" => %{"channel_id" => channel_id}})
        assert {:ok, _} = Client.handle_in(frame, classified_state(:raise))
        refute_received {:fetch_channel, _, _}
        refute_received {:sink_called, _, _}
      end

      {:text, json} = reaction_frame("reaction_added")
      event = put_in(Jason.decode!(json), ["data", "channel_type"], "unknown")
      assert {:ok, _} = Client.handle_in({:text, Jason.encode!(event)}, classified_state(:raise))
      refute_received {:fetch_channel, _, _}
      refute_received {:sink_called, _, _}
    end

    test "valid map-encoded reactions still reach the sink" do
      {:text, json} = reaction_frame("reaction_added")
      event = Jason.decode!(json)
      event = update_in(event, ["data", "reaction"], &Jason.decode!/1)
      assert {:ok, _} = Client.handle_in({:text, Jason.encode!(event)}, capturing_sink_state())
      assert_received {:sink_called, envelope, _}
      assert envelope.payload.emoji == "thumbsup"
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
      frame = posted_frame(%{"user_id" => "other-user"})
      assert {:ok, _state} = Client.handle_in(frame, raising_sink_state())
    end
  end

  # ── handle_in/2 — channel filtering ──────────────────────────────────

  describe "handle_in/2 channel filtering" do
    test "passes through when channel_ids is :all" do
      frame = posted_frame(%{"channel_id" => "any-channel"})
      assert {:ok, _state} = Client.handle_in(frame, raising_sink_state())
    end

    test "filters out messages from untracked channels, sink never invoked" do
      state = Map.put(@base_state, :channel_ids, ["tracked-chan"])
      frame = posted_frame(%{"channel_id" => "other-chan"})
      assert {:ok, _state} = Client.handle_in(frame, state)
    end

    test "passes through messages from tracked channels" do
      state = Map.put(raising_sink_state(), :channel_ids, ["tracked-chan"])
      frame = posted_frame(%{"channel_id" => "tracked-chan"})
      assert {:ok, _state} = Client.handle_in(frame, state)
    end
  end
end
