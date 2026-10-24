defmodule Jido.Chat.Mattermost.TypingOptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.TypingOptions

  test "empty and partial configuration omit nil transport options" do
    assert TypingOptions.transport_opts(TypingOptions.new()) == []

    assert TypingOptions.transport_opts(TypingOptions.new(token: "test-token")) ==
             [token: "test-token"]

    assert TypingOptions.transport_opts(TypingOptions.new(url: "https://chat.example.com")) ==
             [url: "https://chat.example.com"]
  end
end
