defmodule Jido.Chat.Mattermost.ChannelTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{ChannelInfo, Response, Thread}
  alias Jido.Chat.Mattermost.{Adapter, Channel, Listener}
  alias Jido.Chat.Mattermost.Test.RecordingTransport

  test "identity and capabilities match the adapter" do
    assert Channel.channel_type() == :mattermost
    assert Channel.capabilities() == Adapter.capabilities()
  end

  test "normalizes incoming messages" do
    payload = %{"post" => %{"id" => "p1", "channel_id" => "c1", "user_id" => "u1", "message" => "hello"}}
    assert {:ok, incoming} = Channel.transform_incoming(payload)
    assert incoming.external_message_id == "p1"
    assert incoming.external_room_id == "c1"
    assert incoming.text == "hello"
  end

  for {callback, args, transport_callback, transport_args, reply, kind} <- [
        {:send_message, ["c1", "hello"], :send_message, ["c1", "hello"], {:ok, %{"id" => "p1"}}, :response},
        {:edit_message, ["c1", "p1", "updated"], :edit_message, ["c1", "p1", "updated"], {:ok, %{"id" => "p1"}},
         :edited},
        {:delete_message, ["c1", "p1"], :delete_message, ["c1", "p1"], {:ok, %{"id" => "p1"}}, :raw},
        {:start_typing, ["c1"], :send_typing, ["c1"], :ok, :raw},
        {:fetch_metadata, ["c1"], :fetch_channel, ["c1"],
         {:ok, %{"id" => "c1", "type" => "O", "display_name" => "General"}}, :channel},
        {:fetch_thread, ["root"], :fetch_thread, ["root"], {:ok, %{"posts" => %{}}}, :thread},
        {:fetch_message, ["c1", "p1"], :fetch_post, ["p1"], {:ok, %{"id" => "p1"}}, :raw},
        {:fetch_media, ["file1"], :download_file, ["file1"], {:ok, "bytes"}, :raw},
        {:add_reaction, ["c1", "p1", "+1"], :add_reaction, ["p1", "+1"], {:ok, %{"emoji_name" => "+1"}}, :raw},
        {:remove_reaction, ["c1", "p1", "+1"], :remove_reaction, ["p1", "+1", "u1"], {:ok, %{"emoji_name" => "+1"}},
         :raw},
        {:fetch_messages, ["c1"], :fetch_posts, ["c1"], {:ok, %{"posts" => []}}, :raw},
        {:fetch_channel_messages, ["c1"], :fetch_posts, ["c1"], {:ok, %{"posts" => []}}, :raw}
      ] do
    @callback_name callback
    @args args
    @transport_callback transport_callback
    @transport_args transport_args
    @reply reply
    @kind kind

    test "#{callback} forwards arguments and preserves the adapter result" do
      opts = [
        transport: RecordingTransport,
        token: "test-token",
        url: "https://chat.example.com",
        user_id: "u1",
        channel_id: "c1",
        limit: 25
      ]

      Process.put({RecordingTransport, @transport_callback}, @reply)
      result = apply(Channel, @callback_name, @args ++ [opts])
      assert_receive {:transport_call, @transport_callback, forwarded}
      assert Enum.drop(forwarded, -1) == @transport_args
      assert List.last(forwarded)[:token] == "test-token"
      assert List.last(forwarded)[:url] == opts[:url]

      case @kind do
        :response -> assert {:ok, %Response{external_message_id: "p1", external_room_id: "c1", status: :sent}} = result
        :edited -> assert {:ok, %Response{external_message_id: "p1", status: :edited}} = result
        :channel -> assert {:ok, %ChannelInfo{id: "c1", name: "General"}} = result
        :thread -> assert {:ok, %Thread{external_thread_id: "root", external_room_id: "c1"}} = result
        :raw -> assert result == @reply
      end
    end
  end

  test "preserves transport errors" do
    Process.put({RecordingTransport, :edit_message}, {:error, :forbidden})
    assert {:error, :forbidden} = Channel.edit_message("c1", "p1", "text", transport: RecordingTransport)
  end

  test "forwards listener configuration" do
    opts = [url: "https://chat.example.com", token: "test-token", sink_mfa: {__MODULE__, :sink, []}]
    assert {:ok, [spec]} = Channel.listener_child_specs("bridge", opts)
    assert spec.id == {Listener, "bridge"}
    assert {Listener, :start_link, [forwarded]} = spec.start
    assert forwarded == Keyword.put(opts, :bridge_id, "bridge")
  end
end
