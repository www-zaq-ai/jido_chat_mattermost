defmodule Jido.Chat.Mattermost.Transport.ReqClientTest do
  use ExUnit.Case, async: true

  # Integration tests for the real HTTP client.
  # Excluded by default; CI bootstraps an ephemeral server and includes this tag.
  @moduletag :integration

  @url System.get_env("MATTERMOST_URL", "")
  @token System.get_env("MATTERMOST_TOKEN", "")
  @channel_id System.get_env("MATTERMOST_CHANNEL_ID", "")
  @file_id System.get_env("MATTERMOST_FILE_ID", "")

  alias Jido.Chat.Mattermost.Transport.ReqClient

  defp opts, do: [url: @url, token: @token]

  defp create_post(text, extra_opts \\ []) do
    assert {:ok, post} = ReqClient.send_message(@channel_id, text, opts() ++ extra_opts)
    on_exit(fn -> ReqClient.delete_message(@channel_id, post["id"], opts()) end)
    post
  end

  defp reactions(post_id) do
    # Read-only verification endpoint; production reaction writes still use ReqClient.
    {:ok, response} =
      Req.get(@url <> "/api/v4/posts/#{post_id}/reactions",
        headers: [{"Authorization", "Bearer #{@token}"}]
      )

    assert response.status == 200
    # Mattermost returns JSON null rather than [] when the last reaction is removed.
    assert is_nil(response.body) or is_list(response.body)
    response.body || []
  end

  test "send_message/3 creates a post" do
    post = create_post("req_client_test #{DateTime.utc_now()}")

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

  test "download_file/2 returns attachment bytes" do
    assert {:ok, bytes} = ReqClient.download_file(@file_id, opts())
    assert is_binary(bytes) and byte_size(bytes) > 0
  end

  test "message lifecycle sends, fetches, edits, and deletes a post" do
    post = create_post("message lifecycle")
    post_id = post["id"]

    assert {:ok, fetched} = ReqClient.fetch_post(post_id, opts())
    assert fetched["message"] == "message lifecycle"
    assert fetched["channel_id"] == @channel_id

    assert {:ok, edited} = ReqClient.edit_message(@channel_id, post_id, "updated message", opts())
    assert edited["id"] == post_id
    assert edited["message"] == "updated message"
    assert {:ok, fetched} = ReqClient.fetch_post(post_id, opts())
    assert fetched["message"] == "updated message"

    assert {:ok, _} = ReqClient.delete_message(@channel_id, post_id, opts())
    assert {:error, {404, _}} = ReqClient.fetch_post(post_id, opts())
  end

  test "thread replies reference their root and appear in the fetched thread" do
    root = create_post("thread root")
    reply = create_post("thread reply", thread_id: root["id"])

    assert reply["root_id"] == root["id"]
    assert {:ok, thread} = ReqClient.fetch_thread(root["id"], opts())
    assert MapSet.new(thread["order"]) == MapSet.new([root["id"], reply["id"]])
    assert thread["posts"][root["id"]]["message"] == "thread root"
    assert thread["posts"][reply["id"]]["message"] == "thread reply"
    assert thread["posts"][reply["id"]]["root_id"] == root["id"]
  end

  test "reactions resolve the authenticated user, accept an explicit user, and can be removed" do
    post = create_post("reaction target")
    assert {:ok, user} = ReqClient.get_user("me", opts())
    user_id = user["id"]

    for reaction_opts <- [opts(), Keyword.put(opts(), :user_id, user_id)] do
      assert {:ok, reaction} = ReqClient.add_reaction(post["id"], "thumbsup", reaction_opts)
      assert reaction["post_id"] == post["id"]
      assert reaction["user_id"] == user_id
      assert reaction["emoji_name"] == "thumbsup"

      assert Enum.any?(reactions(post["id"]), fn item ->
               item["user_id"] == user_id and item["emoji_name"] == "thumbsup"
             end)

      assert {:ok, _} = ReqClient.remove_reaction(post["id"], "thumbsup", user_id, opts())
      refute Enum.any?(reactions(post["id"]), &(&1["emoji_name"] == "thumbsup"))
    end
  end

  test "the server accepts a typing notification" do
    assert :ok = ReqClient.send_typing(@channel_id, opts())
  end

  @tag :tmp_dir
  test "path-backed and byte-backed uploads attach to posts and download unchanged", %{tmp_dir: tmp_dir} do
    bytes = <<0, 1, 2, 127, 128, 254, 255>> <> "Mattermost binary attachment\n"
    path = Path.join(tmp_dir, "path-fixture.bin")
    File.write!(path, bytes)

    for {file, expected_name} <- [
          {%{path: path}, "path-fixture.bin"},
          {%{body: bytes, filename: "bytes-fixture.bin", content_type: "application/octet-stream"}, "bytes-fixture.bin"}
        ] do
      assert {:ok, uploaded} = ReqClient.upload_file(@channel_id, file, opts())
      assert [info] = uploaded["file_infos"]
      assert info["name"] == expected_name
      assert info["size"] == byte_size(bytes)

      post = create_post("uploaded attachment", file_ids: [info["id"]])
      assert post["file_ids"] == [info["id"]]
      assert {:ok, fetched} = ReqClient.fetch_post(post["id"], opts())
      assert fetched["file_ids"] == [info["id"]]
      assert {:ok, ^bytes} = ReqClient.download_file(info["id"], opts())
    end
  end
end
