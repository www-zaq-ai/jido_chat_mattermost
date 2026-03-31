defmodule Jido.Chat.Mattermost do
  @moduledoc "Mattermost adapter package for Jido.Chat. Uses Req as HTTP transport."

  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Channel

  def adapter, do: Adapter
  def channel, do: Channel
end
