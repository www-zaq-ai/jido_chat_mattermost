defmodule Jido.Chat.Mattermost.Channel do
  @moduledoc """
  Legacy `Jido.Chat.Channel` compatibility wrapper for the Mattermost adapter.

  Delegates all operations to `Jido.Chat.Mattermost.Adapter`.
  """

  alias Jido.Chat.Mattermost.Adapter

  defdelegate channel_type(), to: Adapter
  defdelegate capabilities(), to: Adapter
  defdelegate transform_incoming(payload), to: Adapter
  defdelegate send_message(channel_id, text, opts), to: Adapter
  defdelegate edit_message(channel_id, post_id, text, opts), to: Adapter
  defdelegate delete_message(channel_id, post_id, opts), to: Adapter
  defdelegate start_typing(channel_id, opts), to: Adapter
  defdelegate fetch_metadata(channel_id, opts), to: Adapter
  defdelegate fetch_thread(root_id, opts), to: Adapter
  defdelegate fetch_message(channel_id, post_id, opts), to: Adapter
  defdelegate add_reaction(channel_id, post_id, emoji, opts), to: Adapter
  defdelegate remove_reaction(channel_id, post_id, emoji, opts), to: Adapter
  defdelegate fetch_messages(channel_id, opts), to: Adapter
  defdelegate fetch_channel_messages(channel_id, opts), to: Adapter
  defdelegate listener_child_specs(adapter_config, ingress_config), to: Adapter
end
