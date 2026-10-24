defmodule Jido.Chat.Mattermost.ListenerTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.Listener
  alias Jido.Chat.Mattermost.WebSocket.Client

  defmodule FakeStarter do
    def start_link(uri, client, state, opts) do
      send(self(), {:websocket_start, uri, client, state, opts})
      Process.get({__MODULE__, :result}, {:ok, self()})
    end
  end

  @base_opts [
    url: "https://mattermost.example.com",
    token: "tok",
    bot_user_id: "bot-uid",
    bot_name: "zaq",
    channel_ids: :all,
    bridge_id: "mattermost_1",
    oban_worker: FakeWorker,
    config_id: 1
  ]

  # ── child_spec/1 ──────────────────────────────────────────────────────

  describe "child_spec/1" do
    test "returns a map with the correct keys" do
      spec = Listener.child_spec(@base_opts)

      assert %{id: _, start: _, restart: _, type: _} = spec
    end

    test "id is namespaced by bridge_id to allow multiple instances" do
      spec1 = Listener.child_spec(@base_opts)
      spec2 = Listener.child_spec(Keyword.put(@base_opts, :bridge_id, "mattermost_2"))

      assert spec1.id != spec2.id
    end

    test "id encodes the bridge_id" do
      spec = Listener.child_spec(@base_opts)
      assert {Listener, "mattermost_1"} = spec.id
    end

    test "restart is :permanent" do
      spec = Listener.child_spec(@base_opts)
      assert spec.restart == :permanent
    end

    test "type is :worker" do
      spec = Listener.child_spec(@base_opts)
      assert spec.type == :worker
    end

    test "start points to Listener.start_link/1" do
      spec = Listener.child_spec(@base_opts)
      assert {Listener, :start_link, [_opts]} = spec.start
    end

    test "preserves per-instance metadata transport and credentials in start options" do
      for {bridge_id, url, token} <- [
            {"instance-a", "https://a.example.com", "token-a"},
            {"instance-b", "https://b.example.com", "token-b"}
          ] do
        opts = [bridge_id: bridge_id, url: url, token: token, transport: FakeTransport]
        assert %{start: {Listener, :start_link, [^opts]}} = Listener.child_spec(opts)
      end
    end
  end

  describe "start_link/1" do
    setup do
      {:ok,
       opts: [
         url: "https://chat.example.com",
         token: "test-token",
         bridge_id: "bridge",
         sink_mfa: {__MODULE__, :sink, []},
         websocket_starter: FakeStarter
       ]}
    end

    test "constructs secure and plain WebSocket URIs including ports and subpaths", %{opts: opts} do
      for {url, expected} <- [
            {"https://chat.example.com", "wss://chat.example.com/api/v4/websocket"},
            {"http://localhost:8065", "ws://localhost:8065/api/v4/websocket"},
            {"https://chat.example.com:8443/mattermost", "wss://chat.example.com:8443/mattermost/api/v4/websocket"}
          ] do
        assert {:ok, pid} = Listener.start_link(Keyword.put(opts, :url, url))
        assert pid == self()
        assert_receive {:websocket_start, ^expected, Client, state, []}
        assert state.url == url
      end
    end

    test "passes the client module and default state without unrelated options", %{opts: opts} do
      assert {:ok, _} = Listener.start_link(opts ++ [unrelated: :ignored])
      assert_receive {:websocket_start, _, Client, state, []}

      assert state == %{
               token: "test-token",
               url: opts[:url],
               bot_user_id: nil,
               bot_name: nil,
               channel_ids: :all,
               metadata_opts: Keyword.take(opts, [:url, :token]),
               bridge_id: "bridge",
               sink_mfa: opts[:sink_mfa],
               sink_opts: []
             }
    end

    test "preserves explicit bot, allowlist, sink and metadata configuration", %{opts: opts} do
      extra = [
        bot_user_id: "bot",
        bot_name: "helper",
        channel_ids: ["c1"],
        sink_opts: [custom: true],
        transport: FakeTransport
      ]

      assert {:ok, _} = Listener.start_link(opts ++ extra)
      assert_receive {:websocket_start, _, Client, state, []}
      assert state.bot_user_id == "bot"
      assert state.bot_name == "helper"
      assert state.channel_ids == ["c1"]
      assert state.sink_mfa == opts[:sink_mfa]
      assert state.sink_opts == [custom: true]
      assert Map.new(state.metadata_opts) == %{url: opts[:url], token: "test-token", transport: FakeTransport}
    end

    test "instances retain independent credentials and bridge configuration", %{opts: opts} do
      for id <- ["a", "b"] do
        configured = Keyword.merge(opts, bridge_id: id, url: "https://#{id}.example.com", token: "test-token-#{id}")
        assert {:ok, _} = Listener.start_link(configured)
        assert_receive {:websocket_start, _, Client, state, []}
        assert state.bridge_id == id
        assert state.url == configured[:url]
        assert state.token == configured[:token]
        assert state.metadata_opts[:url] == configured[:url]
        assert state.metadata_opts[:token] == configured[:token]
      end
    end

    test "missing required options raise before starting a connection", %{opts: opts} do
      for key <- [:url, :token, :bridge_id, :sink_mfa] do
        assert_raise KeyError, fn -> Listener.start_link(Keyword.delete(opts, key)) end
        refute_received {:websocket_start, _, _, _, _}
      end
    end

    test "preserves starter errors", %{opts: opts} do
      Process.put({FakeStarter, :result}, {:error, :connection_refused})
      assert {:error, :connection_refused} = Listener.start_link(opts)
      assert_receive {:websocket_start, _, Client, _, []}
    end
  end
end
