defmodule Jido.Chat.Mattermost.Transport do
  @moduledoc """
  Behaviour defining the HTTP transport contract for the Mattermost adapter.

  Implement this behaviour to swap out the real HTTP client with a test double
  without hitting a live Mattermost server.
  """

  @callback send_message(channel_id :: String.t(), text :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback edit_message(
              channel_id :: String.t(),
              post_id :: String.t(),
              text :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback delete_message(channel_id :: String.t(), post_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback add_reaction(post_id :: String.t(), emoji :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback remove_reaction(
              post_id :: String.t(),
              emoji :: String.t(),
              user_id :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_posts(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_post(post_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_thread(root_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback fetch_channel(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback send_typing(channel_id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback get_user(user_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
