defmodule Jido.Chat.Mattermost.DeleteOptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.DeleteOptions

  test "empty and partial configuration omit nil transport options" do
    assert DeleteOptions.transport_opts(DeleteOptions.new()) == []

    assert DeleteOptions.transport_opts(DeleteOptions.new(token: "test-token")) ==
             [token: "test-token"]

    assert DeleteOptions.transport_opts(DeleteOptions.new(url: "https://chat.example.com")) ==
             [url: "https://chat.example.com"]
  end
end
