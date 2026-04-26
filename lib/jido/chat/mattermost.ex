defmodule Jido.Chat.Mattermost do
  @moduledoc "Mattermost adapter package for Jido.Chat. Uses Req as HTTP transport."

  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Mattermost.Channel

  @doc "Returns the canonical Mattermost adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter

  @doc "Returns the legacy Mattermost channel compatibility module."
  @spec channel() :: module()
  def channel, do: Channel
end
