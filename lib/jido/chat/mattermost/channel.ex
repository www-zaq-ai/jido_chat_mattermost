defmodule Jido.Chat.Mattermost.Channel do
  @moduledoc """
  Legacy `Jido.Chat.Channel` compatibility wrapper for the Mattermost adapter.

  Delegates all operations to `Jido.Chat.Mattermost.Adapter`.
  """

  alias Jido.Chat.Mattermost.Adapter

  @doc "Returns the Mattermost channel type."
  defdelegate channel_type(), to: Adapter
  @doc "Returns the Mattermost adapter capability matrix."
  defdelegate capabilities(), to: Adapter
  @doc "Normalizes a Mattermost webhook or WebSocket payload into Jido chat data."
  defdelegate transform_incoming(payload), to: Adapter
  @doc "Sends a Mattermost post to a channel."
  defdelegate send_message(channel_id, text, opts), to: Adapter
  @doc "Edits an existing Mattermost post."
  defdelegate edit_message(channel_id, post_id, text, opts), to: Adapter
  @doc "Deletes an existing Mattermost post."
  defdelegate delete_message(channel_id, post_id, opts), to: Adapter
  @doc "Starts a typing indicator when the Mattermost transport supports it."
  defdelegate start_typing(channel_id, opts), to: Adapter
  @doc "Fetches channel metadata from Mattermost."
  defdelegate fetch_metadata(channel_id, opts), to: Adapter
  @doc "Fetches a Mattermost thread by root post id."
  defdelegate fetch_thread(root_id, opts), to: Adapter
  @doc "Fetches a Mattermost post by channel and post id."
  defdelegate fetch_message(channel_id, post_id, opts), to: Adapter
  @doc "Adds a reaction to a Mattermost post."
  defdelegate add_reaction(channel_id, post_id, emoji, opts), to: Adapter
  @doc "Removes a reaction from a Mattermost post."
  defdelegate remove_reaction(channel_id, post_id, emoji, opts), to: Adapter
  @doc "Fetches Mattermost messages using adapter-level options."
  defdelegate fetch_messages(channel_id, opts), to: Adapter
  @doc "Fetches Mattermost channel messages."
  defdelegate fetch_channel_messages(channel_id, opts), to: Adapter
  @doc "Builds listener child specs for Mattermost ingress."
  defdelegate listener_child_specs(adapter_config, ingress_config), to: Adapter
end
