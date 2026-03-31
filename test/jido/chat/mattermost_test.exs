defmodule Jido.Chat.MattermostTest do
  use ExUnit.Case
  doctest Jido.Chat.Mattermost

  test "greets the world" do
    assert Jido.Chat.Mattermost.hello() == :world
  end
end
