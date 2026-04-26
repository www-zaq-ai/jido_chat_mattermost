# LLM Usage Rules for Jido Chat Mattermost

`jido_chat_mattermost` adapts Mattermost REST and WebSocket behavior to the
`Jido.Chat.Adapter` contract.

## Working Rules

- Keep shared chat behavior in `Jido.Chat.Adapter` callbacks.
- Keep external-service tests tagged and excluded by default.
- Do not commit `.env` or token values.
- Preserve the adapter boundary; runtime supervision belongs in `jido_messaging`.
- Run `mix test`, `mix quality`, and `mix coveralls` before release work.
