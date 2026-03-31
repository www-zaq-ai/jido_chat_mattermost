# Jido Chat Mattermost

`jido_chat_mattermost` is the Mattermost adapter package for `jido_chat`.

## Experimental Status

This package is experimental and pre-1.0. APIs and behavior will change. It is part of the Elixir implementation aligned to the Vercel Chat SDK ([chat-sdk.dev/docs](https://www.chat-sdk.dev/docs)).

`Jido.Chat.Mattermost.Adapter` is the canonical adapter module and uses `Req` as the HTTP transport against the Mattermost REST API v4.

`Jido.Chat.Mattermost.Channel` is kept as a compatibility wrapper for legacy `Jido.Chat.Channel` integrations.

## Installation

```elixir
def deps do
  [
    {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
    {:jido_chat_mattermost, github: "agentjido/jido_chat_mattermost", branch: "main"}
  ]
end
```

## Usage

```elixir
alias Jido.Chat.Mattermost.Adapter

# Normalize an inbound Mattermost webhook payload
{:ok, incoming} =
  Adapter.transform_incoming(%{
    "post" => %{
      "id" => "abc123",
      "channel_id" => "ch001",
      "user_id" => "usr001",
      "message" => "@zaq what is the leave policy?",
      "root_id" => ""
    },
    "channel_display_name" => "general",
    "channel_type" => "O"
  })

# Send a reply
{:ok, sent} = Adapter.send_message("ch001", "Here is the leave policy...", token: "my-token")

# Reply in a thread
{:ok, sent} = Adapter.send_message("ch001", "reply text", token: "my-token", thread_id: "root-post-id")

# Add a reaction
:ok = Adapter.add_reaction("ch001", "post-id", "white_check_mark", token: "my-token")

# Fetch last 10 messages
{:ok, page} = Adapter.fetch_messages("ch001", limit: 10, token: "my-token")

# Fetch a specific post (e.g. from a shared post reference)
{:ok, message} = Adapter.fetch_message("ch001", "post-id", token: "my-token")
```

## Ingress Modes (`listener_child_specs/2`)

Mattermost uses **outgoing webhooks** — there is no persistent gateway connection.

`Jido.Chat.Mattermost.Adapter.listener_child_specs/2` always returns `{:ok, []}`. The host application is responsible for receiving webhook HTTP requests and routing them through `Jido.Chat.handle_webhook_request/4`.

```elixir
chat =
  Jido.Chat.new(user_name: "zaq", adapters: %{mattermost: Jido.Chat.Mattermost.Adapter})
  |> Jido.Chat.on_new_mention(fn thread, incoming ->
    # incoming is a normalized %Jido.Chat.Incoming{}
    Jido.Chat.Thread.post(thread, "Hello #{incoming.display_name}!")
  end)

# In your webhook controller:
{:ok, chat, _envelope, response} =
  Jido.Chat.handle_webhook_request(chat, :mattermost, conn.body_params, token: "my-token")
```

## Configuration

Token and base URL can be provided per-call via opts or set globally:

```elixir
# config/runtime.exs
config :jido_chat_mattermost,
  url: "https://mattermost.yourcompany.com",
  token: System.get_env("MATTERMOST_BOT_TOKEN")
```

## Capability Matrix

| Capability | Status |
|---|---|
| send / edit / delete message | native |
| start typing | native |
| fetch channel metadata | native |
| fetch thread | native |
| fetch message by ID | native |
| add / remove reaction | native |
| fetch messages (history) | native |
| webhook ingress + verification | native |
| send file | unsupported (tracked upstream) |
| ephemeral message | unsupported |
| open DM | unsupported |
| list threads | unsupported |
| modal | unsupported |
