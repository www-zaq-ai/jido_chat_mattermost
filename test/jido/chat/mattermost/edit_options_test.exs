defmodule Jido.Chat.Mattermost.EditOptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost.EditOptions
  alias Jido.Chat.Mattermost.Test.RecordingTransport

  test "defaults contain no credentials or transport options" do
    assert %EditOptions{token: nil, url: nil, transport: nil} = options = EditOptions.new()
    assert EditOptions.transport_opts(options) == []
  end

  test "retains configuration but forwards only credentials" do
    options =
      EditOptions.new(
        token: "test-token",
        url: "https://chat.example.com",
        transport: RecordingTransport,
        unrelated: :ignored
      )

    assert options.transport == RecordingTransport

    assert Map.new(EditOptions.transport_opts(options)) == %{
             token: "test-token",
             url: "https://chat.example.com"
           }
  end

  test "partial configuration omits nil fields" do
    assert EditOptions.transport_opts(EditOptions.new(token: "test-token")) == [token: "test-token"]

    assert EditOptions.transport_opts(EditOptions.new(url: "https://chat.example.com")) ==
             [url: "https://chat.example.com"]
  end
end
