defmodule Jido.Chat.MattermostTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Mattermost

  test "adapter/0 returns the adapter module" do
    assert Mattermost.adapter() == Jido.Chat.Mattermost.Adapter
  end

  test "channel/0 returns the channel wrapper module" do
    assert Mattermost.channel() == Jido.Chat.Mattermost.Channel
  end
end
