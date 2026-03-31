defmodule Jido.Chat.Mattermost.Transport.ReqClientTest do
  use ExUnit.Case, async: true

  # Integration tests for the real HTTP client.
  # These are skipped in CI unless MATTERMOST_URL and MATTERMOST_TOKEN are set.
  @moduletag :integration

  @url System.get_env("MATTERMOST_URL", "")
  @token System.get_env("MATTERMOST_TOKEN", "")
  @channel_id System.get_env("MATTERMOST_CHANNEL_ID", "")

  @skip @url == "" or @token == "" or @channel_id == ""

  setup do
    if @skip, do: {:skip, "Set MATTERMOST_URL, MATTERMOST_TOKEN, MATTERMOST_CHANNEL_ID to run"}
    :ok
  end

  alias Jido.Chat.Mattermost.Transport.ReqClient

  defp opts, do: [url: @url, token: @token]

  test "send_message/3 creates a post" do
    assert {:ok, post} =
             ReqClient.send_message(@channel_id, "req_client_test #{DateTime.utc_now()}", opts())

    assert is_binary(post["id"])
    assert post["channel_id"] == @channel_id
  end

  test "fetch_posts/2 returns channel posts" do
    assert {:ok, result} = ReqClient.fetch_posts(@channel_id, Keyword.put(opts(), :limit, 5))
    assert is_map(result)
  end

  test "fetch_channel/2 returns channel metadata" do
    assert {:ok, channel} = ReqClient.fetch_channel(@channel_id, opts())
    assert is_binary(channel["id"])
  end
end
