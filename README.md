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

## Configuration

Token and base URL can be provided per-call via opts or set globally:

```elixir
# config/runtime.exs
config :jido_chat_mattermost,
  url: "https://mattermost.yourcompany.com",
  token: System.get_env("MATTERMOST_BOT_TOKEN")
```

## Usage

```elixir
alias Jido.Chat.Mattermost.Adapter

# Normalize an inbound Mattermost event payload
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

# Upload and send a file
{:ok, sent} =
  Adapter.send_file("ch001",
    %{path: "/tmp/report.pdf", filename: "report.pdf", media_type: "application/pdf"},
    token: "my-token",
    caption: "Latest report"
  )

# Edit a message
{:ok, updated} = Adapter.edit_message("ch001", "post-id", "updated text", token: "my-token")

# Delete a message
{:ok, _} = Adapter.delete_message("ch001", "post-id", token: "my-token")

# Add a reaction
:ok = Adapter.add_reaction("ch001", "post-id", "white_check_mark", token: "my-token")

# Remove a reaction
:ok = Adapter.remove_reaction("ch001", "post-id", "white_check_mark", token: "my-token", user_id: "usr001")

# Fetch last 10 messages
{:ok, page} = Adapter.fetch_messages("ch001", limit: 10, token: "my-token")

# Fetch a specific post
{:ok, message} = Adapter.fetch_message("ch001", "post-id", token: "my-token")

# Fetch a thread by root post ID
{:ok, thread} = Adapter.fetch_thread("root-post-id", token: "my-token")

# Look up a user (returns the Mattermost user map with a synthesized "display_name" key)
{:ok, user} = Adapter.get_user("usr001", token: "my-token")

# Open (or retrieve) a DM channel between the bot and a user
{:ok, channel} = Adapter.open_dm_channel("bot-user-id", "target-user-id", token: "my-token")
```

## Ingress (WebSocket Listener)

Mattermost ingress uses a **persistent WebSocket connection** (`/api/v4/websocket`).
`listener_child_specs/2` returns a child spec for `Jido.Chat.Mattermost.Listener`, which
wraps a Fresh-based WebSocket client. Add it to your supervision tree:

```elixir
children = [
  Jido.Chat.Mattermost.Listener.child_spec(
    bridge_id: :my_bot,
    url: "https://mattermost.yourcompany.com",
    token: System.get_env("MATTERMOST_BOT_TOKEN"),
    bot_user_id: "bot-user-id",
    bot_name: "zaq",
    channel_ids: :all,                            # or a list of channel ID strings
    sink_mfa: {MyApp.Handler, :handle_incoming, []}
  )
]
```

Each incoming WebSocket event is normalized to a `%Jido.Chat.Incoming{}` struct and
delivered via `sink_mfa`. Multiple Mattermost instances can coexist on the same node
by using distinct `bridge_id` values.

## Transport

The default HTTP transport is `Jido.Chat.Mattermost.Transport.ReqClient`. Swap it out
for tests by injecting a module that implements the `Jido.Chat.Mattermost.Transport`
behaviour:

```elixir
Adapter.send_message("ch001", "hello", transport: MyFakeTransport, token: "x")
```

## Capability Matrix

| Capability | Status |
|---|---|
| send message | native |
| edit message | native |
| delete message | native |
| start typing | native |
| fetch channel metadata | native |
| fetch thread | native |
| fetch message by ID | native |
| add reaction | native |
| remove reaction | native |
| fetch messages (history) | native |
| fetch channel messages | native |
| open DM channel | native |
| post ephemeral message | unsupported |
| list threads | unsupported |
| modal | unsupported |
| webhook ingress | unsupported |
| send file | native |
