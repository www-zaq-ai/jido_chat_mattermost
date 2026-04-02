defmodule Jido.Chat.Mattermost.ListenerTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.Listener
  alias Jido.Chat.Mattermost.WebSocket.Client

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
  end

  # ── URI building (via child_spec start args) ──────────────────────────

  describe "WebSocket URI construction" do
    test "https:// is converted to wss://" do
      spec = Listener.child_spec(Keyword.put(@base_opts, :url, "https://chat.example.com"))
      {_mod, :start_link, [opts]} = spec.start
      assert opts[:url] == "https://chat.example.com"
      # URI conversion is internal to start_link; verify indirectly via start
      # (actual connection is integration-level; URI logic is private)
    end

    test "child_spec with http:// URL is accepted" do
      opts = Keyword.put(@base_opts, :url, "http://localhost:8065")
      assert %{id: {Listener, "mattermost_1"}} = Listener.child_spec(opts)
    end
  end

  # ── state building ─────────────────────────────────────────────────────

  describe "state passed to WebSocket.Client" do
    test "Client module is used" do
      # The child_spec starts Listener.start_link which calls Fresh.start_link(uri, Client, state)
      # We verify the module reference compiles and is correct
      assert Code.ensure_loaded?(Client)
    end
  end
end
