defmodule Jido.Chat.Mattermost.Transport.ReqClient do
  @moduledoc """
  Req-based Mattermost REST API v4 HTTP client.

  Resolves base URL and token from (in priority order):
    1. `opts[:url]` / `opts[:token]`
    2. `Application.get_env(:jido_chat_mattermost, :url)` / `:token`
  """

  @behaviour Jido.Chat.Mattermost.Transport

  @impl true
  def send_message(channel_id, text, opts) do
    body =
      %{"channel_id" => channel_id, "message" => text || ""}
      |> Map.merge(thread_params(opts))
      |> maybe_put_body("file_ids", opts[:file_ids])

    post("/api/v4/posts", body, opts)
  end

  @impl true
  def upload_file(channel_id, %{path: path} = file, opts)
      when is_binary(path) and path != "" do
    file_part =
      {File.stream!(path, [], 2048), multipart_file_options(file, Map.get(file, :filename) || Path.basename(path))}

    post_multipart("/api/v4/files", [channel_id: channel_id, files: file_part], opts)
  end

  def upload_file(channel_id, %{body: body, filename: filename} = file, opts)
      when is_binary(body) and body != "" and is_binary(filename) and filename != "" do
    file_part = {body, multipart_file_options(file, filename)}

    post_multipart("/api/v4/files", [channel_id: channel_id, files: file_part], opts)
  end

  def upload_file(_channel_id, _file, _opts), do: {:error, :missing_file_source}

  @impl true
  def edit_message(_channel_id, post_id, text, opts) do
    put("/api/v4/posts/#{post_id}", %{"id" => post_id, "message" => text}, opts)
  end

  @impl true
  def delete_message(_channel_id, post_id, opts) do
    delete("/api/v4/posts/#{post_id}", opts)
  end

  @impl true
  def add_reaction(post_id, emoji, opts) do
    with {:ok, user_id} <- resolve_user_id(opts) do
      body = %{"user_id" => user_id, "post_id" => post_id, "emoji_name" => emoji}
      post("/api/v4/reactions", body, opts)
    end
  end

  @impl true
  def remove_reaction(post_id, emoji, user_id, opts) do
    delete("/api/v4/users/#{user_id}/posts/#{post_id}/reactions/#{emoji}", opts)
  end

  @impl true
  def fetch_posts(channel_id, opts) do
    params = build_fetch_params(opts)
    get("/api/v4/channels/#{channel_id}/posts", params, opts)
  end

  @impl true
  def fetch_post(post_id, opts) do
    get("/api/v4/posts/#{post_id}", [], opts)
  end

  @impl true
  def fetch_thread(root_id, opts) do
    get("/api/v4/posts/#{root_id}/thread", [], opts)
  end

  @impl true
  def fetch_channel(channel_id, opts) do
    get("/api/v4/channels/#{channel_id}", [], opts)
  end

  @impl true
  def send_typing(channel_id, opts) do
    case post("/api/v4/users/me/typing", %{"channel_id" => channel_id}, opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def get_user(user_id, opts) do
    get("/api/v4/users/#{user_id}", [], opts)
  end

  @doc """
  Creates or returns the existing DM channel between two users.

  Requires the bot user ID and the target user ID. Returns the channel map on
  success, including `"id"` which can be used as a `channel_id` for sending.

      ReqClient.open_dm_channel(bot_user_id, target_user_id, opts)
  """
  @impl true
  def open_dm_channel(bot_user_id, target_user_id, opts) do
    post("/api/v4/channels/direct", [bot_user_id, target_user_id], opts)
  end

  @doc "Lists all teams the bot belongs to."
  def list_teams(opts) do
    get("/api/v4/users/me/teams", [], opts)
  end

  @doc "Lists public channels for a given team."
  def list_public_channels(team_id, opts) do
    get("/api/v4/teams/#{team_id}/channels", [per_page: 200], opts)
  end

  # --- private helpers ---

  defp resolve_user_id(opts) do
    case opts[:user_id] do
      nil ->
        case get("/api/v4/users/me", [], opts) do
          {:ok, %{"id" => id}} -> {:ok, id}
          {:error, _} = err -> err
        end

      user_id ->
        {:ok, user_id}
    end
  end

  defp thread_params(opts) do
    case opts[:thread_id] do
      nil -> %{}
      root_id -> %{"root_id" => root_id}
    end
  end

  defp build_fetch_params(opts) do
    []
    |> maybe_put(:per_page, opts[:limit])
    |> maybe_put(:before, opts[:before])
    |> maybe_put(:after, opts[:after])
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: [{key, value} | params]

  defp maybe_put_body(body, _key, value) when value in [nil, []], do: body
  defp maybe_put_body(body, key, value), do: Map.put(body, key, value)

  defp multipart_file_options(file, filename) do
    []
    |> Keyword.put(:filename, filename)
    |> maybe_put(:content_type, Map.get(file, :content_type))
  end

  defp base_url(opts) do
    opts[:url] || Application.get_env(:jido_chat_mattermost, :url) ||
      raise "Mattermost URL not configured. Set opts[:url] or config :jido_chat_mattermost, url: ..."
  end

  defp token(opts) do
    opts[:token] || Application.get_env(:jido_chat_mattermost, :token) ||
      raise "Mattermost token not configured. Set opts[:token] or config :jido_chat_mattermost, token: ..."
  end

  defp auth_headers(opts), do: [{"Authorization", "Bearer #{token(opts)}"}]

  defp post(path, body, opts) do
    url = base_url(opts) <> path

    case Req.post(url, json: body, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_multipart(path, form, opts) do
    url = base_url(opts) <> path

    case Req.post(url, form_multipart: form, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put(path, body, opts) do
    url = base_url(opts) <> path

    case Req.put(url, json: body, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete(path, opts) do
    url = base_url(opts) <> path

    case Req.delete(url, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(path, params, opts) do
    url = base_url(opts) <> path

    case Req.get(url, params: params, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
