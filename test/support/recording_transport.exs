defmodule Jido.Chat.Mattermost.Test.RecordingTransport do
  @moduledoc false
  @behaviour Jido.Chat.Mattermost.Transport

  for {name, arity} <- [
        send_message: 3,
        upload_file: 3,
        download_file: 2,
        edit_message: 4,
        delete_message: 3,
        add_reaction: 3,
        remove_reaction: 4,
        fetch_posts: 2,
        fetch_post: 2,
        fetch_thread: 2,
        fetch_channel: 2,
        send_typing: 2,
        get_user: 2,
        open_dm_channel: 3
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(name)(unquote_splicing(args)) do
      send(self(), {:transport_call, unquote(name), [unquote_splicing(args)]})
      Process.get({__MODULE__, unquote(name)}, {:error, :unexpected_call})
    end
  end
end
